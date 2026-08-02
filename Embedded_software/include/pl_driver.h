// pl_driver.h
// PL-side CNN accelerator driver for ZCU102 baremetal.
// Controls the denoiser_top.v module via AXI4-Lite registers
// and transfers data through AXI DMA (MM2S / S2MM channels).

#ifndef PL_DRIVER_H
#define PL_DRIVER_H

#include <stdint.h>
#include "xaxidma.h"
#include "xparameters.h"

// ── Base addresses (adjust to match Vivado block design) ──────────────────
// AXI4-Lite control registers for denoiser_top
//#define CNN_CTRL_BASEADDR     XPAR_DENOISER_TOP_0_S_AXIL_BASEADDR
#define CNN_CTRL_BASEADDR  XPAR_DENOISER_TOP_0_BASEADDR
// AXI DMA (MM2S + S2MM)
#define DMA_BASEADDR            XPAR_AXI_DMA_0_BASEADDR

// PS DRAM buffers (must be 4-byte aligned, within 32-bit DDR range for DMA)
#define DMA_INPUT_ADDR          0x10000000UL   // 256 MB : input patch buffer
#define DMA_OUTPUT_ADDR         0x10010000UL   // 256 MB + 64 KB : output buffer

// ── AXI4-Lite register offsets ────────────────────────────────────────────
#define CNN_REG_CTRL            0x00
#define CNN_REG_STAT            0x04
#define CNN_REG_PATCH_H         0x08
#define CNN_REG_PATCH_W         0x0C

// Control bits
#define CNN_CTRL_START          (1 << 0)
#define CNN_CTRL_RESET          (1 << 1)

// Status bits
#define CNN_STAT_BUSY           (1 << 0)
#define CNN_STAT_DONE           (1 << 1)

// ── Patch geometry ────────────────────────────────────────────────────────
#define PATCH_H                 257
#define PATCH_W                 64
#define PATCH_SAMPLES           (PATCH_H * PATCH_W)      // 16448 samples
#define PATCH_BYTES             (PATCH_SAMPLES * 4)       // 4 bytes per sample (32-bit word)

// ── Function prototypes ───────────────────────────────────────────────────
int  pl_init(void);
void pl_reset(void);
int  pl_run_patch(const int16_t *input_q3_12,
                  int16_t       *output_q3_12);

// Low-level helpers
//static inline void cnn_write_reg(uint32_t offset, uint32_t val);
//static inline uint32_t cnn_read_reg(uint32_t offset);

#endif // PL_DRIVER_H
