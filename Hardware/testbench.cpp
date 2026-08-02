// tb_denoiser_top.cpp
// Verilator cycle-accurate testbench for denoiser_top.v
//
// Simulates the full patch processing pipeline as close to the real ZCU102 setup
// as possible:
//   1. Reset (active-low aresetn)
//   2. AXI4-Lite write: CTRL = START  (mimics PS baremetal cnn_write_reg())
//   3. AXI4-Stream send: input patch   (mimics AXI DMA MM2S)
//   4. AXI4-Stream recv: output patch  (mimics AXI DMA S2MM)
//   5. Compare vs golden reference
//   6. Print PASS / FAIL with error statistics
//
// KNOWN RTL BUGS (detected by this testbench):
//   BUG-1  conv_engine.v line ~194: transition condition `inner_cnt == W_DEPTH-1`
//          causes the last kernel element to never be accumulated.
//          Fix: change to `inner_cnt == W_DEPTH` (one extra pipeline drain cycle).
//   BUG-2  denoiser_top.v line ~144: ba_rd_addr in FS_SEND =
//          {tx_cnt[AW-2:0], 1'b0} = tx_cnt*2  (reads stride-2)
//          Should be {tx_cnt[AW-5:0], 4'b0} = tx_cnt*MAX_C = tx_cnt*16.
//          Output stream is garbage without this fix.
//
// Build: see Makefile in this directory.
// Run:   see run_sim.sh for setup (copies .mem files, generates test data).

#include "Vdenoiser_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "axi_driver.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <cmath>
#include <vector>
#include <string>
#include <fstream>
#include <algorithm>

// ── Patch geometry (must match RTL parameters) ────────────────────────────
#define PATCH_H       257
#define PATCH_W       64
#define PATCH_SAMPLES (PATCH_H * PATCH_W)   // 16448
#define Q_FRAC        12
#define Q_SCALE       (1 << Q_FRAC)          // 4096

// ── AXI4-Lite register map (must match denoiser_top.v) ───────────────────
#define REG_CTRL    0x00
#define REG_STAT    0x04
#define REG_PATCH_H 0x08
#define REG_PATCH_W 0x0C
#define CTRL_START  (1u << 0)
#define CTRL_RESET  (1u << 1)
#define STAT_BUSY   (1u << 0)
#define STAT_DONE   (1u << 1)

// ── Simulation limits ─────────────────────────────────────────────────────
#define MAX_SIM_CYCLES  30000000UL   // 30M cycles at 200MHz ≈ 150ms (generous timeout)
#define RESET_CYCLES    20

// ── Global sim state ──────────────────────────────────────────────────────
static uint64_t        sim_time_ns = 0;
static Vdenoiser_top  *dut         = nullptr;
static VerilatedVcdC  *vcd         = nullptr;
static bool            vcd_enabled = false;

static void tick() {
    // Falling edge
    dut->aclk = 0;
    dut->eval();
    if (vcd_enabled && vcd) vcd->dump(sim_time_ns);
    sim_time_ns++;

    // Rising edge
    dut->aclk = 1;
    dut->eval();
    if (vcd_enabled && vcd) vcd->dump(sim_time_ns);
    sim_time_ns++;
}

// ── File I/O helpers ──────────────────────────────────────────────────────
static bool load_bin_i16(const char *path, int16_t *buf, int n) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "[TB] Cannot open %s\n", path); return false; }
    int rd = (int)fread(buf, sizeof(int16_t), n, fp);
    fclose(fp);
    if (rd != n) {
        fprintf(stderr, "[TB] %s: expected %d samples, got %d\n", path, n, rd);
        return false;
    }
    return true;
}

static void save_bin_i16(const char *path, const int16_t *buf, int n) {
    FILE *fp = fopen(path, "wb");
    if (!fp) { fprintf(stderr, "[TB] Cannot write %s\n", path); return; }
    fwrite(buf, sizeof(int16_t), n, fp);
    fclose(fp);
}

// ── Compare and report ────────────────────────────────────────────────────
struct CmpResult {
    int    n_mismatch;
    double rmse;
    double max_err_float;
    int    first_mismatch_idx;
};

