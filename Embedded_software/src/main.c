// main.c
// ZCU102 baremetal main for the CNN denoiser pipeline.
//
// Flow:
//   1. Init platform (caches, GIC, timers)
//   2. Init PL CNN accelerator via AXI DMA + AXI4-Lite
//   3. Init lwIP + configure static IP on ZCU102
//   4. Start UDP server on port 5001
//   5. Main loop: poll Ethernet, process patches when one arrives
//
// Host PC sends STFT magnitude patches (257×64 int16 Q3.12) over UDP,
// ZCU102 runs the 4-layer CNN, returns denoised patches over UDP.
//
// Static IP: 192.168.1.10/24, host PC: 192.168.1.100
// Change BOARD_IP / HOST_IP if your network differs.

#include <stdio.h>
#include <string.h>

// Xilinx standalone BSP
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xscugic.h"
#include "sleep.h"

// lwIP
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/ip_addr.h"
#include "lwip/udp.h"
#include "lwip/timeouts.h"
#include "netif/xadapter.h"    // Xilinx lwIP netif adapter

// Project headers
#include "pl_driver.h"
#include "udp_server.h"

// ── Network configuration (edit to match your setup) ─────────────────────
#define BOARD_IP_0  192
#define BOARD_IP_1  168
#define BOARD_IP_2    1
#define BOARD_IP_3   10

#define BOARD_GW_0  192
#define BOARD_GW_1  168
#define BOARD_GW_2    1
#define BOARD_GW_3    1

#define BOARD_MASK_0 255
#define BOARD_MASK_1 255
#define BOARD_MASK_2 255
#define BOARD_MASK_3   0

// MAC address for ZCU102 (change last byte to avoid conflicts)
static unsigned char board_mac[6] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};

// ── GIC instance (needed by Xilinx lwIP adapter) ──────────────────────────
XScuGic gic_inst;

// ── lwIP netif ────────────────────────────────────────────────────────────
static struct netif server_netif;

// ── UDP server state ──────────────────────────────────────────────────────
static udp_state_t udp_state;

// ── GIC init ──────────────────────────────────────────────────────────────
static int gic_init(void) {
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_XSCUGIC_0_BASEADDR);
    if (!cfg) return -1;
    int status = XScuGic_CfgInitialize(&gic_inst, cfg, cfg->CpuBaseAddress);
    if (status != XST_SUCCESS) return -1;
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                  (Xil_ExceptionHandler)XScuGic_InterruptHandler,
                                  &gic_inst);
    Xil_ExceptionEnable();
    return 0;
}

// ── lwIP network bring-up ─────────────────────────────────────────────────
static int net_init(void) {
    ip_addr_t ip, gw, mask;

    IP4_ADDR(&ip,
             BOARD_IP_0, BOARD_IP_1, BOARD_IP_2, BOARD_IP_3);
    IP4_ADDR(&gw,
             BOARD_GW_0, BOARD_GW_1, BOARD_GW_2, BOARD_GW_3);
    IP4_ADDR(&mask,
             BOARD_MASK_0, BOARD_MASK_1, BOARD_MASK_2, BOARD_MASK_3);

    lwip_init();

    // xemacif_input_fn polls the Ethernet MAC; NULL = no callback
    if (!xemac_add(&server_netif, &ip, &mask, &gw,
                   board_mac, XPAR_XEMACPS_0_BASEADDR)) {
        xil_printf("NET: xemac_add() failed\r\n");
        return -1;
    }

    netif_set_default(&server_netif);
    netif_set_up(&server_netif);

    xil_printf("NET: IP  %d.%d.%d.%d\r\n",
               BOARD_IP_0, BOARD_IP_1, BOARD_IP_2, BOARD_IP_3);
    xil_printf("NET: GW  %d.%d.%d.%d\r\n",
               BOARD_GW_0, BOARD_GW_1, BOARD_GW_2, BOARD_GW_3);
    return 0;
}

// ── Main ──────────────────────────────────────────────────────────────────
int main(void) {
    // Enable caches (D-cache needed for DMA coherency management)
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n====================================\r\n");
    xil_printf("  ZCU102 CNN Denoiser — Baremetal\r\n");
    xil_printf("====================================\r\n");

    // GIC#include "pl_driver.h"

    // PL CNN accelerator
    if (pl_init() != XST_SUCCESS) {
        xil_printf("PL init failed, halting\r\n");
        goto halt;
    }

    // lwIP + Ethernet
    if (net_init() != 0) {
        xil_printf("Network init failed, halting\r\n");
        goto halt;
    }

    // UDP server
    if (udp_server_init(&udp_state) != 0) {
        xil_printf("UDP server init failed, halting\r\n");
        goto halt;
    }

    xil_printf("Ready — waiting for patches on UDP port %d\r\n\r\n", UDP_PORT);

    // ── Main polling loop ─────────────────────────────────────────────────
    uint32_t patch_count = 0;

    while (1) {
        // Drive lwIP timers and receive any pending Ethernet frames
        xemacif_input(&server_netif);
        sys_check_timeouts();

        // Check if a complete patch has been assembled by the UDP callback
        if (!udp_server_is_patch_ready(&udp_state))
            continue;

        uint16_t pid = udp_state.current_patch_id;

        // Run patch through CNN
        int ret = pl_run_patch(udp_state.patch_in, udp_state.patch_out);
        if (ret != XST_SUCCESS) {
            xil_printf("PATCH %u: CNN error (%d), sending zeros\r\n",
                       (unsigned)pid, ret);
            memset(udp_state.patch_out, 0, sizeof(udp_state.patch_out));
        } else {
            patch_count++;
            if (patch_count % 10 == 0)
                xil_printf("PATCH %u: processed (total %lu)\r\n",
                           (unsigned)pid, (unsigned long)patch_count);
        }

        // Send result back to host
        udp_server_send_patch(&udp_state, pid,
                              udp_state.patch_out, PATCH_SAMPLES);

        // Clear ready flag so next patch can be assembled
        udp_server_clear_patch(&udp_state);

        // Check end-of-stream
        if (udp_state.stream_ended) {
            xil_printf("\r\nStream complete. Processed %lu patches.\r\n",
                       (unsigned long)patch_count);
            udp_state.stream_ended = 0;
            patch_count = 0;
            xil_printf("Ready for next stream.\r\n\r\n");
        }
    }

halt:
    xil_printf("Halted.\r\n");
    while (1);
    return 0;
}
