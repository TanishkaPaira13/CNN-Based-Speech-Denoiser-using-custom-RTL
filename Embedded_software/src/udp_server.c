// udp_server.c
// lwIP-based UDP server for ZCU102 baremetal denoiser pipeline.
// Reassembles fragmented patch packets from the host PC, signals
// when a full patch is ready, and sends denoised patches back.

#include "udp_server.h"
#include "xil_printf.h"
#include "lwip/pbuf.h"
#include "lwip/err.h"
#include <string.h>


// Forward declaration of internal receive callback
static void udp_recv_cb(void *arg, struct udp_pcb *pcb,
                        struct pbuf *p, const ip_addr_t *addr, u16_t port);

// ── udp_server_init ───────────────────────────────────────────────────────
// Opens a UDP PCB on UDP_PORT and registers the receive callback.
// Returns 0 on success, -1 on failure.
int udp_server_init(udp_state_t *state) {
    memset(state, 0, sizeof(*state));

    state->pcb = udp_new();
    if (!state->pcb) {
        xil_printf("UDP: udp_new() failed\r\n");
        return -1;
    }

    err_t err = udp_bind(state->pcb, IP_ADDR_ANY, UDP_PORT);
    if (err != ERR_OK) {
        xil_printf("UDP: bind to port %d failed (%d)\r\n", UDP_PORT, (int)err);
        udp_remove(state->pcb);
        state->pcb = NULL;
        return -1;
    }

    udp_recv(state->pcb, udp_recv_cb, state);
    xil_printf("UDP: server listening on port %d\r\n", UDP_PORT);
    return 0;
}

// ── udp_recv_cb ───────────────────────────────────────────────────────────
// Called by lwIP for every incoming datagram.
// Reassembles fragments into state->patch_in.
static void udp_recv_cb(void *arg, struct udp_pcb *pcb,
                        struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    udp_state_t *state = (udp_state_t *)arg;
    (void)pcb;

    if (!p) return;

    if (p->tot_len < UDP_HEADER_BYTES) {
        xil_printf("UDP: short packet (%d bytes), discarding\r\n", (int)p->tot_len);
        pbuf_free(p);
        return;
    }

    // Parse header
    udp_hdr_t hdr;
    pbuf_copy_partial(p, &hdr, UDP_HEADER_BYTES, 0);

    uint16_t patch_id = hdr.patch_id;
    uint16_t pkt_id   = hdr.pkt_id;
    uint16_t num_pkts = hdr.num_pkts;
    uint16_t flags    = hdr.flags;

    // Remember host address for replies
    state->host_addr = *addr;
    state->host_port = port;

    // End-of-stream marker from host
    if (flags & FLAG_END_STREAM) {
        xil_printf("UDP: end-of-stream received after patch %d\r\n",
                   (int)state->current_patch_id);
        state->stream_ended = 1;
        pbuf_free(p);
        return;
    }

    // If this is a new patch, reset assembly buffer
    if (patch_id != state->current_patch_id || state->patch_ready) {
        if (state->pkts_received > 0 && !state->patch_ready)
            xil_printf("UDP: patch %d incomplete (%d/%d pkts), starting new\r\n",
                       (int)state->current_patch_id,
                       (int)state->pkts_received, (int)num_pkts);
        state->current_patch_id = patch_id;
        state->pkts_received    = 0;
        state->patch_ready      = 0;
        memset(state->patch_in, 0, sizeof(state->patch_in));
    }

    // Payload starts after header
    uint16_t payload_len = p->tot_len - UDP_HEADER_BYTES;
    uint16_t n_samples   = payload_len / 2;  // int16 samples

    // Offset into patch buffer
    int sample_offset = (int)pkt_id * SAMPLES_PER_PKT;
    if (sample_offset + n_samples > PATCH_SAMPLES) {
        xil_printf("UDP: packet overflows patch buffer (pkt_id=%d, off=%d, n=%d)\r\n",
                   (int)pkt_id, sample_offset, (int)n_samples);
        pbuf_free(p);
        return;
    }

    // Copy payload directly into patch assembly buffer (little-endian int16)
    pbuf_copy_partial(p, &state->patch_in[sample_offset],
                      n_samples * 2, UDP_HEADER_BYTES);

    state->pkts_received++;

    // Patch is complete when last-packet flag set and all fragments received
    if ((flags & FLAG_LAST_PKT) && state->pkts_received == num_pkts) {
        state->patch_ready = 1;
    }

    pbuf_free(p);
}

// ── udp_server_send_patch ─────────────────────────────────────────────────
// Sends the denoised patch back to the host in fragments of SAMPLES_PER_PKT.
void udp_server_send_patch(udp_state_t *state, uint16_t patch_id,
                           const int16_t *data, int n_samples) {
    if (!state->pcb || state->host_port == 0) {
        xil_printf("UDP: no host address to send to\r\n");
        return;
    }

    int total_pkts = (n_samples + SAMPLES_PER_PKT - 1) / SAMPLES_PER_PKT;

    for (int pkt = 0; pkt < total_pkts; pkt++) {
        int offset  = pkt * SAMPLES_PER_PKT;
        int count   = n_samples - offset;
        if (count > SAMPLES_PER_PKT) count = SAMPLES_PER_PKT;

        uint16_t flags = FLAG_OUTPUT;
        if (pkt == total_pkts - 1) flags |= FLAG_LAST_PKT;

        int total_len = UDP_HEADER_BYTES + count * 2;
        struct pbuf *out = pbuf_alloc(PBUF_TRANSPORT, (u16_t)total_len, PBUF_RAM);
        if (!out) {
            xil_printf("UDP: pbuf_alloc failed for output pkt %d\r\n", pkt);
            return;
        }

        // Fill header
        udp_hdr_t hdr;
        hdr.patch_id  = patch_id;
        hdr.pkt_id    = (uint16_t)pkt;
        hdr.num_pkts  = (uint16_t)total_pkts;
        hdr.flags     = flags;

        uint8_t *buf = (uint8_t *)out->payload;
        memcpy(buf, &hdr, UDP_HEADER_BYTES);
        memcpy(buf + UDP_HEADER_BYTES, &data[offset], count * 2);

        err_t err = udp_sendto(state->pcb, out, &state->host_addr, state->host_port);
        if (err != ERR_OK)
            xil_printf("UDP: send pkt %d/%d failed (%d)\r\n", pkt, total_pkts, (int)err);

        pbuf_free(out);
    }
}

// ── udp_server_is_patch_ready ─────────────────────────────────────────────
int udp_server_is_patch_ready(udp_state_t *state) {
    return state->patch_ready;
}

// ── udp_server_clear_patch ────────────────────────────────────────────────
void udp_server_clear_patch(udp_state_t *state) {
    state->patch_ready   = 0;
    state->pkts_received = 0;
}
