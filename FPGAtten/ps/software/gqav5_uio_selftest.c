#define _POSIX_C_SOURCE 200809L

#include "gqav5_csr.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define PL_DDR_MAP_BYTES 0x10000000u
#define Q_BASE 0x00000000u
#define K_BASE 0x04000000u
#define V_BASE 0x05000000u
#define O_BASE 0x06000000u
#define Q_HEADS 32u
#define KV_HEADS 8u
#define HEAD_DIM 128u
#define CONTEXT_TOKENS 2u
#define QUERY_TOKEN 1u
#define MAX_REGIONS (Q_HEADS * 2u + KV_HEADS * CONTEXT_TOKENS * 2u)
#define BOARD_LOCK_PATH "/run/lock/fpgatten/board.lock"
#define MAX_ERROR_LIMIT 0.020
#define MAE_LIMIT 0.005

/* The routed Z19-P image uses the direct-only packed decode path.  A causal
 * fixture must therefore target the final token in its context window. */
_Static_assert(QUERY_TOKEN + 1u == CONTEXT_TOKENS,
               "board fixture must target the final causal query");

static volatile sig_atomic_t stop_signal;

struct saved_region {
    uint32_t offset;
    uint32_t size;
    uint8_t *data;
};

static void request_stop(int signal_number)
{
    stop_signal = signal_number;
}

static void sleep_one_ms(void)
{
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000L};
    (void)nanosleep(&delay, NULL);
}

static uint16_t float_to_bf16_rne(float value)
{
    union {
        float fp32;
        uint32_t bits;
    } encoded = {.fp32 = value};
    uint32_t rounded = encoded.bits + 0x7fffu + ((encoded.bits >> 16) & 1u);
    return (uint16_t)(rounded >> 16);
}

static float q_value(uint32_t q_head, uint32_t dimension)
{
    if ((dimension & 15u) != 0u)
        return 0.0f;
    return 0.5f + 0.25f * (float)(q_head & 3u);
}

static float k_value(uint32_t kv_head, uint32_t token, uint32_t dimension)
{
    float tile;
    float amplitude;
    float value;

    if ((dimension & 15u) != 0u)
        return 0.0f;
    tile = (float)(dimension / 16u + 1u);
    amplitude = 0.5f + 0.125f * (float)kv_head;
    value = tile * amplitude * 0.25f;
    if (token == 0u)
        return value;
    if (token == 1u)
        return -value;
    return 4.0f * value;
}

static float v_value(uint32_t kv_head, uint32_t token, uint32_t dimension)
{
    float tile = (float)(dimension / 16u);
    float lane = (float)(dimension & 15u);

    if (token == 0u)
        return 0.75f + (float)kv_head / 8.0f
               + tile / 16.0f + lane / 32.0f;
    if (token == 1u)
        return -0.50f + (float)kv_head / 16.0f
               - tile / 32.0f - lane / 32.0f;
    return 8.0f + (float)kv_head + tile / 4.0f + lane / 8.0f;
}

static double expected_value(uint32_t q_head, uint32_t dimension)
{
    uint32_t kv_head = q_head / 4u;
    double q_amplitude = 0.5 + 0.25 * (double)(q_head & 3u);
    double k_amplitude = 0.5 + 0.125 * (double)kv_head;
    double score = 9.0 * q_amplitude * k_amplitude;
    double probability = 1.0 / (1.0 + exp(-2.0 * score / sqrt(128.0)));
    double value0 = (double)v_value(kv_head, 0u, dimension);
    double value1 = (double)v_value(kv_head, 1u, dimension);

    return probability * value0 + (1.0 - probability) * value1;
}

static int model_self_test(void)
{
    double first = expected_value(0u, 0u);
    double last = expected_value(31u, 127u);

    if (float_to_bf16_rne(1.0f) != 0x3f80u
        || float_to_bf16_rne(-0.5f) != 0xbf00u
        || !(first > 0.0 && first < 0.75)
        || !(last > first && last < 8.0)) {
        fprintf(stderr, "FPGAtten numerical model self-test failed\n");
        return 1;
    }
    printf("PASS: FPGAtten userspace numerical model first=%.8f last=%.8f\n",
           first, last);
    return 0;
}

static int acquire_board_lock(void)
{
    struct flock lock = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 0,
    };
    int fd = open(BOARD_LOCK_PATH, O_RDWR | O_CREAT | O_CLOEXEC, 0600);

    if (fd < 0 || fcntl(fd, F_SETLK, &lock) != 0) {
        if (fd >= 0)
            close(fd);
        return -1;
    }
    return fd;
}

