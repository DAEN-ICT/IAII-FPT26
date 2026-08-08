#define _POSIX_C_SOURCE 200809L

#include "gqav5_experiment.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static void initialize_empty_device(gqav5_device *device)
{
    memset(device, 0, sizeof(*device));
    device->accelerator_fd = -1;
    device->ddr_fd = -1;
    device->lock_fd = -1;
    device->counter_read_delay_us = 1000u;
}

static int lock_file(int fd)
{
    struct flock lock = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 0,
    };

    return fcntl(fd, F_SETLK, &lock);
}

static int valid_device(const gqav5_device *device)
{
    return device != NULL && device->csr != NULL && device->ddr != NULL
        && device->csr_bytes >= GQAV5_CSR_MAP_BYTES;
}

static int valid_register(const gqav5_device *device, uint32_t offset)
{
    if (!valid_device(device) || (offset & 3u) != 0u
        || (uint64_t)offset + sizeof(uint32_t) > device->csr_bytes) {
        errno = EINVAL;
        return 0;
    }
    return 1;
}

static int valid_ddr_range(const gqav5_device *device,
                           uint32_t offset,
                           size_t bytes)
{
    uint64_t end = (uint64_t)offset + (uint64_t)bytes;

    if (!valid_device(device) || end > device->ddr_bytes) {
        errno = ERANGE;
        return 0;
    }
    return 1;
}

static uint64_t monotonic_milliseconds(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0u;
    return (uint64_t)now.tv_sec * 1000u
        + (uint64_t)now.tv_nsec / 1000000u;
}

static uint64_t monotonic_nanoseconds(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0u;
    return (uint64_t)now.tv_sec * 1000000000u
        + (uint64_t)now.tv_nsec;
}

static void sleep_one_millisecond(void)
{
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000L};

    (void)nanosleep(&delay, NULL);
}

static void sleep_microseconds(unsigned int delay_us)
{
    struct timespec delay;

    if (delay_us == 0u)
        return;
    delay.tv_sec = (time_t)(delay_us / 1000000u);
    delay.tv_nsec = (long)(delay_us % 1000000u) * 1000L;
    (void)nanosleep(&delay, NULL);
}

