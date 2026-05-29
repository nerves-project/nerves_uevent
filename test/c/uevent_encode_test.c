// SPDX-FileCopyrightText: 2026 Frank Hunleth
//
// SPDX-License-Identifier: Apache-2.0

// Unit tests for the uevent message parser/encoder (encode_uevent).
//
// This file #includes uevent.c directly so it can call the static
// encode_uevent() and reach the in-file constant MAX_KV_PAIRS. Defining
// UEVENT_UNIT_TEST first drops uevent.c's own main(). The harness is built and
// run by test/nerves_uevent/uevent_encode_test.exs (Linux only).

#define UEVENT_UNIT_TEST
#include "uevent.c"

#include <arpa/inet.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAX_VAL_LEN 256

struct kv {
    char key[MAX_VAL_LEN];
    char val[MAX_VAL_LEN];
};

// Append a NUL-terminated token to buf at *off, advancing past the NUL. This
// reproduces the kernel's "KEY=val\0KEY=val\0..." netlink framing.
static void put(char *buf, size_t *off, const char *s)
{
    size_t n = strlen(s) + 1;
    memcpy(buf + *off, s, n);
    *off += n;
}

// Decode the {action, devpath, map} frame encode_uevent() produced. Asserts the
// term is well-formed (decoding consumes exactly the framed length) and that
// the map keys are unique — the invariant binary_to_term enforces, since a map
// with duplicate keys raises badarg. Copies the action atom into `action` and,
// when `out` is non-NULL, the decoded pairs into out[0..count). Returns the map
// entry count.
static int decode_frame(const char *resp, char *action, struct kv *out, int out_max)
{
    uint16_t be;
    memcpy(&be, resp, sizeof(be));
    int frame_len = (int)ntohs(be) + (int)sizeof(be);

    int idx = sizeof(uint16_t); // skip the 2-byte length prefix
    int version = 0;
    assert(ei_decode_version(resp, &idx, &version) == 0);

    int arity = 0;
    assert(ei_decode_tuple_header(resp, &idx, &arity) == 0);
    assert(arity == 3);

    assert(ei_decode_atom(resp, &idx, action) == 0);

    // devpath list — its contents aren't under test here, so just skip it.
    assert(ei_skip_term(resp, &idx) == 0);

    int map_arity = 0;
    assert(ei_decode_map_header(resp, &idx, &map_arity) == 0);
    assert(map_arity <= MAX_KV_PAIRS);
    assert(out == NULL || map_arity <= out_max);

    char keys[MAX_KV_PAIRS][MAX_VAL_LEN];
    for (int i = 0; i < map_arity; i++) {
        long klen = 0, vlen = 0;
        assert(ei_decode_binary(resp, &idx, keys[i], &klen) == 0);
        assert(klen < (long)MAX_VAL_LEN);
        keys[i][klen] = '\0';

        char value[MAX_VAL_LEN];
        assert(ei_decode_binary(resp, &idx, value, &vlen) == 0);
        assert(vlen < (long)MAX_VAL_LEN);
        value[vlen] = '\0';

        // The regression guard: no key may repeat.
        for (int j = 0; j < i; j++)
            assert(strcmp(keys[j], keys[i]) != 0 && "duplicate key in encoded map");

        if (out) {
            memcpy(out[i].key, keys[i], klen + 1);
            memcpy(out[i].val, value, vlen + 1);
        }
    }

    // Nothing trailing, nothing truncated.
    assert(idx == frame_len && "frame not fully consumed — malformed term");

    return map_arity;
}

static const char *lookup(struct kv *pairs, int count, const char *key)
{
    for (int i = 0; i < count; i++)
        if (strcmp(pairs[i].key, key) == 0)
            return pairs[i].val;
    return NULL;
}

