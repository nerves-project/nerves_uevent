// SPDX-FileCopyrightText: 2022 Frank Hunleth
//
// SPDX-License-Identifier: Apache-2.0

// Needed for pipe2() on glibc. musl exposes it unconditionally.
#define _GNU_SOURCE

#include "utils.h"
#include <ctype.h>
#include <dirent.h>
#include <endian.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libmnl/libmnl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/limits.h>

#include <ei.h>

static int run_modprobe = 0;
static uint32_t modprobe_queue_n;
static uint32_t modprobe_queue_index;
// Sized for the boot-time uevent flood. This is far larger than what's
// currently been observed. Dropped modprobes are not recoverable.
static char modprobe_queue_buffer[65536];
static char *modprobe_queue_argv[1024];

// PID of the in-flight modprobe child, or 0 when none. Concurrency is capped
// at 1: the kernel serializes loads via module_mutex anyway, and allowing
// unbounded fan-out would let a uevent storm spawn arbitrarily many modprobes.
static pid_t modprobe_pid = 0;

// Self-pipe so SIGCHLD just wakes the poll loop; reaping and queue-flushing
// happen in the main loop where async-signal-safety doesn't constrain us.
static int sigchld_pipe[2] = {-1, -1};

// Cumulative counters reported to Elixir
struct stats {
    uint32_t uevents_received;
    // Kernel buffer-overflow incidents (ENOBUFS). This indicates lost events
    // and is a serious error since it's unrecoverable without restarting.
    uint32_t uevents_dropped;

    uint32_t modprobes_called;
    uint32_t modaliases_queued;
    uint32_t modaliases_dropped;
    uint32_t modprobe_fork_failures;

    // High-water marks for the modprobe queue for tuning
    uint32_t peak_queue_n;
    uint32_t peak_queue_bytes;

    // Per-action tallies
    uint32_t action_add;
    uint32_t action_change;
    uint32_t action_remove;
    uint32_t action_move;
    uint32_t action_bind;
    uint32_t action_unbind;
    uint32_t action_other;
};

static struct stats stats;
static int stats_dirty = 0;

static void reset_modprobe_queue()
{
    modprobe_queue_argv[0] = "/sbin/modprobe";
    modprobe_queue_argv[1] = "-a";
    modprobe_queue_n = 2;
    modprobe_queue_index = 0;
}

static void run_modprobes()
{
    if (modprobe_queue_index == 0)
        return;

    // One modprobe in flight at a time. If one's still running, leave the
    // queue accumulating — the next call (from another uevent batch or from
    // the SIGCHLD wakeup path) will flush it.
    if (modprobe_pid != 0)
        return;

    pid_t pid = fork();
    if (pid == 0) {
        // child
        int fd = open("/dev/null", O_RDWR);
        if (fd >= 0) {
            close(STDIN_FILENO);
            close(STDOUT_FILENO);
            close(STDERR_FILENO);
            dup2(fd, STDIN_FILENO);
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
        }
        modprobe_queue_argv[modprobe_queue_n] = 0;
        execvp(modprobe_queue_argv[0], modprobe_queue_argv);

        // Not supposed to reach here.
        exit(EXIT_FAILURE);
    } else if (pid > 0) {
        // parent
        modprobe_pid = pid;
        stats.modprobes_called++;
    } else {
        // fork() failures drop the batch but let uevents keep flowing.
        stats.modprobe_fork_failures++;
    }

    stats_dirty = 1;
    reset_modprobe_queue();
}

