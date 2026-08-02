// udp_server.h
// UDP server for ZCU102 baremetal — receives patch data from host PC,
// forwards to PL CNN accelerator, returns denoised patch via UDP.
//
// Protocol (host → ZCU102, port 5001):
//   Header (8 bytes):
//     [0..1] patch_id   : uint16  (patch sequence number, 0-based)
//     [2..3] pkt_id     : uint16  (fragment id within this patch, 0-based)
//     [4..5] num_pkts   : uint16  (total fragments per patch)
//     [6..7] flags      : uint16  (bit 0 = last fragment, bit 1 = flush/end)
//   Payload (up to 1024 bytes = 512 int16 samples)
//
// Protocol (ZCU102 → host, same port, same header format):
//   flags bit 1 = 0 for output patches

#ifndef UDP_SERVER_H
#define UDP_SERVER_H

#include "lwip/udp.h"
#include "lwip/ip_addr.h"
#include <stdint.h>
#include "pl_driver.h"

// ── Configuration ─────────────────────────────────────────────────────────
#define UDP_PORT                5001
#define UDP_PAYLOAD_SAMPLES     512         // int16 samples per UDP packet
#define UDP_PAYLOAD_BYTES       (UDP_PAYLOAD_SAMPLES * 2)
#define UDP_HEADER_BYTES        8

//#define PATCH_SAMPLES           (257 * 64)  // 16448
#define SAMPLES_PER_PKT         UDP_PAYLOAD_SAMPLES
#define PKTS_PER_PATCH          ((PATCH_SAMPLES + SAMPLES_PER_PKT - 1) / SAMPLES_PER_PKT)  // 33

// ── Packet header ─────────────────────────────────────────────────────────
typedef struct __attribute__((packed)) {
    uint16_t patch_id;
    uint16_t pkt_id;
    uint16_t num_pkts;
    uint16_t flags;
} udp_hdr_t;

#define FLAG_LAST_PKT   (1 << 0)
#define FLAG_END_STREAM (1 << 1)
#define FLAG_OUTPUT     (1 << 2)

// ── State ─────────────────────────────────────────────────────────────────
typedef struct {
    int16_t  patch_in[PATCH_SAMPLES];   // assembled input patch
    int16_t  patch_out[PATCH_SAMPLES];  // CNN output patch
    uint16_t current_patch_id;
    uint16_t pkts_received;
    int      patch_ready;               // flag: full patch received
    int      stream_ended;              // FLAG_END_STREAM received
    struct   udp_pcb *pcb;
    ip_addr_t host_addr;
    u16_t    host_port;
} udp_state_t;

// ── Function prototypes ───────────────────────────────────────────────────
int  udp_server_init(udp_state_t *state);
void udp_server_send_patch(udp_state_t *state, uint16_t patch_id,
                           const int16_t *data, int n_samples);
int  udp_server_is_patch_ready(udp_state_t *state);
void udp_server_clear_patch(udp_state_t *state);

#endif // UDP_SERVER_H