// A plain event encodes to {action, devpath, map}; keys are lowercased and the
// kernel's literal double quotes around values are stripped.
static void test_basic_event(void)
{
    char buf[4096];
    size_t off = 0;
    put(buf, &off, "add@/devices/virtual/foo");
    put(buf, &off, "ACTION=add");                  // filtered out of the map
    put(buf, &off, "DEVPATH=/devices/virtual/foo");// filtered out of the map
    put(buf, &off, "SUBSYSTEM=foo");
    put(buf, &off, "NAME=\"quoted name\"");

    char resp[8192];
    char action[MAXATOMLEN];
    struct kv pairs[MAX_KV_PAIRS];

    int n = encode_uevent(buf, buf + off, resp);
    assert(n > 0);
    int count = decode_frame(resp, action, pairs, MAX_KV_PAIRS);

    assert(strcmp(action, "add") == 0);
    assert(count == 2); // subsystem, name
    assert(strcmp(lookup(pairs, count, "subsystem"), "foo") == 0);
    assert(strcmp(lookup(pairs, count, "name"), "quoted name") == 0); // quotes stripped
    printf("ok basic_event (map count=%d)\n", count);
}

// Repeated keys — exact and differing only in case, since keys are lowercased
// before comparison — collapse to one entry. This is the report.bin
// regression: such an event must not produce a duplicate-keyed map.
static void test_duplicate_keys_collapsed(void)
{
    char buf[8192];
    size_t off = 0;
    put(buf, &off, "change@/devices/test/dup");
    put(buf, &off, "ACTION=change");
    put(buf, &off, "DEVPATH=/devices/test/dup");
    put(buf, &off, "SEQNUM=42");
    put(buf, &off, "SUBSYSTEM=power_supply");
    put(buf, &off, "POWER_SUPPLY_TYPE=Battery");
    put(buf, &off, "POWER_SUPPLY_TYPE=Battery"); // exact duplicate
    put(buf, &off, "power_supply_type=Battery"); // duplicate after lowercasing
    put(buf, &off, "POWER_SUPPLY_NAME=BAT1");

    char resp[8192];
    char action[MAXATOMLEN];
    struct kv pairs[MAX_KV_PAIRS];

    int n = encode_uevent(buf, buf + off, resp);
    assert(n > 0);
    int count = decode_frame(resp, action, pairs, MAX_KV_PAIRS);

    assert(strcmp(action, "change") == 0);
    // subsystem, power_supply_type, power_supply_name
    assert(count == 3);
    // First occurrence wins.
    assert(strcmp(lookup(pairs, count, "power_supply_type"), "Battery") == 0);
    printf("ok duplicate_keys_collapsed (map count=%d)\n", count);
}

// More distinct properties than the array can hold are dropped, not
// overflowed: the map is capped at MAX_KV_PAIRS and stays well-formed. This is
// what guards against the stack-array overflow that corrupted report.bin.
static void test_exceeds_max_pairs_capped(void)
{
    static char buf[65536];
    size_t off = 0;
    put(buf, &off, "add@/devices/test/many");
    put(buf, &off, "ACTION=add");
    put(buf, &off, "DEVPATH=/devices/test/many");

    const int n_props = MAX_KV_PAIRS + 50;
    for (int i = 0; i < n_props; i++) {
        char kv[64];
        snprintf(kv, sizeof(kv), "key%04d=val%04d", i, i);
        put(buf, &off, kv);
    }

    char resp[8192];
    char action[MAXATOMLEN];

    int n = encode_uevent(buf, buf + off, resp);
    assert(n > 0);
    int count = decode_frame(resp, action, NULL, 0);

    assert(strcmp(action, "add") == 0);
    assert(count == MAX_KV_PAIRS); // capped, no overflow, still valid
    printf("ok exceeds_max_pairs_capped (map count=%d)\n", count);
}

// Events with a devpath outside /devices are filtered (return 0, no frame).
static void test_non_devices_filtered(void)
{
    char buf[256];
    size_t off = 0;
    put(buf, &off, "add@/module/foo");
    put(buf, &off, "ACTION=add");
    put(buf, &off, "DEVPATH=/module/foo");

    char resp[8192];
    int n = encode_uevent(buf, buf + off, resp);
    assert(n == 0);
    printf("ok non_devices_filtered\n");
}

int main(void)
{
    test_basic_event();
    test_duplicate_keys_collapsed();
    test_exceeds_max_pairs_capped();
    test_non_devices_filtered();
    printf("All uevent encoder tests passed.\n");
    return 0;
}
