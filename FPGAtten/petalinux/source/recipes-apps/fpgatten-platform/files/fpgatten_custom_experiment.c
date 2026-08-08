#define _POSIX_C_SOURCE 200809L

#include "fpgatten_experiment.h"

#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_token_count(const char *text, uint32_t *value_o)
{
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0'
        || value == 0u || value > FPGATTEN_MAX_CONTEXT_TOKENS)
        return -1;
    *value_o = (uint32_t)value;
    return 0;
}

static uint64_t unwrap_total_cycles(const fpgatten_metrics *metrics,
                                    uint64_t clock_hz,
                                    uint32_t *wrap_count_o)
{
    const uint64_t counter_modulus = UINT64_C(1) << 32;
    uint64_t wraps = 0u;

    if (metrics->host_elapsed_ns != 0u) {
        long double measured_cycles =
            (long double)metrics->host_elapsed_ns * (long double)clock_hz
            / 1000000000.0L;
        uint64_t measured_rounded = measured_cycles <= 0.0L ? 0u
            : (uint64_t)llroundl(measured_cycles);

        if (measured_rounded > metrics->total_cycles) {
            wraps = (measured_rounded - metrics->total_cycles
                     + counter_modulus / 2u) / counter_modulus;
        }
    }
    if (wrap_count_o != NULL)
        *wrap_count_o = (uint32_t)wraps;
    return (uint64_t)metrics->total_cycles + wraps * counter_modulus;
}

static int prepare_inputs(fpgatten_device *device, const fpgatten_job *job)
{
    uint16_t row[FPGATTEN_HEAD_DIM];

    /*
     * Q/K 置零，因此 softmax 为均匀权重。V 使用可辨识的 head/token/dim
     * 数据，便于用户把这里替换成自己的输入生成器或文件读取代码。
     */
    memset(row, 0, sizeof(row));
    for (uint32_t query = 0;
         query < (job->prefill_direct ? job->prefill_query_tokens : 1u);
         ++query) {
        uint32_t query_token = job->query_token_base + query;
        for (uint32_t q_head = 0; q_head < FPGATTEN_Q_HEAD_COUNT; ++q_head) {
            if (fpgatten_write_bf16_row(device, job->q_base,
                                     job->q_head_stride,
                                     job->q_token_stride,
                                     q_head, query_token, row) != 0
                || fpgatten_clear_output_row(device, job, q_head,
                                          query_token) != 0)
                return -1;
        }
    }

    for (uint32_t kv_head = 0; kv_head < FPGATTEN_KV_HEAD_COUNT; ++kv_head) {
        for (uint32_t token = 0; token < job->context_tokens; ++token) {
            memset(row, 0, sizeof(row));
            if (fpgatten_write_bf16_row(device, job->k_base,
                                     job->k_head_stride,
                                     job->k_token_stride,
                                     kv_head, token, row) != 0)
                return -1;
            for (uint32_t dimension = 0;
                 dimension < FPGATTEN_HEAD_DIM; ++dimension) {
                float value = (float)(kv_head + 1u)
                    + (float)token / (float)job->context_tokens
                    + (float)dimension / 256.0f;
                row[dimension] = fpgatten_float_to_bf16_rne(value);
            }
            if (fpgatten_write_bf16_row(device, job->v_base,
                                     job->v_head_stride,
                                     job->v_token_stride,
                                     kv_head, token, row) != 0)
                return -1;
        }
    }
    return 0;
}

static void print_metrics(const fpgatten_metrics *metrics, uint64_t clock_hz,
                          uint32_t completed_query_tokens)
{
    uint32_t counter_wraps;
    uint64_t total_cycles =
        unwrap_total_cycles(metrics, clock_hz, &counter_wraps);
    double milliseconds = 1000.0 * (double)total_cycles
        / (double)clock_hz;
    double token_per_second = total_cycles == 0u ? 0.0
        : (double)completed_query_tokens * (double)clock_hz
            / (double)total_cycles;
    double host_elapsed_ms =
        (double)metrics->host_elapsed_ns / 1000000.0;

    printf("结果: query_tokens=%" PRIu32 " cycles=%" PRIu64
           " raw_cycles=%" PRIu32 " counter_wraps=%" PRIu32
           " latency_ms=%.6f host_elapsed_ms=%.6f token/s=%.6f\n",
           completed_query_tokens, total_cycles, metrics->total_cycles,
           counter_wraps, milliseconds, host_elapsed_ms,
           token_per_second);
    printf("阶段: qk=%" PRIu32 " softmax=%" PRIu32
           " pv=%" PRIu32 " overlap=%" PRIu32
           " qk_pv_overlap=%" PRIu32
           " dma_lane_overlap=%" PRIu32 "\n",
           metrics->qk_cycles, metrics->softmax_cycles,
           metrics->pv_cycles, metrics->overlap_cycles,
           metrics->qk_pv_overlap_cycles,
           metrics->dma_lane_overlap_cycles);
    printf("DMA: stall=%" PRIu32 " ar=%" PRIu32
           " beats=%" PRIu32 " ar_wait=%" PRIu32
           " r_gap=%" PRIu32 " r_bp=%" PRIu32
           " bank_wait=%" PRIu32 " emit_wait=%" PRIu32
           " max_out=%" PRIu32 " split_4k=%" PRIu32 "\n",
           metrics->dma_stall_cycles, metrics->dma_ar_count,
           metrics->dma_read_beats, metrics->dma_ar_wait_cycles,
           metrics->dma_r_gap_cycles,
           metrics->dma_r_backpressure_cycles,
           metrics->dma_bank_wait_cycles,
           metrics->dma_emit_wait_cycles,
           metrics->dma_max_outstanding, metrics->dma_4k_splits);
    printf("片上复用: kv_hit=%" PRIu32 " kv_miss=%" PRIu32
           " prefetch=%" PRIu32 "\n",
           metrics->kv_cache_hits, metrics->kv_cache_misses,
           metrics->prefetch_issues);
}

