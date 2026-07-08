module axi_mem_model
  import amba_axi_pkg::*;
  import dma_pkg::*;
#(
  parameter MEM_SIZE   = 1024,    // Memory size in bytes
  parameter MEM_WIDTH  = 32,      // Memory data width (32/64)
  parameter AXI_ADDR_W = 32,      // AXI address width
  parameter AXI_DATA_W = 32,      // AXI data width
  parameter AXI_ID_W   = 4        // AXI ID width
)(
  input logic clk,
  input logic resetn,

  // AXI4 Write Address Channel
  input  logic [AXI_ID_W-1:0]   awid,
  input  logic [AXI_ADDR_W-1:0] awaddr,
  input  logic [7:0]            awlen,
  input  logic [2:0]            awsize,
  input  logic [1:0]            awburst,
  input  logic                  awvalid,
  output logic                  awready,

  // AXI4 Write Data Channel
  input  logic [AXI_DATA_W-1:0] wdata,
  input  logic [AXI_DATA_W/8-1:0] wstrb,
  input  logic                  wlast,
  input  logic                  wvalid,
  output logic                  wready,

  // AXI4 Write Response Channel
  output logic [AXI_ID_W-1:0]   bid,
  output axi_resp_t             bresp,
  output logic                  bvalid,
  input  logic                  bready,

  // AXI4 Read Address Channel
  input  logic [AXI_ID_W-1:0]   arid,
  input  logic [AXI_ADDR_W-1:0] araddr,
  input  logic [7:0]            arlen,
  input  logic [2:0]            arsize,
  input  logic [1:0]            arburst,
  input  logic                  arvalid,
  output logic                  arready,

  // AXI4 Read Data Channel
  output logic [AXI_ID_W-1:0]   rid,
  output logic [AXI_DATA_W-1:0] rdata,
  output axi_resp_t             rresp,
  output logic                  rlast,
  output logic                  rvalid,
  input  logic                  rready
);

  // Internal memory
  logic [AXI_DATA_W-1:0] mem [0:MEM_SIZE/(AXI_DATA_W/8)-1];

  // Write channel FSM
  typedef enum logic [1:0] {W_IDLE, W_ADDR, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  // Read channel FSM
  typedef enum logic [1:0] {R_IDLE, R_ADDR, R_DATA} rstate_t;
  rstate_t rstate;

  typedef enum logic [1:0] {FIXED,INCR,WRAP,RESERVED} mode_t;
  mode_t wmode,rmode;

  // Burst counters
  logic [7:0] wburst_cnt, rburst_cnt;
  logic [AXI_ADDR_W-1:0] waddr, raddr;
  logic [2:0] awsize_r,arsize_r;
  // Response generation
  always_comb begin
    bresp = AXI_OKAY; // OKAY
    rresp = AXI_OKAY; // OKAY
  end

  // Write channel FSM
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      wstate <= W_IDLE;
      awready <= 1'b0;
      wready <= 1'b0;
      bvalid <= 1'b0;
      bid <= '0;
      wburst_cnt <= 'b0;
      wmode <= INCR;
    end else begin
      case (wstate)
        W_IDLE: begin
          awready <= 1'b1;
          if (awvalid) begin
            waddr <= awaddr;
            wburst_cnt <= awlen;
            awsize_r <= awsize;
            wstate <= W_DATA;
            awready <= awready ?1'b0:1'b1;
            wready <= 1'b1;
            wmode <= mode_t'(awburst);
          end
        end

        W_DATA: begin
          awready <= 1'b0;
          if (wvalid) begin
            // Handle write with strobes
            for (int i = 0; i < AXI_DATA_W/8; i++) begin
              if (wstrb[i]) begin
                mem[(waddr)/(AXI_DATA_W/8)][i*8 +: 8] <= wdata[i*8 +: 8];
              end
            end

            if (wburst_cnt == 0) begin
              wstate <= W_RESP;
              wready <= 1'b0;
              bvalid <= 1'b1;
              bid <= awid;
            end else begin
              wburst_cnt <= wburst_cnt - 1;
              if(wmode == FIXED)
                waddr <= waddr;
              else
                waddr <= waddr + (1 << awsize_r);
            end
          end
        end

        W_RESP: begin
          if (bready) begin
            bvalid <= 1'b0;
            wstate <= W_IDLE;
          end
        end

        default: wstate <= W_IDLE;
      endcase
    end
  end

  // Read channel FSM
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      rstate <= R_IDLE;
      arready <= 1'b0;
      rvalid <= 1'b0;
      rlast <= 1'b0;
      rid <= '0;
      rburst_cnt <= 'b0;
      rmode <= INCR;
    end else begin
      case (rstate)
        R_IDLE: begin
          arready <= 1'b1;
          rlast <= 1'b0;
          rvalid <= 1'b0;
          if (arvalid) begin
            raddr <= araddr;
            rburst_cnt <= arlen;
            arsize_r <= arsize;
            rid <= arid;
            rstate <= R_DATA;
            arready <= arready?1'b0: 1'b1;
            rmode <= mode_t'(arburst);
          end
        end

        R_DATA: begin
          arready <= 1'b0;
          if (rready || !rvalid) begin
            rvalid <= 1'b1;
            rdata <= mem[(raddr)/(AXI_DATA_W/8)];
            
            if (rburst_cnt == 0) begin
              rlast <= 1'b1;
              rstate <= R_IDLE;
            end else begin
              rburst_cnt <= rburst_cnt - 1;
              if(rmode == FIXED)
                raddr <= raddr;
              else
                raddr <= raddr + (1 << arsize_r);
              rlast <= (rburst_cnt == 0);
            end
          end
        end

        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule