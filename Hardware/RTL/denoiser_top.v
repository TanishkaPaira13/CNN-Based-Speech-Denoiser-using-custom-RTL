// denoiser_top.v
// Top-level FPGA accelerator for DenoisingCNN on ZCU102.
//
// Interfaces:
//   S_AXIS  : AXI4-Stream input  (receive patch from PS via AXI DMA)
//   M_AXIS  : AXI4-Stream output (send result to PS via AXI DMA)
//   S_AXIL  : AXI4-Lite control/status registers
//   irq     : interrupt to PS (assert when done)
//
// AXI4-Lite register map (byte addresses):
//   0x00  CTRL  [0]=start, [1]=reset
//   0x04  STAT  [0]=busy,  [1]=done
//   0x08  PATCH_H (read-only: 257)
//   0x0C  PATCH_W (read-only: 64)
//
// Data format on AXI4-Stream:
//   32-bit words; lower 16 bits carry one Q3.12 fixed-point sample.
//   Patch = 257×64 = 16,448 words in raster order (row-major).
//
// Processing flow:
//   RECV  → LAYER1 → LAYER2 → LAYER3 → LAYER4 → SEND → IDLE
//
// Ping-pong BRAM banks A and B:
//   Layer input always read from "current" bank.
//   Layer output always written to "next" bank.
//   Bank roles swap each layer.

`timescale 1ns/1ps
`default_nettype none

module denoiser_top #(
    parameter H       = 257,    // patch height
    parameter W       = 64,     // patch width
    parameter MAX_C   = 16,     // max output channels (parallel MAC width)
    parameter DW      = 16,     // fixed-point data width (Q3.12)
    parameter AW      = 19,     // feature BRAM address width
    parameter FRAC    = 12      // fractional bits
)(
    input  wire        aclk,
    input  wire        aresetn,

    // ── AXI4-Stream Slave (patch input) ────────────────────────────────────
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire        s_axis_tlast,

    // ── AXI4-Stream Master (patch output) ──────────────────────────────────
    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,

    // ── AXI4-Lite Slave (control) ──────────────────────────────────────────
    input  wire [7:0]  s_axil_awaddr,  input  wire s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,   input  wire s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,   output reg  s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [7:0]  s_axil_araddr,  input  wire s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,   output reg  [1:0] s_axil_rresp,
    output reg         s_axil_rvalid,  input  wire s_axil_rready,

    output wire        irq
);

// ── Top-level FSM ─────────────────────────────────────────────────────────
localparam  FS_IDLE   = 4'd0,
            FS_RECV   = 4'd1,
            FS_L1     = 4'd2,
            FS_L1WAIT = 4'd3,
            FS_L2     = 4'd4,
            FS_L2WAIT = 4'd5,
            FS_L3     = 4'd6,
            FS_L3WAIT = 4'd7,
            FS_L4     = 4'd8,
            FS_L4WAIT = 4'd9,
            FS_SEND   = 4'd10;

reg [3:0] fsm;

// Control/status registers
reg        ctrl_start;
reg        stat_busy;
reg        stat_done;

// ── Feature BRAM (two banks, ping-pong) ───────────────────────────────────
// Bank A and Bank B; each 257*64*MAX_C entries
// Reception → Bank A
// L1 reads A, writes B
// L2 reads B, writes A
// L3 reads A, writes B
// L4 reads B, writes A  (output in A)
// Transmit from Bank A

wire [AW-1:0] ba_wr_addr, bb_wr_addr;
wire [DW-1:0] ba_wr_data, bb_wr_data;
wire           ba_wr_en,   bb_wr_en;
wire [AW-1:0] ba_rd_addr, bb_rd_addr;
wire [DW-1:0] ba_rd_data, bb_rd_data;

// Mux selects between rx/layer engines and tx
// Bank A reads: recv (during RECV) OR conv engine input (L1_in or L3_in or TX)
// Bank B reads: conv engine input (L2_in or L4_in)

// ── Receive counter ───────────────────────────────────────────────────────
localparam PATCH_SIZE = H * W;  // 16448
reg [$clog2(PATCH_SIZE):0] rx_cnt;

// ── Transmit counter ─────────────────────────────────────────────────────
reg [$clog2(PATCH_SIZE):0] tx_cnt;