static int analyze_outputs(const fpgatten_device *device,
                           const fpgatten_job *job,
                           float first_output[FPGATTEN_HEAD_DIM])
{
    float output[FPGATTEN_HEAD_DIM];
    double visible_sum[FPGATTEN_KV_HEAD_COUNT][FPGATTEN_HEAD_DIM];
    double absolute_error_sum = 0.0;
    double maximum_error = 0.0;
    uint64_t compared = 0u;
    uint64_t violations = 0u;
    uint32_t initial_visible = job->causal
        ? job->query_token_base + 1u : job->context_tokens;

    memset(visible_sum, 0, sizeof(visible_sum));
    for (uint32_t kv_head = 0;
         kv_head < FPGATTEN_KV_HEAD_COUNT; ++kv_head) {
        for (uint32_t token = 0; token < initial_visible; ++token) {
            for (uint32_t dimension = 0;
                 dimension < FPGATTEN_HEAD_DIM; ++dimension) {
                float value = (float)(kv_head + 1u)
                    + (float)token / (float)job->context_tokens
                    + (float)dimension / 256.0f;
                visible_sum[kv_head][dimension] +=
                    (double)fpgatten_bf16_to_float(
                        fpgatten_float_to_bf16_rne(value));
            }
        }
    }

    for (uint32_t query = 0;
         query < (job->prefill_direct ? job->prefill_query_tokens : 1u);
         ++query) {
        uint32_t query_token = job->query_token_base + query;
        uint32_t visible_tokens = job->causal
            ? query_token + 1u : job->context_tokens;
        if (job->causal && query != 0u) {
            for (uint32_t kv_head = 0;
                 kv_head < FPGATTEN_KV_HEAD_COUNT; ++kv_head) {
                for (uint32_t dimension = 0;
                     dimension < FPGATTEN_HEAD_DIM; ++dimension) {
                    float value = (float)(kv_head + 1u)
                        + (float)query_token / (float)job->context_tokens
                        + (float)dimension / 256.0f;
                    visible_sum[kv_head][dimension] +=
                        (double)fpgatten_bf16_to_float(
                            fpgatten_float_to_bf16_rne(value));
                }
            }
        }
        for (uint32_t q_head = 0; q_head < FPGATTEN_Q_HEAD_COUNT; ++q_head) {
            uint32_t kv_head = q_head / 4u;
            if (fpgatten_read_fp32_row(device, job->o_base,
                                    job->o_head_stride,
                                    job->o_token_stride,
                                    q_head, query_token,
                                    output) != 0)
                return -1;
            if (query == 0u && q_head == 0u)
                memcpy(first_output, output, sizeof(output));
            for (uint32_t dimension = 0;
                 dimension < FPGATTEN_HEAD_DIM; ++dimension) {
                double error;
                double expected = visible_sum[kv_head][dimension]
                    / (double)visible_tokens;
                double tolerance = fmax(0.020, 0.002 * fabs(expected));
                error = fabs((double)output[dimension] - expected);
                if (error > maximum_error)
                    maximum_error = error;
                if (!isfinite(output[dimension]) || error > tolerance)
                    ++violations;
                absolute_error_sum += error;
                ++compared;
            }
        }
    }
    printf("数值: compared=%" PRIu64 " max_error=%.8f mae=%.8f"
           " violations=%" PRIu64 "\n",
           compared, maximum_error,
           absolute_error_sum / (double)compared, violations);
    return violations == 0u ? 0 : 1;
}