static void queue_modprobe(char *modalias)
{
    // Optimization: Skip consecutive duplicate modalias strings since some
    // devices have several adjacent entries serviced by the same alias.
    if (modprobe_queue_n > 2 &&
        strcmp(modprobe_queue_argv[modprobe_queue_n - 1], modalias) == 0)
        return;

    // Leave one argv slot for the trailing NULL that execvp needs.
    const int argv_max = (int)(sizeof(modprobe_queue_argv) / sizeof(modprobe_queue_argv[0])) - 1;

    size_t modalias_len = strlen(modalias) + 1;
    if (modprobe_queue_index + modalias_len > sizeof(modprobe_queue_buffer) ||
        modprobe_queue_n >= argv_max) {
        run_modprobes();
        // If a modprobe is already in flight, the flush was a no-op and we're
        // still full. Drop this alias rather than overflow — the same
        // modalias normally recurs on the next matching uevent.
        if (modprobe_queue_index + modalias_len > sizeof(modprobe_queue_buffer) ||
            modprobe_queue_n >= argv_max) {
            stats.modaliases_dropped++;
            stats_dirty = 1;
            return;
        }
    }

    char *p = &modprobe_queue_buffer[modprobe_queue_index];

    modprobe_queue_argv[modprobe_queue_n] = p;
    strcpy(p, modalias);
    modprobe_queue_index += modalias_len;
    modprobe_queue_n++;
    stats.modaliases_queued++;
    if (modprobe_queue_n > stats.peak_queue_n)
        stats.peak_queue_n = modprobe_queue_n;
    if (modprobe_queue_index > stats.peak_queue_bytes)
        stats.peak_queue_bytes = modprobe_queue_index;
    stats_dirty = 1;
}

static void erlcmd_write_header_len(char *response, size_t len)
{
    uint16_t be_len = htons(len - sizeof(uint16_t));
    memcpy(response, &be_len, sizeof(be_len));
}

static void write_all(char *response, size_t len)
{
    size_t wrote = 0;
    do {
        ssize_t amount_written = write(STDOUT_FILENO, response + wrote, len - wrote);
        if (amount_written < 0) {
            if (errno == EINTR)
                continue;

            err(EXIT_FAILURE, "write");
        }

        wrote += amount_written;
    } while (wrote < len);
}

static struct mnl_socket *uevent_open()
{
    struct mnl_socket *nl_uevent = mnl_socket_open2(NETLINK_KOBJECT_UEVENT, O_NONBLOCK | O_CLOEXEC);
    if (!nl_uevent)
        err(EXIT_FAILURE, "mnl_socket_open (NETLINK_KOBJECT_UEVENT)");

    // There is one single group in kobject over netlink
    if (mnl_socket_bind(nl_uevent, (1 << 0), MNL_SOCKET_AUTOPID) < 0)
        err(EXIT_FAILURE, "mnl_socket_bind");

    int nl_fd = mnl_socket_get_fd(nl_uevent);

    // Increase receive buffer to avoid dropping uevent messages. There's no
    // way to get back those dropped messages. The initial device scan can
    // overwhelm the default limits.
    unsigned int bufsize = 1024 * 1024;
    (void) setsockopt(nl_fd, SOL_SOCKET, SO_RCVBUFFORCE, &bufsize, sizeof(bufsize));
    (void) setsockopt(nl_fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));

    return nl_uevent;
}

static void str_tolower(char *str)
{
    for (; *str; str++)
        *str = tolower(*str);
}

static int ei_encode_elixir_string(char *buf, int *index, const char *p)
{
    size_t len = strlen(p);
    return ei_encode_binary(buf, index, p, len);
}

static int ei_encode_devpath(char * buf, int *index, char *devpath, char **end_devpath)
{
    // The devpath is of the form "/devices/something/something_else/etc"
    //
    // Encode it as: ["devices", "something", "something_else", "etc"]

    // Skip the root slash
    devpath++;

#define MAX_SEGMENTS 32
    char *segments[MAX_SEGMENTS];
    segments[0] = devpath;

    int segment_ix = 1;
    char *p = devpath;
    while (*p != '\0') {
        if (*p == '/') {
            *p = '\0';
            p++;
            segments[segment_ix] = p;
            segment_ix++;
            if (segment_ix >= MAX_SEGMENTS) {
                while (*p != '\0') p++;
                break;
            }
        } else {
            p++;
        }
    }

    *end_devpath = p + 1;

    ei_encode_list_header(buf, index, segment_ix);

    for (int ix = 0; ix < segment_ix; ix++)
        ei_encode_elixir_string(buf, index, segments[ix]);

    return ei_encode_empty_list(buf, index);
}