// ── Conv engine control ───────────────────────────────────────────────────
reg         eng_start;
wire        eng_done;

// Per-layer config signals (muxed to conv_engine)
wire [AW-1:0] eng_in_rd_addr, eng_out_wr_addr;
wire [DW-1:0] eng_out_wr_data;
wire           eng_out_wr_en;

// ── Feature BRAM bank routing ─────────────────────────────────────────────
// During RECV: write to Bank A at rx_cnt, ch=0
// During SEND: read from Bank A at tx_cnt, ch=0
// During layers:
//   L1/L3 read Bank A, write Bank B
//   L2/L4 read Bank B, write Bank A

wire recv_wr_en   = (fsm == FS_RECV)   && s_axis_tvalid;
// BRAM layout: addr = pixel_idx * MAX_C + ch  (ch=0 for single-channel input)
// rx_cnt is [$clog2(PATCH_SIZE):0] = 16-bit; rx_cnt * MAX_C = {rx_cnt[AW-5:0], 4'b0}
wire [AW-1:0] recv_wr_addr = {{(AW-$clog2(PATCH_SIZE)-1){1'b0}}, rx_cnt[$clog2(PATCH_SIZE)-1:0], 4'b0};
wire [DW-1:0] recv_wr_data = s_axis_tdata[DW-1:0];  // lower 16-bit

// Decide which engine reads/writes which bank
wire l1_or_l3 = (fsm == FS_L1WAIT) || (fsm == FS_L3WAIT);
wire l2_or_l4 = (fsm == FS_L2WAIT) || (fsm == FS_L4WAIT);

// Bank A: written during RECV and during L2/L4 layer output
assign ba_wr_en   = recv_wr_en || (l2_or_l4 && eng_out_wr_en);
assign ba_wr_addr = recv_wr_en  ? recv_wr_addr : eng_out_wr_addr;
assign ba_wr_data = recv_wr_en  ? recv_wr_data : eng_out_wr_data;
// Bank A read: L1/L3 input reads, or SEND reads
// tx_cnt * MAX_C = {tx_cnt[AW-5:0], 4'b0}  (ch=0, stride=MAX_C=16)
assign ba_rd_addr = (fsm == FS_SEND)
    ? {{(AW-$clog2(PATCH_SIZE)-1){1'b0}}, tx_cnt[$clog2(PATCH_SIZE)-1:0], 4'b0}
    : eng_in_rd_addr;

// Bank B: written during L1/L3 layer output
assign bb_wr_en   = l1_or_l3 && eng_out_wr_en;
assign bb_wr_addr = eng_out_wr_addr;
assign bb_wr_data = eng_out_wr_data;
// Bank B read: L2/L4 input reads
assign bb_rd_addr = eng_in_rd_addr;

// Engine input data comes from appropriate bank
wire [DW-1:0] eng_in_rd_data = l2_or_l4 ? bb_rd_data : ba_rd_data;

// ── Weight ROM selects (shared address for all layers via engine) ──────────
// Four separate weight ROMs instantiated below, engine picks based on FSM.
wire [7:0]          eng_w_addr_raw;
wire [MAX_C*DW-1:0] w1_data, w2_data, w3_data, w4_data;
wire [31:0]         b1_data, b2_data, b3_data, b4_data;
wire [3:0]          eng_b_addr_raw;

// Map engine weight/bias ports to current layer's ROM
wire [MAX_C*DW-1:0] eng_w_data =
    (fsm == FS_L1WAIT) ? w1_data :
    (fsm == FS_L2WAIT) ? w2_data :
    (fsm == FS_L3WAIT) ? w3_data : w4_data;

wire [31:0] eng_b_data =
    (fsm == FS_L1WAIT) ? b1_data :
    (fsm == FS_L2WAIT) ? b2_data :
    (fsm == FS_L3WAIT) ? b3_data : b4_data;

// ── Conv engine (single shared engine, reconfigured per layer) ────────────
// Layer config: C_IN and C_OUT change per layer; use a single max-size engine.
// C_IN_MAX=16, C_OUT=MAX_C=16; smaller layers just ignore unused outputs.
// The inner loop runs C_IN_MAX*9 cycles; for smaller C_IN layers we override.

// For simplicity, instantiate one engine per layer configuration.
// Only the active engine's done signal is routed based on FSM state.

wire eng1_done, eng2_done, eng3_done, eng4_done;
wire [AW-1:0] e1_in_ra, e2_in_ra, e3_in_ra, e4_in_ra;
wire [AW-1:0] e1_ow_a,  e2_ow_a,  e3_ow_a,  e4_ow_a;
wire [DW-1:0] e1_ow_d,  e2_ow_d,  e3_ow_d,  e4_ow_d;
wire           e1_ow_e,  e2_ow_e,  e3_ow_e,  e4_ow_e;
wire [7:0]    e1_wa,    e2_wa,    e3_wa,    e4_wa;
wire [3:0]    e1_ba,    e2_ba,    e3_ba,    e4_ba;

wire eng1_start = (fsm == FS_L1);
wire eng2_start = (fsm == FS_L2);
wire eng3_start = (fsm == FS_L3);
wire eng4_start = (fsm == FS_L4);

// Route engine signals to shared BRAM ports
assign eng_in_rd_addr = (fsm == FS_L1WAIT || fsm == FS_L1) ? e1_in_ra :
                        (fsm == FS_L2WAIT || fsm == FS_L2) ? e2_in_ra :
                        (fsm == FS_L3WAIT || fsm == FS_L3) ? e3_in_ra : e4_in_ra;
assign eng_out_wr_addr = (fsm == FS_L1WAIT) ? e1_ow_a :
                         (fsm == FS_L2WAIT) ? e2_ow_a :
                         (fsm == FS_L3WAIT) ? e3_ow_a : e4_ow_a;
assign eng_out_wr_data = (fsm == FS_L1WAIT) ? e1_ow_d :
                         (fsm == FS_L2WAIT) ? e2_ow_d :
                         (fsm == FS_L3WAIT) ? e3_ow_d : e4_ow_d;
assign eng_out_wr_en   = (fsm == FS_L1WAIT) ? e1_ow_e :
                         (fsm == FS_L2WAIT) ? e2_ow_e :
                         (fsm == FS_L3WAIT) ? e3_ow_e : e4_ow_e;
assign eng_done        = (fsm == FS_L1WAIT) ? eng1_done :
                         (fsm == FS_L2WAIT) ? eng2_done :
                         (fsm == FS_L3WAIT) ? eng3_done : eng4_done;

// ── Submodule instantiations ──────────────────────────────────────────────

feature_bram #(.DEPTH(H*W*MAX_C), .AWIDTH(AW), .DWIDTH(DW)) BRAM_A (
    .clk(aclk), .wr_addr(ba_wr_addr), .wr_data(ba_wr_data), .wr_en(ba_wr_en),
    .rd_addr(ba_rd_addr), .rd_data(ba_rd_data)
);
feature_bram #(.DEPTH(H*W*MAX_C), .AWIDTH(AW), .DWIDTH(DW)) BRAM_B (
    .clk(aclk), .wr_addr(bb_wr_addr), .wr_data(bb_wr_data), .wr_en(bb_wr_en),
    .rd_addr(bb_rd_addr), .rd_data(bb_rd_data)
);

// Layer 1: C_IN=1, C_OUT=8, ReLU=1
conv_engine #(.H(H),.W(W),.C_IN(1),.C_OUT(8),.MAX_C(MAX_C),.FRAC(FRAC),
              .DW(DW),.AW(AW),.APPLY_RELU(1),.W_DEPTH(9)) ENG1 (
    .clk(aclk),.rst_n(aresetn),.start(eng1_start),.done(eng1_done),
    .in_rd_addr(e1_in_ra),.in_rd_data(eng_in_rd_data),
    .out_wr_addr(e1_ow_a),.out_wr_data(e1_ow_d),.out_wr_en(e1_ow_e),
    .w_addr(e1_wa[3:0]),.w_data(eng_w_data),
    .b_addr(e1_ba),.b_data(eng_b_data)
);
// Layer 2: C_IN=8, C_OUT=16, ReLU=1
conv_engine #(.H(H),.W(W),.C_IN(8),.C_OUT(16),.MAX_C(MAX_C),.FRAC(FRAC),
              .DW(DW),.AW(AW),.APPLY_RELU(1),.W_DEPTH(72)) ENG2 (
    .clk(aclk),.rst_n(aresetn),.start(eng2_start),.done(eng2_done),
    .in_rd_addr(e2_in_ra),.in_rd_data(eng_in_rd_data),
    .out_wr_addr(e2_ow_a),.out_wr_data(e2_ow_d),.out_wr_en(e2_ow_e),
    .w_addr(e2_wa[6:0]),.w_data(eng_w_data),
    .b_addr(e2_ba),.b_data(eng_b_data)
);
// Layer 3: C_IN=16, C_OUT=8, ReLU=1
conv_engine #(.H(H),.W(W),.C_IN(16),.C_OUT(8),.MAX_C(MAX_C),.FRAC(FRAC),
              .DW(DW),.AW(AW),.APPLY_RELU(1),.W_DEPTH(144)) ENG3 (
    .clk(aclk),.rst_n(aresetn),.start(eng3_start),.done(eng3_done),
    .in_rd_addr(e3_in_ra),.in_rd_data(eng_in_rd_data),
    .out_wr_addr(e3_ow_a),.out_wr_data(e3_ow_d),.out_wr_en(e3_ow_e),
    .w_addr(e3_wa[7:0]),.w_data(eng_w_data),
    .b_addr(e3_ba),.b_data(eng_b_data)
);
// Layer 4: C_IN=8, C_OUT=1, ReLU=0 (linear output)
conv_engine #(.H(H),.W(W),.C_IN(8),.C_OUT(1),.MAX_C(MAX_C),.FRAC(FRAC),
              .DW(DW),.AW(AW),.APPLY_RELU(0),.W_DEPTH(72)) ENG4 (
    .clk(aclk),.rst_n(aresetn),.start(eng4_start),.done(eng4_done),
    .in_rd_addr(e4_in_ra),.in_rd_data(eng_in_rd_data),
    .out_wr_addr(e4_ow_a),.out_wr_data(e4_ow_d),.out_wr_en(e4_ow_e),
    .w_addr(e4_wa[6:0]),.w_data(eng_w_data),
    .b_addr(e4_ba),.b_data(eng_b_data)
);

