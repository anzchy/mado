#include "../../../AppTests/Issue600MainThreadCapture.h"
#include <signal.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static volatile sig_atomic_t foreign_count;
static void foreign_handler(int signal) { (void)signal; foreign_count++; }
static void *request_from_worker(void *value) { i600_capture_request(*(uint64_t *)value); return NULL; }
static int pending(void) { sigset_t set; sigpending(&set); return sigismember(&set, SIGUSR2); }
static int blocked(void) { sigset_t set; pthread_sigmask(SIG_SETMASK, NULL, &set); return sigismember(&set, SIGUSR2); }
static void set_default(void) { struct sigaction action = {0}; action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask); sigaction(SIGUSR2, &action, NULL); }

int main(int argc, char **argv) {
    set_default();
    if (argc < 2) return 64;
    int status = -1;
    if (!strcmp(argv[1], "foreign")) {
        struct sigaction action = {0}, after = {0}; action.sa_handler = foreign_handler;
        sigemptyset(&action.sa_mask); sigaction(SIGUSR2, &action, NULL);
        uint64_t owner = i600_capture_begin(&status);
        i600_capture_end(owner);
        sigaction(SIGUSR2, NULL, &after);
        raise(SIGUSR2);
        printf("{\"owner\":%s,\"status\":%d,\"preserved\":%s,\"foreignCount\":%d}\n",
            owner ? "true" : "false", status, after.sa_handler == foreign_handler ? "true" : "false", (int)foreign_count);
        return 0;
    }
    uint64_t owner = i600_capture_begin(&status);
    if (!owner) { printf("{\"owner\":false,\"status\":%d}\n", status); return 0; }
    if (!strcmp(argv[1], "busy")) {
        struct sigaction before = {0}, after = {0}, restored = {0};
        sigaction(SIGUSR2, NULL, &before);
        int other_status = -1; uint64_t other = i600_capture_begin(&other_status);
        i600_capture_end(other);
        sigaction(SIGUSR2, NULL, &after);
        i600_capture_end(owner);
        sigaction(SIGUSR2, NULL, &restored);
        printf("{\"owner\":true,\"otherOwner\":%s,\"otherStatus\":%d,\"nonownerPreserved\":%s,\"restored\":%s}\n",
            other ? "true" : "false", other_status,
            before.sa_sigaction == after.sa_sigaction ? "true" : "false", restored.sa_handler == SIG_DFL ? "true" : "false");
        return 0;
    }
    if (strcmp(argv[1], "pending")) { i600_capture_end(owner); return 64; }
    sigset_t set, original; sigemptyset(&set); sigaddset(&set, SIGUSR2);
    pthread_sigmask(SIG_BLOCK, &set, &original);
    pthread_t worker; pthread_create(&worker, NULL, request_from_worker, &owner); pthread_join(worker, NULL);
    int before = pending(), drained = i600_capture_end(owner), after = pending(), mask_preserved = blocked();
    struct sigaction restored = {0}; sigaction(SIGUSR2, NULL, &restored);
    pthread_sigmask(SIG_SETMASK, &original, NULL);
    /* If teardown restored SIG_DFL before consuming its signal, this process dies here. */
    int next_status = -1; uint64_t began = i600_clock_ns(), next = i600_capture_begin(&next_status);
    I600CaptureMeta meta = {0}; unsigned char bytes[65536]; int copied = 0;
    if (next) {
        i600_capture_request(next);
        for (int i = 0; i < 100 && !copied; i++) {
            copied = i600_capture_copy(next, &meta, bytes, sizeof bytes);
            if (!copied) { struct timespec delay = {0,1000000}; nanosleep(&delay, NULL); }
        }
        i600_capture_end(next);
    }
    printf("{\"owner\":true,\"pendingBefore\":%d,\"drained\":%d,\"pendingAfter\":%d,\"maskPreserved\":%s,\"defaultRestored\":%s,\"nextDistinct\":%s,\"nextCaptured\":%s,\"nextFresh\":%s}\n",
        before, drained, after, mask_preserved ? "true" : "false", restored.sa_handler == SIG_DFL ? "true" : "false",
        next && next != owner ? "true" : "false", copied ? "true" : "false", copied && meta.captured_ns >= began ? "true" : "false");
    return 0;
}