// libudev's on-the-wire framing for events broadcast on
// NETLINK_KOBJECT_UEVENT group 2. Magic and the hash/bloom fields are stored
// in network byte order so the in-kernel BPF filter that libudev clients
// install reads them portably; the size/offset fields are host order. Format
// matches systemd's `monitor_netlink_header` in
// src/libsystemd/sd-device/device-monitor.c.
struct udev_monitor_netlink_header {
    char     prefix[8];               // "libudev\0"
    unsigned magic;                   // be32(0xfeedcafe)
    unsigned header_size;             // sizeof(struct ...)
    unsigned properties_off;          // = header_size
    unsigned properties_len;          // length of KEY=val\0 blob
    unsigned filter_subsystem_hash;   // be32(murmur2(SUBSYSTEM))
    unsigned filter_devtype_hash;     // be32(murmur2(DEVTYPE)) or 0
    unsigned filter_tag_bloom_hi;     // 0 — no TAGS=
    unsigned filter_tag_bloom_lo;
};

#define UDEV_MONITOR_MAGIC 0xfeedcafe
#define UDEV_MONITOR_UDEV  2 // nl_groups bit for userspace-to-userspace events

// MurmurHash2, seed=0. Matches systemd's string_hash32() so the BPF filter
// libudev clients install (which compares be32 hashes of subscribed
// subsystem/devtype against these header fields) accepts our messages.
static unsigned murmur_hash2(const char *key, size_t len)
{
    const uint32_t m = 0x5bd1e995;
    const int r = 24;
    uint32_t h = (uint32_t)len; // seed=0
    const unsigned char *data = (const unsigned char *)key;

    while (len >= 4) {
        uint32_t k;
        memcpy(&k, data, 4);
        k *= m;
        k ^= k >> r;
        k *= m;
        h *= m;
        h ^= k;
        data += 4;
        len -= 4;
    }
    switch (len) {
    case 3: h ^= (uint32_t)data[2] << 16; /* fallthrough */
    case 2: h ^= (uint32_t)data[1] << 8;  /* fallthrough */
    case 1: h ^= (uint32_t)data[0];
            h *= m;
    }
    h ^= h >> 13;
    h *= m;
    h ^= h >> 15;
    return h;
}

// Linear scan over a KEY=val\0KEY=val\0... blob. Returns a pointer to the
// value (still inside body) or NULL.
static const char *find_property(const char *body, size_t body_len, const char *key)
{
    size_t klen = strlen(key);
    const char *p = body;
    const char *end = body + body_len;

    while (p < end) {
        size_t plen = strnlen(p, end - p);
        if (plen > klen && p[klen] == '=' && memcmp(p, key, klen) == 0)
            return p + klen + 1;
        p += plen + 1;
    }
    return NULL;
}

static void broadcast_udev_event(struct mnl_socket *nl, const char *body, size_t body_len)
{
    struct udev_monitor_netlink_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    memcpy(hdr.prefix, "libudev", 8);
    hdr.magic = htobe32(UDEV_MONITOR_MAGIC);
    hdr.header_size = sizeof(hdr);
    hdr.properties_off = sizeof(hdr);
    hdr.properties_len = body_len;

    const char *subsystem = find_property(body, body_len, "SUBSYSTEM");
    if (subsystem)
        hdr.filter_subsystem_hash = htobe32(murmur_hash2(subsystem, strlen(subsystem)));

    const char *devtype = find_property(body, body_len, "DEVTYPE");
    if (devtype)
        hdr.filter_devtype_hash = htobe32(murmur_hash2(devtype, strlen(devtype)));

    struct sockaddr_nl dst;
    memset(&dst, 0, sizeof(dst));
    dst.nl_family = AF_NETLINK;
    dst.nl_pid = 0;
    dst.nl_groups = UDEV_MONITOR_UDEV;

    struct iovec iov[2];
    iov[0].iov_base = &hdr;
    iov[0].iov_len = sizeof(hdr);
    iov[1].iov_base = (void *)body;
    iov[1].iov_len = body_len;

    struct msghdr m;
    memset(&m, 0, sizeof(m));
    m.msg_name = &dst;
    m.msg_namelen = sizeof(dst);
    m.msg_iov = iov;
    m.msg_iovlen = 2;

    int fd = mnl_socket_get_fd(nl);
    ssize_t n = sendmsg(fd, &m, 0);
    if (n < 0)
        debug("sendmsg(udev broadcast) failed: %s", strerror(errno));
}