static int lock_pl_ddr(int fd)
{
    struct flock lock = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 0,
    };
    return fcntl(fd, F_SETLK, &lock);
}

static int save_region(volatile uint8_t *ddr, struct saved_region *region,
                       uint32_t offset, uint32_t size)
{
    region->data = malloc(size);
    if (region->data == NULL)
        return -1;
    region->offset = offset;
    region->size = size;
    for (uint32_t index = 0; index < size; ++index)
        region->data[index] = ddr[offset + index];
    return stop_signal == 0 ? 0 : -1;
}

static int restore_regions(volatile uint8_t *ddr,
                           struct saved_region *regions, size_t count)
{
    int result = 0;

    for (size_t region = 0; region < count; ++region) {
        if (regions[region].data == NULL)
            continue;
        for (uint32_t index = 0; index < regions[region].size; ++index)
            ddr[regions[region].offset + index] = regions[region].data[index];
    }
    __sync_synchronize();
    for (size_t region = 0; region < count; ++region) {
        if (regions[region].data == NULL)
            continue;
        for (uint32_t index = 0; index < regions[region].size; ++index) {
            if (ddr[regions[region].offset + index]
                != regions[region].data[index]) {
                fprintf(stderr, "restore verification failed region=%zu byte=%" PRIu32 "\n",
                        region, index);
                result = -1;
                break;
            }
        }
        free(regions[region].data);
        regions[region].data = NULL;
    }
    return result;
}

static void write_bf16_row(volatile uint8_t *ddr, uint32_t offset,
                           uint32_t head, uint32_t token, int operand)
{
    volatile uint16_t *row = (volatile uint16_t *)(ddr + offset);

    for (uint32_t dimension = 0; dimension < HEAD_DIM; ++dimension) {
        float value;
        if (operand == 0)
            value = q_value(head, dimension);
        else if (operand == 1)
            value = k_value(head, token, dimension);
        else
            value = v_value(head, token, dimension);
        row[dimension] = float_to_bf16_rne(value);
    }
}

static int quiesce_gqa(volatile void *csr)
{
    gqav5_csr_write(csr, GQAV5_CSR_CONTROL, GQAV5_CONTROL_SOFT_RESET);
    for (unsigned int millisecond = 0; millisecond < 1000u; ++millisecond) {
        if ((gqav5_csr_read(csr, GQAV5_CSR_STATUS) & GQAV5_STATUS_BUSY) == 0u)
            return 0;
        sleep_one_ms();
    }
    return -1;
}

