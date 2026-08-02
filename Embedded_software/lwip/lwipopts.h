// lwipopts.h
// lwIP configuration for ZCU102 baremetal (no OS, polled Ethernet).
// Adapted for Xilinx lwIP standalone port (xemacif + xemaclite or GEM).

#ifndef LWIPOPTS_H
#define LWIPOPTS_H

// ── Threading / OS ────────────────────────────────────────────────────────
#define NO_SYS                      1   // Bare-metal: no RTOS
#define SYS_LIGHTWEIGHT_PROT        0

#define LWIP_TIMERS                 1

// ── Memory ────────────────────────────────────────────────────────────────
#define MEM_ALIGNMENT               4
#define MEM_SIZE                    (512 * 1024)    // 512 KB heap

// ── pbuf pool ─────────────────────────────────────────────────────────────
// Large pool to buffer incoming patch packets before processing
#define PBUF_POOL_SIZE              64
#define PBUF_POOL_BUFSIZE           1600            // slightly over 1500 MTU

// ── ARP ───────────────────────────────────────────────────────────────────
#define LWIP_ARP                    1
#define ARP_TABLE_SIZE              4
#define ARP_QUEUEING                1

// ── IP ────────────────────────────────────────────────────────────────────
#define IP_FORWARD                  0
#define IP_OPTIONS_ALLOWED          1
#define IP_REASSEMBLY               1
#define IP_FRAG                     1
#define IP_REASS_MAX_PBUFS          8
#define IP_REASS_MAXAGE             3

// ── ICMP ──────────────────────────────────────────────────────────────────
#define LWIP_ICMP                   1

// ── DHCP ──────────────────────────────────────────────────────────────────
// Set to 1 to enable DHCP; set to 0 and configure static IP in main.c
#define LWIP_DHCP                   0

// ── UDP ───────────────────────────────────────────────────────────────────
#define LWIP_UDP                    1
#define UDP_TTL                     64

// ── TCP (not used but required by some lwIP internals) ────────────────────
#define LWIP_TCP                    0

// ── Checksum offload ──────────────────────────────────────────────────────
// Xilinx GEM supports hardware checksum offload; enable if supported
#define CHECKSUM_GEN_IP             1
#define CHECKSUM_GEN_UDP            1
#define CHECKSUM_CHECK_IP           1
#define CHECKSUM_CHECK_UDP          1

// ── Statistics ────────────────────────────────────────────────────────────
#define LWIP_STATS                  0

// ── Debug ─────────────────────────────────────────────────────────────────
#define LWIP_DEBUG                  0
// #define UDP_DEBUG                LWIP_DBG_ON

// ── Misc ──────────────────────────────────────────────────────────────────
#define LWIP_NETIF_HOSTNAME         1
#define LWIP_NETIF_STATUS_CALLBACK  1
#define LWIP_NETIF_LINK_CALLBACK    1

// ── Memp pools ────────────────────────────────────────────────────────────
#define MEMP_NUM_UDP_PCB            4
#define MEMP_NUM_TCP_PCB            0
#define MEMP_NUM_PBUF               32
#define MEMP_NUM_RAW_PCB            0
#define MEMP_NUM_NETBUF             0
#define MEMP_NUM_NETCONN            0

// ── SOF_BROADCAST ─────────────────────────────────────────────────────────
#define IP_SOF_BROADCAST            0

// ── Loopback ──────────────────────────────────────────────────────────────
#define LWIP_HAVE_LOOPIF            0
#define LWIP_NETIF_LOOPBACK         0

// ── Xilinx-specific ───────────────────────────────────────────────────────
// The Xilinx lwIP port defines these; leave them as-is unless you know
// the board's MAC/PHY configuration differs.
#define LWIP_PROVIDE_ERRNO          1

#endif // LWIPOPTS_H