static CmpResult compare(const int16_t *got, const int16_t *expected, int n,
                          const char *label) {
    CmpResult r = {0, 0.0, 0.0, -1};
    double sse = 0.0;
    for (int i = 0; i < n; i++) {
        int diff = (int)got[i] - (int)expected[i];
        if (diff != 0) {
            r.n_mismatch++;
            if (r.first_mismatch_idx < 0) r.first_mismatch_idx = i;
        }
        sse += (double)diff * diff;
        double d_f = std::abs(diff) / (double)Q_SCALE;
        if (d_f > r.max_err_float) r.max_err_float = d_f;
    }
    r.rmse = std::sqrt(sse / n) / Q_SCALE;

    const char *verdict = (r.n_mismatch == 0) ? "PASS" : "FAIL";
    printf("  [%-20s] %s — mismatch: %d/%d  RMSE: %.5f  MaxErr: %.5f\n",
           label, verdict, r.n_mismatch, n, r.rmse, r.max_err_float);
    if (r.first_mismatch_idx >= 0 && r.n_mismatch <= 10) {
        int idx = r.first_mismatch_idx;
        printf("    first mismatch @ idx=%d (h=%d, w=%d): got=%d expected=%d diff=%d\n",
               idx, idx / PATCH_W, idx % PATCH_W,
               got[idx], expected[idx], (int)got[idx] - (int)expected[idx]);
    }
    return r;
}

