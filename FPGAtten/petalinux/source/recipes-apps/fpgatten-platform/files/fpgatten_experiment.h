#ifndef FPGATTEN_EXPERIMENT_H
#define FPGATTEN_EXPERIMENT_H

#include "fpgatten_csr.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FPGATTEN_PL_DDR_MAP_BYTES       0x10000000u
#define FPGATTEN_Q_BASE_DEFAULT         0x00000000u
#define FPGATTEN_K_BASE_DEFAULT         0x04000000u
#define FPGATTEN_V_BASE_DEFAULT         0x05000000u
#define FPGATTEN_O_BASE_DEFAULT         0x06000000u
#define FPGATTEN_Q_HEAD_COUNT           32u
#define FPGATTEN_KV_HEAD_COUNT          8u
#define FPGATTEN_HEAD_DIM               128u
#define FPGATTEN_MAX_CONTEXT_TOKENS     8192u
#define FPGATTEN_DEFAULT_TIMEOUT_MS     30000u
#define FPGATTEN_BOARD_LOCK_PATH        "/run/lock/fpgatten/board.lock"

typedef struct {
    int accelerator_fd;
    int ddr_fd;
    int lock_fd;
    volatile uint8_t *csr;
    volatile uint8_t *ddr;
    size_t csr_bytes;
    size_t ddr_bytes;
    unsigned int counter_read_delay_us;
    int owns_mappings;
} fpgatten_device;

typedef struct {
    uint32_t context_tokens;
    uint32_t query_token_base;
    uint32_t query_valid_rows;
    uint32_t prefill_query_tokens;
    uint32_t prefill_direct;
    uint32_t causal;
    uint32_t q_base;
    uint32_t k_base;
    uint32_t v_base;
    uint32_t o_base;
    uint32_t q_head_stride;
    uint32_t q_token_stride;
    uint32_t k_head_stride;
    uint32_t k_token_stride;
    uint32_t v_head_stride;
    uint32_t v_token_stride;
    uint32_t o_head_stride;
    uint32_t o_token_stride;
    uint32_t bf16_output;
    uint32_t pv_skip_enable;
    uint32_t pv_skip_lambda_bits;
} fpgatten_job;

typedef struct {
    uint32_t raw;
    int busy;
    int done;
    int error;
    int irq;
} fpgatten_status;

typedef struct {
    uint32_t total_cycles;
    uint32_t overlap_cycles;
    uint32_t qk_pv_overlap_cycles;
    uint32_t dma_lane_overlap_cycles;
    uint32_t load_stall_cycles;
    uint32_t core_total_cycles;
    uint32_t qk_cycles;
    uint32_t softmax_cycles;
    uint32_t pv_cycles;
    uint32_t dma_stall_cycles;
    uint32_t pv_blocks_total;
    uint32_t pv_blocks_skipped;
    uint32_t dma_ar_count;
    uint32_t dma_read_beats;
    uint32_t dma_ar_wait_cycles;
    uint32_t dma_r_gap_cycles;
    uint32_t dma_r_backpressure_cycles;
    uint32_t dma_bank_wait_cycles;
    uint32_t dma_emit_wait_cycles;
    uint32_t dma_max_outstanding;
    uint32_t dma_4k_splits;
    uint32_t kv_cache_hits;
    uint32_t kv_cache_misses;
    uint32_t prefetch_issues;
    /*
     * Monotonic host time from immediately before START through completion.
     * It disambiguates 32-bit CSR wraps on long jobs; exact low bits still
     * come from the hardware counter.
     */
    uint64_t host_elapsed_ns;
} fpgatten_metrics;

/*
 * 打开当前 Z19-P 的两个 generic-uio 设备并独占实验窗口。
 * 成功返回 0；失败返回 -1 并设置 errno。
 */
int fpgatten_device_open(fpgatten_device *device,
                      const char *accelerator_uio,
                      const char *ddr_uio);

