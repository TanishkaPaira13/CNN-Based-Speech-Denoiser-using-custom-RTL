// pl_driver.c
// PL CNN accelerator driver — ZCU102 baremetal.
// Uses Xilinx AXI DMA standalone driver to move patches between
// PS DRAM and the PL CNN accelerator.

#include "pl_driver.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"
#include <string.h>

// ── AXI DMA instance ──────────────────────────────────────────────────────
static XAxiDma dma_inst;

// ── DMA transfer buffers (physical addresses, uncached or cache-flushed) ──
static uint32_t *input_buf  = (uint32_t *)DMA_INPUT_ADDR;
static uint32_t *output_buf = (uint32_t *)DMA_OUTPUT_ADDR;

// ── Register helpers ──────────────────────────────────────────────────────
static inline void cnn_write_reg(uint32_t offset, uint32_t val) {
    Xil_Out32(CNN_CTRL_BASEADDR + offset, val);
}
static inline uint32_t cnn_read_reg(uint32_t offset) {
    return Xil_In32(CNN_CTRL_BASEADDR + offset);
}

// ── Initialize DMA and CNN IP ─────────────────────────────────────────────
int pl_init(void) {
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_BASEADDR);
    if (!cfg) {
        xil_printf("PL: DMA config lookup failed\r\n");
        return XST_FAILURE;
    }

    int status = XAxiDma_CfgInitialize(&dma_inst, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("PL: DMA init failed (%d)\r\n", status);
        return status;
    }

    // Disable scatter-gather (simple DMA mode)
    if (XAxiDma_HasSg(&dma_inst)) {
        xil_printf("PL: Unexpected SG mode\r\n");
        return XST_FAILURE;
    }

    // Reset the CNN accelerator
    pl_reset();

    uint32_t h = cnn_read_reg(CNN_REG_PATCH_H);
    uint32_t w = cnn_read_reg(CNN_REG_PATCH_W);
    xil_printf("PL: CNN accelerator ready (patch %dx%d)\r\n", (int)h, (int)w);
    return XST_SUCCESS;
}

void pl_reset(void) {
    cnn_write_reg(CNN_REG_CTRL, CNN_CTRL_RESET);
    // Small delay
    for (volatile int i = 0; i < 1000; i++);
    cnn_write_reg(CNN_REG_CTRL, 0);
}

// ── Run one patch through the CNN accelerator ─────────────────────────────
// input_q3_12  : array of PATCH_SAMPLES int16 values (Q3.12 fixed-point)
// output_q3_12 : array of PATCH_SAMPLES int16 values (result)
// Returns 0 on success.
int pl_run_patch(const int16_t *input_q3_12,
                 int16_t       *output_q3_12) {
    int status;

    // Pack int16 → uint32 (lower 16 bits each; upper 16 zeros)
    for (int i = 0; i < PATCH_SAMPLES; i++)
        input_buf[i] = (uint32_t)(uint16_t)input_q3_12[i];

    // Flush input buffer from D-cache before DMA reads it
    Xil_DCacheFlushRange((UINTPTR)input_buf, PATCH_BYTES);

    // Invalidate output buffer so CPU re-reads from DRAM after DMA writes
    Xil_DCacheInvalidateRange((UINTPTR)output_buf, PATCH_BYTES);

    // Start S2MM (receive: PL → PS DRAM) first so it's ready to accept data
    status = XAxiDma_SimpleTransfer(&dma_inst,
                                    (UINTPTR)output_buf,
                                    PATCH_BYTES,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("PL: S2MM start failed (%d)\r\n", status);
        return status;
    }

    // Trigger CNN: write START bit
    cnn_write_reg(CNN_REG_CTRL, CNN_CTRL_START);

    // Start MM2S (send: PS DRAM → PL)
    status = XAxiDma_SimpleTransfer(&dma_inst,
                                    (UINTPTR)input_buf,
                                    PATCH_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("PL: MM2S start failed (%d)\r\n", status);
        return status;
    }

    // Poll until both DMA channels complete
    // (Replace with interrupt for production; polling is fine for demo)
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma_inst, XAXIDMA_DEVICE_TO_DMA));

    // Poll CNN status for DONE
    uint32_t timeout = 10000000UL;
    while (timeout-- && !(cnn_read_reg(CNN_REG_STAT) & CNN_STAT_DONE));
    if (timeout == 0) {
        xil_printf("PL: CNN timeout!\r\n");
        return XST_FAILURE;
    }

    // Unpack uint32 → int16 output
    for (int i = 0; i < PATCH_SAMPLES; i++)
        output_q3_12[i] = (int16_t)(output_buf[i] & 0xFFFF);

    return XST_SUCCESS;
}
