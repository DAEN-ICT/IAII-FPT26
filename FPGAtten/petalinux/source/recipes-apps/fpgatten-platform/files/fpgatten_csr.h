#ifndef FPGATTEN_CSR_H
#define FPGATTEN_CSR_H

#include <stdint.h>

#define FPGATTEN_CSR_MAP_BYTES              0x1000u
#define FPGATTEN_CSR_CONTROL                0x000u
#define FPGATTEN_CSR_STATUS                 0x004u
#define FPGATTEN_CSR_CONTEXT_TOKENS         0x008u
#define FPGATTEN_CSR_QUERY_CONFIG           0x00cu
#define FPGATTEN_CSR_Q_BASE                 0x010u
#define FPGATTEN_CSR_K_BASE                 0x014u
#define FPGATTEN_CSR_V_BASE                 0x018u
#define FPGATTEN_CSR_O_BASE                 0x01cu
#define FPGATTEN_CSR_Q_HEAD_STRIDE          0x020u
#define FPGATTEN_CSR_Q_TOKEN_STRIDE         0x024u
#define FPGATTEN_CSR_K_HEAD_STRIDE          0x028u
#define FPGATTEN_CSR_K_TOKEN_STRIDE         0x02cu
#define FPGATTEN_CSR_V_HEAD_STRIDE          0x030u
#define FPGATTEN_CSR_V_TOKEN_STRIDE         0x034u
#define FPGATTEN_CSR_O_HEAD_STRIDE          0x038u
#define FPGATTEN_CSR_O_TOKEN_STRIDE         0x03cu
#define FPGATTEN_CSR_VERSION                0x044u
#define FPGATTEN_CSR_TOTAL_CYCLES           0x048u
#define FPGATTEN_CSR_OVERLAP_CYCLES         0x04cu
#define FPGATTEN_CSR_LOAD_STALL_CYCLES      0x050u
#define FPGATTEN_CSR_OPT_CTRL               0x060u
#define FPGATTEN_CSR_PV_LAMBDA              0x064u
#define FPGATTEN_CSR_CORE_TOTAL             0x068u
#define FPGATTEN_CSR_CORE_QK                0x06cu
#define FPGATTEN_CSR_CORE_SOFTMAX           0x070u
#define FPGATTEN_CSR_CORE_PV                0x074u
#define FPGATTEN_CSR_CORE_DMA_STALL         0x078u
#define FPGATTEN_CSR_PV_BLOCK_TOTAL         0x07cu
#define FPGATTEN_CSR_PV_BLOCK_SKIPPED       0x080u
#define FPGATTEN_CSR_BUILD_ID               0x084u
#define FPGATTEN_CSR_DMA_AR_COUNT           0x088u
#define FPGATTEN_CSR_DMA_READ_BEATS         0x08cu
#define FPGATTEN_CSR_DMA_AR_WAIT            0x090u
#define FPGATTEN_CSR_DMA_R_GAP              0x094u
#define FPGATTEN_CSR_DMA_R_BACKPRESSURE     0x098u
#define FPGATTEN_CSR_DMA_BANK_WAIT          0x09cu
#define FPGATTEN_CSR_DMA_EMIT_WAIT          0x0a0u
#define FPGATTEN_CSR_DMA_MAX_OUTSTANDING    0x0a4u
#define FPGATTEN_CSR_DMA_4K_SPLITS          0x0a8u
#define FPGATTEN_CSR_PREFILL_QUERY_TOKENS   0x0acu
#define FPGATTEN_CSR_KV_CACHE_HITS          0x0b0u
#define FPGATTEN_CSR_KV_CACHE_MISSES        0x0b4u
#define FPGATTEN_CSR_PREFETCH_ISSUES        0x0b8u
#define FPGATTEN_CSR_QK_PV_OVERLAP          0x0bcu
#define FPGATTEN_CSR_DMA_LANE_OVERLAP       0x0c0u

#define FPGATTEN_CONTROL_START              (1u << 0)
#define FPGATTEN_CONTROL_CLEAR_DONE         (1u << 1)
#define FPGATTEN_CONTROL_CLEAR_ERROR        (1u << 2)
#define FPGATTEN_CONTROL_SOFT_RESET         (1u << 3)

#define FPGATTEN_STATUS_BUSY                (1u << 0)
#define FPGATTEN_STATUS_DONE                (1u << 1)
#define FPGATTEN_STATUS_ERROR               (1u << 2)
#define FPGATTEN_STATUS_IRQ                 (1u << 3)

#define FPGATTEN_OPT_QK_REUSE               (1u << 0)
#define FPGATTEN_OPT_BF16_OUTPUT             (1u << 2)
#define FPGATTEN_OPT_PV_SKIP                 (1u << 3)
#define FPGATTEN_OPT_PREFILL_DIRECT          (1u << 4)

#define FPGATTEN_VERSION_VALUE               0x47514131u
#define FPGATTEN_BUILD_ID_VALUE              0x56370002u
#define FPGATTEN_BF16_TOKEN_STRIDE           256u
#define FPGATTEN_FP32_TOKEN_STRIDE           512u
#define FPGATTEN_BF16_HEAD_STRIDE_8192       0x00200000u
#define FPGATTEN_FP32_HEAD_STRIDE_8192       0x00400000u

static inline uint32_t fpgatten_csr_read(volatile void *base, uint32_t offset)
{
    return *(volatile uint32_t *)((volatile uint8_t *)base + offset);
}

static inline void fpgatten_csr_write(volatile void *base, uint32_t offset,
                                    uint32_t value)
{
    *(volatile uint32_t *)((volatile uint8_t *)base + offset) = value;
}

static inline uint32_t fpgatten_query_config(uint32_t query_token_base,
                                           uint32_t valid_rows,
                                           uint32_t causal)
{
    return (query_token_base & 0x1fffu)
           | ((valid_rows & 0x1fu) << 16)
           | ((causal & 1u) << 24);
}

#endif