/*
 * 使用调用者提供的内存映射初始化设备，供单元测试或已有 mmap 的程序使用。
 * 此方式不拥有映射，也不支持 UIO 中断等待。
 */
int fpgatten_device_init_mapped(fpgatten_device *device,
                             volatile void *csr,
                             size_t csr_bytes,
                             volatile void *ddr,
                             size_t ddr_bytes);

void fpgatten_device_close(fpgatten_device *device);
int fpgatten_check_identity(const fpgatten_device *device);
void fpgatten_set_counter_read_delay(fpgatten_device *device,
                                  unsigned int delay_us);

uint32_t fpgatten_reg_read(const fpgatten_device *device, uint32_t offset);
int fpgatten_reg_write(fpgatten_device *device, uint32_t offset, uint32_t value);

int fpgatten_get_status(const fpgatten_device *device, fpgatten_status *status);
int fpgatten_clear_status(fpgatten_device *device);
int fpgatten_soft_reset(fpgatten_device *device, unsigned int timeout_ms);

void fpgatten_default_decode_job(fpgatten_job *job, uint32_t context_tokens);
void fpgatten_default_prefill_job(fpgatten_job *job,
                               uint32_t context_tokens,
                               uint32_t query_token_base,
                               uint32_t query_tokens);
int fpgatten_validate_job(const fpgatten_device *device,
                       const fpgatten_job *job,
                       int direct_only);
int fpgatten_program_job(fpgatten_device *device,
                      const fpgatten_job *job,
                      int direct_only);
int fpgatten_arm_irq(fpgatten_device *device);
int fpgatten_start(fpgatten_device *device);
int fpgatten_wait_irq(fpgatten_device *device, unsigned int timeout_ms);
int fpgatten_wait_poll(fpgatten_device *device, unsigned int timeout_ms);
int fpgatten_run_job(fpgatten_device *device,
                  const fpgatten_job *job,
                  int direct_only,
                  int use_interrupt,
                  unsigned int timeout_ms,
                  fpgatten_metrics *metrics);
int fpgatten_read_metrics(fpgatten_device *device, fpgatten_metrics *metrics);

int fpgatten_ddr_write(fpgatten_device *device,
                    uint32_t offset,
                    const void *source,
                    size_t bytes);
int fpgatten_ddr_read(const fpgatten_device *device,
                   uint32_t offset,
                   void *destination,
                   size_t bytes);
int fpgatten_ddr_fill(fpgatten_device *device,
                   uint32_t offset,
                   uint8_t value,
                   size_t bytes);

int fpgatten_row_offset(uint32_t base,
                     uint32_t head_stride,
                     uint32_t token_stride,
                     uint32_t head,
                     uint32_t token,
                     size_t row_bytes,
                     uint32_t *offset);
int fpgatten_write_bf16_row(fpgatten_device *device,
                         uint32_t base,
                         uint32_t head_stride,
                         uint32_t token_stride,
                         uint32_t head,
                         uint32_t token,
                         const uint16_t values[FPGATTEN_HEAD_DIM]);
int fpgatten_read_bf16_row(const fpgatten_device *device,
                        uint32_t base,
                        uint32_t head_stride,
                        uint32_t token_stride,
                        uint32_t head,
                        uint32_t token,
                        uint16_t values[FPGATTEN_HEAD_DIM]);
int fpgatten_read_fp32_row(const fpgatten_device *device,
                        uint32_t base,
                        uint32_t head_stride,
                        uint32_t token_stride,
                        uint32_t head,
                        uint32_t token,
                        float values[FPGATTEN_HEAD_DIM]);
int fpgatten_clear_output_row(fpgatten_device *device,
                           const fpgatten_job *job,
                           uint32_t q_head,
                           uint32_t query_token);

uint16_t fpgatten_float_to_bf16_rne(float value);
float fpgatten_bf16_to_float(uint16_t value);

#ifdef __cplusplus
}
#endif

#endif
