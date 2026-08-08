#ifndef GQAV5_EXPERIMENT_H
#define GQAV5_EXPERIMENT_H

#include "gqav5_csr.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GQAV5_PL_DDR_MAP_BYTES       0x10000000u
#define GQAV5_Q_BASE_DEFAULT         0x00000000u
#define GQAV5_K_BASE_DEFAULT         0x04000000u
#define GQAV5_V_BASE_DEFAULT         0x05000000u
#define GQAV5_O_BASE_DEFAULT         0x06000000u
#define GQAV5_Q_HEAD_COUNT           32u
#define GQAV5_KV_HEAD_COUNT          8u
#define GQAV5_HEAD_DIM               128u
#define GQAV5_MAX_CONTEXT_TOKENS     8192u
#define GQAV5_DEFAULT_TIMEOUT_MS     30000u
#define GQAV5_BOARD_LOCK_PATH        "/run/lock/fpgatten/board.lock"

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
} gqav5_device;

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
} gqav5_job;

typedef struct {
    uint32_t raw;
    int busy;
    int done;
    int error;
    int irq;
} gqav5_status;

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
} gqav5_metrics;

/*
 * 打开当前 Z19-P 的两个 generic-uio 设备并独占实验窗口。
 * 成功返回 0；失败返回 -1 并设置 errno。
 */
int gqav5_device_open(gqav5_device *device,
                      const char *accelerator_uio,
                      const char *ddr_uio);

/*
 * 使用调用者提供的内存映射初始化设备，供单元测试或已有 mmap 的程序使用。
 * 此方式不拥有映射，也不支持 UIO 中断等待。
 */
int gqav5_device_init_mapped(gqav5_device *device,
                             volatile void *csr,
                             size_t csr_bytes,
                             volatile void *ddr,
                             size_t ddr_bytes);

void gqav5_device_close(gqav5_device *device);
int gqav5_check_identity(const gqav5_device *device);
void gqav5_set_counter_read_delay(gqav5_device *device,
                                  unsigned int delay_us);

uint32_t gqav5_reg_read(const gqav5_device *device, uint32_t offset);
int gqav5_reg_write(gqav5_device *device, uint32_t offset, uint32_t value);

int gqav5_get_status(const gqav5_device *device, gqav5_status *status);
int gqav5_clear_status(gqav5_device *device);
int gqav5_soft_reset(gqav5_device *device, unsigned int timeout_ms);

void gqav5_default_decode_job(gqav5_job *job, uint32_t context_tokens);
void gqav5_default_prefill_job(gqav5_job *job,
                               uint32_t context_tokens,
                               uint32_t query_token_base,
                               uint32_t query_tokens);
int gqav5_validate_job(const gqav5_device *device,
                       const gqav5_job *job,
                       int direct_only);
int gqav5_program_job(gqav5_device *device,
                      const gqav5_job *job,
                      int direct_only);
int gqav5_arm_irq(gqav5_device *device);
int gqav5_start(gqav5_device *device);
int gqav5_wait_irq(gqav5_device *device, unsigned int timeout_ms);
int gqav5_wait_poll(gqav5_device *device, unsigned int timeout_ms);
int gqav5_run_job(gqav5_device *device,
                  const gqav5_job *job,
                  int direct_only,
                  int use_interrupt,
                  unsigned int timeout_ms,
                  gqav5_metrics *metrics);
int gqav5_read_metrics(gqav5_device *device, gqav5_metrics *metrics);

int gqav5_ddr_write(gqav5_device *device,
                    uint32_t offset,
                    const void *source,
                    size_t bytes);
int gqav5_ddr_read(const gqav5_device *device,
                   uint32_t offset,
                   void *destination,
                   size_t bytes);
int gqav5_ddr_fill(gqav5_device *device,
                   uint32_t offset,
                   uint8_t value,
                   size_t bytes);

int gqav5_row_offset(uint32_t base,
                     uint32_t head_stride,
                     uint32_t token_stride,
                     uint32_t head,
                     uint32_t token,
                     size_t row_bytes,
                     uint32_t *offset);
int gqav5_write_bf16_row(gqav5_device *device,
                         uint32_t base,
                         uint32_t head_stride,
                         uint32_t token_stride,
                         uint32_t head,
                         uint32_t token,
                         const uint16_t values[GQAV5_HEAD_DIM]);
int gqav5_read_bf16_row(const gqav5_device *device,
                        uint32_t base,
                        uint32_t head_stride,
                        uint32_t token_stride,
                        uint32_t head,
                        uint32_t token,
                        uint16_t values[GQAV5_HEAD_DIM]);
int gqav5_read_fp32_row(const gqav5_device *device,
                        uint32_t base,
                        uint32_t head_stride,
                        uint32_t token_stride,
                        uint32_t head,
                        uint32_t token,
                        float values[GQAV5_HEAD_DIM]);
int gqav5_clear_output_row(gqav5_device *device,
                           const gqav5_job *job,
                           uint32_t q_head,
                           uint32_t query_token);

uint16_t gqav5_float_to_bf16_rne(float value);
float gqav5_bf16_to_float(uint16_t value);

#ifdef __cplusplus
}
#endif

#endif