// ── Main ──────────────────────────────────────────────────────────────────
int main(int argc, char **argv) {
    // Parse arguments
    bool     dump_vcd    = false;
    bool     bp_test     = false;    // test with backpressure on output stream
    int      n_patches   = 1;
    const char *inp_file = "input_patch.bin";
    const char *cor_file = "expected_correct.bin";
    const char *rtl_file = "expected_rtl.bin";
    const char *out_file = "sim_output.bin";

    for (int i = 1; i < argc; i++) {
        std::string a(argv[i]);
        if      (a == "--vcd")         dump_vcd = true;
        else if (a == "--backpressure") bp_test = true;
        else if (a.substr(0,8) == "--input=") inp_file = argv[i]+8;
        else if (a.substr(0,14)== "--expected=")  cor_file = argv[i]+11;
        else if (a == "--help" || a == "-h") {
            printf("Usage: %s [--vcd] [--backpressure] [--input=FILE] [--expected=FILE]\n", argv[0]);
            return 0;
        }
    }

    // ── Verilator init ─────────────────────────────────────────────────────
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(dump_vcd);

    dut = new Vdenoiser_top;

    if (dump_vcd) {
        vcd         = new VerilatedVcdC;
        vcd_enabled = true;
        dut->trace(vcd, 99);
        vcd->open("denoiser_sim.vcd");
        printf("[TB] VCD waveform: denoiser_sim.vcd\n");
    }

    // ── Load test data ─────────────────────────────────────────────────────
    printf("\n[TB] Loading test data ...\n");
    std::vector<int16_t> patch_in(PATCH_SAMPLES);
    std::vector<int16_t> exp_correct(PATCH_SAMPLES);
    std::vector<int16_t> exp_rtl(PATCH_SAMPLES);
    std::vector<int16_t> sim_out(PATCH_SAMPLES);

    bool have_golden = false;
    if (!load_bin_i16(inp_file, patch_in.data(), PATCH_SAMPLES)) {
        fprintf(stderr, "[TB] Input file not found — run gen_golden.py first\n");
        return 1;
    }
    have_golden |= load_bin_i16(cor_file, exp_correct.data(), PATCH_SAMPLES);
    bool have_rtl_golden = load_bin_i16(rtl_file, exp_rtl.data(), PATCH_SAMPLES);

    printf("[TB] Patch loaded: %d samples, range [%d, %d]\n",
           PATCH_SAMPLES,
           *std::min_element(patch_in.begin(), patch_in.end()),
           *std::max_element(patch_in.begin(), patch_in.end()));

    // ── Instantiate AXI drivers ────────────────────────────────────────────
    auto tick_fn = []() { tick(); };

    Axi4LiteMaster<Vdenoiser_top>   axi4l(dut, &sim_time_ns, tick_fn);
    Axi4StreamMaster<Vdenoiser_top> axis_m(dut, tick_fn);
    Axi4StreamSlave<Vdenoiser_top>  axis_s(dut, tick_fn);

    if (bp_test) {
        axis_s.set_backpressure(3);   // assert tready 1 out of every 3 cycles
        printf("[TB] Backpressure test: m_axis_tready asserted every 3 cycles\n");
    }

    // ── Drive initial values ───────────────────────────────────────────────
    dut->aclk           = 0;
    dut->aresetn        = 0;
    dut->s_axis_tdata   = 0;
    dut->s_axis_tvalid  = 0;
    dut->s_axis_tlast   = 0;
    dut->m_axis_tready  = 0;
    dut->s_axil_awaddr  = 0;
    dut->s_axil_awvalid = 0;
    dut->s_axil_wdata   = 0;
    dut->s_axil_wvalid  = 0;
    dut->s_axil_bready  = 0;
    dut->s_axil_araddr  = 0;
    dut->s_axil_arvalid = 0;
    dut->s_axil_rready  = 0;

    // ── Reset ──────────────────────────────────────────────────────────────
    printf("[TB] Resetting DUT (%d cycles) ...\n", RESET_CYCLES);
    for (int i = 0; i < RESET_CYCLES; i++) tick();
    dut->aresetn = 1;
    tick(); tick(); tick();  // settle

    // ── AXI4-Lite sanity reads ─────────────────────────────────────────────
    uint32_t h_reg = axi4l.read(REG_PATCH_H);
    uint32_t w_reg = axi4l.read(REG_PATCH_W);
    printf("[TB] PATCH_H reg = %u  PATCH_W reg = %u\n", h_reg, w_reg);
    if (h_reg != PATCH_H || w_reg != PATCH_W) {
        fprintf(stderr, "[TB] ERROR: dimension registers wrong (expected %d×%d)\n",
                PATCH_H, PATCH_W);
        return 1;
    }

    uint32_t stat = axi4l.read(REG_STAT);
    printf("[TB] Initial STAT = 0x%08X (busy=%d, done=%d)\n",
           stat, (stat>>0)&1, (stat>>1)&1);

    printf("\n[TB] ══════════════════════════════════════════════\n");
    printf("[TB]  Starting patch #1 of %d\n", n_patches);
    printf("[TB] ══════════════════════════════════════════════\n");
    printf("[TB] sim_time=0 (resetting = %llu cycles used)\n",
           (unsigned long long)sim_time_ns / 2);

    uint64_t t_start = sim_time_ns / 2;

    // Keep m_axis_tready LOW during processing so we don't miss output words
    // while doing AXI4-Lite register reads for progress.
    // The DUT waits in FS_SEND until tready goes high (no timeout in RTL).
    dut->m_axis_tready = 0;

    // ── AXI4-Lite: write CTRL = START ─────────────────────────────────────
    printf("[TB] Writing CTRL=START via AXI4-Lite ...\n");
    axi4l.write(REG_CTRL, CTRL_START);
    printf("[TB] CTRL written at cycle %llu\n",
           (unsigned long long)(sim_time_ns / 2 - t_start));

    // ── Wait for s_axis_tready (DUT enters FS_RECV one cycle after ctrl_start) ──
    printf("[TB] Waiting for s_axis_tready (FS_RECV) ...\n");
    {
        uint32_t wait = 0;
        while (!dut->s_axis_tready && wait < 100) { tick(); wait++; }
        if (!dut->s_axis_tready) {
            fprintf(stderr, "[TB] TIMEOUT waiting for s_axis_tready\n");
            return 1;
        }
        printf("[TB] s_axis_tready high at cycle %llu\n",
               (unsigned long long)(sim_time_ns / 2 - t_start));
    }

    // ── Phase 1: Send input patch ──────────────────────────────────────────
    printf("[TB] Sending %d words via AXI4-Stream ...\n", PATCH_SAMPLES);
    uint64_t t_send_start = sim_time_ns / 2 - t_start;

    axis_m.send_patch(patch_in.data(), PATCH_SAMPLES);
    axis_m.deassert();

    uint64_t t_send_end = sim_time_ns / 2 - t_start;
    printf("[TB] Send complete: %d words in %llu cycles (%.1f cycles/word)\n",
           PATCH_SAMPLES,
           (unsigned long long)(t_send_end - t_send_start),
           (double)(t_send_end - t_send_start) / PATCH_SAMPLES);

    // ── Phase 2: Wait for CNN processing (m_axis_tready stays LOW) ────────
    // AXI4-Lite reads are safe here because m_axis_tready=0 means the DUT
    // won't advance tx_cnt even if m_axis_tvalid goes high mid-read.
    printf("[TB] Processing (waiting for m_axis_tvalid) ...\n");
    printf("     (L1: ~440K cycles, L2: ~1.7M, L3: ~2.7M, L4: ~1.2M, total ~6.1M)\n");

    uint64_t last_progress_cycle = 0;
    while (!dut->m_axis_tvalid) {
        tick();
        uint64_t cur = sim_time_ns / 2 - t_start;
        if (cur - last_progress_cycle >= 500000) {
            last_progress_cycle = cur;
            uint32_t s = axi4l.read(REG_STAT);   // safe: tready=0
            printf("     ... %llu cycles  STAT=0x%X (busy=%d done=%d)\n",
                   (unsigned long long)cur, s, (s>>0)&1, (s>>1)&1);
        }
        if (cur > MAX_SIM_CYCLES) {
            fprintf(stderr, "[TB] TIMEOUT: DUT never reached FS_SEND\n");
            return 1;
        }
    }

    uint64_t t_compute_cycles = sim_time_ns / 2 - t_start - t_send_end;
    printf("[TB] Processing done in %llu cycles\n",
           (unsigned long long)t_compute_cycles);

    // ── Phase 3: Receive output patch ─────────────────────────────────────
    // Now assert m_axis_tready (via axis_s) to drain the output stream.
    // We give the BRAM read 2 extra cycles to present valid data for addr=0
    // before starting handshaking (workaround for the first-word latency bug).
    tick(); tick();   // let BRAM[0] propagate to ba_rd_data

    printf("[TB] Receiving %d output words ...\n", PATCH_SAMPLES);
    uint64_t t_recv_start = sim_time_ns / 2 - t_start;

    int n_recv = axis_s.recv_patch(sim_out.data(), PATCH_SAMPLES);

    uint64_t t_recv_end = sim_time_ns / 2 - t_start;
    printf("[TB] Received %d words in %llu cycles\n",
           n_recv, (unsigned long long)(t_recv_end - t_recv_start));

    // ── Wait for IRQ / done ────────────────────────────────────────────────
    // In real HW: PS polls STAT register until done=1, then starts next patch.
    {
        uint32_t timeout = 1000;
        while (!dut->irq && timeout--) tick();
        uint32_t s = axi4l.read(REG_STAT);
        printf("[TB] IRQ=%d  STAT=0x%X (busy=%d, done=%d)\n",
               (int)dut->irq, s, (s>>0)&1, (s>>1)&1);
    }

    uint64_t t_total = sim_time_ns / 2 - t_start;
    printf("[TB] Total simulation cycles: %llu\n", (unsigned long long)t_total);

    // ── Save output ────────────────────────────────────────────────────────
    save_bin_i16(out_file, sim_out.data(), PATCH_SAMPLES);
    printf("[TB] Simulation output saved to: %s\n", out_file);

    // ── Compare results ────────────────────────────────────────────────────
    printf("\n[TB] ══ Comparison Results ══════════════════════════════\n");
    printf("     (PATCH_SAMPLES=%d, Q3.12 fixed-point, scale=4096)\n\n", PATCH_SAMPLES);

    int exit_code = 0;

    if (have_golden) {
        CmpResult cr = compare(sim_out.data(), exp_correct.data(),
                               PATCH_SAMPLES, "vs CORRECT model");
        if (cr.n_mismatch > 0) {
            exit_code = 1;
            printf("  → Expected failures:\n");
            printf("    BUG-1 (conv_engine.v): last MAC element skipped per (h,w)\n");
            printf("    BUG-2 (denoiser_top.v FS_SEND): ba_rd_addr = tx_cnt*2 != tx_cnt*16\n");
            printf("    Run with --vcd flag and open denoiser_sim.vcd in GTKWave to debug.\n");
        }
    }

    if (have_rtl_golden) {
        CmpResult rr = compare(sim_out.data(), exp_rtl.data(),
                               PATCH_SAMPLES, "vs RTL-buggy model");
        if (rr.n_mismatch == 0) {
            printf("  → RTL output matches the RTL-buggy model exactly.\n");
            printf("    The RTL implements its (buggy) design consistently.\n");
        } else {
            printf("  → RTL output doesn't even match its own buggy model!\n");
            printf("    There may be additional RTL issues beyond BUG-1/BUG-2.\n");
        }
    }

    // Output range
    int16_t out_min = *std::min_element(sim_out.begin(), sim_out.end());
    int16_t out_max = *std::max_element(sim_out.begin(), sim_out.end());
    printf("\n[TB] Output range: [%d, %d]  ([%.4f, %.4f] in float Q3.12)\n",
           out_min, out_max,
           (double)out_min / Q_SCALE, (double)out_max / Q_SCALE);

    int n_nonzero = 0;
    for (int i = 0; i < PATCH_SAMPLES; i++)
        if (sim_out[i] != 0) n_nonzero++;
    printf("[TB] Non-zero output samples: %d/%d\n", n_nonzero, PATCH_SAMPLES);
    if (n_nonzero == 0) {
        printf("     WARNING: all zeros — likely BUG-2 (BRAM read at stride-2 returns init'd zeros)\n");
    }

    printf("\n[TB] ════════════════════════════════════════════════════\n");
    printf("[TB]  %s\n", exit_code == 0 ? "ALL PASS" : "FAILURES DETECTED — see above");
    printf("[TB] ════════════════════════════════════════════════════\n\n");

    // ── Cleanup ────────────────────────────────────────────────────────────
    dut->final();
    if (vcd_enabled && vcd) {
        vcd->close();
        delete vcd;
    }
    delete dut;
    return exit_code;
}
