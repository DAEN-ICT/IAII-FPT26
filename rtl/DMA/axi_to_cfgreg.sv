module axi_to_cfgreg 
  import amba_axi_pkg::*;
  import dma_pkg::*;
# (
    parameter AXI_DATA_WIDTH = 64    
)(
    input  logic                        clk_i,
    input  logic                        rstn_i,

    // AXI Interface
    input  logic                        axi_awvalid_i   ,
    input  logic [31:0]                 axi_awaddr_i    ,
    input  logic [3:0]                  axi_awid_i      ,
    input  logic [7:0]                  axi_awlen_i     ,
    input  logic [1:0]                  axi_awburst_i   ,
    input  logic                        axi_wvalid_i    ,
    input  logic [AXI_DATA_WIDTH-1:0]   axi_wdata_i     ,
    input  logic [AXI_DATA_WIDTH/8-1:0] axi_wstrb_i     ,
    input  logic                        axi_wlast_i     ,
    input  logic                        axi_bready_i    ,
    input  logic                        axi_arvalid_i   ,
    input  logic [31:0]                 axi_araddr_i    ,
    input  logic [3:0]                  axi_arid_i      ,
    input  logic [7:0]                  axi_arlen_i     ,
    input  logic [1:0]                  axi_arburst_i   ,
    input  logic                        axi_rready_i    ,

    output logic                        axi_awready_o   ,
    output logic                        axi_wready_o    ,
    output logic                        axi_bvalid_o    ,
    output axi_resp_t                   axi_bresp_o     ,
    output logic [3:0]                  axi_bid_o       ,
    output logic                        axi_arready_o   ,
    output logic                        axi_rvalid_o    ,
    output logic [AXI_DATA_WIDTH-1:0]   axi_rdata_o     ,
    output axi_resp_t                   axi_rresp_o     ,
    output logic [3:0]                  axi_rid_o       ,
    output logic                        axi_rlast_o     ,

    // Config Register Interface
    output logic [11:0]                 config_offset_o ,
    output logic                        config_wen_o    ,
    output logic [AXI_DATA_WIDTH-1:0]   config_wdata_o  ,
    input  logic [AXI_DATA_WIDTH-1:0]   config_rdata_i
);

typedef enum logic [2:0] {
    IDLE  = 3'b000,
    RADDR = 3'b001,
    RDATA = 3'b010,
    WADDR = 3'b011,
    WDATA = 3'b100,
    WRESP = 3'b101
} state_t;

parameter BURST_INCAR = 2'd1;
parameter RESP_OK = 2'b00;

logic [7:0] len;
logic [3:0] arid;
logic [3:0] awid;
logic [1:0] burst;
logic [11:0] raddr;
logic [11:0] waddr;

state_t current_state;
state_t next_state;

// State register
always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
        current_state <= IDLE;
    end else begin
        current_state <= next_state;
    end
end

// AR Channel
assign axi_arready_o = (current_state == RADDR) ? 1'b1 : 1'b0;

// R Channel
assign axi_rdata_o  = (current_state == RDATA) ? config_rdata_i : 
                                                 '0 ;
assign axi_rresp_o  = AXI_OKAY;
assign axi_rvalid_o = (current_state == RDATA) ? 1'b1 : 1'b0;
assign axi_rlast_o  = (current_state == RDATA && axi_rvalid_o && axi_rready_i) ? 1'b1 : 1'b0;
assign axi_rid_o    = (current_state == RDATA) ? arid : '0; 

// AW Channel
assign axi_awready_o = (current_state == WADDR) ? 1'b1 : 1'b0;

// W Channel
assign axi_wready_o = (current_state == WDATA) ? 1'b1 : 1'b0;

// B Channel
assign axi_bvalid_o = (current_state == WRESP) ? 1'b1 : 1'b0;
assign axi_bid_o    = (current_state == WRESP) ? awid : '0;
assign axi_bresp_o  = AXI_OKAY;

// Config Register Interface
assign config_offset_o  = (current_state == RDATA) ? axi_araddr_i[11:0] : 
                          (current_state == WDATA) ? axi_awaddr_i[11:0] : '0;
assign config_wdata_o   = axi_wdata_i;
assign config_wen_o     = (current_state == WDATA);

// Address and ID registers
always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
        waddr <= '0;
        raddr <= '0;
        arid  <= '0;
        awid  <= '0; 
    end else begin
        case (current_state) 
            RADDR: begin
                raddr <= axi_araddr_i[11:0];
                arid  <= axi_arid_i;
            end 
            WADDR: begin
                waddr <= axi_awaddr_i[11:0];
                awid  <= axi_awid_i;
            end
            default: begin
                // Keep values
            end
        endcase
    end  
end

// Next state logic
always_comb begin
    next_state = current_state;
    
    case (current_state)
        IDLE: begin
            if (axi_arvalid_i) 
                next_state = RADDR;
            else if (axi_awvalid_i) 
                next_state = WADDR;
        end
        
        RADDR: begin
            if (axi_arvalid_i && axi_arready_o)
                next_state = RDATA;
        end
        
        RDATA: begin
            if (axi_rvalid_o && axi_rready_i)
                next_state = IDLE;
        end
        
        WADDR: begin
            if (axi_awvalid_i && axi_awready_o)
                next_state = WDATA; 
        end
        
        WDATA: begin
            if (axi_wvalid_i && axi_wready_o)// && axi_wlast_i)
                next_state = WRESP;
        end
        
        WRESP: begin
            if (axi_bvalid_o && axi_bready_i)
                next_state = IDLE; 
        end
        
        default: next_state = IDLE;
    endcase
end

endmodule