module gqav5_done_stage_adapter #(
  parameter int unsigned REQ_W  = 1,
  parameter int unsigned RSP_W  = 1,
  parameter int unsigned DESC_W = 1
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              req_valid_i,
  output logic              req_ready_o,
  input  logic [REQ_W-1:0]  req_data_i,
  input  logic [DESC_W-1:0] req_desc_i,

  output logic              backend_start_o,
  input  logic              backend_ready_i,
  output logic [REQ_W-1:0]  backend_req_o,
  output logic [DESC_W-1:0] backend_desc_o,
  input  logic              backend_done_i,
  input  logic [RSP_W-1:0]  backend_rsp_i,

  output logic              rsp_valid_o,
  input  logic              rsp_ready_i,
  output logic [RSP_W-1:0]  rsp_data_o,
  output logic [DESC_W-1:0] rsp_desc_o,

  output logic              busy_o,
  output logic              protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RUN,
    ST_HOLD
  } state_t;

  state_t            state_q;
  logic [REQ_W-1:0]  req_data_q;
  logic [DESC_W-1:0] desc_q;
  logic [RSP_W-1:0]  rsp_data_q;

  assign req_ready_o      = (state_q == ST_IDLE) && backend_ready_i;
  assign backend_start_o  = req_valid_i && req_ready_o;
  assign backend_req_o    = (state_q == ST_IDLE) ? req_data_i : req_data_q;
  assign backend_desc_o   = (state_q == ST_IDLE) ? req_desc_i : desc_q;
  assign rsp_valid_o      = (state_q == ST_HOLD);
  assign rsp_data_o       = rsp_data_q;
  assign rsp_desc_o       = desc_q;
  assign busy_o           = (state_q != ST_IDLE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= ST_IDLE;
      req_data_q       <= '0;
      desc_q           <= '0;
      rsp_data_q       <= '0;
      protocol_error_o <= 1'b0;
    end else begin
      if (backend_done_i && state_q != ST_RUN)
        protocol_error_o <= 1'b1;

      unique case (state_q)
        ST_IDLE: begin
          if (req_valid_i && req_ready_o) begin
            req_data_q <= req_data_i;
            desc_q     <= req_desc_i;
            state_q    <= ST_RUN;
          end
        end

        ST_RUN: begin
          if (backend_done_i) begin
            rsp_data_q <= backend_rsp_i;
            state_q    <= ST_HOLD;
          end
        end

        ST_HOLD: begin
          if (rsp_valid_o && rsp_ready_i)
            state_q <= ST_IDLE;
        end

        default: begin
          state_q          <= ST_IDLE;
          protocol_error_o <= 1'b1;
        end
      endcase
    end
  end
endmodule
