#include "Issue600MainThreadCapture.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <errno.h>
#include <sys/ucontext.h>
#if defined(__arm64__)
#include <ptrauth.h>
#endif

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "signal publication and pulse fields must be lock-free");
struct I600Pulse {
    _Atomic uint64_t last, queued, acknowledged, cancelled;
    _Atomic int active, pending;
};
I600Pulse *i600_pulse_create(uint64_t now) {
    I600Pulse *p = calloc(1, sizeof(*p));
    if (p) {
        atomic_init(&p->last, now); atomic_init(&p->active, 1); atomic_init(&p->pending, 0);
        atomic_init(&p->queued, 0); atomic_init(&p->acknowledged, 0); atomic_init(&p->cancelled, 0);
    }
    return p;
}
void i600_pulse_destroy(I600Pulse *p) { free(p); }
int i600_pulse_queue(I600Pulse *p) {
    if (!atomic_load_explicit(&p->active, memory_order_acquire)) return 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&p->pending, &expected, 1, memory_order_acq_rel, memory_order_relaxed)) return 0;
    atomic_fetch_add_explicit(&p->queued, 1, memory_order_relaxed);
    if (!atomic_load_explicit(&p->active, memory_order_acquire)) {
        if (atomic_exchange_explicit(&p->pending, 0, memory_order_acq_rel))
            atomic_fetch_add_explicit(&p->cancelled, 1, memory_order_relaxed);
        return 0;
    }
    return 1;
}
int i600_pulse_ack(I600Pulse *p, uint64_t now) {
    if (!atomic_load_explicit(&p->active, memory_order_acquire) || !atomic_exchange_explicit(&p->pending, 0, memory_order_acq_rel)) return 0;
    atomic_store_explicit(&p->last, now, memory_order_release);
    atomic_fetch_add_explicit(&p->acknowledged, 1, memory_order_relaxed);
    return 1;
}
uint64_t i600_pulse_lag(I600Pulse *p, uint64_t now) {
    uint64_t last = atomic_load_explicit(&p->last, memory_order_acquire);
    return now >= last ? now - last : 0;
}
I600PulseCounts i600_pulse_counts(I600Pulse *p) {
    return (I600PulseCounts){atomic_load(&p->queued), atomic_load(&p->acknowledged),
        atomic_load(&p->cancelled), atomic_load(&p->pending), atomic_load(&p->active)};
}
void i600_pulse_close(I600Pulse *p) {
    atomic_store_explicit(&p->active, 0, memory_order_release);
    if (atomic_exchange_explicit(&p->pending, 0, memory_order_acq_rel))
        atomic_fetch_add_explicit(&p->cancelled, 1, memory_order_relaxed);
}
uint64_t i600_clock_ns(void) {
    struct timespec t = {0};
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static _Atomic uint64_t capture_owner;
static _Atomic int capture_requested, capture_ready;
static uint64_t next_owner;
static pthread_t capture_main;
static struct sigaction previous_action;
static uintptr_t capture_stack_low, capture_stack_high;
static I600CaptureMeta capture_meta;
static unsigned char capture_bytes[65536];

/* Only lock-free atomics, register reads, clock_gettime and bounded memory stores.
   The interrupted main stack above SP is mapped; the handler itself runs below it.
   No unwinder, allocation, locks, Swift, Foundation, symbol lookup or I/O. */
static void i600_snapshot_handler(int signal, siginfo_t *info, void *context) {
    (void)signal; (void)info;
    int saved_errno = errno;
    if (!atomic_load_explicit(&capture_owner, memory_order_acquire) ||
        !atomic_load_explicit(&capture_requested, memory_order_acquire) ||
        atomic_load_explicit(&capture_ready, memory_order_relaxed)) return;
    ucontext_t *u = context;
    uint64_t pc, fp, sp, lr = 0;
    int architecture;
#if defined(__arm64__)
    pc = __darwin_arm_thread_state64_get_pc(u->uc_mcontext->__ss);
    fp = __darwin_arm_thread_state64_get_fp(u->uc_mcontext->__ss);
    sp = __darwin_arm_thread_state64_get_sp(u->uc_mcontext->__ss);
    lr = __darwin_arm_thread_state64_get_lr(u->uc_mcontext->__ss);
    architecture = 1;
#elif defined(__x86_64__)
    pc = u->uc_mcontext->__ss.__rip;
    fp = u->uc_mcontext->__ss.__rbp;
    sp = u->uc_mcontext->__ss.__rsp;
    architecture = 2;
#else
    return;
#endif
    /* Also refuses a process-directed signal delivered on another thread's stack. */
    if (sp < capture_stack_low || sp >= capture_stack_high) return;
    capture_meta.pc = pc; capture_meta.fp = fp; capture_meta.sp = sp; capture_meta.lr = lr;
    capture_meta.architecture = architecture;
    capture_meta.captured_ns = i600_clock_ns();
    size_t available = capture_stack_high - sp;
    size_t count = available < sizeof capture_bytes ? available : sizeof capture_bytes;
    capture_meta.byte_count = (uint32_t)count;
    capture_meta.truncated = available > count;
    const volatile unsigned char *source = (const volatile unsigned char *)(uintptr_t)sp;
    volatile unsigned char *destination = capture_bytes;
    for (size_t i = 0; i < count; i++) destination[i] = source[i];
    errno = saved_errno;
    atomic_store_explicit(&capture_ready, 1, memory_order_release);
}
uint64_t i600_capture_begin(int *status) {
    *status = 3;
    if (!pthread_main_np()) return 0;
    if (atomic_load_explicit(&capture_owner, memory_order_acquire)) { *status = 1; return 0; }
    struct sigaction existing = {0};
    if (sigaction(SIGUSR2, NULL, &existing)) return 0;
    if (existing.sa_handler != SIG_DFL && existing.sa_handler != SIG_IGN) { *status = 2; return 0; }
    if (!i600_clock_ns()) return 0; /* Prewarm RAW clock and lazy binding outside handler. */
    capture_main = pthread_self();
    capture_stack_high = (uintptr_t)pthread_get_stackaddr_np(capture_main);
    size_t stack_size = pthread_get_stacksize_np(capture_main);
    if (!capture_stack_high || !stack_size || capture_stack_high < stack_size) return 0;
    capture_stack_low = capture_stack_high - stack_size;
    memset(&capture_meta, 0, sizeof capture_meta);
    memset(capture_bytes, 0, sizeof capture_bytes); /* Commit destination pages off signal path. */
    atomic_store_explicit(&capture_ready, 0, memory_order_relaxed);
    atomic_store_explicit(&capture_requested, 0, memory_order_relaxed);
    struct sigaction action = {0};
    action.sa_sigaction = i600_snapshot_handler;
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&action.sa_mask);
    previous_action = existing;
    if (sigaction(SIGUSR2, &action, NULL)) return 0;
    uint64_t owner = ++next_owner;
    if (!owner) owner = ++next_owner;
    atomic_store_explicit(&capture_owner, owner, memory_order_release);
    *status = 0;
    return owner;
}
int i600_capture_request(uint64_t owner) {
    if (!owner || atomic_load_explicit(&capture_owner, memory_order_acquire) != owner) return EINVAL;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&capture_requested, &expected, 1, memory_order_acq_rel, memory_order_relaxed)) return EALREADY;
    return pthread_kill(capture_main, SIGUSR2);
}
int i600_capture_copy(uint64_t owner, I600CaptureMeta *meta, unsigned char *bytes, size_t capacity) {
    if (!owner || atomic_load_explicit(&capture_owner, memory_order_acquire) != owner ||
        !atomic_load_explicit(&capture_ready, memory_order_acquire)) return 0;
    *meta = capture_meta;
    size_t count = capture_meta.byte_count;
    if (count > capacity) { count = capacity; meta->truncated = 1; }
    meta->byte_count = (uint32_t)count;
    if (count) memcpy(bytes, capture_bytes, count);
    return 1;
}
int i600_capture_end(uint64_t owner) {
    if (!owner || atomic_load_explicit(&capture_owner, memory_order_acquire) != owner) return 0;
    if (!pthread_main_np()) return -1;
    sigset_t set, original, pending;
    sigemptyset(&set); sigaddset(&set, SIGUSR2);
    if (pthread_sigmask(SIG_BLOCK, &set, &original)) return -2;
    /* Requesting worker must already have joined: no send can pass the owner check now. */
    atomic_store_explicit(&capture_owner, 0, memory_order_release);
    int drained = 0;
    if (sigpending(&pending) || (sigismember(&pending, SIGUSR2) == 1 && sigwait(&set, &drained))) {
        pthread_sigmask(SIG_SETMASK, &original, NULL);
        return -3; /* Static safe handler remains installed if safe drain cannot be established. */
    }
    drained = drained == SIGUSR2 ? 1 : 0;
    struct sigaction current = {0};
    int restored = sigaction(SIGUSR2, NULL, &current) == 0 &&
        (current.sa_flags & SA_SIGINFO) && current.sa_sigaction == i600_snapshot_handler;
    if (restored) restored = sigaction(SIGUSR2, &previous_action, NULL) == 0;
    atomic_store_explicit(&capture_requested, 0, memory_order_relaxed);
    int mask_status = pthread_sigmask(SIG_SETMASK, &original, NULL);
    return restored && !mask_status ? drained : -4;
}
static uintptr_t strip_return(uintptr_t value) {
#if defined(__arm64__)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_return_address);
#else
    return value;
#endif
}
size_t i600_decode_frames(const I600CaptureMeta *meta, const unsigned char *bytes, size_t count,
                         uintptr_t *frames, size_t capacity, int *reason) {
    *reason = 0;
    if (!capacity) { *reason = 4; return 0; }
    if (meta->architecture != 1 && meta->architecture != 2) { *reason = 7; return 0; }
    size_t used = 0;
    frames[used++] = strip_return((uintptr_t)meta->pc);
    if (meta->architecture == 1 && meta->lr && meta->lr != meta->pc) {
        if (used == capacity) { *reason = 4; return used; }
        frames[used++] = strip_return((uintptr_t)meta->lr);
    }
    if (!count || !bytes) { *reason = 6; return used; }
    if (count > meta->byte_count) count = meta->byte_count;
    uint64_t fp = meta->fp;
    uint64_t alignment = meta->architecture == 1 ? 16 : 8;
    while (fp) {
        if (used == capacity) { *reason = 4; break; }
        if (fp % alignment) { *reason = 2; break; }
        if (fp < meta->sp || fp - meta->sp > count) { *reason = 1; break; }
        size_t offset = (size_t)(fp - meta->sp);
        if (count - offset < 16) { *reason = 5; break; }
        uint64_t next, returned;
        memcpy(&next, bytes + offset, 8);
        memcpy(&returned, bytes + offset + 8, 8);
        frames[used++] = strip_return((uintptr_t)returned);
        if (next && next <= fp) { *reason = 3; break; }
        fp = next;
    }
    return used;
}
__attribute__((noinline,visibility("default"))) void i600_main_thread_controlled_hold(unsigned milliseconds) {
    uint64_t end = i600_clock_ns() + (uint64_t)milliseconds * 1000000;
    while (i600_clock_ns() < end) { struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL); }
}
