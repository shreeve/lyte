/* sendmmsg/recvmmsg and struct mmsghdr are GNU extensions. */
#define _GNU_SOURCE

#include "lyte_netio.h"

#include <arpa/inet.h>
#include <errno.h>
#include <linux/errqueue.h>
#include <linux/net_tstamp.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct lyte_netio {
    int fd;
    uint16_t local_port;
    int tx_timestamps_armed;
    /* Datagrams sent since timestamps were armed; mirrors the kernel's
       SOF_TIMESTAMPING_OPT_ID counter so pkt_ids can be handed out at
       send time without waiting for the error queue. */
    uint32_t sent_since_arm;
};

static void set_err(char *err, size_t errlen, const char *fmt, ...)
{
    if (!err || errlen == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static void sys_err(char *err, size_t errlen, const char *what)
{
    set_err(err, errlen, "%s: %s", what, strerror(errno));
}

static int parse_addr(const char *ip, uint16_t port, struct sockaddr_in *sa,
                      char *err, size_t errlen)
{
    memset(sa, 0, sizeof(*sa));
    sa->sin_family = AF_INET;
    sa->sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &sa->sin_addr) != 1) {
        set_err(err, errlen, "invalid IPv4 address \"%s\"", ip);
        return -1;
    }
    return 0;
}

lyte_netio *lyte_netio_new(const char *bind_ip, uint16_t bind_port,
                           char *err, size_t errlen)
{
    struct sockaddr_in sa;
    if (parse_addr(bind_ip, bind_port, &sa, err, errlen) != 0)
        return NULL;

    struct lyte_netio *n = calloc(1, sizeof(*n));
    if (!n) {
        set_err(err, errlen, "out of memory");
        return NULL;
    }

    n->fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (n->fd < 0) {
        sys_err(err, errlen, "socket(AF_INET, SOCK_DGRAM) failed");
        goto fail;
    }

    /* Received TOS arrives as an IP_TOS control message on each datagram. */
    int one = 1;
    if (setsockopt(n->fd, IPPROTO_IP, IP_RECVTOS, &one, sizeof(one)) < 0) {
        sys_err(err, errlen, "setsockopt(IP_RECVTOS) failed");
        goto fail;
    }

    if (bind(n->fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        sys_err(err, errlen, "bind failed");
        goto fail;
    }

    struct sockaddr_in bound;
    socklen_t blen = sizeof(bound);
    if (getsockname(n->fd, (struct sockaddr *)&bound, &blen) < 0) {
        sys_err(err, errlen, "getsockname failed");
        goto fail;
    }
    n->local_port = ntohs(bound.sin_port);

    return n;

fail:
    lyte_netio_free(n);
    return NULL;
}

uint16_t lyte_netio_local_port(const lyte_netio *n)
{
    return n->local_port;
}

int lyte_netio_set_peer(lyte_netio *n, const char *ip, uint16_t port,
                        char *err, size_t errlen)
{
    struct sockaddr_in sa;
    if (parse_addr(ip, port, &sa, err, errlen) != 0)
        return -1;
    if (connect(n->fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        sys_err(err, errlen, "connect failed");
        return -1;
    }
    return 0;
}

int lyte_netio_enable_tx_timestamps(lyte_netio *n, char *err, size_t errlen)
{
    /* TX_SOFTWARE: stamp on handoff to the device; SOFTWARE: report those
       stamps; OPT_ID: tag each report with a per-datagram counter;
       OPT_TSONLY: error-queue reports carry cmsgs only, no payload copy. */
    unsigned int flags = SOF_TIMESTAMPING_TX_SOFTWARE
                       | SOF_TIMESTAMPING_SOFTWARE
                       | SOF_TIMESTAMPING_OPT_ID
                       | SOF_TIMESTAMPING_OPT_TSONLY;
    if (setsockopt(n->fd, SOL_SOCKET, SO_TIMESTAMPING, &flags,
                   sizeof(flags)) < 0) {
        sys_err(err, errlen, "setsockopt(SO_TIMESTAMPING) failed");
        return -1;
    }
    n->tx_timestamps_armed = 1;
    n->sent_since_arm = 0;
    return 0;
}

int lyte_netio_send_batch(lyte_netio *n, const lyte_netio_pkt *pkts, int count,
                          uint32_t *first_pkt_id, char *err, size_t errlen)
{
    if (count < 0 || count > LYTE_NETIO_MAX_BATCH) {
        set_err(err, errlen, "send batch of %d exceeds max %d", count,
                LYTE_NETIO_MAX_BATCH);
        return -1;
    }

    struct mmsghdr msgs[LYTE_NETIO_MAX_BATCH];
    struct iovec iovs[LYTE_NETIO_MAX_BATCH];
    /* One IP_TOS control message per datagram — per-packet DSCP is the
       reason this leaf exists. The kernel takes the value as an int. */
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } ctrl[LYTE_NETIO_MAX_BATCH];

    memset(msgs, 0, sizeof(msgs[0]) * (size_t)count);
    for (int i = 0; i < count; i++) {
        iovs[i].iov_base = (void *)pkts[i].data;
        iovs[i].iov_len = pkts[i].len;
        msgs[i].msg_hdr.msg_iov = &iovs[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
        msgs[i].msg_hdr.msg_control = ctrl[i].buf;
        msgs[i].msg_hdr.msg_controllen = sizeof(ctrl[i].buf);

        struct cmsghdr *cm = CMSG_FIRSTHDR(&msgs[i].msg_hdr);
        cm->cmsg_level = IPPROTO_IP;
        cm->cmsg_type = IP_TOS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        int tos = pkts[i].tos;
        memcpy(CMSG_DATA(cm), &tos, sizeof(tos));
    }

    int sent = sendmmsg(n->fd, msgs, (unsigned int)count, 0);
    if (sent < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        sys_err(err, errlen, "sendmmsg failed");
        return -1;
    }
    if (first_pkt_id)
        *first_pkt_id = n->sent_since_arm;
    if (n->tx_timestamps_armed)
        n->sent_since_arm += (uint32_t)sent;
    return sent;
}

int lyte_netio_recv_batch(lyte_netio *n, lyte_netio_slot *slots, int count,
                          char *err, size_t errlen)
{
    if (count < 0 || count > LYTE_NETIO_MAX_BATCH) {
        set_err(err, errlen, "recv batch of %d exceeds max %d", count,
                LYTE_NETIO_MAX_BATCH);
        return -1;
    }

    struct mmsghdr msgs[LYTE_NETIO_MAX_BATCH];
    struct iovec iovs[LYTE_NETIO_MAX_BATCH];
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } ctrl[LYTE_NETIO_MAX_BATCH];

    memset(msgs, 0, sizeof(msgs[0]) * (size_t)count);
    for (int i = 0; i < count; i++) {
        iovs[i].iov_base = slots[i].data;
        iovs[i].iov_len = slots[i].cap;
        msgs[i].msg_hdr.msg_iov = &iovs[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
        msgs[i].msg_hdr.msg_control = ctrl[i].buf;
        msgs[i].msg_hdr.msg_controllen = sizeof(ctrl[i].buf);
    }

    int got = recvmmsg(n->fd, msgs, (unsigned int)count, 0, NULL);
    if (got < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        sys_err(err, errlen, "recvmmsg failed");
        return -1;
    }

    for (int i = 0; i < got; i++) {
        slots[i].len = msgs[i].msg_len;
        slots[i].tos = 0;
        for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msgs[i].msg_hdr); cm;
             cm = CMSG_NXTHDR(&msgs[i].msg_hdr, cm)) {
            /* Delivered as IP_TOS (one byte) — glibc also names it
               IP_RECVTOS on the setsockopt side; the cmsg type is IP_TOS. */
            if (cm->cmsg_level == IPPROTO_IP && cm->cmsg_type == IP_TOS)
                slots[i].tos = *(uint8_t *)CMSG_DATA(cm);
        }
    }
    return got;
}

