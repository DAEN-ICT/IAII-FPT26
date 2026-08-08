#ifndef GQAV5_CSR_H
#define GQAV5_CSR_H

#include <stdint.h>

#define GQAV5_CSR_MAP_BYTES              0x1000u
#define GQAV5_CSR_CONTROL                0x000u
#define GQAV5_CSR_STATUS                 0x004u
#define GQAV5_CSR_CONTEXT_TOKENS         0x008u
#define GQAV5_CSR_QUERY_CONFIG           0x00cu
#define GQAV5_CSR_Q_BASE                 0x010u
#define GQAV5_CSR_K_BASE                 0x014u
#define GQAV5_CSR_V_BASE                 0x018u
#define GQAV5_CSR_O_BASE                 0x01cu
#define GQAV5_CSR_Q_HEAD_STRIDE          0x020u
#define GQAV5_CSR_Q_TOKEN_STRIDE         0x024u
#define GQAV5_CSR_K_HEAD_STRIDE          0x028u
#define GQAV5_CSR_K_TOKEN_STRIDE         0x02cu
#define GQAV5_CSR_V_HEAD_STRIDE          0x030u
#define GQAV5_CSR_V_TOKEN_STRIDE         0x034u
#define GQAV5_CSR_O_HEAD_STRIDE          0x038u
#define GQAV5_CSR_O_TOKEN_STRIDE         0x03cu
#define GQAV5_CSR_VERSION                0x044u
#define GQAV5_CSR_TOTAL_CYCLES           0x048u
#define GQAV5_CSR_OVERLAP_CYCLES         0x04cu
#define GQAV5_CSR_LOAD_STALL_CYCLES      0x050u
#define GQAV5_CSR_OPT_CTRL               0x060u
#define GQAV5_CSR_PV_LAMBDA              0x064u
#define GQAV5_CSR_CORE_TOTAL             0x068u
#define GQAV5_CSR_CORE_QK                0x06cu
#define GQAV5_CSR_CORE_SOFTMAX           0x070u
#define GQAV5_CSR_CORE_PV                0x074u
#define GQAV5_CSR_CORE_DMA_STALL         0x078u
#define GQAV5_CSR_PV_BLOCK_TOTAL         0x07cu
#define GQAV5_CSR_PV_BLOCK_SKIPPED       0x080u
#define GQAV5_CSR_BUILD_ID               0x084u
#define GQAV5_CSR_DMA_AR_COUNT           0x088u
#define GQAV5_CSR_DMA_READ_BEATS         0x08cu
#define GQAV5_CSR_DMA_AR_WAIT            0x090u
#define GQAV5_CSR_DMA_R_GAP              0x094u
#define GQAV5_CSR_DMA_R_BACKPRESSURE     0x098u
#define GQAV5_CSR_DMA_BANK_WAIT          0x09cu
#define GQAV5_CSR_DMA_EMIT_WAIT          0x0a0u
#define GQAV5_CSR_DMA_MAX_OUTSTANDING    0x0a4u
#define GQAV5_CSR_DMA_4K_SPLITS          0x0a8u
#define GQAV5_CSR_PREFILL_QUERY_TOKENS   0x0acu
#define GQAV5_CSR_KV_CACHE_HITS          0x0b0u
#define GQAV5_CSR_KV_CACHE_MISSES        0x0b4u
#define GQAV5_CSR_PREFETCH_ISSUES        0x0b8u
#define GQAV5_CSR_QK_PV_OVERLAP          0x0bcu
#define GQAV5_CSR_DMA_LANE_OVERLAP       0x0c0u

#define GQAV5_CONTROL_START              (1u << 0)
#define GQAV5_CONTROL_CLEAR_DONE         (1u << 1)
#define GQAV5_CONTROL_CLEAR_ERROR        (1u << 2)
#define GQAV5_CONTROL_SOFT_RESET         (1u << 3)

#define GQAV5_STATUS_BUSY                (1u << 0)
#define GQAV5_STATUS_DONE                (1u << 1)
#define GQAV5_STATUS_ERROR               (1u << 2)
#define GQAV5_STATUS_IRQ                 (1u << 3)

#define GQAV5_OPT_QK_REUSE               (1u << 0)
#define GQAV5_OPT_BF16_OUTPUT             (1u << 2)
#define GQAV5_OPT_PV_SKIP                 (1u << 3)
#define GQAV5_OPT_PREFILL_DIRECT          (1u << 4)

#define GQAV5_VERSION_VALUE               0x47514131u
#define GQAV5_BUILD_ID_VALUE              0x56370002u
#define GQAV5_BF16_TOKEN_STRIDE           256u
#define GQAV5_FP32_TOKEN_STRIDE           512u
#define GQAV5_BF16_HEAD_STRIDE_8192       0x00200000u
#define GQAV5_FP32_HEAD_STRIDE_8192       0x00400000u

static inline uint32_t gqav5_csr_read(volatile void *base, uint32_t offset)
{
    return *(volatile uint32_t *)((volatile uint8_t *)base + offset);
}

static inline void gqav5_csr_write(volatile void *base, uint32_t offset,
                                    uint32_t value)
{
    *(volatile uint32_t *)((volatile uint8_t *)base + offset) = value;
}

static inline uint32_t gqav5_query_config(uint32_t query_token_base,
                                           uint32_t valid_rows,
                                           uint32_t causal)
{
    return (query_token_base & 0x1fffu)
           | ((valid_rows & 0x1fu) << 16)
           | ((causal & 1u) << 24);
}

#endif