// Read exactly `n` bytes from `fd` into `buf`. Returns 0 on success, -1 on
// EOF or unrecoverable error.
static int read_exact(int fd, void *buf, size_t n)
{
    char *p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r == 0)
            return -1;
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

// Erlang Port {:packet, 2} frames each command with a 2-byte big-endian
// length prefix. Returns 0 on success / unknown command, -1 on EOF or fatal
// error (caller should exit).
static int handle_erlang_command(int fd, struct mnl_socket *nl)
{
    uint16_t be_len;
    if (read_exact(fd, &be_len, sizeof(be_len)) < 0)
        return -1;
    size_t len = ntohs(be_len);

    char buf[8192];
    if (len > sizeof(buf))
        return -1;

    if (read_exact(fd, buf, len) < 0)
        return -1;

    int idx = 0;
    int version = 0;
    if (ei_decode_version(buf, &idx, &version) < 0)
        return 0;

    int arity = 0;
    if (ei_decode_tuple_header(buf, &idx, &arity) < 0 || arity != 2)
        return 0;

    char atom[MAXATOMLEN];
    if (ei_decode_atom(buf, &idx, atom) < 0)
        return 0;

    if (strcmp(atom, "broadcast") == 0) {
        int type = 0, size = 0;
        if (ei_get_type(buf, &idx, &type, &size) < 0)
            return 0;
        if (type != ERL_BINARY_EXT || (size_t)size > sizeof(buf))
            return 0;

        // The decoded body is bounded by the framed message size, which is
        // already capped at sizeof(buf) above. Stack-allocate to avoid a
        // malloc/free per broadcast.
        char body[sizeof(buf)];
        long got = 0;
        if (ei_decode_binary(buf, &idx, body, &got) == 0 && got > 0)
            broadcast_udev_event(nl, body, (size_t)got);
    }

    return 0;
}