// Weight ROMs (separate .mem file per layer)
// weight_rom uses WWIDTH (not DW) for the data-width parameter
weight_rom #(.MAX_C(MAX_C),.WWIDTH(DW),.C_IN(1), .DEPTH(9),
             .INIT_FILE("weights_L1_conv.mem")) WROM1 (.clk(aclk),.addr(e1_wa[3:0]),.dout(w1_data));
weight_rom #(.MAX_C(MAX_C),.WWIDTH(DW),.C_IN(8), .DEPTH(72),
             .INIT_FILE("weights_L2_conv.mem")) WROM2 (.clk(aclk),.addr(e2_wa[6:0]),.dout(w2_data));
weight_rom #(.MAX_C(MAX_C),.WWIDTH(DW),.C_IN(16),.DEPTH(144),
             .INIT_FILE("weights_L3_conv.mem")) WROM3 (.clk(aclk),.addr(e3_wa[7:0]),.dout(w3_data));
weight_rom #(.MAX_C(MAX_C),.WWIDTH(DW),.C_IN(8), .DEPTH(72),
             .INIT_FILE("weights_L4_conv.mem")) WROM4 (.clk(aclk),.addr(e4_wa[6:0]),.dout(w4_data));

bias_rom #(.MAX_C(MAX_C),.INIT_FILE("biases_L1_conv.mem")) BROM1 (.clk(aclk),.addr(e1_ba),.dout(b1_data));
bias_rom #(.MAX_C(MAX_C),.INIT_FILE("biases_L2_conv.mem")) BROM2 (.clk(aclk),.addr(e2_ba),.dout(b2_data));
bias_rom #(.MAX_C(MAX_C),.INIT_FILE("biases_L3_conv.mem")) BROM3 (.clk(aclk),.addr(e3_ba),.dout(b3_data));
bias_rom #(.MAX_C(MAX_C),.INIT_FILE("biases_L4_conv.mem")) BROM4 (.clk(aclk),.addr(e4_ba),.dout(b4_data));

