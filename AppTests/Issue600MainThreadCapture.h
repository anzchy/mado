#ifndef ISSUE600_MAIN_THREAD_CAPTURE_H
#define ISSUE600_MAIN_THREAD_CAPTURE_H
#include <stdint.h>
#include <stddef.h>

/* Test-target-only bridge. No Foundation, Swift or unwinder executes in the handler. */
typedef struct I600Pulse I600Pulse;
typedef struct { uint64_t queued, acknowledged, cancelled; int pending, active; } I600PulseCounts;
I600Pulse *i600_pulse_create(uint64_t now);
void i600_pulse_destroy(I600Pulse *pulse);
int i600_pulse_queue(I600Pulse *pulse);
int i600_pulse_ack(I600Pulse *pulse, uint64_t now);
uint64_t i600_pulse_lag(I600Pulse *pulse, uint64_t now);
I600PulseCounts i600_pulse_counts(I600Pulse *pulse);
void i600_pulse_close(I600Pulse *pulse);
uint64_t i600_clock_ns(void);

typedef struct {
    uint64_t pc, fp, sp, lr, captured_ns;
    uint32_t byte_count;
    int architecture; /* 1 arm64; 2 x86_64 */
    int truncated;
} I600CaptureMeta;
/* begin status: 0 owned, 1 busy, 2 foreign disposition, 3 setup failure/not-main. */
uint64_t i600_capture_begin(int *status);
int i600_capture_request(uint64_t owner);
int i600_capture_copy(uint64_t owner, I600CaptureMeta *meta, unsigned char *bytes, size_t capacity);
/* Called on main only after the requesting worker joins. Returns pending signals drained. */
int i600_capture_end(uint64_t owner);
/* Decoder reads only supplied copied bytes. Reasons: 0 end, 1 outside, 2 alignment,
   3 nonmonotonic/cycle, 4 cap, 5 truncated frame, 6 no bytes, 7 unsupported arch. */
size_t i600_decode_frames(const I600CaptureMeta *meta, const unsigned char *bytes, size_t count,
                         uintptr_t *frames, size_t capacity, int *reason);
void i600_main_thread_controlled_hold(unsigned milliseconds);
#endif
