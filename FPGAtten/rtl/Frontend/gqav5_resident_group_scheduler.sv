module gqav5_resident_group_scheduler #(
  parameter int unsigned Q_HEADS_PER_KV = 4,
  parameter bit ENABLE_FULL_ROW_BURST = 1'b1,
  parameter bit ENABLE_DUAL_DMA = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,
  input  logic pv_skip_enable_i,
  input  logic pv_skip_decision_valid_i,
  input  logic pv_skip_decision_i,

  input  logic launch_valid_i,
  output logic launch_ready_o,
  input  gqav5_pkg::gqav5_tile_desc_t launch_desc_i,
  output logic invalidate_q_cache_o,
  output logic invalidate_kv_cache_o,

  output logic compute_desc_valid_o,
  input  logic compute_desc_ready_i,
  output gqav5_pkg::gqav5_tile_desc_t compute_desc_o,
  output logic [1:0] compute_state_slot_o,

  output logic load_request_valid_o,
  input  logic load_request_ready_i,
  output gqav5_pkg::gqav5_dma_op_e load_request_op_o,
  output gqav5_pkg::gqav5_tile_desc_t load_request_desc_o,

  output logic replay_request_valid_o,
  input  logic replay_request_ready_i,
  output gqav5_pkg::gqav5_dma_op_e replay_request_op_o,
  output gqav5_pkg::gqav5_tile_desc_t replay_request_desc_o,

  // All load commands issued by this group have crossed the DMA pipeline and
  // their final cache rows are visible in the core clock domain.  A
  // speculative ping-pong slot must not be advertised to the next group
  // merely because its command was accepted: until this condition is true,
  // stale valid bits from the previous same-parity context can still exist.
  input  logic load_pipeline_idle_i,
  input  logic compute_issue_done_i,
  input  logic compute_done_i,
  output logic group_done_o,
  output logic active_o,
  output logic [1:0] active_q_lane_o,
  output logic [63:0] compute_descriptor_count_o,
  output logic [63:0] load_request_count_o,
  output logic [63:0] replay_request_count_o,
  output logic [63:0] completed_q_head_count_o,
  output logic [63:0] kv_resident_hit_count_o,
  output logic [63:0] kv_resident_miss_count_o,
  output logic [63:0] prefetch_issue_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  // Loading and local replay are deliberately independent. Once all K load
  // commands have been issued, compute may start while the single AXI mover
  // continues filling resident V tiles. Per-tile valid metadata provides the
  // dependency without a full-tile ready broadcast.
  typedef enum logic [3:0] {
    LD_IDLE,
    LD_Q,
    LD_K,
    LD_WAIT_PV_DECISION,
    LD_V,
    LD_PREFETCH_K,
    LD_PREFETCH_V,
    LD_PREFETCH_KV,
    LD_DONE
  } load_state_t;
  typedef enum logic [3:0] {
    CP_IDLE,
    CP_WAIT_K,
    CP_DESC,
    CP_REPLAY_Q,
    CP_REPLAY_K,
    CP_WAIT_PV_DECISION,
    CP_REPLAY_V,
    CP_WAIT,
    CP_WAIT_PENDING_Q,
    CP_WAIT_CREDIT,
    CP_DONE
  } compute_state_t;

  function automatic load_state_t state_after_current(
    input logic k_ready,
    input logic v_ready,
    input logic pv_skip_enabled,
    input logic last_context,
    input logic following_k_ready,
    input logic following_v_ready
  );
    if (!k_ready)
      return LD_K;
    if (pv_skip_enabled)
      return LD_WAIT_PV_DECISION;
    if (!v_ready)
      return LD_V;
    if (last_context || (following_k_ready && following_v_ready))
      return LD_DONE;
    if (ENABLE_DUAL_DMA && !following_k_ready && !following_v_ready)
      return LD_PREFETCH_KV;
    return following_k_ready ? LD_PREFETCH_V : LD_PREFETCH_K;
  endfunction

  load_state_t load_state_q;
  compute_state_t compute_state_q;
  gqav5_tile_desc_t base_desc_q;
  // Packed decode keeps one following context descriptor beside the current
  // V replay.  The QK descriptor/replay for this slot can run while the
  // current descriptor is still feeding PV, which turns the former
  // QK->8xV serialization into genuine cross-context QK/PV overlap.
  gqav5_tile_desc_t pending_desc_q;
  gqav5_tile_desc_t base_compute_desc;
  gqav5_tile_desc_t pending_compute_desc;
  gqav5_tile_desc_t load_anchor_desc;
  logic pending_desc_valid_q;
  logic pending_desc_issued_q;
  logic pending_q_replay_issued_q;
  logic early_prefetch_pending_q;
  logic [1:0] q_lane_q;
  logic [1:0] load_q_lane_q;
  logic [1:0] load_kv_partition_q;
  logic [1:0] prefetch_k_partition_q;
  logic [1:0] prefetch_v_partition_q;
  logic prefetch_k_done_q;
  logic prefetch_v_done_q;
  logic prefetch_issue_v_q;
  logic prefetch_dual_select_v;
  logic [1:0] load_request_partition;
  logic [2:0] load_reduction_tile_q;
  logic [2:0] load_output_tile_q;
  logic [2:0] replay_reduction_tile_q;
  logic [2:0] replay_output_tile_q;
  logic [1:0] replay_kv_partition_q;
  logic pv_skip_enable_q;
  logic current_k_hit_q;
  logic current_v_hit_q;
  logic [3:0] k_slot_valid_q;
  logic [3:0] v_slot_valid_q;
  logic [2:0] k_slot_kv_head_q [4];
  logic [2:0] v_slot_kv_head_q [4];
  logic [8:0] k_slot_context_q [4];
  logic [8:0] v_slot_context_q [4];
  logic [3:0] k_slot_direct_q;
  logic [3:0] v_slot_direct_q;
  logic [3:0] k_slot_wave_q;
  logic [3:0] v_slot_wave_q;
  logic local_error_q;
  logic launch_fire;
  logic legacy_launch_fire;
  logic pending_launch_fire;
  logic compute_desc_fire;
  logic base_compute_desc_fire;
  logic pending_compute_desc_fire;
  logic load_request_fire;
  logic replay_request_fire;
  logic pending_q_replay_fire;
  logic descriptor_issue_done;
  logic descriptor_has_more_q_lanes;
  logic [1:0] outstanding_desc_q;
  logic launch_cache_flush;
  logic launch_k_hit;
  logic launch_v_hit;
  logic launch_next_k_hit;
  logic launch_next_v_hit;
  logic next_k_hit;
  logic next_v_hit;
  logic load_is_prefetch;
  logic packed_overlap_mode;
  logic pending_desc_issue_select;
  logic pending_q_replay_select;
  logic pending_k_hit;
  logic pending_v_hit;
  logic pending_next_k_hit;
  logic pending_next_v_hit;
  logic pending_k_hit_q;
  logic pending_v_hit_q;
  logic pending_next_k_hit_q;
  logic pending_next_v_hit_q;
  logic pending_q_replay_armed_q;
  // A pending descriptor becomes visible about one resident-cache service
  // window before its Q replay can launch.  Use that otherwise idle interval
  // to fetch only pending+1 K.  V remains at the proven post-Q-replay timing,
  // so this optimization cannot steal the current group's PV lane.
  logic early_prefetch_k_only_q;
  logic early_prefetch_counted_q;
  logic [1:0] launch_slot;
  logic [1:0] launch_next_slot;
  logic [1:0] base_slot;
  logic [1:0] base_next_slot;
  logic [1:0] pending_slot;
  logic [1:0] pending_next_slot;
  logic [1:0] load_anchor_next_slot;

  assign launch_slot = launch_desc_i.context_tile[1:0];
  assign launch_next_slot = launch_desc_i.context_tile[1:0] + 2'd1;
  assign base_slot = base_desc_q.context_tile[1:0];
  assign base_next_slot = base_desc_q.context_tile[1:0] + 2'd1;
  assign pending_slot = pending_desc_q.context_tile[1:0];
  assign pending_next_slot = pending_desc_q.context_tile[1:0] + 2'd1;
  assign launch_cache_flush = launch_desc_i.first_context &&
      (!launch_desc_i.prefill_direct || launch_desc_i.q_lane == 2'd0);
  assign launch_k_hit = !launch_cache_flush &&
      k_slot_valid_q[launch_slot] &&
      k_slot_kv_head_q[launch_slot] ==
          launch_desc_i.kv_head &&
      k_slot_context_q[launch_slot] ==
          launch_desc_i.context_tile &&
      k_slot_direct_q[launch_slot] ==
          launch_desc_i.prefill_direct &&
      k_slot_wave_q[launch_slot] ==
          launch_desc_i.kv_wave_packed;
  assign launch_v_hit = !launch_cache_flush &&
      v_slot_valid_q[launch_slot] &&
      v_slot_kv_head_q[launch_slot] ==
          launch_desc_i.kv_head &&
      v_slot_context_q[launch_slot] ==
          launch_desc_i.context_tile &&
      v_slot_direct_q[launch_slot] ==
          launch_desc_i.prefill_direct &&
      v_slot_wave_q[launch_slot] ==
          launch_desc_i.kv_wave_packed;
  assign launch_next_k_hit =
      k_slot_valid_q[launch_next_slot] &&
      k_slot_kv_head_q[launch_next_slot] ==
          launch_desc_i.kv_head &&
      k_slot_context_q[launch_next_slot] ==
          launch_desc_i.context_tile + 9'd1 &&
      k_slot_direct_q[launch_next_slot] ==
          launch_desc_i.prefill_direct &&
      k_slot_wave_q[launch_next_slot] ==
          launch_desc_i.kv_wave_packed;
  assign launch_next_v_hit =
      v_slot_valid_q[launch_next_slot] &&
      v_slot_kv_head_q[launch_next_slot] ==
          launch_desc_i.kv_head &&
      v_slot_context_q[launch_next_slot] ==
          launch_desc_i.context_tile + 9'd1 &&
      v_slot_direct_q[launch_next_slot] ==
          launch_desc_i.prefill_direct &&
      v_slot_wave_q[launch_next_slot] ==
          launch_desc_i.kv_wave_packed;
  assign next_k_hit =
      k_slot_valid_q[base_next_slot] &&
      k_slot_kv_head_q[base_next_slot] ==
          base_desc_q.kv_head &&
      k_slot_context_q[base_next_slot] ==
          base_desc_q.context_tile + 9'd1 &&
      k_slot_direct_q[base_next_slot] ==
          base_desc_q.prefill_direct &&
      k_slot_wave_q[base_next_slot] ==
          base_desc_q.kv_wave_packed;
  assign next_v_hit =
      v_slot_valid_q[base_next_slot] &&
      v_slot_kv_head_q[base_next_slot] ==
          base_desc_q.kv_head &&
      v_slot_context_q[base_next_slot] ==
          base_desc_q.context_tile + 9'd1 &&
      v_slot_direct_q[base_next_slot] ==
          base_desc_q.prefill_direct &&
      v_slot_wave_q[base_next_slot] ==
          base_desc_q.kv_wave_packed;
  assign pending_k_hit =
      k_slot_valid_q[pending_slot] &&
      k_slot_kv_head_q[pending_slot] ==
          pending_desc_q.kv_head &&
      k_slot_context_q[pending_slot] ==
          pending_desc_q.context_tile &&
      k_slot_direct_q[pending_slot] ==
          pending_desc_q.prefill_direct &&
      k_slot_wave_q[pending_slot] ==
          pending_desc_q.kv_wave_packed;
  assign pending_v_hit =
      v_slot_valid_q[pending_slot] &&
      v_slot_kv_head_q[pending_slot] ==
          pending_desc_q.kv_head &&
      v_slot_context_q[pending_slot] ==
          pending_desc_q.context_tile &&
      v_slot_direct_q[pending_slot] ==
          pending_desc_q.prefill_direct &&
      v_slot_wave_q[pending_slot] ==
          pending_desc_q.kv_wave_packed;
  assign pending_next_k_hit =
      k_slot_valid_q[pending_next_slot] &&
      k_slot_kv_head_q[pending_next_slot] ==
          pending_desc_q.kv_head &&
      k_slot_context_q[pending_next_slot] ==
          pending_desc_q.context_tile + 9'd1 &&
      k_slot_direct_q[pending_next_slot] ==
          pending_desc_q.prefill_direct &&
      k_slot_wave_q[pending_next_slot] ==
          pending_desc_q.kv_wave_packed;
  assign pending_next_v_hit =
      v_slot_valid_q[pending_next_slot] &&
      v_slot_kv_head_q[pending_next_slot] ==
          pending_desc_q.kv_head &&
      v_slot_context_q[pending_next_slot] ==
          pending_desc_q.context_tile + 9'd1 &&
      v_slot_direct_q[pending_next_slot] ==
          pending_desc_q.prefill_direct &&
      v_slot_wave_q[pending_next_slot] ==
          pending_desc_q.kv_wave_packed;
  assign load_is_prefetch = (load_state_q == LD_PREFETCH_K) ||
                            (load_state_q == LD_PREFETCH_V) ||
                            (load_state_q == LD_PREFETCH_KV);
  assign load_anchor_desc = (load_is_prefetch &&
      early_prefetch_pending_q) ? pending_desc_q : base_desc_q;
  assign load_anchor_next_slot =
      load_anchor_desc.context_tile[1:0] + 2'd1;
  assign prefetch_dual_select_v =
      (load_state_q == LD_PREFETCH_KV) && !prefetch_v_done_q &&
      (prefetch_k_done_q || prefetch_issue_v_q);
  assign load_request_partition =
      (load_state_q == LD_PREFETCH_KV)
          ? (prefetch_dual_select_v
              ? prefetch_v_partition_q : prefetch_k_partition_q)
          : load_kv_partition_q;
  assign descriptor_issue_done =
      ((compute_state_q == CP_WAIT_PV_DECISION) &&
       pv_skip_decision_valid_i && pv_skip_decision_i) ||
      ((compute_state_q == CP_WAIT) && compute_issue_done_i);
  assign descriptor_has_more_q_lanes =
      !base_desc_q.kv_wave_packed && !base_desc_q.decode_packed &&
      (q_lane_q != 2'(Q_HEADS_PER_KV - 1));
  assign packed_overlap_mode =
      base_desc_q.kv_wave_packed && base_desc_q.decode_packed &&
      !base_desc_q.prefill_direct && !pv_skip_enable_q;
  assign pending_desc_issue_select =
      packed_overlap_mode && pending_desc_valid_q &&
      !pending_desc_issued_q && (compute_state_q != CP_DESC);
  // The arm bit is registered only after a packed pending descriptor owns a
  // compute slot and its K tile is resident.  It is cleared on every pending
  // invalidation and replay handshake, so repeating the wide mode/descriptor
  // predicates here only recreates a long ready path into the resident cache.
  assign pending_q_replay_select = pending_q_replay_armed_q;

  always_comb begin
    base_compute_desc = base_desc_q;
    base_compute_desc.q_lane = base_desc_q.prefill_direct
        ? base_desc_q.q_lane
        : ((base_desc_q.decode_packed || base_desc_q.kv_wave_packed)
            ? 2'd0 : q_lane_q);
    base_compute_desc.kv_partition = 2'd0;
    base_compute_desc.reduction_tile = 3'd0;
    base_compute_desc.output_tile = 3'd0;
    base_compute_desc.last_output_tile = 1'b1;
    base_compute_desc.query_valid_rows = base_desc_q.prefill_direct
        ? base_desc_q.query_valid_rows
        : (base_desc_q.kv_wave_packed ? 5'd16 : (base_desc_q.decode_packed
            ? 5'(Q_HEADS_PER_KV) : base_desc_q.query_valid_rows));
    if (!base_desc_q.prefill_direct && !base_desc_q.kv_wave_packed &&
        !base_desc_q.decode_packed)
      base_compute_desc.q_head =
          {base_desc_q.kv_head, q_lane_q};
    base_compute_desc.txn_id = base_desc_q.txn_id +
        ((base_desc_q.decode_packed || base_desc_q.kv_wave_packed)
            ? 16'd0 : 16'(q_lane_q));

    pending_compute_desc = pending_desc_q;
    pending_compute_desc.q_lane = 2'd0;
    pending_compute_desc.kv_partition = 2'd0;
    pending_compute_desc.reduction_tile = 3'd0;
    pending_compute_desc.output_tile = 3'd0;
    pending_compute_desc.last_output_tile = 1'b1;
    pending_compute_desc.query_valid_rows = 5'd16;
    compute_desc_o = pending_desc_issue_select
        ? pending_compute_desc : base_compute_desc;

    load_request_desc_o = load_anchor_desc;
    if (load_is_prefetch) begin
      load_request_desc_o.context_tile =
          load_anchor_desc.context_tile + 9'd1;
      load_request_desc_o.context_valid_cols =
          load_anchor_desc.next_context_valid_cols;
      load_request_desc_o.first_context = 1'b0;
    end
    // K/V addressing and resident-cache tags do not consume q_lane.  Drive a
    // canonical zero outside Q loads so the base descriptor's q_lane bit does
    // not fan through the DMA/tag path into the K/V cache valid controls.
    load_request_desc_o.q_lane = (load_state_q == LD_Q)
        ? load_q_lane_q : 2'd0;
    load_request_desc_o.kv_partition = load_request_partition;
    // In direct-prefill mode q_head carries the logical model head used by
    // the address generator, while kv_head[1:0] is deliberately repurposed
    // on load commands as the physical packed-cache bank tag.  This lets one
    // logical Q head place its 16 query rows into the 4x4 array rows and lets
    // the same logical K/V head be duplicated into all four physical banks
    // without adding a wide broadcast write network.
    load_request_desc_o.kv_head = load_anchor_desc.prefill_direct
        ? {1'b0, load_request_partition}
        : (load_anchor_desc.kv_head +
            (load_anchor_desc.kv_wave_packed
                ? 3'(load_request_partition) : 3'd0));
    load_request_desc_o.reduction_tile = load_reduction_tile_q;
    load_request_desc_o.output_tile = load_output_tile_q;
    load_request_desc_o.txn_id = load_anchor_desc.txn_id +
        (load_anchor_desc.kv_wave_packed
            ? ({14'd0, load_request_partition} << 2) : 16'd0) +
        16'(load_request_desc_o.q_lane);

    replay_request_desc_o = base_compute_desc;
    replay_request_desc_o.kv_partition = replay_kv_partition_q;
    replay_request_desc_o.kv_head = base_desc_q.kv_head +
        ((base_desc_q.kv_wave_packed && !base_desc_q.prefill_direct)
            ? 3'(replay_kv_partition_q) : 3'd0);
    replay_request_desc_o.reduction_tile = replay_reduction_tile_q;
    replay_request_desc_o.output_tile = replay_output_tile_q;

    load_request_op_o = GQAV5_DMA_LOAD_Q;
    unique case (load_state_q)
      LD_Q:      load_request_op_o = GQAV5_DMA_LOAD_Q;
      LD_K:      load_request_op_o = GQAV5_DMA_LOAD_K;
      LD_V:      load_request_op_o = GQAV5_DMA_LOAD_V;
      LD_PREFETCH_K: load_request_op_o = GQAV5_DMA_LOAD_K;
      LD_PREFETCH_V: load_request_op_o = GQAV5_DMA_LOAD_V;
      LD_PREFETCH_KV: load_request_op_o = prefetch_dual_select_v
          ? GQAV5_DMA_LOAD_V : GQAV5_DMA_LOAD_K;
      default:   load_request_op_o = GQAV5_DMA_LOAD_Q;
    endcase

    if (pending_q_replay_select) begin
      replay_request_desc_o = pending_compute_desc;
      replay_request_op_o = GQAV5_DMA_LOAD_Q;
    end else begin
      replay_request_op_o = GQAV5_DMA_LOAD_Q;
      unique case (compute_state_q)
        CP_REPLAY_Q: replay_request_op_o = GQAV5_DMA_LOAD_Q;
        CP_REPLAY_K: replay_request_op_o = GQAV5_DMA_LOAD_K;
        CP_REPLAY_V: replay_request_op_o = GQAV5_DMA_LOAD_V;
        default:     replay_request_op_o = GQAV5_DMA_LOAD_Q;
      endcase
    end
  end

  assign launch_ready_o =
      ((load_state_q == LD_IDLE) && (compute_state_q == CP_IDLE) &&
       (outstanding_desc_q < 2)) ||
      (packed_overlap_mode && !base_desc_q.last_context &&
       !pending_desc_valid_q &&
       ((compute_state_q == CP_REPLAY_V) ||
        (compute_state_q == CP_WAIT)) &&
       ((load_state_q == LD_PREFETCH_K) ||
        (load_state_q == LD_PREFETCH_V) ||
        (load_state_q == LD_PREFETCH_KV) ||
        (load_state_q == LD_DONE)) &&
       (outstanding_desc_q < 2) &&
       (!launch_valid_i ||
        ((launch_desc_i.kv_head == base_desc_q.kv_head) &&
         (launch_desc_i.context_tile ==
              (base_desc_q.context_tile + 9'd1)) &&
         ((load_state_q != LD_DONE) ||
          (launch_k_hit && launch_v_hit)))));
  assign launch_fire = launch_valid_i && launch_ready_o;
  assign pending_launch_fire = launch_fire &&
      !((load_state_q == LD_IDLE) && (compute_state_q == CP_IDLE));
  assign legacy_launch_fire = launch_fire && !pending_launch_fire;
  assign compute_desc_valid_o =
      (compute_state_q == CP_DESC) || pending_desc_issue_select;
  assign compute_desc_fire = compute_desc_valid_o && compute_desc_ready_i;
  assign pending_compute_desc_fire =
      compute_desc_fire && pending_desc_issue_select;
  assign base_compute_desc_fire =
      compute_desc_fire && !pending_desc_issue_select;
  assign load_request_valid_o = (load_state_q == LD_Q) ||
      (load_state_q == LD_K) || (load_state_q == LD_V) ||
      (load_state_q == LD_PREFETCH_K) ||
      (load_state_q == LD_PREFETCH_V) ||
      (load_state_q == LD_PREFETCH_KV);
  assign load_request_fire = load_request_valid_o && load_request_ready_i;
  assign replay_request_valid_o = pending_q_replay_select ||
      (compute_state_q == CP_REPLAY_Q) ||
      (compute_state_q == CP_REPLAY_K) ||
      (compute_state_q == CP_REPLAY_V);
  assign replay_request_fire = replay_request_valid_o &&
                               replay_request_ready_i;
  assign pending_q_replay_fire =
      replay_request_fire && pending_q_replay_select;
  assign active_o = (load_state_q != LD_IDLE) ||
                    (compute_state_q != CP_IDLE) ||
                    pending_desc_valid_q ||
                    (outstanding_desc_q != 0);
  assign active_q_lane_o = q_lane_q;
  assign compute_state_slot_o = pending_desc_issue_select
      ? 2'd0 : (base_desc_q.prefill_direct
      ? base_desc_q.q_lane
      : ((base_desc_q.decode_packed || base_desc_q.kv_wave_packed)
          ? 2'd0 : q_lane_q));
  assign protocol_error_o = local_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      load_state_q               <= LD_IDLE;
      compute_state_q            <= CP_IDLE;
      base_desc_q                <= '0;
      pending_desc_q             <= '0;
      pending_desc_valid_q       <= 1'b0;
      pending_desc_issued_q      <= 1'b0;
      pending_q_replay_issued_q  <= 1'b0;
      pending_k_hit_q            <= 1'b0;
      pending_v_hit_q            <= 1'b0;
      pending_next_k_hit_q       <= 1'b0;
      pending_next_v_hit_q       <= 1'b0;
      pending_q_replay_armed_q   <= 1'b0;
      early_prefetch_pending_q   <= 1'b0;
      early_prefetch_k_only_q    <= 1'b0;
      early_prefetch_counted_q   <= 1'b0;
      q_lane_q                   <= '0;
      load_q_lane_q              <= '0;
      load_kv_partition_q       <= '0;
      prefetch_k_partition_q     <= '0;
      prefetch_v_partition_q     <= '0;
      prefetch_k_done_q          <= 1'b0;
      prefetch_v_done_q          <= 1'b0;
      prefetch_issue_v_q         <= 1'b0;
      load_reduction_tile_q     <= '0;
      load_output_tile_q        <= '0;
      replay_reduction_tile_q   <= '0;
      replay_output_tile_q      <= '0;
      replay_kv_partition_q     <= '0;
      pv_skip_enable_q          <= 1'b0;
      current_k_hit_q           <= 1'b0;
      current_v_hit_q           <= 1'b0;
      k_slot_valid_q            <= '0;
      v_slot_valid_q            <= '0;
      k_slot_kv_head_q[0]       <= '0;
      k_slot_kv_head_q[1]       <= '0;
      k_slot_kv_head_q[2]       <= '0;
      k_slot_kv_head_q[3]       <= '0;
      v_slot_kv_head_q[0]       <= '0;
      v_slot_kv_head_q[1]       <= '0;
      v_slot_kv_head_q[2]       <= '0;
      v_slot_kv_head_q[3]       <= '0;
      k_slot_context_q[0]       <= '0;
      k_slot_context_q[1]       <= '0;
      k_slot_context_q[2]       <= '0;
      k_slot_context_q[3]       <= '0;
      v_slot_context_q[0]       <= '0;
      v_slot_context_q[1]       <= '0;
      v_slot_context_q[2]       <= '0;
      v_slot_context_q[3]       <= '0;
      k_slot_direct_q           <= '0;
      v_slot_direct_q           <= '0;
      k_slot_wave_q             <= '0;
      v_slot_wave_q             <= '0;
      invalidate_q_cache_o       <= 1'b0;
      invalidate_kv_cache_o      <= 1'b0;
      local_error_q              <= 1'b0;
      group_done_o               <= 1'b0;
      compute_descriptor_count_o <= '0;
      load_request_count_o       <= '0;
      replay_request_count_o     <= '0;
      completed_q_head_count_o   <= '0;
      kv_resident_hit_count_o    <= '0;
      kv_resident_miss_count_o   <= '0;
      prefetch_issue_count_o     <= '0;
      outstanding_desc_q         <= '0;
    end else begin
      group_done_o          <= 1'b0;
      invalidate_q_cache_o  <= 1'b0;
      invalidate_kv_cache_o <= 1'b0;
      if (clear_error_i) begin
        local_error_q <= 1'b0;
        k_slot_valid_q <= '0;
        v_slot_valid_q <= '0;
        pending_k_hit_q <= 1'b0;
        pending_v_hit_q <= 1'b0;
        pending_next_k_hit_q <= 1'b0;
        pending_next_v_hit_q <= 1'b0;
        pending_q_replay_armed_q <= 1'b0;
        invalidate_q_cache_o <= 1'b1;
        invalidate_kv_cache_o <= 1'b1;
      end else if (pending_launch_fire) begin
        // Snapshot the just-admitted descriptor's resident state and then
        // refresh it every cycle while pending.  The separate replay-arm
        // register cuts cache tag comparison and load-pipeline readiness out
        // of the cross-module replay ready/valid path.
        pending_k_hit_q <= launch_k_hit;
        pending_v_hit_q <= launch_v_hit;
        pending_next_k_hit_q <= launch_next_k_hit;
        pending_next_v_hit_q <= launch_next_v_hit;
        pending_q_replay_armed_q <= 1'b0;
      end else if (!pending_desc_valid_q) begin
        pending_k_hit_q <= 1'b0;
        pending_v_hit_q <= 1'b0;
        pending_next_k_hit_q <= 1'b0;
        pending_next_v_hit_q <= 1'b0;
        pending_q_replay_armed_q <= 1'b0;
      end else begin
        pending_k_hit_q <= pending_k_hit;
        pending_v_hit_q <= pending_v_hit;
        pending_next_k_hit_q <= pending_next_k_hit;
        pending_next_v_hit_q <= pending_next_v_hit;
        if (pending_q_replay_fire) begin
          pending_q_replay_armed_q <= 1'b0;
        end else if (pending_desc_issued_q &&
                     !pending_q_replay_issued_q &&
                     pending_k_hit) begin
          // QK only consumes Q and K.  Do not hold the following group's Q
          // replay behind its V refill or the DMA pipeline tail; the replay
          // ready/valid handshake already arbitrates the resident frontend.
          // Promotion below still waits for V residency before issuing PV.
          pending_q_replay_armed_q <= 1'b1;
        end
      end
      if (load_state_q != LD_PREFETCH_KV) begin
        prefetch_k_partition_q <= '0;
        prefetch_v_partition_q <= '0;
        prefetch_k_done_q <= 1'b0;
        prefetch_v_done_q <= 1'b0;
        prefetch_issue_v_q <= 1'b0;
      end
      if (load_state_q == LD_DONE)
        early_prefetch_pending_q <= 1'b0;
      if (pending_launch_fire) begin
        pending_desc_q <= launch_desc_i;
        pending_desc_valid_q <= 1'b1;
        pending_desc_issued_q <= 1'b0;
        pending_q_replay_issued_q <= 1'b0;
        if (launch_desc_i.kv_head != base_desc_q.kv_head ||
            launch_desc_i.context_tile !=
                (base_desc_q.context_tile + 9'd1) ||
            ((load_state_q == LD_DONE) &&
             (!launch_k_hit || !launch_v_hit)))
          local_error_q <= 1'b1;
      end
      if (pending_compute_desc_fire) begin
        pending_desc_issued_q <= 1'b1;
        compute_descriptor_count_o <= compute_descriptor_count_o + 64'd1;
        if (ENABLE_DUAL_DMA && !pending_desc_q.last_context &&
            (load_state_q == LD_DONE) && !pending_next_k_hit_q) begin
          // The K/Q column caches and the V row cache are independent.  Pull
          // pending+1 K forward as soon as the pending descriptor owns a QK
          // descriptor bank, but deliberately stop after K.  The existing
          // pending-Q handshake below will start pending+1 V at its original
          // safe point.
          early_prefetch_pending_q <= 1'b1;
          early_prefetch_k_only_q <= 1'b1;
          load_kv_partition_q <= '0;
          load_reduction_tile_q <= '0;
          load_output_tile_q <= '0;
          load_state_q <= LD_PREFETCH_K;
          early_prefetch_counted_q <= 1'b1;
          prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
        end
      end
      if (pending_q_replay_fire) begin
        pending_q_replay_issued_q <= 1'b1;
        replay_request_count_o <= replay_request_count_o + 64'd1;
        group_done_o <= 1'b1;
        // If the early K wave is still active, leave the mode bit set until
        // its final command.  That completion edge uses the already-issued
        // Q replay as the cue to continue directly into V; clearing it here
        // would lose V when both handshakes coincide.
        if (load_state_q != LD_PREFETCH_K)
          early_prefetch_k_only_q <= 1'b0;
        if (ENABLE_DUAL_DMA && !pending_desc_q.last_context &&
            (load_state_q == LD_DONE) &&
            !(pending_next_k_hit_q && pending_next_v_hit_q)) begin
          // Admit Q into the compute pipeline before starting pending+1 K/V.
          // This preserves QK/PV overlap while the remaining current PV tail
          // plus the following PV service window hides the resident refill.
          early_prefetch_pending_q <= 1'b1;
          load_state_q <= state_after_current(
              1'b1, 1'b1, 1'b0, pending_desc_q.last_context,
              pending_next_k_hit_q, pending_next_v_hit_q);
          if (!early_prefetch_counted_q)
            prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
        end
        early_prefetch_counted_q <= 1'b0;
      end
      if (compute_done_i && (outstanding_desc_q == 0) &&
          !descriptor_issue_done)
        local_error_q <= 1'b1;
      unique case ({descriptor_issue_done, compute_done_i})
        2'b10: outstanding_desc_q <= outstanding_desc_q + 2'd1;
        2'b01: outstanding_desc_q <= outstanding_desc_q - 2'd1;
        default: begin end
      endcase

      unique case (load_state_q)
        LD_IDLE: begin
          if (legacy_launch_fire) begin
            base_desc_q          <= launch_desc_i;
            pv_skip_enable_q     <= pv_skip_enable_i;
            load_q_lane_q        <= '0;
            load_kv_partition_q <= '0;
            load_reduction_tile_q <= '0;
            load_output_tile_q   <= '0;
            invalidate_q_cache_o <= launch_cache_flush;
            invalidate_kv_cache_o <= launch_cache_flush;
            if (launch_cache_flush) begin
              k_slot_valid_q <= '0;
              v_slot_valid_q <= '0;
            end
            current_k_hit_q <= launch_k_hit;
            current_v_hit_q <= launch_v_hit;
            if (launch_k_hit)
              kv_resident_hit_count_o <= kv_resident_hit_count_o + 64'd1;
            else
              kv_resident_miss_count_o <= kv_resident_miss_count_o + 64'd1;
            if (launch_desc_i.first_context) begin
              load_state_q <= LD_Q;
            end else begin
              load_state_q <= state_after_current(
                  launch_k_hit, launch_v_hit, pv_skip_enable_i,
                  launch_desc_i.last_context,
                  launch_next_k_hit, launch_next_v_hit);
              if (launch_k_hit && launch_v_hit &&
                  !pv_skip_enable_i && !launch_desc_i.last_context &&
                  !(launch_next_k_hit && launch_next_v_hit))
                prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
            end
          end
        end

        LD_Q: begin
          if (load_request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (ENABLE_FULL_ROW_BURST) begin
              load_reduction_tile_q <= '0;
              if (load_q_lane_q == 2'(Q_HEADS_PER_KV - 1)) begin
                load_q_lane_q <= '0;
                if (base_desc_q.kv_wave_packed &&
                    load_kv_partition_q != 2'd3)
                  load_kv_partition_q <= load_kv_partition_q + 2'd1;
                else begin
                  load_kv_partition_q <= '0;
                  load_state_q <= state_after_current(
                      current_k_hit_q, current_v_hit_q, pv_skip_enable_q,
                      base_desc_q.last_context, next_k_hit, next_v_hit);
                  if (current_k_hit_q && current_v_hit_q &&
                      !pv_skip_enable_q && !base_desc_q.last_context &&
                      !(next_k_hit && next_v_hit))
                    prefetch_issue_count_o <=
                        prefetch_issue_count_o + 64'd1;
                end
              end else begin
                load_q_lane_q <= load_q_lane_q + 2'd1;
              end
            end else if (load_reduction_tile_q == 3'd7) begin
              load_reduction_tile_q <= '0;
              if (load_q_lane_q == 2'(Q_HEADS_PER_KV - 1)) begin
                load_q_lane_q <= '0;
                if (base_desc_q.kv_wave_packed &&
                    load_kv_partition_q != 2'd3)
                  load_kv_partition_q <= load_kv_partition_q + 2'd1;
                else begin
                  load_kv_partition_q <= '0;
                  load_state_q <= state_after_current(
                      current_k_hit_q, current_v_hit_q, pv_skip_enable_q,
                      base_desc_q.last_context, next_k_hit, next_v_hit);
                  if (current_k_hit_q && current_v_hit_q &&
                      !pv_skip_enable_q && !base_desc_q.last_context &&
                      !(next_k_hit && next_v_hit))
                    prefetch_issue_count_o <=
                        prefetch_issue_count_o + 64'd1;
                end
              end else begin
                load_q_lane_q <= load_q_lane_q + 2'd1;
              end
            end else begin
              load_reduction_tile_q <= load_reduction_tile_q + 3'd1;
            end
          end
        end

        LD_K: begin
          if (load_request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (ENABLE_FULL_ROW_BURST) begin
              load_reduction_tile_q <= '0;
              if (base_desc_q.kv_wave_packed &&
                  !base_desc_q.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                load_output_tile_q <= '0;
                k_slot_valid_q[base_slot] <= 1'b1;
                k_slot_kv_head_q[base_slot] <=
                    base_desc_q.kv_head;
                k_slot_context_q[base_slot] <=
                    base_desc_q.context_tile;
                k_slot_direct_q[base_slot] <=
                    base_desc_q.prefill_direct;
                k_slot_wave_q[base_slot] <=
                    base_desc_q.kv_wave_packed;
                load_state_q <= state_after_current(
                    1'b1, current_v_hit_q, pv_skip_enable_q,
                    base_desc_q.last_context, next_k_hit, next_v_hit);
                if (current_v_hit_q && !pv_skip_enable_q &&
                    !base_desc_q.last_context &&
                    !(next_k_hit && next_v_hit))
                  prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
              end
            end else if (load_reduction_tile_q == 3'd7) begin
              load_reduction_tile_q <= '0;
              if (base_desc_q.kv_wave_packed &&
                  !base_desc_q.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                load_output_tile_q <= '0;
                k_slot_valid_q[base_slot] <= 1'b1;
                k_slot_kv_head_q[base_slot] <=
                    base_desc_q.kv_head;
                k_slot_context_q[base_slot] <=
                    base_desc_q.context_tile;
                k_slot_direct_q[base_slot] <=
                    base_desc_q.prefill_direct;
                k_slot_wave_q[base_slot] <=
                    base_desc_q.kv_wave_packed;
                load_state_q <= state_after_current(
                    1'b1, current_v_hit_q, pv_skip_enable_q,
                    base_desc_q.last_context, next_k_hit, next_v_hit);
                if (current_v_hit_q && !pv_skip_enable_q &&
                    !base_desc_q.last_context &&
                    !(next_k_hit && next_v_hit))
                  prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
              end
            end else begin
              load_reduction_tile_q <= load_reduction_tile_q + 3'd1;
            end
          end
        end

        LD_WAIT_PV_DECISION: begin
          if (pv_skip_decision_valid_i) begin
            load_output_tile_q <= '0;
            load_kv_partition_q <= '0;
            if (!pv_skip_decision_i && !current_v_hit_q) begin
              load_state_q <= LD_V;
            end else begin
              load_state_q <= state_after_current(
                  1'b1, 1'b1, 1'b0, base_desc_q.last_context,
                  next_k_hit, next_v_hit);
              if (!base_desc_q.last_context &&
                  !(next_k_hit && next_v_hit))
                prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
            end
          end
        end

        LD_V: begin
          if (load_request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (ENABLE_FULL_ROW_BURST) begin
              load_output_tile_q <= '0;
              if (base_desc_q.kv_wave_packed &&
                  !base_desc_q.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                v_slot_valid_q[base_slot] <= 1'b1;
                v_slot_kv_head_q[base_slot] <=
                    base_desc_q.kv_head;
                v_slot_context_q[base_slot] <=
                    base_desc_q.context_tile;
                v_slot_direct_q[base_slot] <=
                    base_desc_q.prefill_direct;
                v_slot_wave_q[base_slot] <=
                    base_desc_q.kv_wave_packed;
                load_state_q <= state_after_current(
                    1'b1, 1'b1, 1'b0, base_desc_q.last_context,
                    next_k_hit, next_v_hit);
                if (!base_desc_q.last_context &&
                    !(next_k_hit && next_v_hit))
                  prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
              end
            end else if (load_output_tile_q == 3'd7) begin
              load_output_tile_q <= '0;
              if (base_desc_q.kv_wave_packed &&
                  !base_desc_q.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                v_slot_valid_q[base_slot] <= 1'b1;
                v_slot_kv_head_q[base_slot] <=
                    base_desc_q.kv_head;
                v_slot_context_q[base_slot] <=
                    base_desc_q.context_tile;
                v_slot_direct_q[base_slot] <=
                    base_desc_q.prefill_direct;
                v_slot_wave_q[base_slot] <=
                    base_desc_q.kv_wave_packed;
                load_state_q <= state_after_current(
                    1'b1, 1'b1, 1'b0, base_desc_q.last_context,
                    next_k_hit, next_v_hit);
                if (!base_desc_q.last_context &&
                    !(next_k_hit && next_v_hit))
                  prefetch_issue_count_o <= prefetch_issue_count_o + 64'd1;
              end
            end else begin
              load_output_tile_q <= load_output_tile_q + 3'd1;
            end
          end
        end

        LD_PREFETCH_K: begin
          if (load_request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (ENABLE_FULL_ROW_BURST) begin
              load_reduction_tile_q <= '0;
              if (load_anchor_desc.kv_wave_packed &&
                  !load_anchor_desc.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                load_output_tile_q <= '0;
                k_slot_valid_q[load_anchor_next_slot] <= 1'b1;
                k_slot_kv_head_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_head;
                k_slot_context_q[load_anchor_next_slot] <=
                    load_anchor_desc.context_tile + 9'd1;
                k_slot_direct_q[load_anchor_next_slot] <=
                    load_anchor_desc.prefill_direct;
                k_slot_wave_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_wave_packed;
                if (early_prefetch_k_only_q) begin
                  early_prefetch_k_only_q <= 1'b0;
                  load_state_q <=
                      (pending_q_replay_issued_q || pending_q_replay_fire)
                          ? (pending_next_v_hit_q
                              ? LD_DONE : LD_PREFETCH_V)
                          : LD_DONE;
                end else begin
                  load_state_q <= next_v_hit ? LD_DONE : LD_PREFETCH_V;
                end
              end
            end else if (load_reduction_tile_q == 3'd7) begin
              load_reduction_tile_q <= '0;
              if (load_anchor_desc.kv_wave_packed &&
                  !load_anchor_desc.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                load_output_tile_q <= '0;
                k_slot_valid_q[load_anchor_next_slot] <= 1'b1;
                k_slot_kv_head_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_head;
                k_slot_context_q[load_anchor_next_slot] <=
                    load_anchor_desc.context_tile + 9'd1;
                k_slot_direct_q[load_anchor_next_slot] <=
                    load_anchor_desc.prefill_direct;
                k_slot_wave_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_wave_packed;
                if (early_prefetch_k_only_q) begin
                  early_prefetch_k_only_q <= 1'b0;
                  load_state_q <=
                      (pending_q_replay_issued_q || pending_q_replay_fire)
                          ? (pending_next_v_hit_q
                              ? LD_DONE : LD_PREFETCH_V)
                          : LD_DONE;
                end else begin
                  load_state_q <= next_v_hit ? LD_DONE : LD_PREFETCH_V;
                end
              end
            end else begin
              load_reduction_tile_q <= load_reduction_tile_q + 3'd1;
            end
          end
        end

        LD_PREFETCH_V: begin
          if (load_request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (ENABLE_FULL_ROW_BURST) begin
              load_output_tile_q <= '0;
              if (load_anchor_desc.kv_wave_packed &&
                  !load_anchor_desc.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                v_slot_valid_q[load_anchor_next_slot] <= 1'b1;
                v_slot_kv_head_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_head;
                v_slot_context_q[load_anchor_next_slot] <=
                    load_anchor_desc.context_tile + 9'd1;
                v_slot_direct_q[load_anchor_next_slot] <=
                    load_anchor_desc.prefill_direct;
                v_slot_wave_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_wave_packed;
                load_state_q <= LD_DONE;
              end
            end else if (load_output_tile_q == 3'd7) begin
              load_output_tile_q <= '0;
              if (load_anchor_desc.kv_wave_packed &&
                  !load_anchor_desc.prefill_direct &&
                  load_kv_partition_q != 2'd3)
                load_kv_partition_q <= load_kv_partition_q + 2'd1;
              else begin
                load_kv_partition_q <= '0;
                v_slot_valid_q[load_anchor_next_slot] <= 1'b1;
                v_slot_kv_head_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_head;
                v_slot_context_q[load_anchor_next_slot] <=
                    load_anchor_desc.context_tile + 9'd1;
                v_slot_direct_q[load_anchor_next_slot] <=
                    load_anchor_desc.prefill_direct;
                v_slot_wave_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_wave_packed;
                load_state_q <= LD_DONE;
              end
            end else begin
              load_output_tile_q <= load_output_tile_q + 3'd1;
            end
          end
        end

        LD_PREFETCH_KV: begin
          if (load_request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            prefetch_issue_v_q <= ~prefetch_dual_select_v;
            if (prefetch_dual_select_v) begin
              // Prefill-direct fills are broadcast to all four physical
              // cache partitions by the frontend.  Only packed decode
              // waves need one AXI request per partition.
              if (load_anchor_desc.prefill_direct ||
                  (prefetch_v_partition_q == 2'd3)) begin
                prefetch_v_done_q <= 1'b1;
                v_slot_valid_q[load_anchor_next_slot] <= 1'b1;
                v_slot_kv_head_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_head;
                v_slot_context_q[load_anchor_next_slot] <=
                    load_anchor_desc.context_tile + 9'd1;
                v_slot_direct_q[load_anchor_next_slot] <=
                    load_anchor_desc.prefill_direct;
                v_slot_wave_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_wave_packed;
                if (prefetch_k_done_q)
                  load_state_q <= LD_DONE;
              end else begin
                prefetch_v_partition_q <= prefetch_v_partition_q + 2'd1;
              end
            end else begin
              if (load_anchor_desc.prefill_direct ||
                  (prefetch_k_partition_q == 2'd3)) begin
                prefetch_k_done_q <= 1'b1;
                k_slot_valid_q[load_anchor_next_slot] <= 1'b1;
                k_slot_kv_head_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_head;
                k_slot_context_q[load_anchor_next_slot] <=
                    load_anchor_desc.context_tile + 9'd1;
                k_slot_direct_q[load_anchor_next_slot] <=
                    load_anchor_desc.prefill_direct;
                k_slot_wave_q[load_anchor_next_slot] <=
                    load_anchor_desc.kv_wave_packed;
                if (prefetch_v_done_q)
                  load_state_q <= LD_DONE;
              end else begin
                prefetch_k_partition_q <= prefetch_k_partition_q + 2'd1;
              end
            end
          end
        end

        LD_DONE: begin
        end

        default: begin
          local_error_q <= 1'b1;
          load_state_q <= LD_IDLE;
        end
      endcase

      unique case (compute_state_q)
        CP_IDLE: begin
          if (legacy_launch_fire) begin
            q_lane_q <= '0;
            replay_reduction_tile_q <= '0;
            replay_output_tile_q <= '0;
            replay_kv_partition_q <= '0;
            compute_state_q <= launch_k_hit ? CP_DESC : CP_WAIT_K;
          end
        end

        CP_WAIT_K: begin
          if (load_request_fire && load_state_q == LD_K &&
              (ENABLE_FULL_ROW_BURST ||
               load_reduction_tile_q == 3'd7) &&
              (!base_desc_q.kv_wave_packed ||
               base_desc_q.prefill_direct ||
               load_kv_partition_q == 2'd3))
            compute_state_q <= CP_DESC;
        end

        CP_DESC: begin
          if (base_compute_desc_fire) begin
            compute_descriptor_count_o <=
                compute_descriptor_count_o + 64'd1;
            replay_reduction_tile_q <= '0;
            replay_output_tile_q <= '0;
            replay_kv_partition_q <= '0;
            compute_state_q <= CP_REPLAY_Q;
          end
        end

        CP_REPLAY_Q: begin
          if (replay_request_fire && !pending_q_replay_select) begin
            replay_request_count_o <= replay_request_count_o + 64'd1;
            // A packed four-KV request now launches the complete 8x16 QK
            // resident wave: sixteen strided Q row-zero tiles and four K
            // partitions are replayed together.  Compatibility modes retain
            // the per-reduction Q then K command sequence.
            if (base_desc_q.kv_wave_packed) begin
              replay_output_tile_q <= '0;
              replay_kv_partition_q <= '0;
              if (packed_overlap_mode)
                group_done_o <= 1'b1;
              compute_state_q <= pv_skip_enable_q
                  ? CP_WAIT_PV_DECISION : CP_REPLAY_V;
            end else begin
              compute_state_q <= CP_REPLAY_K;
            end
          end
        end

        CP_REPLAY_K: begin
          if (replay_request_fire && !pending_q_replay_select) begin
            replay_request_count_o <= replay_request_count_o + 64'd1;
            if (base_desc_q.kv_wave_packed &&
                replay_kv_partition_q != 2'd3) begin
              replay_kv_partition_q <= replay_kv_partition_q + 2'd1;
            end else begin
              replay_kv_partition_q <= '0;
              if (replay_reduction_tile_q == 3'd7) begin
                replay_output_tile_q <= '0;
                compute_state_q <= pv_skip_enable_q
                    ? CP_WAIT_PV_DECISION : CP_REPLAY_V;
              end else begin
                replay_reduction_tile_q <= replay_reduction_tile_q + 3'd1;
                compute_state_q <= CP_REPLAY_Q;
              end
            end
          end
        end

        CP_WAIT_PV_DECISION: begin
          if (pv_skip_decision_valid_i) begin
            replay_output_tile_q <= '0;
            replay_kv_partition_q <= '0;
            if (pv_skip_decision_i) begin
              completed_q_head_count_o <= completed_q_head_count_o +
                  (base_desc_q.prefill_direct
                      ? 64'(base_desc_q.query_valid_rows)
                      : (base_desc_q.kv_wave_packed ? 64'd16 :
                   (base_desc_q.decode_packed
                      ? 64'(Q_HEADS_PER_KV) : 64'd1)));
              if (descriptor_has_more_q_lanes) begin
                q_lane_q <= q_lane_q + 2'd1;
                replay_reduction_tile_q <= '0;
                if ((outstanding_desc_q < 1) || compute_done_i)
                  compute_state_q <= CP_DESC;
                else
                  compute_state_q <= CP_WAIT_CREDIT;
              end else begin
                compute_state_q <= CP_DONE;
              end
            end else begin
              compute_state_q <= CP_REPLAY_V;
            end
          end
        end

        CP_REPLAY_V: begin
          if (replay_request_fire && !pending_q_replay_select) begin
            replay_request_count_o <= replay_request_count_o + 64'd1;
            // Packed resident V replay widens locally across all four KV
            // partitions, so one command per output tile replaces four serial
            // partition commands. Compatibility mode also remains one command
            // per output tile because its payload is broadcast downstream.
            replay_kv_partition_q <= '0;
            if (replay_output_tile_q == 3'd7) begin
              compute_state_q <= CP_WAIT;
            end else begin
              replay_output_tile_q <= replay_output_tile_q + 3'd1;
            end
          end
        end

        CP_WAIT: begin
          if (compute_issue_done_i) begin
            completed_q_head_count_o <= completed_q_head_count_o +
                (base_desc_q.prefill_direct
                    ? 64'(base_desc_q.query_valid_rows)
                    : (base_desc_q.kv_wave_packed ? 64'd16 :
                 (base_desc_q.decode_packed
                    ? 64'(Q_HEADS_PER_KV) : 64'd1)));
            if (packed_overlap_mode && pending_desc_valid_q &&
                (pending_q_replay_issued_q || pending_q_replay_fire) &&
                pending_v_hit) begin
              // The following descriptor has already completed descriptor
              // admission and Q replay, including a replay accepted in this
              // same cycle.  Promote it only after the current V stream is
              // fully accepted so txn/V ordering remains exact.  Accounting
              // for the same-cycle handshake avoids entering WAIT_PENDING_Q
              // after the only replay pulse has already been consumed.
              base_desc_q <= pending_desc_q;
              pending_desc_valid_q <= 1'b0;
              pending_desc_issued_q <= 1'b0;
              pending_q_replay_issued_q <= 1'b0;
              q_lane_q <= '0;
              replay_reduction_tile_q <= '0;
              replay_output_tile_q <= '0;
              replay_kv_partition_q <= '0;
              current_k_hit_q <= pending_k_hit;
              current_v_hit_q <= pending_v_hit;
              load_q_lane_q <= '0;
              load_kv_partition_q <= '0;
              load_reduction_tile_q <= '0;
              load_output_tile_q <= '0;
              if (!early_prefetch_pending_q)
                load_state_q <= state_after_current(
                    pending_k_hit, pending_v_hit, 1'b0,
                    pending_desc_q.last_context,
                    pending_next_k_hit_q, pending_next_v_hit_q);
              compute_state_q <= CP_REPLAY_V;
              if (!pending_k_hit || !pending_v_hit)
                local_error_q <= 1'b1;
            end else if (packed_overlap_mode && pending_desc_valid_q) begin
              // The following descriptor was admitted while its ping-pong
              // K/V refill was still draining.  Keep ownership of the
              // current descriptor until that refill becomes visible and
              // its Q replay is accepted; returning through IDLE here would
              // let a later launch overtake this pending descriptor.
              compute_state_q <= CP_WAIT_PENDING_Q;
            end else if (descriptor_has_more_q_lanes) begin
                q_lane_q <= q_lane_q + 2'd1;
                replay_reduction_tile_q <= '0;
                replay_output_tile_q <= '0;
                replay_kv_partition_q <= '0;
                if ((outstanding_desc_q < 1) || compute_done_i)
                  compute_state_q <= CP_DESC;
                else
                  compute_state_q <= CP_WAIT_CREDIT;
            end else begin
              compute_state_q <= CP_DONE;
            end
          end
        end

        CP_WAIT_PENDING_Q: begin
          if ((pending_q_replay_issued_q || pending_q_replay_fire) &&
              pending_v_hit) begin
            base_desc_q <= pending_desc_q;
            pending_desc_valid_q <= 1'b0;
            pending_desc_issued_q <= 1'b0;
            pending_q_replay_issued_q <= 1'b0;
            q_lane_q <= '0;
            replay_reduction_tile_q <= '0;
            replay_output_tile_q <= '0;
            replay_kv_partition_q <= '0;
            current_k_hit_q <= pending_k_hit;
            current_v_hit_q <= pending_v_hit;
            load_q_lane_q <= '0;
            load_kv_partition_q <= '0;
            load_reduction_tile_q <= '0;
            load_output_tile_q <= '0;
            if (!early_prefetch_pending_q)
              load_state_q <= state_after_current(
                  pending_k_hit, pending_v_hit, 1'b0,
                  pending_desc_q.last_context,
                  pending_next_k_hit_q, pending_next_v_hit_q);
            compute_state_q <= CP_REPLAY_V;
          end
        end

        CP_WAIT_CREDIT: begin
          if ((outstanding_desc_q < 2) || compute_done_i) begin
            compute_state_q <= CP_DESC;
          end
        end

        CP_DONE: begin
        end

        default: begin
          local_error_q <= 1'b1;
          compute_state_q <= CP_IDLE;
        end
      endcase

      if (load_state_q == LD_DONE && compute_state_q == CP_DONE &&
          load_pipeline_idle_i) begin
        if (!packed_overlap_mode)
          group_done_o <= 1'b1;
        load_state_q <= LD_IDLE;
        compute_state_q <= CP_IDLE;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && !clear_error_i && pending_q_replay_armed_q &&
        (!packed_overlap_mode || !pending_desc_valid_q ||
         !pending_desc_issued_q || pending_q_replay_issued_q))
      $error("pending Q replay arm escaped its packed pending descriptor");
  end
`endif

  initial begin
    if (REDUCTION_TILES != 8 || OUTPUT_TILES != 8)
      $error("resident group scheduler targets head_dim=128");
    if (Q_HEADS_PER_KV < 1 || Q_HEADS_PER_KV > 4)
      $error("Q_HEADS_PER_KV must fit the two-bit q_lane field");
  end
endmodule
