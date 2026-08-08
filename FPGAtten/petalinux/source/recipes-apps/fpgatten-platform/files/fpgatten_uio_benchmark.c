#define _POSIX_C_SOURCE 200809L

#include "fpgatten_csr.h"

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
#define MAX_CONTEXT_TOKENS 8192u
#define ARRAY_MACS_PER_ACTIVE_CYCLE 64u
#define DEFAULT_CLOCK_HZ 230000000ull
#define DEFAULT_DMA_CLOCK_HZ 300000000ull
#define BOARD_LOCK_PATH "/run/lock/fpgatten/board.lock"

static const uint32_t default_contexts[] = {
    1u, 2u, 3u, 4u, 7u, 8u, 15u, 16u, 17u, 31u,
    32u, 33u, 64u, 128u, 256u, 512u, 1024u, 2048u,
    4096u, 8192u
};

static volatile sig_atomic_t stop_signal;

struct saved_region {
    uint32_t offset;
    uint32_t size;
    uint8_t *data;
};

struct run_metrics {
    uint32_t cycles;
    uint32_t overlap_cycles;
    uint32_t qk_pv_overlap_cycles;
    uint32_t dma_lane_overlap_cycles;
    uint32_t load_stall_cycles;
    uint32_t core_total_cycles;
    uint32_t qk_cycles;
    uint32_t softmax_cycles;
    uint32_t pv_cycles;
    uint32_t dma_stall_cycles;
    uint32_t dma_ar_count;
    uint32_t dma_read_beats;
    uint32_t dma_ar_wait_cycles;
    uint32_t dma_r_gap_cycles;
    uint32_t dma_r_backpressure_cycles;
    uint32_t dma_bank_wait_cycles;
    uint32_t dma_emit_wait_cycles;
    uint32_t dma_max_outstanding;
    uint32_t dma_boundary_splits;
    uint32_t kv_cache_hits;
    uint32_t kv_cache_misses;
    uint32_t prefetch_issues;
    uint32_t blocks_total;
    uint32_t blocks_skipped;
    double maximum_error;
    double mean_absolute_error;
    uint32_t violations;
};