static int nl_uevent_process_one(struct mnl_socket *nl_uevent, char *resp)
{
    char nlbuf[8192]; // See MNL_SOCKET_BUFFER_SIZE
    int bytecount = mnl_socket_recvfrom(nl_uevent, nlbuf, sizeof(nlbuf));
    if (bytecount <= 0) {
        if (errno == EAGAIN || errno == EINTR)
            return -1;
        if (errno == ENOBUFS) {
            // This doesn't getting printed in a helpful location and
            // handling it other ways doesn't make things better. It is
            // useful when debugging if messages are suspected to have
            // been dropped.
            // warnx("mnl_socket_recvfrom: netlink messages dropped");
            stats.uevents_dropped++;
            stats_dirty = 1;
            return -1;
        }
        err(EXIT_FAILURE, "mnl_socket_recvfrom");
    }

    stats.uevents_received++;
    stats_dirty = 1;

    char *str = nlbuf;
    char *str_end = str + bytecount;

    debug("uevent: %s", str);
    int resp_index = sizeof(uint16_t); // Skip over payload size
    ei_encode_version(resp, &resp_index);

    // The uevent comes in with the form:
    //
    // "action@devpath\0ACTION=action\0DEVPATH=devpath\0KEY=value\0"
    //
    // Construct the tuple for Elixir:
    //   {action, devpath, kv_map}
    //
    // The kv_map contains all of the kv pairs in the uevent except
    // ACTION, DEVPATH, SEQNUM, SYNTH_UUID.

    ei_encode_tuple_header(resp, &resp_index, 3);

    char *atsign = strchr(str, '@');
    if (!atsign)
        return 0;
    *atsign = '\0';

    // action
    const char *action = str;
    ei_encode_atom(resp, &resp_index, str);

    if (strcmp(action, "add") == 0) stats.action_add++;
    else if (strcmp(action, "change") == 0) stats.action_change++;
    else if (strcmp(action, "remove") == 0) stats.action_remove++;
    else if (strcmp(action, "move") == 0) stats.action_move++;
    else if (strcmp(action, "bind") == 0) stats.action_bind++;
    else if (strcmp(action, "unbind") == 0) stats.action_unbind++;
    else stats.action_other++;

    // devpath - filter anything that's not under "/devices"
    str = atsign + 1;
    if (strncmp("/devices", str, 8) != 0)
        return 0;
    ei_encode_devpath(resp, &resp_index, str, &str);

#define MAX_KV_PAIRS 16
    int kvpairs_count = 0;
    char *keys[MAX_KV_PAIRS];
    char *values[MAX_KV_PAIRS];

    for (; str < str_end; str += strlen(str) + 1) {
        // Don't encode these keys in the map:
        //
        // ACTION: already delivered
        // DEVPATH: already delivered
        // SEQNUM: unused in Elixir
        // SYNTH_UUID: unused in Elixir (when Elixir triggers synthetic events, it currently doesn't set a UUID)
        if (strncmp("ACTION=", str, 7) == 0 ||
                strncmp("DEVPATH=", str, 8) == 0 ||
                strncmp("SEQNUM=", str, 7) == 0 ||
                strncmp("SYNTH_UUID=", str, 11) == 0)
            continue;

        char *equalsign = strchr(str, '=');
        if (!equalsign)
            continue;
        *equalsign = '\0';

        // We like lowercase keys
        str_tolower(str);
        keys[kvpairs_count] = str;

        // The kernel wraps some values in literal double quotes — notably
        // NAME, PHYS, and UNIQ on input devices (see drivers/input/input.c).
        // Strip them so downstream rule matching compares against the
        // natural string.
        char *value = equalsign + 1;
        size_t value_len = strlen(value);
        if (value_len >= 2 && value[0] == '"' && value[value_len - 1] == '"') {
            value[value_len - 1] = '\0';
            value++;
        }
        values[kvpairs_count] = value;

        // Optionally run modprobe on newly added devices that have a modalias
        if (run_modprobe && strcmp(str, "modalias") == 0 && strcmp(action, "add") == 0) {
            queue_modprobe(value);
        }

        kvpairs_count++;
    }

    ei_encode_map_header(resp, &resp_index, kvpairs_count);
    for (int i = 0; i < kvpairs_count; i++) {
        ei_encode_elixir_string(resp, &resp_index, keys[i]);
        ei_encode_elixir_string(resp, &resp_index, values[i]);
    }
    erlcmd_write_header_len(resp, resp_index);
    return resp_index;
}

