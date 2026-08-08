module gqav5_wave_sequencer #(
  parameter int unsigned DESC_W         = 1,
  parameter int unsigned LOAD_CYCLES    = 1,
  parameter int unsigned COMPUTE_CYCLES = 1,
  parameter int unsigned DRAIN_CYCLES   = 1
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,

  input  logic                              launch_valid_i,
  output logic                              launch_ready_o,
  input  logic                              resources_ready_i,
  input  logic [DESC_W-1:0]                 launch_desc_i,

  output logic                              active_o,
  output gqav5_pkg::gqav5_wave_phase_e      phase_o,
  output logic [15:0]                       phase_cycle_o,
  output logic [15:0]                       wave_cycle_o,

  output logic                              commit_valid_o,
  input  logic                              commit_ready_i,
  output logic [DESC_W-1:0]                 commit_desc_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOAD,
    ST_COMPUTE,
    ST_DRAIN,
    ST_HOLD
  } state_e;

  state_e            state_q;
  logic [DESC_W-1:0] desc_q;
  logic [15:0]       phase_cycle_q;
  logic [15:0]       wave_cycle_q;

  assign launch_ready_o = (state_q == ST_IDLE) && resources_ready_i;
  assign active_o       = (state_q == ST_LOAD) ||
                          (state_q == ST_COMPUTE) ||
                          (state_q == ST_DRAIN);
  assign phase_o        = (state_q == ST_LOAD)    ? GQAV5_WAVE_LOAD :
                          (state_q == ST_COMPUTE) ? GQAV5_WAVE_COMPUTE :
                          (state_q == ST_DRAIN)   ? GQAV5_WAVE_DRAIN :
                                                   GQAV5_WAVE_IDLE;
  assign phase_cycle_o  = phase_cycle_q;
  assign wave_cycle_o   = wave_cycle_q;
  assign commit_valid_o = (state_q == ST_HOLD);
  assign commit_desc_o  = desc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= ST_IDLE;
      desc_q        <= '0;
      phase_cycle_q <= '0;
      wave_cycle_q  <= '0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          phase_cycle_q <= '0;
          wave_cycle_q  <= '0;
          if (launch_valid_i && launch_ready_o) begin
            desc_q  <= launch_desc_i;
            state_q <= ST_LOAD;
          end
        end

        ST_LOAD: begin
          wave_cycle_q <= wave_cycle_q + 16'd1;
          if (phase_cycle_q == 16'(LOAD_CYCLES - 1)) begin
            phase_cycle_q <= '0;
            state_q       <= ST_COMPUTE;
          end else begin
            phase_cycle_q <= phase_cycle_q + 16'd1;
          end
        end

        ST_COMPUTE: begin
          wave_cycle_q <= wave_cycle_q + 16'd1;
          if (phase_cycle_q == 16'(COMPUTE_CYCLES - 1)) begin
            phase_cycle_q <= '0;
            state_q       <= ST_DRAIN;
          end else begin
            phase_cycle_q <= phase_cycle_q + 16'd1;
          end
        end

        ST_DRAIN: begin
          wave_cycle_q <= wave_cycle_q + 16'd1;
          if (phase_cycle_q == 16'(DRAIN_CYCLES - 1)) begin
            phase_cycle_q <= '0;
            state_q       <= ST_HOLD;
          end else begin
            phase_cycle_q <= phase_cycle_q + 16'd1;
          end
        end

        ST_HOLD: begin
          if (commit_valid_o && commit_ready_i)
            state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  initial begin
    if (LOAD_CYCLES < 1 || COMPUTE_CYCLES < 1 || DRAIN_CYCLES < 1)
      $error("gqav5_wave_sequencer phase lengths must be >= 1");
    if (LOAD_CYCLES > 65536 || COMPUTE_CYCLES > 65536 ||
        DRAIN_CYCLES > 65536)
      $error("gqav5_wave_sequencer phase length exceeds 16-bit counter");
  end
endmodule
