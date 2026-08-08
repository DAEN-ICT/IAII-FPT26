package gqav5_pkg;
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  parameter int unsigned Q_HEADS           = 32;
  parameter int unsigned KV_HEADS          = 8;
  parameter int unsigned HEAD_DIM          = 128;
  parameter int unsigned QUERY_TILE_ROWS   = 16;
  parameter int unsigned CONTEXT_TILE_COLS = 16;
  parameter int unsigned OUTPUT_TILE_DIMS  = 16;
  parameter int unsigned REDUCTION_TILES   = HEAD_DIM / 16;
  parameter int unsigned OUTPUT_TILES      = HEAD_DIM / OUTPUT_TILE_DIMS;

  // The QK sidecar has already applied 1/sqrt(head_dim). Online Softmax
  // therefore only converts the natural-exponential argument into exp2.
  parameter logic [31:0] FP32_LOG2_E = 32'h3fb8_aa3b;
  parameter logic [31:0] FP32_NEG_INF = 32'hff80_0000;

  typedef enum logic [1:0] {
    GQAV5_BANK_FREE,
    GQAV5_BANK_FILLING,
    GQAV5_BANK_READY,
    GQAV5_BANK_COMPUTING
  } gqav5_bank_state_e;

  typedef enum logic [1:0] {
    GQAV5_DMA_LOAD_Q,
    GQAV5_DMA_LOAD_K,
    GQAV5_DMA_LOAD_V,
    GQAV5_DMA_STORE_O
  } gqav5_dma_op_e;

  typedef enum logic [1:0] {
    GQAV5_WAVE_IDLE,
    GQAV5_WAVE_LOAD,
    GQAV5_WAVE_COMPUTE,
    GQAV5_WAVE_DRAIN
  } gqav5_wave_phase_e;

  typedef struct packed {
    logic [2:0]  kv_head;
    logic [1:0]  q_lane;
    // q_head is the logical source/output Q head.  Packed decode can derive
    // it from the physical partition, while prefill-direct keeps it explicit
    // because the sixteen physical rows represent query tokens instead.
    logic [4:0]  q_head;
    // kv_partition selects one of the four statically placed 4-row regions.
    // kv_wave_packed means the regions carry four distinct KV heads and the
    // sixteen rows map to 4 KV groups x 4 Q heads instead of query tokens.
    logic [1:0]  kv_partition;
    logic        kv_wave_packed;
    logic        prefill_direct;
    logic [8:0]  query_tile;
    logic [8:0]  context_tile;
    logic [2:0]  reduction_tile;
    logic [2:0]  output_tile;
    logic [4:0]  query_valid_rows;
    logic [4:0]  context_valid_cols;
    // Size of the immediately following context tile.  It is zero on the
    // last tile and lets the resident scheduler prefetch a partial tail
    // without retaining the full job token count.
    logic [4:0]  next_context_valid_cols;
    logic        causal;
    logic        first_context;
    logic        last_context;
    logic        last_output_tile;
    logic        decode_packed;
    logic [15:0] txn_id;
  } gqav5_tile_desc_t;

  typedef struct packed {
    logic       valid;
    logic [4:0] q_head;
    logic [2:0] kv_head;
    logic [3:0] query_row;
  } gqav5_pe_row_map_t;
endpackage