int gqav5_device_open(gqav5_device *device,
                      const char *accelerator_uio,
                      const char *ddr_uio)
{
    if (device == NULL || accelerator_uio == NULL || ddr_uio == NULL) {
        errno = EINVAL;
        return -1;
    }

    initialize_empty_device(device);
    device->lock_fd = open(GQAV5_BOARD_LOCK_PATH,
                           O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (device->lock_fd < 0 || lock_file(device->lock_fd) != 0)
        goto error;

    device->accelerator_fd = open(accelerator_uio, O_RDWR | O_CLOEXEC);
    device->ddr_fd = open(ddr_uio, O_RDWR | O_CLOEXEC);
    if (device->accelerator_fd < 0 || device->ddr_fd < 0
        || lock_file(device->ddr_fd) != 0)
        goto error;

    device->csr = mmap(NULL, GQAV5_CSR_MAP_BYTES,
                       PROT_READ | PROT_WRITE, MAP_SHARED,
                       device->accelerator_fd, 0);
    if (device->csr == MAP_FAILED) {
        device->csr = NULL;
        goto error;
    }
    device->ddr = mmap(NULL, GQAV5_PL_DDR_MAP_BYTES,
                       PROT_READ | PROT_WRITE, MAP_SHARED,
                       device->ddr_fd, 0);
    if (device->ddr == MAP_FAILED) {
        device->ddr = NULL;
        goto error;
    }
    device->csr_bytes = GQAV5_CSR_MAP_BYTES;
    device->ddr_bytes = GQAV5_PL_DDR_MAP_BYTES;
    device->owns_mappings = 1;

    if (gqav5_check_identity(device) != 0
        || gqav5_soft_reset(device, 1000u) != 0)
        goto error;
    return 0;

error:
    {
        int saved_errno = errno;
        gqav5_device_close(device);
        errno = saved_errno;
    }
    return -1;
}

int gqav5_device_init_mapped(gqav5_device *device,
                             volatile void *csr,
                             size_t csr_bytes,
                             volatile void *ddr,
                             size_t ddr_bytes)
{
    if (device == NULL || csr == NULL || ddr == NULL
        || csr_bytes < GQAV5_CSR_MAP_BYTES || ddr_bytes == 0u) {
        errno = EINVAL;
        return -1;
    }
    initialize_empty_device(device);
    device->csr = (volatile uint8_t *)csr;
    device->ddr = (volatile uint8_t *)ddr;
    device->csr_bytes = csr_bytes;
    device->ddr_bytes = ddr_bytes;
    return 0;
}

void gqav5_device_close(gqav5_device *device)
{
    if (device == NULL)
        return;
    if (device->owns_mappings && device->ddr != NULL)
        (void)munmap((void *)device->ddr, device->ddr_bytes);
    if (device->owns_mappings && device->csr != NULL)
        (void)munmap((void *)device->csr, device->csr_bytes);
    if (device->ddr_fd >= 0)
        (void)close(device->ddr_fd);
    if (device->accelerator_fd >= 0)
        (void)close(device->accelerator_fd);
    if (device->lock_fd >= 0)
        (void)close(device->lock_fd);
    initialize_empty_device(device);
}

int gqav5_check_identity(const gqav5_device *device)
{
    if (!valid_device(device)) {
        errno = EINVAL;
        return -1;
    }
    if (gqav5_reg_read(device, GQAV5_CSR_VERSION) != GQAV5_VERSION_VALUE
        || gqav5_reg_read(device, GQAV5_CSR_BUILD_ID)
            != GQAV5_BUILD_ID_VALUE) {
        errno = ENODEV;
        return -1;
    }
    return 0;
}

void gqav5_set_counter_read_delay(gqav5_device *device,
                                  unsigned int delay_us)
{
    if (device != NULL)
        device->counter_read_delay_us = delay_us;
}

uint32_t gqav5_reg_read(const gqav5_device *device, uint32_t offset)
{
    if (!valid_register(device, offset))
        return 0u;
    return gqav5_csr_read((volatile void *)device->csr, offset);
}

int gqav5_reg_write(gqav5_device *device, uint32_t offset, uint32_t value)
{
    if (!valid_register(device, offset))
        return -1;
    gqav5_csr_write((volatile void *)device->csr, offset, value);
    __sync_synchronize();
    return 0;
}

int gqav5_get_status(const gqav5_device *device, gqav5_status *status)
{
    uint32_t raw;

    if (status == NULL || !valid_register(device, GQAV5_CSR_STATUS)) {
        errno = EINVAL;
        return -1;
    }
    raw = gqav5_reg_read(device, GQAV5_CSR_STATUS);
    status->raw = raw;
    status->busy = (raw & GQAV5_STATUS_BUSY) != 0u;
    status->done = (raw & GQAV5_STATUS_DONE) != 0u;
    status->error = (raw & GQAV5_STATUS_ERROR) != 0u;
    status->irq = (raw & GQAV5_STATUS_IRQ) != 0u;
    return 0;
}

int gqav5_clear_status(gqav5_device *device)
{
    return gqav5_reg_write(device, GQAV5_CSR_CONTROL,
                           GQAV5_CONTROL_CLEAR_DONE
                           | GQAV5_CONTROL_CLEAR_ERROR);
}

int gqav5_soft_reset(gqav5_device *device, unsigned int timeout_ms)
{
    uint64_t start;

    if (gqav5_reg_write(device, GQAV5_CSR_CONTROL,
                        GQAV5_CONTROL_SOFT_RESET) != 0)
        return -1;
    start = monotonic_milliseconds();
    for (;;) {
        gqav5_status status;
        if (gqav5_get_status(device, &status) != 0)
            return -1;
        if (!status.busy)
            return 0;
        if (monotonic_milliseconds() - start >= timeout_ms) {
            errno = ETIMEDOUT;
            return -1;
        }
        sleep_one_millisecond();
    }
}

void gqav5_default_decode_job(gqav5_job *job, uint32_t context_tokens)
{
    if (job == NULL)
        return;
    memset(job, 0, sizeof(*job));
    job->context_tokens = context_tokens;
    job->query_token_base = context_tokens == 0u ? 0u : context_tokens - 1u;
    job->query_valid_rows = 1u;
    job->prefill_query_tokens = 1u;
    job->prefill_direct = 0u;
    job->causal = 1u;
    job->q_base = GQAV5_Q_BASE_DEFAULT;
    job->k_base = GQAV5_K_BASE_DEFAULT;
    job->v_base = GQAV5_V_BASE_DEFAULT;
    job->o_base = GQAV5_O_BASE_DEFAULT;
    job->q_head_stride = GQAV5_BF16_HEAD_STRIDE_8192;
    job->q_token_stride = GQAV5_BF16_TOKEN_STRIDE;
    job->k_head_stride = GQAV5_BF16_HEAD_STRIDE_8192;
    job->k_token_stride = GQAV5_BF16_TOKEN_STRIDE;
    job->v_head_stride = GQAV5_BF16_HEAD_STRIDE_8192;
    job->v_token_stride = GQAV5_BF16_TOKEN_STRIDE;
    job->o_head_stride = GQAV5_FP32_HEAD_STRIDE_8192;
    job->o_token_stride = GQAV5_FP32_TOKEN_STRIDE;
    job->pv_skip_lambda_bits = 0xc0a00000u;
}

void gqav5_default_prefill_job(gqav5_job *job,
                               uint32_t context_tokens,
                               uint32_t query_token_base,
                               uint32_t query_tokens)
{
    gqav5_default_decode_job(job, context_tokens);
    if (job == NULL)
        return;
    job->query_token_base = query_token_base;
    job->query_valid_rows = query_tokens >= 16u ? 16u : query_tokens;
    job->prefill_query_tokens = query_tokens;
    job->prefill_direct = 1u;
    job->causal = 1u;
}

static int check_last_row(const gqav5_device *device,
                          uint32_t base,
                          uint32_t head_stride,
                          uint32_t token_stride,
                          uint32_t head,
                          uint32_t token,
                          size_t row_bytes)
{
    uint32_t offset;

    return gqav5_row_offset(base, head_stride, token_stride,
                            head, token, row_bytes, &offset) == 0
        && valid_ddr_range(device, offset, row_bytes);
}

int gqav5_validate_job(const gqav5_device *device,
                       const gqav5_job *job,
                       int direct_only)
{
    uint32_t last_query;
    size_t output_row_bytes;

    if (!valid_device(device) || job == NULL
        || job->context_tokens == 0u
        || job->context_tokens > GQAV5_MAX_CONTEXT_TOKENS
        || job->query_valid_rows == 0u || job->query_valid_rows > 16u
        || (job->prefill_direct &&
            (job->prefill_query_tokens == 0u ||
             job->prefill_query_tokens > GQAV5_MAX_CONTEXT_TOKENS))
        || job->query_token_base >= job->context_tokens
        || (job->prefill_direct
                ? job->prefill_query_tokens : job->query_valid_rows) - 1u
            > UINT32_MAX - job->query_token_base) {
        errno = EINVAL;
        return -1;
    }
    last_query = job->query_token_base +
        (job->prefill_direct
             ? job->prefill_query_tokens : job->query_valid_rows) - 1u;
    if (last_query >= job->context_tokens) {
        errno = EINVAL;
        return -1;
    }
    if (direct_only && !job->prefill_direct
        && (job->query_valid_rows != 1u
            || (job->causal != 0u
                && job->query_token_base + 1u < job->context_tokens))) {
        errno = ENOTSUP;
        return -1;
    }
    if ((job->q_base | job->k_base | job->v_base | job->o_base
         | job->q_head_stride | job->q_token_stride
         | job->k_head_stride | job->k_token_stride
         | job->v_head_stride | job->v_token_stride
         | job->o_head_stride | job->o_token_stride) & 31u) {
        errno = EINVAL;
        return -1;
    }

    output_row_bytes = job->bf16_output
        ? GQAV5_BF16_TOKEN_STRIDE : GQAV5_FP32_TOKEN_STRIDE;
    if (!check_last_row(device, job->q_base, job->q_head_stride,
                        job->q_token_stride, GQAV5_Q_HEAD_COUNT - 1u,
                        last_query, GQAV5_BF16_TOKEN_STRIDE)
        || !check_last_row(device, job->k_base, job->k_head_stride,
                           job->k_token_stride,
                           GQAV5_KV_HEAD_COUNT - 1u,
                           job->context_tokens - 1u,
                           GQAV5_BF16_TOKEN_STRIDE)
        || !check_last_row(device, job->v_base, job->v_head_stride,
                           job->v_token_stride,
                           GQAV5_KV_HEAD_COUNT - 1u,
                           job->context_tokens - 1u,
                           GQAV5_BF16_TOKEN_STRIDE)
        || !check_last_row(device, job->o_base, job->o_head_stride,
                           job->o_token_stride,
                           GQAV5_Q_HEAD_COUNT - 1u,
                           last_query, output_row_bytes)) {
        if (errno == 0)
            errno = ERANGE;
        return -1;
    }
    return 0;
}

int gqav5_program_job(gqav5_device *device,
                      const gqav5_job *job,
                      int direct_only)
{
    gqav5_status status;
    uint32_t options = GQAV5_OPT_QK_REUSE;

    if (gqav5_validate_job(device, job, direct_only) != 0
        || gqav5_get_status(device, &status) != 0)
        return -1;
    if (status.busy) {
        errno = EBUSY;
        return -1;
    }
    if (job->bf16_output)
        options |= GQAV5_OPT_BF16_OUTPUT;
    if (job->pv_skip_enable)
        options |= GQAV5_OPT_PV_SKIP;
    if (job->prefill_direct)
        options |= GQAV5_OPT_PREFILL_DIRECT;

#define WRITE_JOB_REGISTER(offset, value) \
    do { \
        if (gqav5_reg_write(device, (offset), (value)) != 0) \
            return -1; \
    } while (0)
    WRITE_JOB_REGISTER(GQAV5_CSR_CONTEXT_TOKENS, job->context_tokens);
    WRITE_JOB_REGISTER(GQAV5_CSR_QUERY_CONFIG,
                       gqav5_query_config(job->query_token_base,
                                          job->query_valid_rows,
                                          job->causal));
    WRITE_JOB_REGISTER(GQAV5_CSR_Q_BASE, job->q_base);
    WRITE_JOB_REGISTER(GQAV5_CSR_K_BASE, job->k_base);
    WRITE_JOB_REGISTER(GQAV5_CSR_V_BASE, job->v_base);
    WRITE_JOB_REGISTER(GQAV5_CSR_O_BASE, job->o_base);
    WRITE_JOB_REGISTER(GQAV5_CSR_Q_HEAD_STRIDE, job->q_head_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_Q_TOKEN_STRIDE, job->q_token_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_K_HEAD_STRIDE, job->k_head_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_K_TOKEN_STRIDE, job->k_token_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_V_HEAD_STRIDE, job->v_head_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_V_TOKEN_STRIDE, job->v_token_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_O_HEAD_STRIDE, job->o_head_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_O_TOKEN_STRIDE, job->o_token_stride);
    WRITE_JOB_REGISTER(GQAV5_CSR_OPT_CTRL, options);
    WRITE_JOB_REGISTER(GQAV5_CSR_PV_LAMBDA, job->pv_skip_lambda_bits);
    WRITE_JOB_REGISTER(GQAV5_CSR_PREFILL_QUERY_TOKENS,
                       job->prefill_direct
                           ? job->prefill_query_tokens : 1u);
#undef WRITE_JOB_REGISTER
    return 0;
}

int gqav5_start(gqav5_device *device)
{
    gqav5_status status;

    if (gqav5_get_status(device, &status) != 0)
        return -1;
    if (status.busy) {
        errno = EBUSY;
        return -1;
    }
    return gqav5_reg_write(device, GQAV5_CSR_CONTROL,
                           GQAV5_CONTROL_START);
}

int gqav5_arm_irq(gqav5_device *device)
{
    uint32_t enable = 1u;

    if (device == NULL || device->accelerator_fd < 0) {
        errno = ENOTSUP;
        return -1;
    }
    if (write(device->accelerator_fd, &enable, sizeof(enable))
        != (ssize_t)sizeof(enable))
        return -1;
    return 0;
}

int gqav5_wait_irq(gqav5_device *device, unsigned int timeout_ms)
{
    struct pollfd request;
    uint32_t event_count;
    int result;

    if (device == NULL || device->accelerator_fd < 0) {
        errno = ENOTSUP;
        return -1;
    }
    request.fd = device->accelerator_fd;
    request.events = POLLIN;
    request.revents = 0;
    result = poll(&request, 1, (int)timeout_ms);
    if (result == 0) {
        errno = ETIMEDOUT;
        return -1;
    }
    if (result < 0)
        return -1;
    if ((request.revents & POLLIN) == 0) {
        errno = EIO;
        return -1;
    }
    if (read(device->accelerator_fd, &event_count, sizeof(event_count))
        != (ssize_t)sizeof(event_count))
        return -1;
    return 0;
}

int gqav5_wait_poll(gqav5_device *device, unsigned int timeout_ms)
{
    uint64_t start = monotonic_milliseconds();

    for (;;) {
        gqav5_status status;
        if (gqav5_get_status(device, &status) != 0)
            return -1;
        if (status.error) {
            errno = EIO;
            return -1;
        }
        if (status.done && !status.busy)
            return 0;
        if (monotonic_milliseconds() - start >= timeout_ms) {
            errno = ETIMEDOUT;
            return -1;
        }
        sleep_one_millisecond();
    }
}

static uint32_t read_counter(gqav5_device *device, uint32_t offset)
{
    uint32_t value = gqav5_reg_read(device, offset);

    __sync_synchronize();
    sleep_microseconds(device->counter_read_delay_us);
    return value;
}

int gqav5_read_metrics(gqav5_device *device, gqav5_metrics *metrics)
{
    if (!valid_device(device) || metrics == NULL) {
        errno = EINVAL;
        return -1;
    }
    memset(metrics, 0, sizeof(*metrics));
#define READ_METRIC(field, offset) \
    do { (metrics)->field = read_counter(device, (offset)); } while (0)
    READ_METRIC(total_cycles, GQAV5_CSR_TOTAL_CYCLES);
    READ_METRIC(overlap_cycles, GQAV5_CSR_OVERLAP_CYCLES);
    READ_METRIC(qk_pv_overlap_cycles, GQAV5_CSR_QK_PV_OVERLAP);
    READ_METRIC(dma_lane_overlap_cycles, GQAV5_CSR_DMA_LANE_OVERLAP);
    READ_METRIC(load_stall_cycles, GQAV5_CSR_LOAD_STALL_CYCLES);
    READ_METRIC(core_total_cycles, GQAV5_CSR_CORE_TOTAL);
    READ_METRIC(qk_cycles, GQAV5_CSR_CORE_QK);
    READ_METRIC(softmax_cycles, GQAV5_CSR_CORE_SOFTMAX);
    READ_METRIC(pv_cycles, GQAV5_CSR_CORE_PV);
    READ_METRIC(dma_stall_cycles, GQAV5_CSR_CORE_DMA_STALL);
    READ_METRIC(pv_blocks_total, GQAV5_CSR_PV_BLOCK_TOTAL);
    READ_METRIC(pv_blocks_skipped, GQAV5_CSR_PV_BLOCK_SKIPPED);
    READ_METRIC(dma_ar_count, GQAV5_CSR_DMA_AR_COUNT);
    READ_METRIC(dma_read_beats, GQAV5_CSR_DMA_READ_BEATS);
    READ_METRIC(dma_ar_wait_cycles, GQAV5_CSR_DMA_AR_WAIT);
    READ_METRIC(dma_r_gap_cycles, GQAV5_CSR_DMA_R_GAP);
    READ_METRIC(dma_r_backpressure_cycles,
                GQAV5_CSR_DMA_R_BACKPRESSURE);
    READ_METRIC(dma_bank_wait_cycles, GQAV5_CSR_DMA_BANK_WAIT);
    READ_METRIC(dma_emit_wait_cycles, GQAV5_CSR_DMA_EMIT_WAIT);
    READ_METRIC(dma_max_outstanding, GQAV5_CSR_DMA_MAX_OUTSTANDING);
    READ_METRIC(dma_4k_splits, GQAV5_CSR_DMA_4K_SPLITS);
    READ_METRIC(kv_cache_hits, GQAV5_CSR_KV_CACHE_HITS);
    READ_METRIC(kv_cache_misses, GQAV5_CSR_KV_CACHE_MISSES);
    READ_METRIC(prefetch_issues, GQAV5_CSR_PREFETCH_ISSUES);
#undef READ_METRIC
    return 0;
}

int gqav5_run_job(gqav5_device *device,
                  const gqav5_job *job,
                  int direct_only,
                  int use_interrupt,
                  unsigned int timeout_ms,
                  gqav5_metrics *metrics)
{
    gqav5_status status;
    uint64_t host_start_ns;
    uint64_t host_end_ns;
    int metrics_result;

    if (timeout_ms == 0u)
        timeout_ms = GQAV5_DEFAULT_TIMEOUT_MS;
    if (gqav5_soft_reset(device, 1000u) != 0
        || gqav5_program_job(device, job, direct_only) != 0)
        return -1;
    if (use_interrupt && gqav5_arm_irq(device) != 0)
        return -1;
    host_start_ns = monotonic_nanoseconds();
    if (gqav5_start(device) != 0)
        return -1;
    if ((use_interrupt
         ? gqav5_wait_irq(device, timeout_ms)
         : gqav5_wait_poll(device, timeout_ms)) != 0)
        return -1;
    host_end_ns = monotonic_nanoseconds();
    if (gqav5_get_status(device, &status) != 0)
        return -1;
    if (!status.done || status.busy || status.error) {
        errno = EIO;
        return -1;
    }
    if (metrics != NULL) {
        metrics_result = gqav5_read_metrics(device, metrics);
        if (metrics_result != 0)
            return metrics_result;
        if (host_start_ns != 0u && host_end_ns >= host_start_ns)
            metrics->host_elapsed_ns = host_end_ns - host_start_ns;
    }
    return 0;
}

int gqav5_ddr_write(gqav5_device *device,
                    uint32_t offset,
                    const void *source,
                    size_t bytes)
{
    const uint8_t *input = (const uint8_t *)source;

    if ((source == NULL && bytes != 0u)
        || !valid_ddr_range(device, offset, bytes)) {
        if (source == NULL && bytes != 0u)
            errno = EINVAL;
        return -1;
    }
    for (size_t index = 0; index < bytes; ++index)
        device->ddr[offset + index] = input[index];
    __sync_synchronize();
    return 0;
}

int gqav5_ddr_read(const gqav5_device *device,
                   uint32_t offset,
                   void *destination,
                   size_t bytes)
{
    uint8_t *output = (uint8_t *)destination;

    if ((destination == NULL && bytes != 0u)
        || !valid_ddr_range(device, offset, bytes)) {
        if (destination == NULL && bytes != 0u)
            errno = EINVAL;
        return -1;
    }
    __sync_synchronize();
    for (size_t index = 0; index < bytes; ++index)
        output[index] = device->ddr[offset + index];
    return 0;
}

int gqav5_ddr_fill(gqav5_device *device,
                   uint32_t offset,
                   uint8_t value,
                   size_t bytes)
{
    if (!valid_ddr_range(device, offset, bytes))
        return -1;
    for (size_t index = 0; index < bytes; ++index)
        device->ddr[offset + index] = value;
    __sync_synchronize();
    return 0;
}

int gqav5_row_offset(uint32_t base,
                     uint32_t head_stride,
                     uint32_t token_stride,
                     uint32_t head,
                     uint32_t token,
                     size_t row_bytes,
                     uint32_t *offset)
{
    uint64_t address;

    if (offset == NULL) {
        errno = EINVAL;
        return -1;
    }
    address = (uint64_t)base + (uint64_t)head * head_stride
        + (uint64_t)token * token_stride;
    if (address > UINT32_MAX
        || row_bytes > (uint64_t)UINT32_MAX + 1u - address) {
        errno = ERANGE;
        return -1;
    }
    *offset = (uint32_t)address;
    return 0;
}

int gqav5_write_bf16_row(gqav5_device *device,
                         uint32_t base,
                         uint32_t head_stride,
                         uint32_t token_stride,
                         uint32_t head,
                         uint32_t token,
                         const uint16_t values[GQAV5_HEAD_DIM])
{
    uint32_t offset;

    if (values == NULL
        || gqav5_row_offset(base, head_stride, token_stride,
                            head, token, GQAV5_BF16_TOKEN_STRIDE,
                            &offset) != 0) {
        if (values == NULL)
            errno = EINVAL;
        return -1;
    }
    return gqav5_ddr_write(device, offset, values,
                           GQAV5_BF16_TOKEN_STRIDE);
}

int gqav5_read_bf16_row(const gqav5_device *device,
                        uint32_t base,
                        uint32_t head_stride,
                        uint32_t token_stride,
                        uint32_t head,
                        uint32_t token,
                        uint16_t values[GQAV5_HEAD_DIM])
{
    uint32_t offset;

    if (values == NULL
        || gqav5_row_offset(base, head_stride, token_stride,
                            head, token, GQAV5_BF16_TOKEN_STRIDE,
                            &offset) != 0) {
        if (values == NULL)
            errno = EINVAL;
        return -1;
    }
    return gqav5_ddr_read(device, offset, values,
                          GQAV5_BF16_TOKEN_STRIDE);
}

int gqav5_read_fp32_row(const gqav5_device *device,
                        uint32_t base,
                        uint32_t head_stride,
                        uint32_t token_stride,
                        uint32_t head,
                        uint32_t token,
                        float values[GQAV5_HEAD_DIM])
{
    uint32_t offset;

    if (values == NULL
        || gqav5_row_offset(base, head_stride, token_stride,
                            head, token, GQAV5_FP32_TOKEN_STRIDE,
                            &offset) != 0) {
        if (values == NULL)
            errno = EINVAL;
        return -1;
    }
    return gqav5_ddr_read(device, offset, values,
                          GQAV5_FP32_TOKEN_STRIDE);
}

int gqav5_clear_output_row(gqav5_device *device,
                           const gqav5_job *job,
                           uint32_t q_head,
                           uint32_t query_token)
{
    uint32_t offset;
    size_t bytes;

    if (job == NULL || q_head >= GQAV5_Q_HEAD_COUNT) {
        errno = EINVAL;
        return -1;
    }
    bytes = job->bf16_output
        ? GQAV5_BF16_TOKEN_STRIDE : GQAV5_FP32_TOKEN_STRIDE;
    if (gqav5_row_offset(job->o_base, job->o_head_stride,
                         job->o_token_stride, q_head, query_token,
                         bytes, &offset) != 0)
        return -1;
    return gqav5_ddr_fill(device, offset, 0u, bytes);
}

uint16_t gqav5_float_to_bf16_rne(float value)
{
    union {
        float fp32;
        uint32_t bits;
    } encoded = {.fp32 = value};
    uint32_t rounded = encoded.bits + 0x7fffu
        + ((encoded.bits >> 16) & 1u);

    return (uint16_t)(rounded >> 16);
}

float gqav5_bf16_to_float(uint16_t value)
{
    union {
        uint32_t bits;
        float fp32;
    } decoded = {.bits = (uint32_t)value << 16};

    return decoded.fp32;
}