static void send_stats()
{
    // 1 KB easily covers the encoded map — 8 scalars plus a nested 7-entry
    // action submap, each value a u32 and each key a short atom.
    char resp[1024];
    int resp_index = sizeof(uint16_t); // skip over the 2-byte length prefix
    ei_encode_version(resp, &resp_index);
    ei_encode_tuple_header(resp, &resp_index, 2);
    ei_encode_atom(resp, &resp_index, "stats");
    ei_encode_map_header(resp, &resp_index, 9);

    ei_encode_atom(resp, &resp_index, "uevents_received");
    ei_encode_ulong(resp, &resp_index, stats.uevents_received);
    ei_encode_atom(resp, &resp_index, "uevents_dropped");
    ei_encode_ulong(resp, &resp_index, stats.uevents_dropped);
    ei_encode_atom(resp, &resp_index, "modprobes_called");
    ei_encode_ulong(resp, &resp_index, stats.modprobes_called);
    ei_encode_atom(resp, &resp_index, "modaliases_queued");
    ei_encode_ulong(resp, &resp_index, stats.modaliases_queued);
    ei_encode_atom(resp, &resp_index, "modaliases_dropped");
    ei_encode_ulong(resp, &resp_index, stats.modaliases_dropped);
    ei_encode_atom(resp, &resp_index, "modprobe_fork_failures");
    ei_encode_ulong(resp, &resp_index, stats.modprobe_fork_failures);
    ei_encode_atom(resp, &resp_index, "peak_queue_n");
    ei_encode_ulong(resp, &resp_index, stats.peak_queue_n);
    ei_encode_atom(resp, &resp_index, "peak_queue_bytes");
    ei_encode_ulong(resp, &resp_index, stats.peak_queue_bytes);

    ei_encode_atom(resp, &resp_index, "actions");
    ei_encode_map_header(resp, &resp_index, 7);
    ei_encode_atom(resp, &resp_index, "add");
    ei_encode_ulong(resp, &resp_index, stats.action_add);
    ei_encode_atom(resp, &resp_index, "change");
    ei_encode_ulong(resp, &resp_index, stats.action_change);
    ei_encode_atom(resp, &resp_index, "remove");
    ei_encode_ulong(resp, &resp_index, stats.action_remove);
    ei_encode_atom(resp, &resp_index, "move");
    ei_encode_ulong(resp, &resp_index, stats.action_move);
    ei_encode_atom(resp, &resp_index, "bind");
    ei_encode_ulong(resp, &resp_index, stats.action_bind);
    ei_encode_atom(resp, &resp_index, "unbind");
    ei_encode_ulong(resp, &resp_index, stats.action_unbind);
    ei_encode_atom(resp, &resp_index, "other");
    ei_encode_ulong(resp, &resp_index, stats.action_other);

    erlcmd_write_header_len(resp, resp_index);
    write_all(resp, resp_index);
}

static void nl_uevent_process_all(struct mnl_socket *nl_uevent)
{
    // Erlang response buffer
    char resp[8192];
    size_t resp_index;

    // Process uevents until there aren't any more or we're
    // within 1K of the end. This is pretty conservative since
    // the Erlang reports look like they're nearly always < 200 bytes.
    for (resp_index = 0; resp_index < sizeof(resp) - 1024;) {
        int bytes_added = nl_uevent_process_one(nl_uevent, &resp[resp_index]);
        if (bytes_added < 0)
            break;

        resp_index += bytes_added;
    }

    if (resp_index > 0) {
        run_modprobes();
        write_all(resp, resp_index);
    }
}

static int filter(const struct dirent *dirp)
{
    return (dirp->d_type == DT_REG && strcmp(dirp->d_name, "uevent") == 0) ||
           (dirp->d_type == DT_DIR && dirp->d_name[0] != '.');
}

static int uevent_compare(const struct dirent **first, const struct dirent **second)
{
    // Sorting rules
    //
    // 1. uevent files always come first. This tries to trigger events from
    //    most general to least. I.e., it's nice to get the events for the USB bus
    //    before the devices on the bus.
    // 2. Everything else in alphabetical order so that things are somewhat deterministic.
    //
    const char *first_name = (*first)->d_name;
    const char *second_name = (*second)->d_name;

    if (strcmp(first_name, "uevent") == 0)
        return -1;
    else if (strcmp(second_name, "uevent") == 0)
        return 1;
    else
        return strcmp(first_name, second_name);
}

static void scandirs(char *path, int path_end)
{
    struct dirent **namelist;
    int n;

    n = scandir(path, &namelist, filter, uevent_compare);
    if (n < 0)
        return;

    path[path_end] = '/';

    int i;
    for (i = 0; i < n; i++) {
        strcpy(&path[path_end + 1], namelist[i]->d_name);
        if (namelist[i]->d_type == DT_DIR) {
            scandirs(path, strlen(path));
        } else {
            int fd = open(path, O_WRONLY);
            if (fd >= 0) {
                int result = write(fd, "add", 3);
                if (result < 0)
                    debug("Ignoring error when writing to %s", path);
                close(fd);
            }
        }
        free(namelist[i]);
    }
    free(namelist);
    path[path_end] = 0;
}