int main(int argc, char **argv)
{
    const char *accelerator_uio;
    const char *ddr_uio;
    uint32_t context;
    uint32_t query_tokens = 1u;
    uint64_t clock_hz = 230000000u;
    fpgatten_device device;
    fpgatten_job job;
    fpgatten_metrics metrics;
    float output[FPGATTEN_HEAD_DIM];
    int analysis_result;
    int prefill = 0;
    int result = 1;

    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        printf("用法: %s ACCELERATOR_UIO PL_DDR_UIO CONTEXT\n", argv[0]);
        printf("      %s [--clock-hz HZ] --prefill ACCELERATOR_UIO PL_DDR_UIO"
               " CONTEXT QUERY_TOKENS\n", argv[0]);
        printf("--clock-hz 默认 230000000 Hz。\n");
        printf("示例: %s /dev/uio4 /dev/uio5 128\n", argv[0]);
        printf("      %s --prefill /dev/uio4 /dev/uio5 128 128\n",
               argv[0]);
        return 0;
    }
    int argument = 1;
    if (argc >= 3 && strcmp(argv[argument], "--clock-hz") == 0) {
        char *end = NULL;

        errno = 0;
        clock_hz = strtoull(argv[argument + 1], &end, 0);
        if (errno != 0 || end == argv[argument + 1] || *end != '\0'
            || clock_hz == 0u) {
            fprintf(stderr, "invalid --clock-hz value\n");
            return 2;
        }
        argument += 2;
    }
    if (argc - argument == 5 && strcmp(argv[argument], "--prefill") == 0) {
        prefill = 1;
        accelerator_uio = argv[argument + 1];
        ddr_uio = argv[argument + 2];
        if (parse_token_count(argv[argument + 3], &context) != 0
            || parse_token_count(argv[argument + 4], &query_tokens) != 0
            || query_tokens > context) {
            fprintf(stderr, "prefill 参数非法，要求 1 <= QUERY_TOKENS <= CONTEXT <= 8192\n");
            return 2;
        }
    } else if (argc - argument == 3 &&
               parse_token_count(argv[argument + 2], &context) == 0) {
        accelerator_uio = argv[argument];
        ddr_uio = argv[argument + 1];
    } else {
        fprintf(stderr,
                "用法: %s ACCELERATOR_UIO PL_DDR_UIO CONTEXT\n",
                argv[0]);
        fprintf(stderr,
                 "      %s [--clock-hz HZ] --prefill ACCELERATOR_UIO PL_DDR_UIO"
                " CONTEXT QUERY_TOKENS\n", argv[0]);
        fprintf(stderr, "示例: %s /dev/uio4 /dev/uio5 128\n", argv[0]);
        return 2;
    }
    if (prefill)
        fpgatten_default_prefill_job(&job, context, 0u, query_tokens);
    else
        fpgatten_default_decode_job(&job, context);

    if (fpgatten_device_open(&device, accelerator_uio, ddr_uio) != 0) {
        fprintf(stderr, "failed to open FPGAtten device: %s\n", strerror(errno));
        return 1;
    }
    printf("设备: version=0x%08" PRIx32 " build=0x%08" PRIx32 "\n",
           fpgatten_reg_read(&device, FPGATTEN_CSR_VERSION),
           fpgatten_reg_read(&device, FPGATTEN_CSR_BUILD_ID));
    printf("准备: mode=%s context=%" PRIu32 " query_tokens=%" PRIu32
           "，写入 Q/K/V 并清零 O\n",
           prefill ? "prefill" : "decode", context, query_tokens);

    if (prepare_inputs(&device, &job) != 0) {
        fprintf(stderr, "输入搬运失败: %s\n", strerror(errno));
        goto cleanup;
    }
    if (fpgatten_run_job(&device, &job, 1, 1,
                      prefill ? 120000u : FPGATTEN_DEFAULT_TIMEOUT_MS,
                      &metrics) != 0) {
        fprintf(stderr, "加速器运行失败: %s\n", strerror(errno));
        goto cleanup;
    }
    analysis_result = analyze_outputs(&device, &job, output);
    if (analysis_result < 0) {
        fprintf(stderr, "结果读取失败: %s\n", strerror(errno));
        goto cleanup;
    }
    if (analysis_result > 0) {
        fprintf(stderr, "数值校验失败：存在超出容差的输出\n");
        goto cleanup;
    }

    print_metrics(&metrics, clock_hz, query_tokens);
    printf("O[q_head=0, dim=0..7]:");
    for (unsigned int dimension = 0; dimension < 8u; ++dimension)
        printf(" %.6f", output[dimension]);
    putchar('\n');
    result = 0;

cleanup:
    (void)fpgatten_soft_reset(&device, 1000u);
    fpgatten_device_close(&device);
    return result;
}