static int enable_uio_interrupt(int uio_fd)
{
    uint32_t enable = 1u;
    ssize_t transferred = write(uio_fd, &enable, sizeof(enable));

    if (transferred != (ssize_t)sizeof(enable)) {
        fprintf(stderr, "failed to enable UIO IRQ: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int wait_for_interrupt(int uio_fd)
{
    uint32_t event_count;
    struct pollfd request = {.fd = uio_fd, .events = POLLIN, .revents = 0};
    ssize_t transferred;
    int poll_result;

    poll_result = poll(&request, 1, 30000);
    if (poll_result <= 0 || (request.revents & POLLIN) == 0) {
        fprintf(stderr, "FPGAtten IRQ timeout or poll failure\n");
        return -1;
    }
    transferred = read(uio_fd, &event_count, sizeof(event_count));
    if (transferred != (ssize_t)sizeof(event_count)) {
        fprintf(stderr, "failed to acknowledge UIO IRQ: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static float read_fp32(volatile uint8_t *ddr, uint32_t offset)
{
    union {
        uint32_t bits;
        float fp32;
    } value;

    value.bits = *(volatile uint32_t *)(ddr + offset);
    return value.fp32;
}

static void program_job(volatile void *csr)
{
    gqav5_csr_write(csr, GQAV5_CSR_CONTEXT_TOKENS, CONTEXT_TOKENS);
    gqav5_csr_write(csr, GQAV5_CSR_QUERY_CONFIG,
                    gqav5_query_config(QUERY_TOKEN, 1u, 1u));
    gqav5_csr_write(csr, GQAV5_CSR_Q_BASE, Q_BASE);
    gqav5_csr_write(csr, GQAV5_CSR_K_BASE, K_BASE);
    gqav5_csr_write(csr, GQAV5_CSR_V_BASE, V_BASE);
    gqav5_csr_write(csr, GQAV5_CSR_O_BASE, O_BASE);
    gqav5_csr_write(csr, GQAV5_CSR_Q_HEAD_STRIDE,
                    GQAV5_BF16_HEAD_STRIDE_8192);
    gqav5_csr_write(csr, GQAV5_CSR_Q_TOKEN_STRIDE,
                    GQAV5_BF16_TOKEN_STRIDE);
    gqav5_csr_write(csr, GQAV5_CSR_K_HEAD_STRIDE,
                    GQAV5_BF16_HEAD_STRIDE_8192);
    gqav5_csr_write(csr, GQAV5_CSR_K_TOKEN_STRIDE,
                    GQAV5_BF16_TOKEN_STRIDE);
    gqav5_csr_write(csr, GQAV5_CSR_V_HEAD_STRIDE,
                    GQAV5_BF16_HEAD_STRIDE_8192);
    gqav5_csr_write(csr, GQAV5_CSR_V_TOKEN_STRIDE,
                    GQAV5_BF16_TOKEN_STRIDE);
    gqav5_csr_write(csr, GQAV5_CSR_O_HEAD_STRIDE,
                    GQAV5_FP32_HEAD_STRIDE_8192);
    gqav5_csr_write(csr, GQAV5_CSR_O_TOKEN_STRIDE,
                    GQAV5_FP32_TOKEN_STRIDE);
    gqav5_csr_write(csr, GQAV5_CSR_OPT_CTRL, GQAV5_OPT_QK_REUSE);
}

static int run_hardware_test(const char *gqa_uio, const char *ddr_uio)
{
    struct saved_region regions[MAX_REGIONS] = {{0u, 0u, NULL}};
    struct sigaction action;
    volatile uint8_t *ddr = MAP_FAILED;
    volatile void *csr = MAP_FAILED;
    size_t region_count = 0;
    int board_lock_fd = -1;
    int gqa_fd = -1;
    int ddr_fd = -1;
    int result = 1;
    double absolute_error_sum = 0.0;
    double maximum_error = 0.0;
    uint32_t compared = 0;

    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGTERM, &action, NULL);

    board_lock_fd = acquire_board_lock();
    if (board_lock_fd < 0) {
        fprintf(stderr, "another FPGAtten board test is active\n");
        goto cleanup;
    }
    gqa_fd = open(gqa_uio, O_RDWR | O_CLOEXEC);
    ddr_fd = open(ddr_uio, O_RDWR | O_CLOEXEC);
    if (gqa_fd < 0 || ddr_fd < 0 || lock_pl_ddr(ddr_fd) != 0) {
        fprintf(stderr, "failed to open/lock UIO devices: %s\n", strerror(errno));
        goto cleanup;
    }
    csr = mmap(NULL, GQAV5_CSR_MAP_BYTES, PROT_READ | PROT_WRITE,
               MAP_SHARED, gqa_fd, 0);
    ddr = mmap(NULL, PL_DDR_MAP_BYTES, PROT_READ | PROT_WRITE,
               MAP_SHARED, ddr_fd, 0);
    if (csr == MAP_FAILED || ddr == MAP_FAILED) {
        fprintf(stderr, "UIO mmap failed: %s\n", strerror(errno));
        goto cleanup;
    }
    if (quiesce_gqa(csr) != 0
        || gqav5_csr_read(csr, GQAV5_CSR_VERSION) != GQAV5_VERSION_VALUE
        || gqav5_csr_read(csr, GQAV5_CSR_BUILD_ID) != GQAV5_BUILD_ID_VALUE) {
        fprintf(stderr, "FPGAtten CSR identity/quiesce check failed\n");
        goto cleanup;
    }

    for (uint32_t q_head = 0; q_head < Q_HEADS; ++q_head) {
        uint32_t q_offset = Q_BASE + q_head * GQAV5_BF16_HEAD_STRIDE_8192
                            + QUERY_TOKEN * GQAV5_BF16_TOKEN_STRIDE;
        uint32_t o_offset = O_BASE + q_head * GQAV5_FP32_HEAD_STRIDE_8192
                            + QUERY_TOKEN * GQAV5_FP32_TOKEN_STRIDE;
        if (save_region(ddr, &regions[region_count++], q_offset,
                        GQAV5_BF16_TOKEN_STRIDE) != 0
            || save_region(ddr, &regions[region_count++], o_offset,
                           GQAV5_FP32_TOKEN_STRIDE) != 0)
            goto cleanup;
        write_bf16_row(ddr, q_offset, q_head, QUERY_TOKEN, 0);
        for (uint32_t byte = 0; byte < GQAV5_FP32_TOKEN_STRIDE; ++byte)
            ddr[o_offset + byte] = 0u;
    }
    for (uint32_t kv_head = 0; kv_head < KV_HEADS; ++kv_head) {
        for (uint32_t token = 0; token < CONTEXT_TOKENS; ++token) {
            uint32_t k_offset = K_BASE + kv_head * GQAV5_BF16_HEAD_STRIDE_8192
                                + token * GQAV5_BF16_TOKEN_STRIDE;
            uint32_t v_offset = V_BASE + kv_head * GQAV5_BF16_HEAD_STRIDE_8192
                                + token * GQAV5_BF16_TOKEN_STRIDE;
            if (save_region(ddr, &regions[region_count++], k_offset,
                            GQAV5_BF16_TOKEN_STRIDE) != 0
                || save_region(ddr, &regions[region_count++], v_offset,
                               GQAV5_BF16_TOKEN_STRIDE) != 0)
                goto cleanup;
            write_bf16_row(ddr, k_offset, kv_head, token, 1);
            write_bf16_row(ddr, v_offset, kv_head, token, 2);
        }
    }
    __sync_synchronize();

    program_job(csr);
    if (enable_uio_interrupt(gqa_fd) != 0)
        goto cleanup;
    gqav5_csr_write(csr, GQAV5_CSR_CONTROL, GQAV5_CONTROL_START);
    if (wait_for_interrupt(gqa_fd) != 0)
        goto cleanup;
    {
        uint32_t status = gqav5_csr_read(csr, GQAV5_CSR_STATUS);
        if ((status & (GQAV5_STATUS_DONE | GQAV5_STATUS_IRQ))
              != (GQAV5_STATUS_DONE | GQAV5_STATUS_IRQ)
            || (status & (GQAV5_STATUS_BUSY | GQAV5_STATUS_ERROR)) != 0u) {
        fprintf(stderr, "FPGAtten completion status is 0x%08" PRIx32 "\n", status);
            goto cleanup;
        }
    }

    __sync_synchronize();
    for (uint32_t q_head = 0; q_head < Q_HEADS; ++q_head) {
        uint32_t o_offset = O_BASE + q_head * GQAV5_FP32_HEAD_STRIDE_8192
                            + QUERY_TOKEN * GQAV5_FP32_TOKEN_STRIDE;
        for (uint32_t dimension = 0; dimension < HEAD_DIM; ++dimension) {
            double expected = expected_value(q_head, dimension);
            double actual = (double)read_fp32(ddr, o_offset + dimension * 4u);
            double error = fabs(actual - expected);
            absolute_error_sum += error;
            if (error > maximum_error)
                maximum_error = error;
            ++compared;
        }
    }
    if (maximum_error > MAX_ERROR_LIMIT
        || absolute_error_sum / (double)compared > MAE_LIMIT) {
        fprintf(stderr, "numerical mismatch max=%.8f mae=%.8f\n",
                maximum_error, absolute_error_sum / (double)compared);
        goto cleanup;
    }

    printf("PASS: FPGAtten Z19-P nonzero attention max=%.8f mae=%.8f cycles=%" PRIu32
           " overlap=%" PRIu32 " qk=%" PRIu32 " pv=%" PRIu32 "\n",
           maximum_error, absolute_error_sum / (double)compared,
           gqav5_csr_read(csr, GQAV5_CSR_TOTAL_CYCLES),
           gqav5_csr_read(csr, GQAV5_CSR_OVERLAP_CYCLES),
           gqav5_csr_read(csr, GQAV5_CSR_CORE_QK),
           gqav5_csr_read(csr, GQAV5_CSR_CORE_PV));
    result = 0;

cleanup:
    if (csr != MAP_FAILED)
        (void)quiesce_gqa(csr);
    if (ddr != MAP_FAILED && restore_regions(ddr, regions, region_count) != 0)
        result = 1;
    if (ddr != MAP_FAILED)
        (void)munmap((void *)ddr, PL_DDR_MAP_BYTES);
    if (csr != MAP_FAILED)
        (void)munmap((void *)csr, GQAV5_CSR_MAP_BYTES);
    if (ddr_fd >= 0)
        close(ddr_fd);
    if (gqa_fd >= 0)
        close(gqa_fd);
    if (board_lock_fd >= 0)
        close(board_lock_fd);
    return result;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--model-self-test") == 0)
        return model_self_test();
    if (argc != 3) {
        fprintf(stderr, "usage: %s GQA_UIO PL_DDR_UIO\n", argv[0]);
        fprintf(stderr, "       %s --model-self-test\n", argv[0]);
        return 2;
    }
    return run_hardware_test(argv[1], argv[2]);
}