struct context_summary {
    uint32_t context;
    uint32_t repeats;
    uint64_t cycle_sum;
    uint32_t cycle_min;
    uint32_t cycle_max;
    uint64_t overlap_sum;
    uint64_t qk_pv_overlap_sum;
    uint64_t dma_lane_overlap_sum;
    uint64_t qk_cycle_sum;
    uint64_t softmax_cycle_sum;
    uint64_t pv_cycle_sum;
    uint64_t load_stall_sum;
    uint64_t dma_stall_sum;
    uint64_t dma_ar_count_sum;
    uint64_t dma_read_beats_sum;
    uint64_t dma_ar_wait_sum;
    uint64_t dma_r_gap_sum;
    uint64_t dma_r_backpressure_sum;
    uint64_t dma_bank_wait_sum;
    uint64_t dma_emit_wait_sum;
    uint32_t dma_max_outstanding;
    uint64_t dma_boundary_split_sum;
    uint64_t kv_cache_hit_sum;
    uint64_t kv_cache_miss_sum;
    uint64_t prefetch_issue_sum;
    double maximum_error;
    double mean_absolute_error_sum;
    uint64_t violations;
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

static double expected_value(uint32_t context, uint32_t q_head,
                             uint32_t dimension)
{
    uint32_t kv_head = q_head / 4u;
    double q_amplitude = 0.5 + 0.25 * (double)(q_head & 3u);
    double k_amplitude = 0.5 + 0.125 * (double)kv_head;
    double base_score = 9.0 * q_amplitude * k_amplitude / sqrt(128.0);
    double maximum_score = context > 2u ? 4.0 * base_score : base_score;
    double weight0 = exp(base_score - maximum_score);
    double weight1 = context > 1u ? exp(-base_score - maximum_score) : 0.0;
    double weight2 = context > 2u
        ? (double)(context - 2u) * exp(4.0 * base_score - maximum_score)
        : 0.0;
    double denominator = weight0 + weight1 + weight2;
    double numerator = weight0 * (double)v_value(kv_head, 0u, dimension);

    if (context > 1u)
        numerator += weight1 * (double)v_value(kv_head, 1u, dimension);
    if (context > 2u)
        numerator += weight2 * (double)v_value(kv_head, 2u, dimension);
    return numerator / denominator;
}

static int model_self_test(void)
{
    const uint32_t contexts[] = {1u, 2u, 17u, 1024u, 8192u};

    if (float_to_bf16_rne(1.0f) != 0x3f80u
        || float_to_bf16_rne(-0.5f) != 0xbf00u)
        return 1;
    for (size_t index = 0; index < sizeof(contexts) / sizeof(contexts[0]);
         ++index) {
        double first = expected_value(contexts[index], 0u, 0u);
        double last = expected_value(contexts[index], 31u, 127u);
        if (!isfinite(first) || !isfinite(last) || first >= last)
            return 1;
    }
    printf("PASS: FPGAtten benchmark model contexts=1,2,17,1024,8192\n");
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

static int save_benchmark_regions(volatile uint8_t *ddr,
                                  const uint32_t *contexts,
                                  size_t context_count,
                                  struct saved_region **regions_o,
                                  size_t *region_count_o)
{
    size_t capacity = 2u * KV_HEADS + 2u * Q_HEADS * context_count;
    struct saved_region *regions = calloc(capacity, sizeof(*regions));
    uint32_t maximum_context = contexts[context_count - 1u];
    size_t count = 0;

    if (regions == NULL)
        return -1;
    for (uint32_t kv_head = 0; kv_head < KV_HEADS; ++kv_head) {
        uint32_t bytes = maximum_context * FPGATTEN_BF16_TOKEN_STRIDE;
        if (save_region(ddr, &regions[count++],
                        K_BASE + kv_head * FPGATTEN_BF16_HEAD_STRIDE_8192,
                        bytes) != 0
            || save_region(ddr, &regions[count++],
                           V_BASE + kv_head * FPGATTEN_BF16_HEAD_STRIDE_8192,
                           bytes) != 0)
            goto error;
    }
    for (size_t context_index = 0; context_index < context_count;
         ++context_index) {
        uint32_t query_token = contexts[context_index] - 1u;
        for (uint32_t q_head = 0; q_head < Q_HEADS; ++q_head) {
            if (save_region(ddr, &regions[count++],
                            Q_BASE + q_head * FPGATTEN_BF16_HEAD_STRIDE_8192
                                + query_token * FPGATTEN_BF16_TOKEN_STRIDE,
                            FPGATTEN_BF16_TOKEN_STRIDE) != 0
                || save_region(ddr, &regions[count++],
                               O_BASE + q_head * FPGATTEN_FP32_HEAD_STRIDE_8192
                                   + query_token * FPGATTEN_FP32_TOKEN_STRIDE,
                               FPGATTEN_FP32_TOKEN_STRIDE) != 0)
                goto error;
        }
    }
    *regions_o = regions;
    *region_count_o = count;
    return 0;

error:
    (void)restore_regions(ddr, regions, count);
    free(regions);
    return -1;
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

static void initialize_fixture(volatile uint8_t *ddr,
                               const uint32_t *contexts,
                               size_t context_count)
{
    uint32_t maximum_context = contexts[context_count - 1u];

    printf("PREP: initialize K/V through context=%" PRIu32 "\n",
           maximum_context);
    for (uint32_t kv_head = 0; kv_head < KV_HEADS; ++kv_head) {
        for (uint32_t token = 0; token < maximum_context; ++token) {
            write_bf16_row(ddr,
                           K_BASE + kv_head * FPGATTEN_BF16_HEAD_STRIDE_8192
                               + token * FPGATTEN_BF16_TOKEN_STRIDE,
                           kv_head, token, 1);
            write_bf16_row(ddr,
                           V_BASE + kv_head * FPGATTEN_BF16_HEAD_STRIDE_8192
                               + token * FPGATTEN_BF16_TOKEN_STRIDE,
                           kv_head, token, 2);
        }
        printf("PREP: kv_head=%" PRIu32 "/%u complete\n",
               kv_head + 1u, KV_HEADS);
        fflush(stdout);
    }
    for (size_t context_index = 0; context_index < context_count;
         ++context_index) {
        uint32_t query_token = contexts[context_index] - 1u;
        for (uint32_t q_head = 0; q_head < Q_HEADS; ++q_head) {
            write_bf16_row(ddr,
                           Q_BASE + q_head * FPGATTEN_BF16_HEAD_STRIDE_8192
                               + query_token * FPGATTEN_BF16_TOKEN_STRIDE,
                           q_head, query_token, 0);
        }
    }
    __sync_synchronize();
}

static void clear_output_rows(volatile uint8_t *ddr, uint32_t query_token)
{
    for (uint32_t q_head = 0; q_head < Q_HEADS; ++q_head) {
        uint32_t offset = O_BASE + q_head * FPGATTEN_FP32_HEAD_STRIDE_8192
                          + query_token * FPGATTEN_FP32_TOKEN_STRIDE;
        for (uint32_t byte = 0; byte < FPGATTEN_FP32_TOKEN_STRIDE; ++byte)
            ddr[offset + byte] = 0u;
    }
    __sync_synchronize();
}

static int quiesce_gqa(volatile void *csr)
{
    fpgatten_csr_write(csr, FPGATTEN_CSR_CONTROL, FPGATTEN_CONTROL_SOFT_RESET);
    for (unsigned int millisecond = 0; millisecond < 1000u; ++millisecond) {
        if ((fpgatten_csr_read(csr, FPGATTEN_CSR_STATUS) & FPGATTEN_STATUS_BUSY) == 0u)
            return 0;
        sleep_one_ms();
    }
    return -1;
}

static int enable_uio_interrupt(int uio_fd)
{
    uint32_t enable = 1u;
    return write(uio_fd, &enable, sizeof(enable)) == (ssize_t)sizeof(enable)
        ? 0 : -1;
}

static int wait_for_interrupt(int uio_fd)
{
    uint32_t event_count;
    struct pollfd request = {.fd = uio_fd, .events = POLLIN, .revents = 0};
    int poll_result = poll(&request, 1, 30000);

    if (poll_result <= 0 || (request.revents & POLLIN) == 0)
        return -1;
    return read(uio_fd, &event_count, sizeof(event_count))
               == (ssize_t)sizeof(event_count)
        ? 0 : -1;
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

/*
 * 当前板级 AXI-Lite 路径对连续的相邻 CSR 读取较敏感。单独的非内联读取
 * 配合一次很短的间隔可避免 CPU 将多个性能计数器访问紧密压在一起。
 * 该间隔发生在硬件任务完成、周期计数锁存之后，不计入 token/s。
 */
__attribute__((noinline))
static uint32_t read_counter(volatile void *csr, uint32_t offset)
{
    uint32_t value = fpgatten_csr_read(csr, offset);

    __sync_synchronize();
    sleep_one_ms();
    return value;
}

static void program_job(volatile void *csr, uint32_t context)
{
    uint32_t query_token = context - 1u;

    fpgatten_csr_write(csr, FPGATTEN_CSR_CONTEXT_TOKENS, context);
    fpgatten_csr_write(csr, FPGATTEN_CSR_QUERY_CONFIG,
                    fpgatten_query_config(query_token, 1u, 1u));
    fpgatten_csr_write(csr, FPGATTEN_CSR_Q_BASE, Q_BASE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_K_BASE, K_BASE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_V_BASE, V_BASE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_O_BASE, O_BASE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_Q_HEAD_STRIDE,
                    FPGATTEN_BF16_HEAD_STRIDE_8192);
    fpgatten_csr_write(csr, FPGATTEN_CSR_Q_TOKEN_STRIDE,
                    FPGATTEN_BF16_TOKEN_STRIDE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_K_HEAD_STRIDE,
                    FPGATTEN_BF16_HEAD_STRIDE_8192);
    fpgatten_csr_write(csr, FPGATTEN_CSR_K_TOKEN_STRIDE,
                    FPGATTEN_BF16_TOKEN_STRIDE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_V_HEAD_STRIDE,
                    FPGATTEN_BF16_HEAD_STRIDE_8192);
    fpgatten_csr_write(csr, FPGATTEN_CSR_V_TOKEN_STRIDE,
                    FPGATTEN_BF16_TOKEN_STRIDE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_O_HEAD_STRIDE,
                    FPGATTEN_FP32_HEAD_STRIDE_8192);
    fpgatten_csr_write(csr, FPGATTEN_CSR_O_TOKEN_STRIDE,
                    FPGATTEN_FP32_TOKEN_STRIDE);
    fpgatten_csr_write(csr, FPGATTEN_CSR_OPT_CTRL, FPGATTEN_OPT_QK_REUSE);
}

static void verify_output(volatile uint8_t *ddr, uint32_t context,
                          struct run_metrics *metrics)
{
    uint32_t query_token = context - 1u;
    double absolute_error_sum = 0.0;
    uint32_t compared = 0;

    metrics->maximum_error = 0.0;
    metrics->violations = 0u;
    for (uint32_t q_head = 0; q_head < Q_HEADS; ++q_head) {
        uint32_t offset = O_BASE + q_head * FPGATTEN_FP32_HEAD_STRIDE_8192
                          + query_token * FPGATTEN_FP32_TOKEN_STRIDE;
        for (uint32_t dimension = 0; dimension < HEAD_DIM; ++dimension) {
            double expected = expected_value(context, q_head, dimension);
            double actual = (double)read_fp32(
                ddr, offset + dimension * (uint32_t)sizeof(uint32_t));
            double error = fabs(actual - expected);
            double tolerance = fmax(0.020, 0.002 * fabs(expected));

            if (!isfinite(actual) || error > tolerance)
                ++metrics->violations;
            if (error > metrics->maximum_error)
                metrics->maximum_error = error;
            absolute_error_sum += error;
            ++compared;
        }
    }
    metrics->mean_absolute_error = absolute_error_sum / (double)compared;
}

static int run_one(volatile void *csr, volatile uint8_t *ddr, int gqa_fd,
                   uint32_t context, int verify, struct run_metrics *metrics)
{
    uint32_t status;

    memset(metrics, 0, sizeof(*metrics));
    printf("RUN: context=%" PRIu32 " stage=quiesce\n", context);
    fflush(stdout);
    if (quiesce_gqa(csr) != 0)
        return -1;
    printf("RUN: context=%" PRIu32 " stage=clear_output\n", context);
    fflush(stdout);
    clear_output_rows(ddr, context - 1u);
    printf("RUN: context=%" PRIu32 " stage=program\n", context);
    fflush(stdout);
    program_job(csr, context);
    printf("RUN: context=%" PRIu32 " stage=interrupt_enable\n", context);
    fflush(stdout);
    if (enable_uio_interrupt(gqa_fd) != 0)
        return -1;
    printf("RUN: context=%" PRIu32 " stage=start\n", context);
    fflush(stdout);
    fpgatten_csr_write(csr, FPGATTEN_CSR_CONTROL, FPGATTEN_CONTROL_START);
    printf("RUN: context=%" PRIu32 " stage=wait\n", context);
    fflush(stdout);
    if (wait_for_interrupt(gqa_fd) != 0) {
        uint32_t wait_status =
            fpgatten_csr_read(csr, FPGATTEN_CSR_STATUS);
        uint32_t wait_total_cycles =
            fpgatten_csr_read(csr, FPGATTEN_CSR_TOTAL_CYCLES);
        uint32_t wait_core_cycles =
            fpgatten_csr_read(csr, FPGATTEN_CSR_CORE_TOTAL);

        fprintf(stderr,
                "hardware interrupt wait failed context=%" PRIu32
                " raw=0x%08" PRIx32
                " done=%u irq=%u busy=%u error=%u"
                " total_cycles=%" PRIu32 " core_total=%" PRIu32 "\n",
                context, wait_status,
                (wait_status & FPGATTEN_STATUS_DONE) != 0u ? 1u : 0u,
                (wait_status & FPGATTEN_STATUS_IRQ) != 0u ? 1u : 0u,
                (wait_status & FPGATTEN_STATUS_BUSY) != 0u ? 1u : 0u,
                (wait_status & FPGATTEN_STATUS_ERROR) != 0u ? 1u : 0u,
                wait_total_cycles, wait_core_cycles);
        return -1;
    }
    printf("RUN: context=%" PRIu32 " stage=read_counters\n", context);
    fflush(stdout);
    status = fpgatten_csr_read(csr, FPGATTEN_CSR_STATUS);
    if ((status & (FPGATTEN_STATUS_DONE | FPGATTEN_STATUS_IRQ))
          != (FPGATTEN_STATUS_DONE | FPGATTEN_STATUS_IRQ)
        || (status & (FPGATTEN_STATUS_BUSY | FPGATTEN_STATUS_ERROR)) != 0u) {
        fprintf(stderr,
                "hardware status invalid context=%" PRIu32
                " raw=0x%08" PRIx32
                " done=%u irq=%u busy=%u error=%u\n",
                context, status,
                (status & FPGATTEN_STATUS_DONE) != 0u ? 1u : 0u,
                (status & FPGATTEN_STATUS_IRQ) != 0u ? 1u : 0u,
                (status & FPGATTEN_STATUS_BUSY) != 0u ? 1u : 0u,
                (status & FPGATTEN_STATUS_ERROR) != 0u ? 1u : 0u);
        return -1;
    }

    metrics->cycles = read_counter(csr, FPGATTEN_CSR_TOTAL_CYCLES);
    metrics->overlap_cycles = read_counter(csr, FPGATTEN_CSR_OVERLAP_CYCLES);
    metrics->qk_pv_overlap_cycles =
        read_counter(csr, FPGATTEN_CSR_QK_PV_OVERLAP);
    metrics->dma_lane_overlap_cycles =
        read_counter(csr, FPGATTEN_CSR_DMA_LANE_OVERLAP);
    metrics->load_stall_cycles =
        read_counter(csr, FPGATTEN_CSR_LOAD_STALL_CYCLES);
    metrics->core_total_cycles =
        read_counter(csr, FPGATTEN_CSR_CORE_TOTAL);
    metrics->qk_cycles = read_counter(csr, FPGATTEN_CSR_CORE_QK);
    metrics->softmax_cycles = read_counter(csr, FPGATTEN_CSR_CORE_SOFTMAX);
    metrics->pv_cycles = read_counter(csr, FPGATTEN_CSR_CORE_PV);
    metrics->dma_stall_cycles =
        read_counter(csr, FPGATTEN_CSR_CORE_DMA_STALL);
    metrics->dma_ar_count = read_counter(csr, FPGATTEN_CSR_DMA_AR_COUNT);
    metrics->dma_read_beats =
        read_counter(csr, FPGATTEN_CSR_DMA_READ_BEATS);
    metrics->dma_ar_wait_cycles =
        read_counter(csr, FPGATTEN_CSR_DMA_AR_WAIT);
    metrics->dma_r_gap_cycles =
        read_counter(csr, FPGATTEN_CSR_DMA_R_GAP);
    metrics->dma_r_backpressure_cycles =
        read_counter(csr, FPGATTEN_CSR_DMA_R_BACKPRESSURE);
    metrics->dma_bank_wait_cycles =
        read_counter(csr, FPGATTEN_CSR_DMA_BANK_WAIT);
    metrics->dma_emit_wait_cycles =
        read_counter(csr, FPGATTEN_CSR_DMA_EMIT_WAIT);
    metrics->dma_max_outstanding =
        read_counter(csr, FPGATTEN_CSR_DMA_MAX_OUTSTANDING);
    metrics->dma_boundary_splits =
        read_counter(csr, FPGATTEN_CSR_DMA_4K_SPLITS);
    metrics->kv_cache_hits =
        read_counter(csr, FPGATTEN_CSR_KV_CACHE_HITS);
    metrics->kv_cache_misses =
        read_counter(csr, FPGATTEN_CSR_KV_CACHE_MISSES);
    metrics->prefetch_issues =
        read_counter(csr, FPGATTEN_CSR_PREFETCH_ISSUES);
    metrics->blocks_total = read_counter(csr, FPGATTEN_CSR_PV_BLOCK_TOTAL);
    metrics->blocks_skipped =
        read_counter(csr, FPGATTEN_CSR_PV_BLOCK_SKIPPED);
    if (metrics->cycles == 0u) {
        fprintf(stderr, "hardware total cycles zero context=%" PRIu32 "\n",
                context);
        return -1;
    }
    if (verify)
        verify_output(ddr, context, metrics);
    return stop_signal == 0 ? 0 : -1;
}

static int compare_u32(const void *left, const void *right)
{
    uint32_t a = *(const uint32_t *)left;
    uint32_t b = *(const uint32_t *)right;
    return a < b ? -1 : a > b ? 1 : 0;
}

static int parse_u32(const char *text, uint32_t minimum, uint32_t maximum,
                     uint32_t *value_o)
{
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0'
        || value < minimum || value > maximum)
        return -1;
    *value_o = (uint32_t)value;
    return 0;
}

static int parse_context_list(const char *text, uint32_t **contexts_o,
                              size_t *count_o)
{
    char *copy = strdup(text);
    char *save = NULL;
    char *token;
    size_t capacity = 16u;
    size_t count = 0;
    uint32_t *contexts = malloc(capacity * sizeof(*contexts));

    if (copy == NULL || contexts == NULL) {
        free(copy);
        free(contexts);
        return -1;
    }
    token = strtok_r(copy, ",", &save);
    while (token != NULL) {
        uint32_t value;
        if (parse_u32(token, 1u, MAX_CONTEXT_TOKENS, &value) != 0)
            goto error;
        if (count == capacity) {
            uint32_t *resized;
            capacity *= 2u;
            resized = realloc(contexts, capacity * sizeof(*contexts));
            if (resized == NULL)
                goto error;
            contexts = resized;
        }
        contexts[count++] = value;
        token = strtok_r(NULL, ",", &save);
    }
    free(copy);
    if (count == 0u) {
        free(contexts);
        return -1;
    }
    qsort(contexts, count, sizeof(*contexts), compare_u32);
    {
        size_t unique = 1u;
        for (size_t index = 1u; index < count; ++index) {
            if (contexts[index] != contexts[unique - 1u])
                contexts[unique++] = contexts[index];
        }
        count = unique;
    }
    *contexts_o = contexts;
    *count_o = count;
    return 0;

error:
    free(copy);
    free(contexts);
    return -1;
}

static void print_usage(const char *program)
{
    printf("Core clock defaults to 230000000 Hz; DMA clock defaults to 300000000 Hz.\n");
    printf("  --dma-clock-hz HZ             DMA bandwidth conversion clock\n");
    printf("用法: %s [选项] /dev/uio4 /dev/uio5\n", program);
    printf("  --contexts 1,16,17,1024,8192  指定 context 列表\n");
    printf("  --all                         测试每个 1..8192 context\n");
    printf("  --repeat N                    每个 context 重复 N 次\n");
    printf("  --clock-hz HZ                 token/s 换算时钟，默认 230000000\n");
    printf("  --no-restore                  不保存/恢复被测试占用的 PL-DDR\n");
    printf("  --skip-verify                 跳过 4096 个输出的数值对拍\n");
    printf("  --model-self-test             只测试主机数值模型\n");
}

int main(int argc, char **argv)
{
    uint32_t *contexts = NULL;
    size_t context_count = 0;
    uint32_t repeats = 1u;
    uint64_t clock_hz = DEFAULT_CLOCK_HZ;
    uint64_t dma_clock_hz = DEFAULT_DMA_CLOCK_HZ;
    int preserve = 1;
    int verify = 1;
    int model_only = 0;
    const char *devices[2] = {NULL, NULL};
    size_t device_count = 0;
    struct sigaction action;
    struct saved_region *regions = NULL;
    size_t region_count = 0;
    struct context_summary *summaries = NULL;
    volatile uint8_t *ddr = MAP_FAILED;
    volatile void *csr = MAP_FAILED;
    int board_lock_fd = -1;
    int gqa_fd = -1;
    int ddr_fd = -1;
    int result = 1;

    for (int argument = 1; argument < argc; ++argument) {
        if (strcmp(argv[argument], "--contexts") == 0) {
            if (++argument >= argc || contexts != NULL
                || parse_context_list(argv[argument], &contexts,
                                      &context_count) != 0) {
                fprintf(stderr, "非法 --contexts 参数\n");
                goto cleanup;
            }
        } else if (strcmp(argv[argument], "--all") == 0) {
            if (contexts != NULL) {
                fprintf(stderr, "--all 与 --contexts 不能同时使用\n");
                goto cleanup;
            }
            context_count = MAX_CONTEXT_TOKENS;
            contexts = malloc(context_count * sizeof(*contexts));
            if (contexts == NULL)
                goto cleanup;
            for (size_t index = 0; index < context_count; ++index)
                contexts[index] = (uint32_t)index + 1u;
        } else if (strcmp(argv[argument], "--repeat") == 0) {
            if (++argument >= argc
                || parse_u32(argv[argument], 1u, 100u, &repeats) != 0) {
                fprintf(stderr, "非法 --repeat 参数\n");
                goto cleanup;
            }
        } else if (strcmp(argv[argument], "--clock-hz") == 0) {
            char *end = NULL;
            errno = 0;
            if (++argument >= argc)
                goto cleanup;
            clock_hz = strtoull(argv[argument], &end, 0);
            if (errno != 0 || end == argv[argument] || *end != '\0'
                || clock_hz == 0u) {
                fprintf(stderr, "非法 --clock-hz 参数\n");
                goto cleanup;
            }
        } else if (strcmp(argv[argument], "--dma-clock-hz") == 0) {
            char *end = NULL;
            errno = 0;
            if (++argument >= argc)
                goto cleanup;
            dma_clock_hz = strtoull(argv[argument], &end, 0);
            if (errno != 0 || end == argv[argument] || *end != '\0'
                || dma_clock_hz == 0u) {
                fprintf(stderr, "invalid --dma-clock-hz value\n");
                goto cleanup;
            }
        } else if (strcmp(argv[argument], "--no-restore") == 0) {
            preserve = 0;
        } else if (strcmp(argv[argument], "--skip-verify") == 0) {
            verify = 0;
        } else if (strcmp(argv[argument], "--model-self-test") == 0) {
            model_only = 1;
        } else if (strcmp(argv[argument], "--help") == 0) {
            print_usage(argv[0]);
            result = 0;
            goto cleanup;
        } else if (argv[argument][0] == '-') {
            fprintf(stderr, "未知参数: %s\n", argv[argument]);
            goto cleanup;
        } else if (device_count < 2u) {
            devices[device_count++] = argv[argument];
        } else {
            fprintf(stderr, "设备参数过多\n");
            goto cleanup;
        }
    }

    if (model_only) {
        result = model_self_test();
        goto cleanup;
    }
    if (device_count != 2u) {
        print_usage(argv[0]);
        goto cleanup;
    }
    if (contexts == NULL) {
        context_count = sizeof(default_contexts) / sizeof(default_contexts[0]);
        contexts = malloc(context_count * sizeof(*contexts));
        if (contexts == NULL)
            goto cleanup;
        memcpy(contexts, default_contexts, sizeof(default_contexts));
    }
    summaries = calloc(context_count, sizeof(*summaries));
    if (summaries == NULL)
        goto cleanup;

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
    gqa_fd = open(devices[0], O_RDWR | O_CLOEXEC);
    ddr_fd = open(devices[1], O_RDWR | O_CLOEXEC);
    if (gqa_fd < 0 || ddr_fd < 0 || lock_pl_ddr(ddr_fd) != 0) {
        fprintf(stderr, "打开或锁定 UIO 失败: %s\n", strerror(errno));
        goto cleanup;
    }
    csr = mmap(NULL, FPGATTEN_CSR_MAP_BYTES, PROT_READ | PROT_WRITE,
               MAP_SHARED, gqa_fd, 0);
    ddr = mmap(NULL, PL_DDR_MAP_BYTES, PROT_READ | PROT_WRITE,
               MAP_SHARED, ddr_fd, 0);
    if (csr == MAP_FAILED || ddr == MAP_FAILED) {
        fprintf(stderr, "UIO mmap 失败: %s\n", strerror(errno));
        goto cleanup;
    }
    if (quiesce_gqa(csr) != 0
        || fpgatten_csr_read(csr, FPGATTEN_CSR_VERSION) != FPGATTEN_VERSION_VALUE
        || fpgatten_csr_read(csr, FPGATTEN_CSR_BUILD_ID) != FPGATTEN_BUILD_ID_VALUE) {
        fprintf(stderr, "FPGAtten CSR identity/quiesce check failed\n");
        goto cleanup;
    }

    printf("FPGATTEN_PERF_BEGIN clock_hz=%" PRIu64
           " dma_clock_hz=%" PRIu64
           " contexts=%zu repeats=%" PRIu32
           " verify=%d preserve=%d max_context=%" PRIu32 "\n",
           clock_hz, dma_clock_hz, context_count, repeats, verify, preserve,
           contexts[context_count - 1u]);
    if (preserve) {
        printf("PREP: 保存将被覆盖的 PL-DDR 区域\n");
        fflush(stdout);
        if (save_benchmark_regions(ddr, contexts, context_count,
                                   &regions, &region_count) != 0) {
            fprintf(stderr, "保存 PL-DDR 区域失败\n");
            goto cleanup;
        }
    }
    initialize_fixture(ddr, contexts, context_count);

    for (size_t context_index = 0; context_index < context_count;
         ++context_index) {
        struct context_summary *summary = &summaries[context_index];
        summary->context = contexts[context_index];
        summary->repeats = repeats;
        summary->cycle_min = UINT32_MAX;
        for (uint32_t repeat = 0; repeat < repeats; ++repeat) {
            struct run_metrics metrics;
            double seconds;
            double layer_token_s;
            double overlap_percent;
            double qk_pv_overlap_percent;
            double dma_lane_overlap_percent;
            double qk_util_percent;
            double pv_util_percent;
            double logical_bytes;
            double effective_gb_s;
            double useful_macs;
            double useful_gmac_s;
            double issued_gmac_s;
            double dma_service_cycles;
            double dma_read_gb_s;
            double dma_bus_util_percent;

            if (run_one(csr, ddr, gqa_fd, summary->context, verify,
                        &metrics) != 0) {
                fprintf(stderr,
                        "硬件运行失败 context=%" PRIu32 " repeat=%" PRIu32 "\n",
                        summary->context, repeat + 1u);
                goto cleanup;
            }
            seconds = (double)metrics.cycles / (double)clock_hz;
            layer_token_s = 1.0 / seconds;
            overlap_percent = 100.0 * (double)metrics.overlap_cycles
                              / (double)metrics.cycles;
            qk_pv_overlap_percent =
                100.0 * (double)metrics.qk_pv_overlap_cycles
                    / (double)metrics.cycles;
            dma_lane_overlap_percent =
                100.0 * (double)metrics.dma_lane_overlap_cycles
                    / (double)metrics.cycles;
            qk_util_percent = metrics.qk_cycles == 0u ? 0.0
                : 100.0 * (double)(Q_HEADS * summary->context * HEAD_DIM)
                    / ((double)metrics.qk_cycles
                       * ARRAY_MACS_PER_ACTIVE_CYCLE);
            pv_util_percent = metrics.pv_cycles == 0u ? 0.0
                : 100.0 * (double)(Q_HEADS * summary->context * HEAD_DIM)
                    / ((double)metrics.pv_cycles
                       * ARRAY_MACS_PER_ACTIVE_CYCLE);
            logical_bytes = (double)(Q_HEADS * FPGATTEN_BF16_TOKEN_STRIDE
                + 2u * KV_HEADS * summary->context
                    * FPGATTEN_BF16_TOKEN_STRIDE
                + Q_HEADS * FPGATTEN_FP32_TOKEN_STRIDE);
            effective_gb_s = logical_bytes / seconds / 1.0e9;
            useful_macs = 2.0 * Q_HEADS * (double)summary->context * HEAD_DIM;
            useful_gmac_s = useful_macs / seconds / 1.0e9;
            issued_gmac_s = (double)(metrics.qk_cycles + metrics.pv_cycles)
                * ARRAY_MACS_PER_ACTIVE_CYCLE / seconds / 1.0e9;
            dma_service_cycles = (double)metrics.dma_read_beats
                + (double)metrics.dma_r_gap_cycles
                + (double)metrics.dma_r_backpressure_cycles;
            dma_read_gb_s = dma_service_cycles == 0.0 ? 0.0
                : (double)metrics.dma_read_beats * 32.0
                    * (double)dma_clock_hz / dma_service_cycles / 1.0e9;
            dma_bus_util_percent = dma_service_cycles == 0.0 ? 0.0
                : 100.0 * (double)metrics.dma_read_beats
                    / dma_service_cycles;

            printf("PERF context=%" PRIu32 " repeat=%" PRIu32
                   " cycles=%" PRIu32 " latency_ms=%.6f"
                   " layer_token_s=%.6f attention32_token_s=%.6f"
                   " overlap=%" PRIu32 " overlap_pct=%.4f"
                   " qk_pv_overlap=%" PRIu32 " qk_pv_overlap_pct=%.4f"
                   " dma_lane_overlap=%" PRIu32
                   " dma_lane_overlap_pct=%.4f"
                   " qk_cycles=%" PRIu32 " softmax_cycles=%" PRIu32
                   " pv_cycles=%" PRIu32
                   " qk_util_pct=%.4f pv_util_pct=%.4f"
                   " load_stall=%" PRIu32 " core_total=%" PRIu32
                   " dma_stall=%" PRIu32
                   " dma_ar=%" PRIu32 " dma_beats=%" PRIu32
                   " dma_ar_wait=%" PRIu32 " dma_r_gap=%" PRIu32
                   " dma_r_bp=%" PRIu32 " dma_bank_wait=%" PRIu32
                   " dma_emit_wait=%" PRIu32
                   " dma_max_out=%" PRIu32
                   " dma_4k_splits=%" PRIu32
                   " kv_hits=%" PRIu32 " kv_misses=%" PRIu32
                   " prefetch=%" PRIu32
                   " dma_read_gb_s=%.6f dma_bus_util_pct=%.4f"
                   " blocks=%" PRIu32 " skipped=%" PRIu32
                   " logical_gb_s=%.6f useful_gmac_s=%.6f"
                   " issued_gmac_s=%.6f max_error=%.8f mae=%.8f"
                   " violations=%" PRIu32 "\n",
                   summary->context, repeat + 1u, metrics.cycles,
                   seconds * 1000.0, layer_token_s, layer_token_s / 32.0,
                   metrics.overlap_cycles, overlap_percent,
                   metrics.qk_pv_overlap_cycles, qk_pv_overlap_percent,
                   metrics.dma_lane_overlap_cycles,
                   dma_lane_overlap_percent,
                   metrics.qk_cycles, metrics.softmax_cycles,
                   metrics.pv_cycles, qk_util_percent, pv_util_percent,
                   metrics.load_stall_cycles, metrics.core_total_cycles,
                   metrics.dma_stall_cycles, metrics.dma_ar_count,
                   metrics.dma_read_beats, metrics.dma_ar_wait_cycles,
                   metrics.dma_r_gap_cycles,
                   metrics.dma_r_backpressure_cycles,
                   metrics.dma_bank_wait_cycles,
                   metrics.dma_emit_wait_cycles,
                   metrics.dma_max_outstanding,
                   metrics.dma_boundary_splits,
                   metrics.kv_cache_hits, metrics.kv_cache_misses,
                   metrics.prefetch_issues, dma_read_gb_s,
                   dma_bus_util_percent, metrics.blocks_total,
                   metrics.blocks_skipped, effective_gb_s, useful_gmac_s,
                   issued_gmac_s, metrics.maximum_error,
                   metrics.mean_absolute_error, metrics.violations);
            fflush(stdout);

            summary->cycle_sum += metrics.cycles;
            if (metrics.cycles < summary->cycle_min)
                summary->cycle_min = metrics.cycles;
            if (metrics.cycles > summary->cycle_max)
                summary->cycle_max = metrics.cycles;
            summary->overlap_sum += metrics.overlap_cycles;
            summary->qk_pv_overlap_sum += metrics.qk_pv_overlap_cycles;
            summary->dma_lane_overlap_sum +=
                metrics.dma_lane_overlap_cycles;
            summary->qk_cycle_sum += metrics.qk_cycles;
            summary->softmax_cycle_sum += metrics.softmax_cycles;
            summary->pv_cycle_sum += metrics.pv_cycles;
            summary->load_stall_sum += metrics.load_stall_cycles;
            summary->dma_stall_sum += metrics.dma_stall_cycles;
            summary->dma_ar_count_sum += metrics.dma_ar_count;
            summary->dma_read_beats_sum += metrics.dma_read_beats;
            summary->dma_ar_wait_sum += metrics.dma_ar_wait_cycles;
            summary->dma_r_gap_sum += metrics.dma_r_gap_cycles;
            summary->dma_r_backpressure_sum +=
                metrics.dma_r_backpressure_cycles;
            summary->dma_bank_wait_sum += metrics.dma_bank_wait_cycles;
            summary->dma_emit_wait_sum += metrics.dma_emit_wait_cycles;
            if (metrics.dma_max_outstanding >
                summary->dma_max_outstanding)
                summary->dma_max_outstanding =
                    metrics.dma_max_outstanding;
            summary->dma_boundary_split_sum +=
                metrics.dma_boundary_splits;
            summary->kv_cache_hit_sum += metrics.kv_cache_hits;
            summary->kv_cache_miss_sum += metrics.kv_cache_misses;
            summary->prefetch_issue_sum += metrics.prefetch_issues;
            if (metrics.maximum_error > summary->maximum_error)
                summary->maximum_error = metrics.maximum_error;
            summary->mean_absolute_error_sum += metrics.mean_absolute_error;
            summary->violations += metrics.violations;
        }
    }

    printf("FPGATTEN_PERF_TABLE_BEGIN\n");
    printf("context,avg_cycles,min_cycles,max_cycles,latency_ms,"
           "layer_token_s,attention32_token_s,overlap_pct,"
           "qk_pv_overlap_pct,dma_lane_overlap_pct,qk_cycles,"
           "softmax_cycles,pv_cycles,load_stall,dma_stall,dma_ar,"
           "dma_beats,dma_ar_wait,dma_r_gap,dma_r_backpressure,"
           "dma_bank_wait,dma_emit_wait,dma_max_outstanding,"
           "dma_4k_splits,kv_cache_hits,kv_cache_misses,prefetch_issues,"
           "dma_read_gb_s,dma_bus_util_pct,"
           "max_error,mae,violations\n");
    for (size_t index = 0; index < context_count; ++index) {
        const struct context_summary *summary = &summaries[index];
        double average_cycles = (double)summary->cycle_sum / summary->repeats;
        double seconds = average_cycles / (double)clock_hz;
        double layer_token_s = 1.0 / seconds;
        double average_dma_beats =
            (double)summary->dma_read_beats_sum / summary->repeats;
        double average_dma_service_cycles = average_dma_beats
            + (double)summary->dma_r_gap_sum / summary->repeats
            + (double)summary->dma_r_backpressure_sum / summary->repeats;
        double dma_read_gb_s = average_dma_service_cycles == 0.0 ? 0.0
            : average_dma_beats * 32.0 * (double)dma_clock_hz
                / average_dma_service_cycles / 1.0e9;
        double dma_bus_util_percent =
            average_dma_service_cycles == 0.0 ? 0.0
            : 100.0 * average_dma_beats / average_dma_service_cycles;

        printf("%" PRIu32 ",%.3f,%" PRIu32 ",%" PRIu32
               ",%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,"
               "%.3f,%.3f,%.3f,%.3f,%.3f,"
               "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%" PRIu32
               ",%.3f,%.3f,%.3f,%.3f,%.6f,%.4f,%.8f,%.8f,%" PRIu64 "\n",
               summary->context, average_cycles, summary->cycle_min,
               summary->cycle_max, seconds * 1000.0, layer_token_s,
               layer_token_s / 32.0,
               100.0 * (double)summary->overlap_sum
                   / (double)summary->cycle_sum,
               100.0 * (double)summary->qk_pv_overlap_sum
                   / (double)summary->cycle_sum,
               100.0 * (double)summary->dma_lane_overlap_sum
                   / (double)summary->cycle_sum,
               (double)summary->qk_cycle_sum / summary->repeats,
               (double)summary->softmax_cycle_sum / summary->repeats,
               (double)summary->pv_cycle_sum / summary->repeats,
               (double)summary->load_stall_sum / summary->repeats,
               (double)summary->dma_stall_sum / summary->repeats,
               (double)summary->dma_ar_count_sum / summary->repeats,
               (double)summary->dma_read_beats_sum / summary->repeats,
               (double)summary->dma_ar_wait_sum / summary->repeats,
               (double)summary->dma_r_gap_sum / summary->repeats,
               (double)summary->dma_r_backpressure_sum /
                   summary->repeats,
               (double)summary->dma_bank_wait_sum / summary->repeats,
               (double)summary->dma_emit_wait_sum / summary->repeats,
               summary->dma_max_outstanding,
               (double)summary->dma_boundary_split_sum /
                   summary->repeats,
               (double)summary->kv_cache_hit_sum / summary->repeats,
               (double)summary->kv_cache_miss_sum / summary->repeats,
               (double)summary->prefetch_issue_sum / summary->repeats,
               dma_read_gb_s, dma_bus_util_percent,
               summary->maximum_error,
               summary->mean_absolute_error_sum / summary->repeats,
               summary->violations);
    }
    printf("FPGATTEN_PERF_TABLE_END\n");
    result = 0;
    for (size_t index = 0; index < context_count; ++index) {
        if (summaries[index].violations != 0u)
            result = 2;
    }

cleanup:
    if (csr != MAP_FAILED)
        (void)quiesce_gqa(csr);
    if (ddr != MAP_FAILED && regions != NULL) {
        printf("CLEANUP: 恢复 PL-DDR 区域\n");
        fflush(stdout);
        if (restore_regions(ddr, regions, region_count) != 0)
            result = 1;
    }
    free(regions);
    if (ddr != MAP_FAILED)
        (void)munmap((void *)ddr, PL_DDR_MAP_BYTES);
    if (csr != MAP_FAILED)
        (void)munmap((void *)csr, FPGATTEN_CSR_MAP_BYTES);
    if (ddr_fd >= 0)
        close(ddr_fd);
    if (gqa_fd >= 0)
        close(gqa_fd);
    if (board_lock_fd >= 0)
        close(board_lock_fd);
    free(summaries);
    free(contexts);
    if (stop_signal != 0)
        fprintf(stderr, "benchmark 被 signal %d 中止\n", stop_signal);
    return result;
}