static void sigchld_handler(int signum)
{
    (void) signum;
    // Only async-signal-safe work here: poke the self-pipe. The main loop
    // will wake from poll, reap with WNOHANG, and clear modprobe_pid. If the
    // write fails (pipe full, EAGAIN) there's already a pending wakeup byte,
    // so the main loop will still run reap_children — no data is lost.
    const char b = 0;
    if (write(sigchld_pipe[1], &b, 1) < 0) { /* intentionally ignored */ }
}

static void reap_children()
{
    int status;
    pid_t pid;

    for (;;) {
        pid = waitpid(-1, &status, WNOHANG);
        if (pid > 0) {
            if (pid == modprobe_pid)
                modprobe_pid = 0;
            // Other PIDs (the initial discovery fork) are reaped but need no
            // bookkeeping.
            continue;
        }

        if (pid == 0)
            break;

        if (errno == EINTR)
            continue;

        if (errno == ECHILD)
            break;

        break;
    }
}

static void uevent_discover()
{
    // Fork the discover work into a separate process so that it can occur in
    // parallel with sending events back.
    pid_t pid = fork();
    if (pid == 0) {
        char path[PATH_MAX] = "/sys/devices";
        scandirs(path, strlen(path));
        exit(EXIT_SUCCESS);
    }
}

int main(int argc, char *argv[])
{
    if (argc == 2 && strcmp(argv[1], "modprobe") == 0) {
        run_modprobe = 1;
    }

    // Self-pipe must exist before the SIGCHLD handler can fire.
    if (pipe2(sigchld_pipe, O_CLOEXEC | O_NONBLOCK) < 0)
        err(EXIT_FAILURE, "pipe2");

    struct sigaction act;
    act.sa_handler = sigchld_handler;
    sigemptyset (&act.sa_mask);
    act.sa_flags = 0;
    sigaction (SIGCHLD, &act, NULL);

    reset_modprobe_queue();

    struct mnl_socket *nl_uevent = uevent_open();

    // It's necessary to run the discovery process after every start to avoid
    // missing device additions. Removals between restarts can still be missed.
    // This is unhandled, but less of an issue since restarts should be rare
    // and removed devices usually cause errors against anything using them.
    uevent_discover();

    for (;;) {
        struct pollfd fdset[3];

        fdset[0].fd = mnl_socket_get_fd(nl_uevent);
        fdset[0].events = POLLIN;
        fdset[0].revents = 0;

        fdset[1].fd = STDIN_FILENO;
        fdset[1].events = POLLIN;
        fdset[1].revents = 0;

        fdset[2].fd = sigchld_pipe[0];
        fdset[2].events = POLLIN;
        fdset[2].revents = 0;

        int timeout = stats_dirty ? 5000 : -1;
        int rc = poll(fdset, 3, timeout);
        if (rc < 0) {
            // Retry if EINTR
            if (errno == EINTR)
                continue;

            err(EXIT_FAILURE, "poll");
        }

        if (rc == 0 && stats_dirty) {
            send_stats();
            stats_dirty = 0;
            continue;
        }

        if (fdset[2].revents & POLLIN) {
            // Drain the pipe; the content is irrelevant, only the wakeup is.
            char drain[64];
            while (read(sigchld_pipe[0], drain, sizeof(drain)) > 0)
                ;
            reap_children();
            // If a modprobe just finished and more modaliases queued up
            // while it was running, launch the next batch now.
            run_modprobes();
        }

        if (fdset[0].revents & (POLLIN | POLLHUP))
            nl_uevent_process_all(nl_uevent);

        // EOF on stdin (BEAM has gone away) = exit. POLLIN may be a
        // {:broadcast, body} command from Elixir; if read_exact fails it
        // returns -1 and we exit too.
        if (fdset[1].revents & POLLHUP)
            break;
        if (fdset[1].revents & POLLIN) {
            if (handle_erlang_command(STDIN_FILENO, nl_uevent) < 0)
                break;
        }
    }

    mnl_socket_close(nl_uevent);
    return 0;
}
