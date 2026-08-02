// feature_bram.v
// Dual-port feature-map BRAM.
// Depth = 257*64*16 = 263,168 entries × 16-bit = ~4 Mbit per bank.
// Vivado infers RAMB36E2 blocks automatically from this pattern.
//
// Address layout:  addr = h*(W*MAX_C) + w*MAX_C + ch
//   H=257, W=64, MAX_C=16  →  max_addr = 256*1024 + 63*16 + 15 = 263,167

`timescale 1ns/1ps
module feature_bram #(
    parameter DEPTH  = 263168,   // 257*64*16
    parameter AWIDTH = 19,        // ceil(log2(263168)) = 18 → use 19 for safety
    parameter DWIDTH = 16
)(
    input  wire              clk,
    // Write port
    input  wire [AWIDTH-1:0] wr_addr,
    input  wire [DWIDTH-1:0] wr_data,
    input  wire              wr_en,
    // Read port (registered, 1-cycle latency)
    input  wire [AWIDTH-1:0] rd_addr,
    output reg  [DWIDTH-1:0] rd_data
);

(* ram_style = "block" *)
reg [DWIDTH-1:0] mem [0:DEPTH-1];

always @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];
end

endmodule
