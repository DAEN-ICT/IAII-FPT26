#define _POSIX_C_SOURCE 200809L

/*
 * Host-only replay application for real Llama3-8B Attention Golden tensors.
 *
 * Input payloads are produced by
 * tool/Benchmark/prepare_llama3_replay_payload.py.  BF16 files are copied as
 * uint16 bit patterns without a floating-point decode/re-encode step.  This
 * program uses the existing FPGAtten UIO / PL-DDR ABI; it does not modify RTL,
 * CSR registers beyond an ordinary job launch, or the FPGA bitstream.
 */

#include "fpgatten_experiment.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

typedef enum {
    REPLAY_DECODE,
    REPLAY_PREFILL,
} replay_mode;

typedef struct {
    const char *input_dir;
    const char *accelerator_uio;
    const char *ddr_uio;
    replay_mode mode;
    uint32_t context;
    uint32_t repeats;
    uint64_t clock_hz;
    unsigned int timeout_ms;
    int verify;
    int preloaded_kv;
} replay_options;

typedef struct {
    uint64_t compared;
    uint64_t finite_compared;
    uint64_t nan_or_inf;
    uint64_t violations_atol_0p02_rtol_0p002;
    uint64_t violations_atol_0p02_rtol_0p02;
    double max_abs_error;
    double mae;
    double rmse;
    double mean_relative_error;
    double max_relative_error;
    double cosine_similarity;
} accuracy_metrics;

