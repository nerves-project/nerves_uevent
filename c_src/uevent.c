// SPDX-FileCopyrightText: 2022 Frank Hunleth
//
// SPDX-License-Identifier: Apache-2.0

#include "utils.h"
#include <ctype.h>
#include <dirent.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libmnl/libmnl.h>
#include <linux/rtnetlink.h>
#include <linux/limits.h>

#include <ei.h>

static int run_modprobe = 0;
static int modprobe_queue_n;
static int modprobe_queue_index;
// Experimentation showed that batches max out around 18 modprobe calls and
// require a max ~700 bytes of buffer. These shouldn't overflow in practice,
// but are still checked below.
static char modprobe_queue_buffer[1024];
static char *modprobe_queue_argv[32];

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
    } else {
        // parent
        int status = -1;
        int rc;
        do {
            rc = waitpid(pid, &status, 0);
        } while (rc < 0 && errno == EINTR);

        // Ignore errors.
        reset_modprobe_queue();
    }
}

static void queue_modprobe(char *modalias)
{
    size_t modalias_len = strlen(modalias) + 1;
    if (modprobe_queue_index + modalias_len > sizeof(modprobe_queue_buffer)) {
        run_modprobes();
    }

    char *p = &modprobe_queue_buffer[modprobe_queue_index];

    modprobe_queue_argv[modprobe_queue_n] = p;
    strcpy(p, modalias);
    modprobe_queue_index += modalias_len;
    modprobe_queue_n++;
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

    // Turn off ENOBUFS notifications since there's nothing that we can do
    // about them.
    unsigned int val = 1;
    if (mnl_socket_setsockopt(nl_uevent, NETLINK_NO_ENOBUFS, &val, sizeof(val)) < 0)
        err(EXIT_FAILURE, "mnl_socket_setsockopt(NETLINK_NO_ENOBUFS)");

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

static int nl_uevent_process_one(struct mnl_socket *nl_uevent, char *resp)
{
    char nlbuf[8192]; // See MNL_SOCKET_BUFFER_SIZE
    int bytecount = mnl_socket_recvfrom(nl_uevent, nlbuf, sizeof(nlbuf));
    if (bytecount <= 0) {
        if (errno == EAGAIN)
            return -1;
        else
            err(EXIT_FAILURE, "mnl_socket_recvfrom");
    }

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
        values[kvpairs_count] = equalsign + 1;

        // Optionally run modprobe on newly added devices that have a modalias
        if (run_modprobe && strcmp(str, "modalias") == 0 && strcmp(action, "add") == 0) {
            queue_modprobe(equalsign + 1);
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

static void discovery_exit_handler(int signum)
{
    // Call wait on the child so that it's not a zombie, but ignore whether
    // it exited successfully.
    int status;
    wait(&status);
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

    struct sigaction act;
    act.sa_handler = discovery_exit_handler;
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
        struct pollfd fdset[2];

        fdset[0].fd = mnl_socket_get_fd(nl_uevent);
        fdset[0].events = POLLIN;
        fdset[0].revents = 0;

        fdset[1].fd = STDIN_FILENO;
        fdset[1].events = POLLIN;
        fdset[1].revents = 0;

        int rc = poll(fdset, 2, -1);
        if (rc < 0) {
            // Retry if EINTR
            if (errno == EINTR)
                continue;

            err(EXIT_FAILURE, "poll");
        }

        if (fdset[0].revents & (POLLIN | POLLHUP))
            nl_uevent_process_all(nl_uevent);

        // Any notification from Erlang is to exit
        if (fdset[1].revents & (POLLIN | POLLHUP))
            break;
    }

    mnl_socket_close(nl_uevent);
    return 0;
}
