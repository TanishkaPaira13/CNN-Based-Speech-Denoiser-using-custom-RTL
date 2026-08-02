// conv_engine.v
// Sequential Conv2D engine for DenoisingCNN on ZCU102.
//
// Computes one layer of Conv2d(kernel=3x3, padding=1, stride=1).
// All MAX_C_OUT output channels are computed in parallel each cycle.
// Inner loop (ci, kh, kw) runs sequentially — one accumulation per clock.
//
// Fixed-point: Q3.12 for features and weights; 48-bit accumulator (Q6.24×scale).
//   weight: int16 Q3.12   (actual × 4096)
//   feature: int16 Q3.12
//   product: int32 Q6.24  (actual_product × 4096²)
//   acc: int48             (sum of C_IN*9 products + bias in Q6.24)
//   output = saturate(acc >> 12, 16-bit)  → Q3.12
//
// Timing per (h,w) group:
//   1 (bias load) + C_IN*9 (MAC) + C_OUT (write-back) cycles

`timescale 1ns/1ps
module conv_engine #(
    parameter H        = 257,  // Patch height
    parameter W        = 64,   // Patch width
    parameter C_IN     = 8,    // Input channels this layer
    parameter C_OUT    = 16,   // Output channels this layer
    parameter MAX_C    = 16,   // RTL-wide constant: max parallel channels
    parameter FRAC     = 12,   // Fractional bits for weights/features
    parameter DW       = 16,   // Feature/weight data width
    parameter AW       = 19,   // Feature BRAM address width
    parameter APPLY_RELU = 1,  // 1 = ReLU after layer, 0 = linear
    // Weight ROM size for this layer
    parameter W_DEPTH  = C_IN * 9
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,   // Pulse to begin processing this layer
    output reg         done,    // Pulses when layer complete

    // Input feature BRAM (read port)
    output reg  [AW-1:0]  in_rd_addr,
    input  wire [DW-1:0]  in_rd_data,   // 1-cycle registered read

    // Output feature BRAM (write port)
    output reg  [AW-1:0]  out_wr_addr,
    output reg  [DW-1:0]  out_wr_data,
    output reg             out_wr_en,

    // Weight ROM (parallel output for all MAX_C channels)
    output reg  [$clog2(W_DEPTH)-1:0] w_addr,
    input  wire [MAX_C*DW-1:0]        w_data,  // MAX_C weights in one read

    // Bias ROM
    output reg  [3:0]      b_addr,
    input  wire [31:0]     b_data   // one bias per channel (Q6.24)
);

// ---------- Loop counters ----------
// Spatial loop
reg [$clog2(H)-1:0] h_cnt;
reg [$clog2(W)-1:0] w_cnt;
// Output channel write-back counter
reg [$clog2(MAX_C)-1:0] co_cnt;
// Inner loop: ci × kh × kw  (sequential)
reg [$clog2(W_DEPTH)-1:0] inner_cnt;

// ---------- Accumulators (one per output channel, 48-bit) ----------
// Store in int64 but only use 48 bits; synthesis uses DSP48E2
reg signed [47:0] acc [0:MAX_C-1];

// ---------- State machine ----------
localparam  S_IDLE    = 3'd0,
            S_BIAS    = 3'd1,   // load bias into accumulators (C_OUT cycles)
            S_MAC     = 3'd2,   // inner MAC loop (C_IN*9 cycles per pos)
            S_WRITE   = 3'd3,   // write C_OUT outputs (C_OUT cycles)
            S_NEXT    = 3'd4;   // advance spatial position

reg [2:0] state;

// Pipeline registers for MAC input (BRAM read latency = 1)
reg [$clog2(W_DEPTH)-1:0] inner_d1;
reg                         mac_valid;

// Recompute the spatial padded address
// Zero-padding for conv2d with padding=1:
//   if row or col is out of bounds → use 0 (no memory read)
reg                               pad_zero;
reg signed [DW-1:0]               feat_in_val;

// Compute (h,w) position and kernel offset from inner_cnt
wire [$clog2(C_IN)-1:0]   ci_idx  = inner_cnt / 9;
wire [1:0]                 kh_off  = (inner_cnt % 9) / 3;  // 0,1,2
wire [1:0]                 kw_off  = (inner_cnt % 9) % 3;  // 0,1,2

// Spatial position with kernel offset
wire signed [$clog2(H):0] row_pos = $signed({1'b0, h_cnt}) + kh_off - 1;
wire signed [$clog2(W):0] col_pos = $signed({1'b0, w_cnt}) + kw_off - 1;

wire in_bounds = (row_pos >= 0) && (row_pos < H) &&
                 (col_pos >= 0) && (col_pos < W);

// Input BRAM address: channel-major then spatial
// Layout: addr = h*W*MAX_C + w*MAX_C + ci
wire [AW-1:0] feat_rd_base = row_pos[AW-2:0] * (W * MAX_C) +
                              col_pos[AW-2:0] * MAX_C +
                              ci_idx;

// Output BRAM address (same layout)
wire [AW-1:0] out_wr_base  = h_cnt * (W * MAX_C) + w_cnt * MAX_C;

integer co;

genvar g;
generate
    // Per-channel wires for MAC
    for (g = 0; g < MAX_C; g = g + 1) begin : gen_mac
        wire signed [DW-1:0]   w_val = w_data[g*DW +: DW];
        wire signed [2*DW-1:0] prod  = feat_in_val * w_val;
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_IDLE;
        done       <= 1'b0;
        out_wr_en  <= 1'b0;
        mac_valid  <= 1'b0;
        h_cnt      <= 0;
        w_cnt      <= 0;
        co_cnt     <= 0;
        inner_cnt  <= 0;
    end else begin
        done       <= 1'b0;
        out_wr_en  <= 1'b0;

        case (state)
        // ── Wait for start pulse ──────────────────────────────────────────
        S_IDLE: begin
            if (start) begin
                h_cnt     <= 0;
                w_cnt     <= 0;
                inner_cnt <= 0;
                co_cnt    <= 0;
                mac_valid <= 0;
                state     <= S_BIAS;
                b_addr    <= 0;
            end
        end

        // ── Load biases into accumulators (one per cycle, C_OUT total) ───
        S_BIAS: begin
            // b_data is registered (1-cycle ROM latency) so we must wait
            b_addr <= co_cnt[3:0];

            if (co_cnt > 0) begin   // data from previous b_addr is valid
                // Sign-extend 32-bit Q6.24 bias to 48-bit accumulator
                acc[co_cnt - 1] <= {{16{b_data[31]}}, b_data};
            end

            if (co_cnt == C_OUT) begin
                // Last bias loaded in next cycle (handle outside timing)
                inner_cnt <= 0;
                mac_valid <= 0;
                state     <= S_MAC;
            end else begin
                co_cnt <= co_cnt + 1;
            end
        end

        // ── MAC inner loop: read feat, multiply by 16 weights ────────────
        S_MAC: begin
            // Issue read to feature BRAM
            if (in_bounds) begin
                in_rd_addr <= feat_rd_base;
                pad_zero   <= 1'b0;
            end else begin
                in_rd_addr <= 0;         // dummy read (will mask result)
                pad_zero   <= 1'b1;
            end

            // Issue read to weight ROM (same inner address)
            w_addr <= inner_cnt[$clog2(W_DEPTH)-1:0];
            inner_d1 <= inner_cnt;

            // Accumulate from previous cycle's data
            if (mac_valid) begin
                feat_in_val = pad_zero ? 16'sd0 : $signed(in_rd_data);
                for (co = 0; co < MAX_C; co = co + 1) begin
                    if (co < C_OUT)
                        acc[co] <= acc[co] + feat_in_val *
                                   $signed(w_data[co*DW +: DW]);
                end
            end

            mac_valid <= 1'b1;

            if (inner_cnt == W_DEPTH - 1) begin
                inner_cnt <= 0;
                mac_valid <= 0;
                co_cnt    <= 0;
                state     <= S_WRITE;
            end else begin
                inner_cnt <= inner_cnt + 1;
            end
        end

        // ── Write back C_OUT results ──────────────────────────────────────
        S_WRITE: begin
            if (co_cnt < C_OUT) begin
                // Arithmetic right shift by FRAC bits, saturate to 16-bit
                reg signed [47:0] shifted;
                reg signed [DW-1:0] sat_val;
                shifted = acc[co_cnt] >>> FRAC;
                // Apply ReLU if enabled
                if (APPLY_RELU && shifted < 0)
                    sat_val = 0;
                else if (shifted > $signed(16'sh7FFF))
                    sat_val = 16'sh7FFF;
                else if (shifted < $signed(16'sh8000))
                    sat_val = 16'sh8000;
                else
                    sat_val = shifted[DW-1:0];

                out_wr_addr <= out_wr_base + co_cnt;
                out_wr_data <= sat_val;
                out_wr_en   <= 1'b1;
                co_cnt      <= co_cnt + 1;
            end else begin
                state <= S_NEXT;
            end
        end

        // ── Advance spatial position ──────────────────────────────────────
        S_NEXT: begin
            co_cnt <= 0;
            if (w_cnt == W - 1) begin
                w_cnt <= 0;
                if (h_cnt == H - 1) begin
                    h_cnt <= 0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    h_cnt <= h_cnt + 1;
                    state <= S_BIAS;
                    b_addr <= 0;
                end
            end else begin
                w_cnt <= w_cnt + 1;
                state <= S_BIAS;
                b_addr <= 0;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
