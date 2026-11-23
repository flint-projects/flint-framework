/* Confirm a full native producer remains capped during a real 10-minute broker outage. */
#define _POSIX_C_SOURCE 200809L
#include "flint_mq.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>

/* Darwin has no /proc: the task's resident size, as VmRSS reports it on Linux (ADR-024). */
static size_t rss_kib(void)
{
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    const kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    assert(status == KERN_SUCCESS && info.resident_size > 0);
    return (size_t)(info.resident_size / 1024);
}
#else
static size_t rss_kib(void)
{
    FILE *status = fopen("/proc/self/status", "r");
    assert(status);
    char line[256];
    size_t rss = 0;
    while (fgets(line, sizeof(line), status) && sscanf(line, "VmRSS: %zu", &rss) != 1) {}
    assert(fclose(status) == 0 && rss > 0);
    return rss;
}
#endif

int main(int count, char **args)
{
    assert(count == 3);
    const unsigned duration = (unsigned)strtoul(args[2], NULL, 10);
    assert(duration && duration <= 600);
    const flint_kafka_options config = { args[1], "outage", NULL, 900000, 16 * 1024 * 1024, 1024, 0 };
    flint_kafka_client *client = NULL;
    assert(flint_kafka_open(&config, &client) == FLINT_MQ_OK);
    const size_t idle = rss_kib();
    uint8_t payload[32768];
    memset(payload, 0xa5, sizeof(payload));
    for (uint64_t token = 1; token <= 512; ++token)
        assert(flint_kafka_produce(client, "outage", NULL, 0, payload, sizeof(payload), token) == FLINT_MQ_OK);
    assert(flint_kafka_produce(client, "outage", NULL, 0, payload, sizeof(payload), 513) == FLINT_MQ_EXHAUSTED);
    size_t high = 0;
    const struct timespec interval = {1, 0};
    for (unsigned i = 0; i < duration; ++i) {
        flint_kafka_receipt receipt;
        assert(flint_kafka_receipt_take(client, 1, &receipt) == FLINT_MQ_UNAVAILABLE);
        assert(flint_kafka_produce(client, "outage", NULL, 0, payload, sizeof(payload), 513) == FLINT_MQ_EXHAUSTED);
        assert(flint_kafka_flush(client, 0) == FLINT_MQ_UNAVAILABLE);
        const size_t rss = rss_kib();
        if (rss > high)
            high = rss;
        nanosleep(&interval, NULL);
        if (i == 0 || (i + 1) % 60 == 0) {
            printf("elapsed_seconds=%u owned_payload_bytes=16777216 maximum_rss_kib=%zu\n", i + 1, high);
            fflush(stdout);
        }
    }
    assert(flint_kafka_drain_begin(client) == FLINT_MQ_OK);
    assert(flint_kafka_flush(client, 0) == FLINT_MQ_UNAVAILABLE);
    flint_kafka_free(client);
    printf("duration=%u idle_rss_kib=%zu peak_rss_kib=%zu admitted_bytes=16777216 overload=rejected drain=pending\n",
           duration, idle, high);
}
