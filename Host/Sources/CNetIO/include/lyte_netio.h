#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Nonblocking IPv4 UDP socket with batched send/receive, per-packet TOS
   (DSCP) control messages, and kernel software TX timestamps. Mechanism
   only: no protocol knowledge, no threads, no loop — the caller owns all
   of that. (CMSG_* are macros and unreachable from Swift; this is the
   OS boundary.) */

typedef struct lyte_netio lyte_netio;

/* Largest batch one send/receive call accepts (bounds the stack arrays). */
#define LYTE_NETIO_MAX_BATCH 64

/* One datagram to send. `tos` is the raw IPv4 TOS byte (DSCP << 2):
   audio 0xC0 (CS6/DSCP 48), video 0xA0 (CS5/DSCP 40). Every packet in a
   batch may carry its own value — that is the point of this leaf. */
typedef struct {
    const uint8_t *data;
    size_t len;
    uint8_t tos;
} lyte_netio_pkt;

/* One receive slot. Caller supplies `data`/`cap`; the receive call fills
   `len`, `tos` (the TOS byte the datagram arrived with, IP_RECVTOS), and
   the datagram's source address (HS-7: the session learns the client's
   4-tuple from message 1's arrival, and HS-12's demux trigger attributes
   every datagram to its source tuple — recvmmsg reports msg_name even on
   a connected socket). */
typedef struct {
    uint8_t *data;
    size_t cap;
    size_t len;
    uint8_t tos;
    char src_ip[16];   /* dotted quad, NUL-terminated */
    uint16_t src_port; /* host order */
} lyte_netio_slot;

/* One TX timestamp drained from the socket error queue. `pkt_id` counts
   datagrams sent since timestamps were armed (SOF_TIMESTAMPING_OPT_ID;
   the first sent datagram is id 0); `ts_ns` is the kernel software send
   timestamp, CLOCK_REALTIME nanoseconds. */
typedef struct {
    uint32_t pkt_id;
    uint64_t ts_ns;
} lyte_netio_txstamp;

/* Opens a nonblocking IPv4 UDP socket bound to `bind_ip`:`bind_port`
   (port 0 = kernel-assigned) with IP_RECVTOS armed so received TOS is
   visible. Returns NULL with `err` filled on failure. */
lyte_netio *lyte_netio_new(const char *bind_ip, uint16_t bind_port,
                           char *err, size_t errlen);

/* The locally bound port, host order — the answer after binding port 0. */
uint16_t lyte_netio_local_port(const lyte_netio *n);

/* connect()s the socket to `ip`:`port`. Required before sending; receiving
   works without it. Returns 0 on success, -1 with `err` filled. */
int lyte_netio_set_peer(lyte_netio *n, const char *ip, uint16_t port,
                        char *err, size_t errlen);

/* Arms SO_TIMESTAMPING software TX timestamps (TX_SOFTWARE + OPT_ID +
   OPT_TSONLY): the kernel stamps each datagram as it leaves for the
   device and queues (pkt_id, timestamp) on the error queue, drained with
   lyte_netio_poll_txstamps. Returns 0 on success, -1 with `err` filled. */
int lyte_netio_enable_tx_timestamps(lyte_netio *n, char *err, size_t errlen);

/* Sends up to `count` (≤ LYTE_NETIO_MAX_BATCH) datagrams in one sendmmsg
   call, each carrying its own IP_TOS control message. Returns the number
   actually sent — 0 if the socket would block, possibly short on a partial
   send (caller retries the tail) — or -1 with `err` filled. If
   `first_pkt_id` is non-NULL and TX timestamps are armed, it receives the
   pkt_id of the first datagram of this batch. */
int lyte_netio_send_batch(lyte_netio *n, const lyte_netio_pkt *pkts, int count,
                          uint32_t *first_pkt_id, char *err, size_t errlen);

/* Receives up to `count` (≤ LYTE_NETIO_MAX_BATCH) datagrams in one
   recvmmsg call. Returns the number received (0 if the socket would
   block), -1 with `err` filled. */
int lyte_netio_recv_batch(lyte_netio *n, lyte_netio_slot *slots, int count,
                          char *err, size_t errlen);

/* Drains pending TX timestamps from the error queue into `out`, up to
   `max`. Returns the number drained (0 if none are pending yet — the
   kernel delivers them asynchronously after send), -1 with `err` filled. */
int lyte_netio_poll_txstamps(lyte_netio *n, lyte_netio_txstamp *out, int max,
                             char *err, size_t errlen);

void lyte_netio_free(lyte_netio *n);

#ifdef __cplusplus
}
#endif