static void print_usage(const char *program)
{
    printf("Usage: %s [--clock-hz HZ] [--repeats N] [--timeout-ms MS] [--no-verify] \\\n"
           "       [--preloaded-kv] --mode decode|prefill --context 1..8192 --input-dir DIR \\\n"
           "       ACCELERATOR_UIO PL_DDR_UIO\n",
           program);
    printf("Payload directory must contain q_bf16_le.bin and o_fp32_golden_le.bin; "
           "k_bf16_le.bin/v_bf16_le.bin are required unless --preloaded-kv is used.\n");
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

static int parse_u64(const char *text, uint64_t minimum, uint64_t *value_o)
{
    char *end = NULL;
    unsigned long long value;

    errno = 0;
    value = strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' || value < minimum)
        return -1;
    *value_o = (uint64_t)value;
    return 0;
}

static int parse_options(int argc, char **argv, replay_options *options)
{
    int argument = 1;

    memset(options, 0, sizeof(*options));
    options->repeats = 1u;
    options->clock_hz = UINT64_C(235000000);
    options->verify = 1;

    while (argument < argc) {
        if (strcmp(argv[argument], "--clock-hz") == 0 && argument + 1 < argc) {
            if (parse_u64(argv[argument + 1], 1u, &options->clock_hz) != 0)
                return -1;
            argument += 2;
        } else if (strcmp(argv[argument], "--repeats") == 0 && argument + 1 < argc) {
            if (parse_u32(argv[argument + 1], 1u, 1000u,
                          &options->repeats) != 0)
                return -1;
            argument += 2;
        } else if (strcmp(argv[argument], "--timeout-ms") == 0 && argument + 1 < argc) {
            uint32_t timeout;
            if (parse_u32(argv[argument + 1], 1u, UINT_MAX, &timeout) != 0)
                return -1;
            options->timeout_ms = timeout;
            argument += 2;
        } else if (strcmp(argv[argument], "--no-verify") == 0) {
            options->verify = 0;
            ++argument;
        } else if (strcmp(argv[argument], "--preloaded-kv") == 0) {
            options->preloaded_kv = 1;
            ++argument;
        } else if (strcmp(argv[argument], "--mode") == 0 && argument + 1 < argc) {
            if (strcmp(argv[argument + 1], "decode") == 0)
                options->mode = REPLAY_DECODE;
            else if (strcmp(argv[argument + 1], "prefill") == 0)
                options->mode = REPLAY_PREFILL;
            else
                return -1;
            ++argument;
            ++argument;
        } else if (strcmp(argv[argument], "--context") == 0 && argument + 1 < argc) {
            if (parse_u32(argv[argument + 1], 1u, FPGATTEN_MAX_CONTEXT_TOKENS,
                          &options->context) != 0)
                return -1;
            argument += 2;
        } else if (strcmp(argv[argument], "--input-dir") == 0 && argument + 1 < argc) {
            options->input_dir = argv[argument + 1];
            argument += 2;
        } else {
            break;
        }
    }
    if (options->context == 0u || options->input_dir == NULL
        || argc - argument != 2)
        return -1;
    options->accelerator_uio = argv[argument];
    options->ddr_uio = argv[argument + 1];
    if (options->timeout_ms == 0u)
        options->timeout_ms = options->mode == REPLAY_PREFILL ? 120000u
            : FPGATTEN_DEFAULT_TIMEOUT_MS;
    return 0;
}

static int join_path(char output[PATH_MAX], const char *directory,
                     const char *basename)
{
    int length = snprintf(output, PATH_MAX, "%s/%s", directory, basename);

    return length >= 0 && length < PATH_MAX ? 0 : -1;
}

static int checked_multiply_size(size_t left, size_t right, size_t *result_o)
{
    if (right != 0u && left > SIZE_MAX / right)
        return -1;
    *result_o = left * right;
    return 0;
}

static int expected_sizes(const replay_options *options,
                          size_t *q_bytes_o, size_t *kv_bytes_o,
                          size_t *o_bytes_o, uint32_t *query_tokens_o)
{
    size_t query_tokens = options->mode == REPLAY_DECODE ? 1u : options->context;
    size_t elements;

    if (checked_multiply_size(FPGATTEN_Q_HEAD_COUNT, query_tokens, &elements) != 0
        || checked_multiply_size(elements, FPGATTEN_HEAD_DIM, &elements) != 0
        || checked_multiply_size(elements, sizeof(uint16_t), q_bytes_o) != 0)
        return -1;
    if (checked_multiply_size(FPGATTEN_KV_HEAD_COUNT, options->context, &elements) != 0
        || checked_multiply_size(elements, FPGATTEN_HEAD_DIM, &elements) != 0
        || checked_multiply_size(elements, sizeof(uint16_t), kv_bytes_o) != 0)
        return -1;
    if (checked_multiply_size(FPGATTEN_Q_HEAD_COUNT, query_tokens, &elements) != 0
        || checked_multiply_size(elements, FPGATTEN_HEAD_DIM, &elements) != 0
        || checked_multiply_size(elements, sizeof(float), o_bytes_o) != 0)
        return -1;
    *query_tokens_o = (uint32_t)query_tokens;
    return 0;
}

static int read_file_exact(const char *path, void *destination, size_t bytes)
{
    FILE *handle;
    long file_bytes;
    size_t read_bytes;

    handle = fopen(path, "rb");
    if (handle == NULL)
        return -1;
    if (fseek(handle, 0L, SEEK_END) != 0
        || (file_bytes = ftell(handle)) < 0
        || (uintmax_t)file_bytes != (uintmax_t)bytes
        || fseek(handle, 0L, SEEK_SET) != 0) {
        (void)fclose(handle);
        errno = EINVAL;
        return -1;
    }
    read_bytes = fread(destination, 1u, bytes, handle);
    if (read_bytes != bytes || ferror(handle)) {
        (void)fclose(handle);
        errno = EIO;
        return -1;
    }
    if (fclose(handle) != 0)
        return -1;
    return 0;
}

static int load_payloads(const replay_options *options,
                         size_t q_bytes, size_t kv_bytes, size_t o_bytes,
                         uint8_t **q_o, uint8_t **k_o, uint8_t **v_o,
                         float **golden_o)
{
    char path[PATH_MAX];
    uint8_t *q = NULL;
    uint8_t *k = NULL;
    uint8_t *v = NULL;
    float *golden = NULL;
    const struct {
        const char *name;
        size_t bytes;
        void **target;
    } inputs[] = {
        {"q_bf16_le.bin", q_bytes, (void **)&q},
        {"k_bf16_le.bin", kv_bytes, (void **)&k},
        {"v_bf16_le.bin", kv_bytes, (void **)&v},
        {"o_fp32_golden_le.bin", o_bytes, (void **)&golden},
    };

    for (size_t index = 0; index < sizeof(inputs) / sizeof(inputs[0]); ++index) {
        if (options->preloaded_kv && (index == 1u || index == 2u))
            continue;
        if (join_path(path, options->input_dir, inputs[index].name) != 0
            || (*inputs[index].target = malloc(inputs[index].bytes)) == NULL
            || read_file_exact(path, *inputs[index].target, inputs[index].bytes) != 0) {
            fprintf(stderr, "failed to load %s: %s\n", path, strerror(errno));
            free(q);
            free(k);
            free(v);
            free(golden);
            return -1;
        }
    }
    *q_o = q;
    *k_o = k;
    *v_o = v;
    *golden_o = golden;
    return 0;
}

static int write_real_inputs(fpgatten_device *device, const fpgatten_job *job,
                             const replay_options *options,
                             const uint8_t *q, const uint8_t *k,
                             const uint8_t *v, uint32_t query_tokens)
{
    size_t q_head_bytes = (size_t)query_tokens * FPGATTEN_BF16_TOKEN_STRIDE;
    size_t kv_head_bytes = (size_t)options->context * FPGATTEN_BF16_TOKEN_STRIDE;
    size_t output_head_bytes = (size_t)query_tokens * FPGATTEN_FP32_TOKEN_STRIDE;
    uint32_t query_base = options->mode == REPLAY_DECODE
        ? options->context - 1u : 0u;

    for (uint32_t head = 0; head < FPGATTEN_Q_HEAD_COUNT; ++head) {
        uint32_t offset;

        if (fpgatten_row_offset(job->q_base, job->q_head_stride,
                             job->q_token_stride, head, query_base,
                             q_head_bytes, &offset) != 0
            || fpgatten_ddr_write(device, offset, q + (size_t)head * q_head_bytes,
                               q_head_bytes) != 0
            || fpgatten_row_offset(job->o_base, job->o_head_stride,
                                job->o_token_stride, head, query_base,
                                output_head_bytes, &offset) != 0
            || fpgatten_ddr_fill(device, offset, 0u, output_head_bytes) != 0)
            return -1;
    }
    if (options->preloaded_kv)
        return 0;
    if (k == NULL || v == NULL) {
        errno = EINVAL;
        return -1;
    }
    for (uint32_t head = 0; head < FPGATTEN_KV_HEAD_COUNT; ++head) {
        uint32_t offset;

        if (fpgatten_row_offset(job->k_base, job->k_head_stride,
                             job->k_token_stride, head, 0u,
                             kv_head_bytes, &offset) != 0
            || fpgatten_ddr_write(device, offset, k + (size_t)head * kv_head_bytes,
                               kv_head_bytes) != 0
            || fpgatten_row_offset(job->v_base, job->v_head_stride,
                                job->v_token_stride, head, 0u,
                                kv_head_bytes, &offset) != 0
            || fpgatten_ddr_write(device, offset, v + (size_t)head * kv_head_bytes,
                               kv_head_bytes) != 0)
            return -1;
    }
    return 0;
}

static int read_outputs(const fpgatten_device *device, const fpgatten_job *job,
                        const replay_options *options, float *actual,
                        uint32_t query_tokens)
{
    size_t output_head_bytes = (size_t)query_tokens * FPGATTEN_FP32_TOKEN_STRIDE;
    uint32_t query_base = options->mode == REPLAY_DECODE
        ? options->context - 1u : 0u;

    for (uint32_t head = 0; head < FPGATTEN_Q_HEAD_COUNT; ++head) {
        uint32_t offset;

        if (fpgatten_row_offset(job->o_base, job->o_head_stride,
                             job->o_token_stride, head, query_base,
                             output_head_bytes, &offset) != 0
            || fpgatten_ddr_read(device, offset,
                              actual + (size_t)head * query_tokens * FPGATTEN_HEAD_DIM,
                              output_head_bytes) != 0)
            return -1;
    }
    return 0;
}

static accuracy_metrics compare_outputs(const float *actual, const float *golden,
                                        size_t elements)
{
    accuracy_metrics result;
    long double absolute_sum = 0.0L;
    long double square_sum = 0.0L;
    long double relative_sum = 0.0L;
    long double dot = 0.0L;
    long double actual_squared = 0.0L;
    long double golden_squared = 0.0L;

    memset(&result, 0, sizeof(result));
    for (size_t index = 0; index < elements; ++index) {
        double value = actual[index];
        double reference = golden[index];
        double error;
        double absolute_error;
        double relative_error;

        ++result.compared;
        if (!isfinite(value) || !isfinite(reference)) {
            ++result.nan_or_inf;
            continue;
        }
        ++result.finite_compared;
        error = value - reference;
        absolute_error = fabs(error);
        relative_error = absolute_error / fmax(fabs(reference), 1.0e-8);
        if (absolute_error > result.max_abs_error)
            result.max_abs_error = absolute_error;
        if (relative_error > result.max_relative_error)
            result.max_relative_error = relative_error;
        if (absolute_error > 0.02 + 0.002 * fabs(reference))
            ++result.violations_atol_0p02_rtol_0p002;
        if (absolute_error > 0.02 + 0.02 * fabs(reference))
            ++result.violations_atol_0p02_rtol_0p02;
        absolute_sum += absolute_error;
        square_sum += error * error;
        relative_sum += relative_error;
        dot += value * reference;
        actual_squared += value * value;
        golden_squared += reference * reference;
    }
    if (result.finite_compared != 0u) {
        result.mae = (double)(absolute_sum / result.finite_compared);
        result.rmse = sqrt((double)(square_sum / result.finite_compared));
        result.mean_relative_error =
            (double)(relative_sum / result.finite_compared);
    }
    if (actual_squared > 0.0L && golden_squared > 0.0L)
        result.cosine_similarity = (double)(dot / sqrtl(actual_squared * golden_squared));
    return result;
}

static uint64_t unwrap_total_cycles(const fpgatten_metrics *metrics,
                                    uint64_t clock_hz, uint32_t *wrap_count_o)
{
    const uint64_t counter_modulus = UINT64_C(1) << 32;
    uint64_t wraps = 0u;

    if (metrics->host_elapsed_ns != 0u) {
        long double estimated_cycles =
            (long double)metrics->host_elapsed_ns * (long double)clock_hz
            / 1000000000.0L;
        uint64_t rounded = estimated_cycles <= 0.0L ? 0u
            : (uint64_t)llroundl(estimated_cycles);
        if (rounded > metrics->total_cycles)
            wraps = (rounded - metrics->total_cycles + counter_modulus / 2u)
                / counter_modulus;
    }
    if (wrap_count_o != NULL)
        *wrap_count_o = (uint32_t)wraps;
    return (uint64_t)metrics->total_cycles + wraps * counter_modulus;
}

int main(int argc, char **argv)
{
    replay_options options;
    fpgatten_device device;
    fpgatten_job job;
    fpgatten_metrics metrics;
    uint8_t *q = NULL;
    uint8_t *k = NULL;
    uint8_t *v = NULL;
    float *golden = NULL;
    float *actual = NULL;
    size_t q_bytes;
    size_t kv_bytes;
    size_t o_bytes;
    uint32_t query_tokens;
    uint64_t cycle_sum = 0u;
    uint64_t last_cycles = 0u;
    uint32_t last_wraps = 0u;
    int result = 1;

    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        print_usage(argv[0]);
        return 0;
    }
    if (parse_options(argc, argv, &options) != 0
        || expected_sizes(&options, &q_bytes, &kv_bytes, &o_bytes,
                          &query_tokens) != 0) {
        print_usage(argv[0]);
        return 2;
    }
    if (load_payloads(&options, q_bytes, kv_bytes, o_bytes,
                      &q, &k, &v, &golden) != 0)
        goto cleanup;
    actual = malloc(o_bytes);
    if (actual == NULL) {
        fprintf(stderr, "failed to allocate output buffer\n");
        goto cleanup;
    }
    if (options.mode == REPLAY_DECODE)
        fpgatten_default_decode_job(&job, options.context);
    else
        fpgatten_default_prefill_job(&job, options.context, 0u, query_tokens);
    if (fpgatten_device_open(&device, options.accelerator_uio, options.ddr_uio) != 0) {
        fprintf(stderr, "failed to open FPGAtten device: %s\n", strerror(errno));
        goto cleanup;
    }
    printf("FPGATTEN_LLAMA3_REPLAY_BEGIN mode=%s context=%" PRIu32
           " query_tokens=%" PRIu32 " repeats=%" PRIu32
           " core_hz=%" PRIu64 " preloaded_kv=%d input_dir=%s\n",
           options.mode == REPLAY_DECODE ? "decode" : "prefill",
           options.context, query_tokens, options.repeats,
           options.clock_hz, options.preloaded_kv, options.input_dir);
    printf("FPGATTEN_LLAMA3_DEVICE version=0x%08" PRIx32 " build=0x%08" PRIx32 "\n",
           fpgatten_reg_read(&device, FPGATTEN_CSR_VERSION),
           fpgatten_reg_read(&device, FPGATTEN_CSR_BUILD_ID));
    if (write_real_inputs(&device, &job, &options, q, k, v, query_tokens) != 0) {
        fprintf(stderr, "failed to preload real Q/K/V: %s\n", strerror(errno));
        goto device_cleanup;
    }
    for (uint32_t iteration = 0; iteration < options.repeats; ++iteration) {
        uint32_t wraps;
        uint64_t cycles;

        if (fpgatten_run_job(&device, &job, 1, 1, options.timeout_ms, &metrics) != 0) {
            fprintf(stderr, "accelerator run failed on iteration %" PRIu32 ": %s\n",
                    iteration + 1u, strerror(errno));
            goto device_cleanup;
        }
        cycles = unwrap_total_cycles(&metrics, options.clock_hz, &wraps);
        cycle_sum += cycles;
        last_cycles = cycles;
        last_wraps = wraps;
        printf("FPGATTEN_LLAMA3_TIMING iteration=%" PRIu32 " cycles=%" PRIu64
               " raw_cycles=%" PRIu32 " counter_wraps=%" PRIu32
               " hardware_tokens_per_second=%.6f host_elapsed_ms=%.6f\n",
               iteration + 1u, cycles, metrics.total_cycles, wraps,
               cycles == 0u ? 0.0 : (double)query_tokens * (double)options.clock_hz
                   / (double)cycles,
               (double)metrics.host_elapsed_ns / 1000000.0);
    }
    if (read_outputs(&device, &job, &options, actual, query_tokens) != 0) {
        fprintf(stderr, "failed to read FPGA output: %s\n", strerror(errno));
        goto device_cleanup;
    }
    if (options.verify) {
        accuracy_metrics accuracy = compare_outputs(actual, golden,
            o_bytes / sizeof(*golden));

        printf("FPGATTEN_LLAMA3_REPLAY_RESULT mode=%s context=%" PRIu32
               " query_tokens=%" PRIu32 " repeats=%" PRIu32
               " last_cycles=%" PRIu64 " mean_cycles=%.3f"
               " last_tokens_per_second=%.6f mean_tokens_per_second=%.6f"
               " max_abs_error=%.9g mae=%.9g rmse=%.9g"
               " mean_relative_error=%.9g max_relative_error=%.9g"
               " cosine_similarity=%.12g compared=%" PRIu64
               " finite_compared=%" PRIu64 " nan_or_inf=%" PRIu64
               " violations_atol_0p02_rtol_0p002=%" PRIu64
               " violations_atol_0p02_rtol_0p02=%" PRIu64
               " counter_wraps=%" PRIu32 "\n",
               options.mode == REPLAY_DECODE ? "decode" : "prefill",
               options.context, query_tokens, options.repeats,
               last_cycles, (double)cycle_sum / options.repeats,
               last_cycles == 0u ? 0.0
                   : (double)query_tokens * (double)options.clock_hz / last_cycles,
               cycle_sum == 0u ? 0.0
                   : (double)query_tokens * (double)options.clock_hz
                       * options.repeats / cycle_sum,
               accuracy.max_abs_error, accuracy.mae, accuracy.rmse,
               accuracy.mean_relative_error, accuracy.max_relative_error,
               accuracy.cosine_similarity, accuracy.compared,
               accuracy.finite_compared, accuracy.nan_or_inf,
               accuracy.violations_atol_0p02_rtol_0p002,
               accuracy.violations_atol_0p02_rtol_0p02, last_wraps);
        if (accuracy.nan_or_inf != 0u
            || accuracy.violations_atol_0p02_rtol_0p002 != 0u) {
            fprintf(stderr, "FPGATTEN_LLAMA3_REPLAY_FAIL numerical tolerance exceeded\n");
            goto device_cleanup;
        }
    } else {
        printf("FPGATTEN_LLAMA3_REPLAY_RESULT mode=%s context=%" PRIu32
               " verify=disabled last_cycles=%" PRIu64 "\n",
               options.mode == REPLAY_DECODE ? "decode" : "prefill",
               options.context, last_cycles);
    }
    result = 0;

device_cleanup:
    (void)fpgatten_soft_reset(&device, 1000u);
    fpgatten_device_close(&device);
cleanup:
    free(q);
    free(k);
    free(v);
    free(golden);
    free(actual);
    return result;
}