int lyte_netio_poll_txstamps(lyte_netio *n, lyte_netio_txstamp *out, int max,
                             char *err, size_t errlen)
{
    int drained = 0;
    while (drained < max) {
        char ctrl[512];
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_control = ctrl;
        msg.msg_controllen = sizeof(ctrl);

        ssize_t rc = recvmsg(n->fd, &msg, MSG_ERRQUEUE);
        if (rc < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            sys_err(err, errlen, "recvmsg(MSG_ERRQUEUE) failed");
            return -1;
        }

        /* One error-queue message carries two cmsgs: SCM_TIMESTAMPING
           (ts[0] = software stamp) and the extended error whose ee_data
           is the OPT_ID packet counter. */
        struct scm_timestamping *tss = NULL;
        struct sock_extended_err *ee = NULL;
        for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm;
             cm = CMSG_NXTHDR(&msg, cm)) {
            if (cm->cmsg_level == SOL_SOCKET
                && cm->cmsg_type == SCM_TIMESTAMPING)
                tss = (struct scm_timestamping *)CMSG_DATA(cm);
            else if (cm->cmsg_level == IPPROTO_IP && cm->cmsg_type == IP_RECVERR)
                ee = (struct sock_extended_err *)CMSG_DATA(cm);
        }
        if (!tss || !ee || ee->ee_origin != SO_EE_ORIGIN_TIMESTAMPING)
            continue; /* unrelated error-queue traffic; not ours to report */

        out[drained].pkt_id = ee->ee_data;
        out[drained].ts_ns = (uint64_t)tss->ts[0].tv_sec * 1000000000ull
                           + (uint64_t)tss->ts[0].tv_nsec;
        drained++;
    }
    return drained;
}

void lyte_netio_free(lyte_netio *n)
{
    if (!n)
        return;
    if (n->fd >= 0)
        close(n->fd);
    free(n);
}
