module gqav5_four_stage_pipeline_control #(
  parameter int unsigned DESC_W          = 1,
  parameter int unsigned FIFO_DEPTH      = 4,
  parameter int unsigned QK_CYCLES       = 8,
  parameter int unsigned SOFTMAX_CYCLES  = 3,
  parameter int unsigned PV_CYCLES       = 8,
  parameter int unsigned UPDATE_CYCLES   = 4,
  localparam int unsigned FIFO_COUNT_W   = $clog2(FIFO_DEPTH + 1)
) (
  input  logic               clk_i,
  input  logic               rst_ni,

  input  logic               in_valid_i,
  output logic               in_ready_o,
  input  logic [DESC_W-1:0]  in_desc_i,

  output logic               out_valid_o,
  input  logic               out_ready_i,
  output logic [DESC_W-1:0]  out_desc_o,

  output logic [3:0]         stage_active_o,
  output logic [63:0]        total_cycles_o,
  output logic [63:0]        overlap_cycles_o,
  output logic [63:0]        all_stage_overlap_cycles_o,
  output logic [63:0]        qk_pv_overlap_cycles_o,
  output logic [63:0]        completed_tiles_o,
  output logic [63:0]        stage_stall_cycles_o [4],
  output gqav5_pkg::gqav5_wave_phase_e stage_phase_o [4],
  output logic [15:0]        stage_phase_cycle_o [4],
  output logic [15:0]        stage_wave_cycle_o [4],
  output logic [FIFO_COUNT_W-1:0] fifo_occupancy_o [3],
  output logic [FIFO_COUNT_W-1:0] fifo_high_watermark_o [3],
  output logic [2:0]         fifo_full_o,
  output logic [2:0]         fifo_empty_o,
  output logic [FIFO_COUNT_W-1:0] credit_available_o [3],
  output logic [FIFO_COUNT_W-1:0] credit_reserved_o [3],
  output logic               protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic qk_launch_ready;
  logic sm_launch_ready;
  logic pv_launch_ready;
  logic up_launch_ready;
  logic qk_launch_fire;
  logic sm_launch_fire;
  logic pv_launch_fire;
  logic up_launch_fire;

  logic qk_active;
  logic sm_active;
  logic pv_active;
  logic up_active;

  logic              qk_commit_valid;
  logic              qk_commit_ready;
  logic [DESC_W-1:0] qk_commit_desc;
  logic              sm_commit_valid;
  logic              sm_commit_ready;
  logic [DESC_W-1:0] sm_commit_desc;
  logic              pv_commit_valid;
  logic              pv_commit_ready;
  logic [DESC_W-1:0] pv_commit_desc;
  logic              up_commit_valid;
  logic [DESC_W-1:0] up_commit_desc;

  logic              qk_sm_valid;
  logic              qk_sm_ready;
  logic [DESC_W-1:0] qk_sm_desc;
  logic              sm_pv_valid;
  logic              sm_pv_ready;
  logic [DESC_W-1:0] sm_pv_desc;
  logic              pv_up_valid;
  logic              pv_up_ready;
  logic [DESC_W-1:0] pv_up_desc;

  logic qk_credit_ready;
  logic sm_credit_ready;
  logic pv_credit_ready;
  logic qk_credit_error;
  logic sm_credit_error;
  logic pv_credit_error;

  assign in_ready_o    = qk_launch_ready;
  assign qk_launch_fire = in_valid_i && in_ready_o;
  assign sm_launch_fire = qk_sm_valid && qk_sm_ready;
  assign pv_launch_fire = sm_pv_valid && sm_pv_ready;
  assign up_launch_fire = pv_up_valid && pv_up_ready;

  assign qk_sm_ready = sm_launch_ready;
  assign sm_pv_ready = pv_launch_ready;
  assign pv_up_ready = up_launch_ready;

  assign out_valid_o = up_commit_valid;
  assign out_desc_o  = up_commit_desc;

  assign stage_active_o = {up_active, pv_active, sm_active, qk_active};

  gqav5_wave_sequencer #(
    .DESC_W        (DESC_W),
    .LOAD_CYCLES   (1),
    .COMPUTE_CYCLES(QK_CYCLES),
    .DRAIN_CYCLES  (1)
  ) i_qk_wave (
    .clk_i,
    .rst_ni,
    .launch_valid_i   (in_valid_i),
    .launch_ready_o   (qk_launch_ready),
    .resources_ready_i(qk_credit_ready),
    .launch_desc_i    (in_desc_i),
    .active_o         (qk_active),
    .phase_o          (stage_phase_o[0]),
    .phase_cycle_o    (stage_phase_cycle_o[0]),
    .wave_cycle_o     (stage_wave_cycle_o[0]),
    .commit_valid_o   (qk_commit_valid),
    .commit_ready_i   (qk_commit_ready),
    .commit_desc_o    (qk_commit_desc)
  );

  gqav5_wave_sequencer #(
    .DESC_W        (DESC_W),
    .LOAD_CYCLES   (1),
    .COMPUTE_CYCLES(SOFTMAX_CYCLES),
    .DRAIN_CYCLES  (1)
  ) i_softmax_wave (
    .clk_i,
    .rst_ni,
    .launch_valid_i   (qk_sm_valid),
    .launch_ready_o   (sm_launch_ready),
    .resources_ready_i(sm_credit_ready),
    .launch_desc_i    (qk_sm_desc),
    .active_o         (sm_active),
    .phase_o          (stage_phase_o[1]),
    .phase_cycle_o    (stage_phase_cycle_o[1]),
    .wave_cycle_o     (stage_wave_cycle_o[1]),
    .commit_valid_o   (sm_commit_valid),
    .commit_ready_i   (sm_commit_ready),
    .commit_desc_o    (sm_commit_desc)
  );

  gqav5_wave_sequencer #(
    .DESC_W        (DESC_W),
    .LOAD_CYCLES   (1),
    .COMPUTE_CYCLES(PV_CYCLES),
    .DRAIN_CYCLES  (1)
  ) i_pv_wave (
    .clk_i,
    .rst_ni,
    .launch_valid_i   (sm_pv_valid),
    .launch_ready_o   (pv_launch_ready),
    .resources_ready_i(pv_credit_ready),
    .launch_desc_i    (sm_pv_desc),
    .active_o         (pv_active),
    .phase_o          (stage_phase_o[2]),
    .phase_cycle_o    (stage_phase_cycle_o[2]),
    .wave_cycle_o     (stage_wave_cycle_o[2]),
    .commit_valid_o   (pv_commit_valid),
    .commit_ready_i   (pv_commit_ready),
    .commit_desc_o    (pv_commit_desc)
  );

  gqav5_wave_sequencer #(
    .DESC_W        (DESC_W),
    .LOAD_CYCLES   (1),
    .COMPUTE_CYCLES(UPDATE_CYCLES),
    .DRAIN_CYCLES  (1)
  ) i_update_wave (
    .clk_i,
    .rst_ni,
    .launch_valid_i   (pv_up_valid),
    .launch_ready_o   (up_launch_ready),
    .resources_ready_i(1'b1),
    .launch_desc_i    (pv_up_desc),
    .active_o         (up_active),
    .phase_o          (stage_phase_o[3]),
    .phase_cycle_o    (stage_phase_cycle_o[3]),
    .wave_cycle_o     (stage_wave_cycle_o[3]),
    .commit_valid_o   (up_commit_valid),
    .commit_ready_i   (out_ready_i),
    .commit_desc_o    (up_commit_desc)
  );

  gqav5_sync_fifo #(
    .DATA_W(DESC_W),
    .DEPTH (FIFO_DEPTH)
  ) i_qk_softmax_fifo (
    .clk_i,
    .rst_ni,
    .s_valid_i       (qk_commit_valid),
    .s_ready_o       (qk_commit_ready),
    .s_data_i        (qk_commit_desc),
    .m_valid_o       (qk_sm_valid),
    .m_ready_i       (qk_sm_ready),
    .m_data_o        (qk_sm_desc),
    .occupancy_o     (fifo_occupancy_o[0]),
    .high_watermark_o(fifo_high_watermark_o[0]),
    .full_o          (fifo_full_o[0]),
    .empty_o         (fifo_empty_o[0])
  );

  gqav5_sync_fifo #(
    .DATA_W(DESC_W),
    .DEPTH (FIFO_DEPTH)
  ) i_softmax_pv_fifo (
    .clk_i,
    .rst_ni,
    .s_valid_i       (sm_commit_valid),
    .s_ready_o       (sm_commit_ready),
    .s_data_i        (sm_commit_desc),
    .m_valid_o       (sm_pv_valid),
    .m_ready_i       (sm_pv_ready),
    .m_data_o        (sm_pv_desc),
    .occupancy_o     (fifo_occupancy_o[1]),
    .high_watermark_o(fifo_high_watermark_o[1]),
    .full_o          (fifo_full_o[1]),
    .empty_o         (fifo_empty_o[1])
  );

  gqav5_sync_fifo #(
    .DATA_W(DESC_W),
    .DEPTH (FIFO_DEPTH)
  ) i_pv_update_fifo (
    .clk_i,
    .rst_ni,
    .s_valid_i       (pv_commit_valid),
    .s_ready_o       (pv_commit_ready),
    .s_data_i        (pv_commit_desc),
    .m_valid_o       (pv_up_valid),
    .m_ready_i       (pv_up_ready),
    .m_data_o        (pv_up_desc),
    .occupancy_o     (fifo_occupancy_o[2]),
    .high_watermark_o(fifo_high_watermark_o[2]),
    .full_o          (fifo_full_o[2]),
    .empty_o         (fifo_empty_o[2])
  );

  gqav5_credit_pool #(
    .CREDITS(FIFO_DEPTH)
  ) i_qk_credit (
    .clk_i,
    .rst_ni,
    .reserve_valid_i(qk_launch_fire),
    .reserve_ready_o(qk_credit_ready),
    .release_i      (sm_launch_fire),
    .available_o    (credit_available_o[0]),
    .reserved_o     (credit_reserved_o[0]),
    .protocol_error_o(qk_credit_error)
  );

  gqav5_credit_pool #(
    .CREDITS(FIFO_DEPTH)
  ) i_softmax_credit (
    .clk_i,
    .rst_ni,
    .reserve_valid_i(sm_launch_fire),
    .reserve_ready_o(sm_credit_ready),
    .release_i      (pv_launch_fire),
    .available_o    (credit_available_o[1]),
    .reserved_o     (credit_reserved_o[1]),
    .protocol_error_o(sm_credit_error)
  );

  gqav5_credit_pool #(
    .CREDITS(FIFO_DEPTH)
  ) i_pv_credit (
    .clk_i,
    .rst_ni,
    .reserve_valid_i(pv_launch_fire),
    .reserve_ready_o(pv_credit_ready),
    .release_i      (up_launch_fire),
    .available_o    (credit_available_o[2]),
    .reserved_o     (credit_reserved_o[2]),
    .protocol_error_o(pv_credit_error)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      total_cycles_o             <= '0;
      overlap_cycles_o           <= '0;
      all_stage_overlap_cycles_o <= '0;
      qk_pv_overlap_cycles_o     <= '0;
      completed_tiles_o          <= '0;
      protocol_error_o           <= 1'b0;
      for (int unsigned stage = 0; stage < 4; stage++)
        stage_stall_cycles_o[stage] <= '0;
    end else begin
      total_cycles_o <= total_cycles_o + 64'd1;

      if ($countones(stage_active_o) >= 2)
        overlap_cycles_o <= overlap_cycles_o + 64'd1;
      if (&stage_active_o)
        all_stage_overlap_cycles_o <= all_stage_overlap_cycles_o + 64'd1;
      if (stage_active_o[0] && stage_active_o[2])
        qk_pv_overlap_cycles_o <= qk_pv_overlap_cycles_o + 64'd1;
      if (out_valid_o && out_ready_i)
        completed_tiles_o <= completed_tiles_o + 64'd1;

      if (in_valid_i && !in_ready_o)
        stage_stall_cycles_o[0] <= stage_stall_cycles_o[0] + 64'd1;
      if (qk_sm_valid && !qk_sm_ready)
        stage_stall_cycles_o[1] <= stage_stall_cycles_o[1] + 64'd1;
      if (sm_pv_valid && !sm_pv_ready)
        stage_stall_cycles_o[2] <= stage_stall_cycles_o[2] + 64'd1;
      if ((pv_up_valid && !pv_up_ready) || (out_valid_o && !out_ready_i))
        stage_stall_cycles_o[3] <= stage_stall_cycles_o[3] + 64'd1;

      if (qk_credit_error || sm_credit_error || pv_credit_error ||
          (qk_commit_valid && !qk_commit_ready) ||
          (sm_commit_valid && !sm_commit_ready) ||
          (pv_commit_valid && !pv_commit_ready))
        protocol_error_o <= 1'b1;
    end
  end
endmodule