// ── Top FSM ───────────────────────────────────────────────────────────────
assign irq = stat_done;

always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        fsm           <= FS_IDLE;
        s_axis_tready <= 0;
        m_axis_tvalid <= 0;
        m_axis_tlast  <= 0;
        stat_busy     <= 0;
        stat_done     <= 0;
        rx_cnt        <= 0;
        tx_cnt        <= 0;
    end else begin
        case (fsm)
        FS_IDLE: begin
            stat_done     <= 0;
            s_axis_tready <= 0;
            if (ctrl_start) begin
                rx_cnt        <= 0;
                stat_busy     <= 1;
                stat_done     <= 0;
                s_axis_tready <= 1;
                fsm           <= FS_RECV;
            end
        end
        FS_RECV: begin
            if (s_axis_tvalid) begin
                rx_cnt <= rx_cnt + 1;
                if (rx_cnt == PATCH_SIZE - 1) begin
                    s_axis_tready <= 0;
                    fsm           <= FS_L1;
                end
            end
        end
        FS_L1: begin
            // eng1_start asserted (combinational = (fsm==FS_L1))
            fsm <= FS_L1WAIT;
        end
        FS_L1WAIT: if (eng1_done) fsm <= FS_L2;
        FS_L2:     fsm <= FS_L2WAIT;
        FS_L2WAIT: if (eng2_done) fsm <= FS_L3;
        FS_L3:     fsm <= FS_L3WAIT;
        FS_L3WAIT: if (eng3_done) fsm <= FS_L4;
        FS_L4:     fsm <= FS_L4WAIT;
        FS_L4WAIT: begin
            if (eng4_done) begin
                tx_cnt        <= 0;
                m_axis_tvalid <= 1;
                fsm           <= FS_SEND;
            end
        end
        FS_SEND: begin
            // Read from Bank A, channel 0 (output of L4)
            // ba_rd_addr is driven by tx_cnt above
            if (m_axis_tready && m_axis_tvalid) begin
                m_axis_tdata  <= {16'h0000, ba_rd_data};
                m_axis_tlast  <= (tx_cnt == PATCH_SIZE - 1);
                tx_cnt        <= tx_cnt + 1;
                if (tx_cnt == PATCH_SIZE - 1) begin
                    m_axis_tvalid <= 0;
                    stat_busy     <= 0;
                    stat_done     <= 1;
                    fsm           <= FS_IDLE;
                end
            end else if (!m_axis_tvalid) begin
                // Prime first read
                m_axis_tdata  <= {16'h0000, ba_rd_data};
            end
        end
        default: fsm <= FS_IDLE;
        endcase
    end
end

// ── AXI4-Lite register interface ─────────────────────────────────────────
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        ctrl_start     <= 0;
        s_axil_awready <= 0; s_axil_wready <= 0;
        s_axil_bvalid  <= 0; s_axil_bresp  <= 0;
        s_axil_arready <= 0; s_axil_rvalid <= 0;
        s_axil_rdata   <= 0; s_axil_rresp  <= 0;
    end else begin
        ctrl_start <= 0;  // auto-clear

        // Write
        if (s_axil_awvalid && !s_axil_awready) s_axil_awready <= 1;
        else                                     s_axil_awready <= 0;

        if (s_axil_wvalid && !s_axil_wready) begin
            s_axil_wready <= 1;
            if (s_axil_awaddr[3:0] == 4'h0)
                ctrl_start <= s_axil_wdata[0];
        end else s_axil_wready <= 0;

        if (s_axil_wready) begin s_axil_bvalid <= 1; s_axil_bresp <= 0; end
        if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 0;

        // Read
        if (s_axil_arvalid && !s_axil_arready) begin
            s_axil_arready <= 1;
            case (s_axil_araddr[3:0])
            4'h0: s_axil_rdata <= {30'h0, stat_done, stat_busy};   // CTRL dummy
            4'h4: s_axil_rdata <= {30'h0, stat_done, stat_busy};   // STAT
            4'h8: s_axil_rdata <= H;
            4'hC: s_axil_rdata <= W;
            default: s_axil_rdata <= 32'hDEAD_BEEF;
            endcase
            s_axil_rvalid <= 1; s_axil_rresp <= 0;
        end else begin
            s_axil_arready <= 0;
            if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 0;
        end
    end
end

endmodule
`default_nettype wire
