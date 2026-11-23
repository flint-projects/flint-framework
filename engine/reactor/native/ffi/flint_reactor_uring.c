#include "flint_reactor_uring.h"

#ifdef FLINT_HAS_LIBURING

#include <errno.h>
#include <liburing.h>
#include <poll.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

/* Submission-queue entries per ring (64 bytes each); see flint_uring_open. */
#define FLINT_URING_SQ_ENTRIES 256u

struct flint_uring {
    struct io_uring ring;
    size_t pending;
    size_t limit;
    unsigned setup_flags; /* the IORING_SETUP_* flags the kernel accepted */
    int enabled;          /* a ring set up disabled has been enabled by its issuing thread */
};

static int required_operations_supported(struct io_uring *ring)
{
    struct io_uring_probe *probe = io_uring_get_probe_ring(ring);
    if (probe == NULL)
        return 0;
    int supported = io_uring_opcode_supported(probe, IORING_OP_ACCEPT)
        && io_uring_opcode_supported(probe, IORING_OP_RECV)
        && io_uring_opcode_supported(probe, IORING_OP_SEND)
        && io_uring_opcode_supported(probe, IORING_OP_POLL_ADD)
        && io_uring_opcode_supported(probe, IORING_OP_ASYNC_CANCEL);
    io_uring_free_probe(probe);
    return supported;
}

int flint_uring_open(unsigned entries, void **out)
{
    if (out == NULL)
        return -EINVAL;
    *out = NULL;
    if (entries == 0)
        return -EINVAL;
    struct flint_uring *owner = calloc(1, sizeof(*owner));
    if (owner == NULL)
        return -ENOMEM;
    /* `entries` bounds the operations in flight, which the completion queue must hold. The submission queue only
     * holds what one loop pass prepares before it submits, and `reserve` submits early when it fills, so it is
     * capped: the kernel keeps both rings resident, and at the HTTP engine's 4,160 operations per worker a
     * submission queue as large as the completion queue cost 1 MiB of SQEs per worker. */
    /* Task running, best first; a kernel that does not know a flag rejects the set with EINVAL and the next is tried.
     * - Deferred (Linux 6.1): completions are processed only when the ring's one issuing thread waits for them, with
     *   no interruption and no cross-thread work. The ring starts disabled (R_DISABLED, 5.10) and the first thread
     *   to submit or wait enables it and becomes its issuer (SINGLE_ISSUER, 6.0): each reactor worker owns its ring,
     *   which the main thread creates and, after the workers have joined, closes, without submitting.
     * - Cooperative (5.19): completions are processed when the loop next enters the kernel instead of interrupting
     *   it for each one.
     * TASKRUN_FLAG makes the kernel set IORING_SQ_TASKRUN when work is pending, so liburing's peek enters for it. */
    static const unsigned attempts[] = {
        IORING_SETUP_R_DISABLED | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_TASKRUN_FLAG,
        IORING_SETUP_COOP_TASKRUN | IORING_SETUP_TASKRUN_FLAG,
        0,
    };
    unsigned submission = entries < FLINT_URING_SQ_ENTRIES ? entries : FLINT_URING_SQ_ENTRIES;
    struct io_uring_params params;
    int status = -EINVAL;
    for (size_t attempt = 0; attempt < sizeof(attempts) / sizeof(attempts[0]) && status == -EINVAL; ++attempt) {
        memset(&params, 0, sizeof(params));
        params.flags = IORING_SETUP_CQSIZE | attempts[attempt];
        params.cq_entries = entries;
        status = io_uring_queue_init_params(submission, &owner->ring, &params);
    }
    if (status < 0) {
        free(owner);
        return status;
    }
    const unsigned required = IORING_FEAT_NODROP | IORING_FEAT_EXT_ARG;
    if ((params.features & required) != required || !required_operations_supported(&owner->ring)) {
        io_uring_queue_exit(&owner->ring);
        free(owner);
        return -EOPNOTSUPP;
    }
    owner->limit = params.cq_entries;
    owner->setup_flags = params.flags;
    *out = owner;
    return 0;
}

unsigned flint_uring_setup_flags(void *ring)
{
    const struct flint_uring *owner = ring;
    return owner == NULL ? 0 : owner->setup_flags;
}

void flint_uring_close(void *ring)
{
    struct flint_uring *owner = ring;
    if (owner == NULL)
        return;
    if (owner->pending != 0)
        abort();
    io_uring_queue_exit(&owner->ring);
    free(owner);
}

/* A ring set up disabled is enabled by the first thread that submits to it or waits on it, which becomes its single
   issuer; the reactor only ever does either on the ring's worker thread. */
static int ensure_enabled(struct flint_uring *owner)
{
    if (owner->enabled || (owner->setup_flags & IORING_SETUP_R_DISABLED) == 0)
        return 0;
    int status = io_uring_enable_rings(&owner->ring);
    if (status < 0)
        return status;
    owner->enabled = 1;
    return 0;
}

static struct io_uring_sqe *reserve(struct flint_uring *owner)
{
    if (owner->pending == owner->limit)
        return NULL;
    struct io_uring_sqe *sqe = io_uring_get_sqe(&owner->ring);
    if (sqe == NULL) {
        /* The submission queue is full of prepared entries; hand them to the kernel and take a fresh one. The
         * completion queue still has room for every pending operation, so -EBUSY cannot come from overflow. */
        int status = io_uring_submit(&owner->ring);
        if (status < 0 && status != -EAGAIN && status != -EBUSY && status != -EINTR)
            return NULL;
        sqe = io_uring_get_sqe(&owner->ring);
    }
    if (sqe != NULL)
        ++owner->pending;
    return sqe;
}

int flint_uring_accept(void *ring, int listener, uint64_t token)
{
    if (ring == NULL || listener < 0 || token == 0)
        return -EINVAL;
    int enabled = ensure_enabled(ring);
    if (enabled < 0)
        return enabled;
    struct io_uring_sqe *sqe = reserve(ring);
    if (sqe == NULL)
        return -EAGAIN;
    io_uring_prep_accept(sqe, listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, token);
    return 0;
}

int flint_uring_recv(void *ring, int fd, uint8_t *buffer, unsigned length, uint64_t token)
{
    if (ring == NULL || fd < 0 || buffer == NULL || length == 0 || token == 0)
        return -EINVAL;
    int enabled = ensure_enabled(ring);
    if (enabled < 0)
        return enabled;
    struct io_uring_sqe *sqe = reserve(ring);
    if (sqe == NULL)
        return -EAGAIN;
    io_uring_prep_recv(sqe, fd, buffer, length, 0);
    io_uring_sqe_set_data64(sqe, token);
    return 0;
}

int flint_uring_send(void *ring, int fd, const uint8_t *buffer, unsigned length, uint64_t token)
{
    if (ring == NULL || fd < 0 || buffer == NULL || length == 0 || token == 0)
        return -EINVAL;
    int enabled = ensure_enabled(ring);
    if (enabled < 0)
        return enabled;
    struct io_uring_sqe *sqe = reserve(ring);
    if (sqe == NULL)
        return -EAGAIN;
    io_uring_prep_send(sqe, fd, buffer, length, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, token);
    return 0;
}

int flint_uring_poll_readable(void *ring, int fd, uint64_t token)
{
    if (ring == NULL || fd < 0 || token == 0)
        return -EINVAL;
    int enabled = ensure_enabled(ring);
    if (enabled < 0)
        return enabled;
    struct io_uring_sqe *sqe = reserve(ring);
    if (sqe == NULL)
        return -EAGAIN;
    io_uring_prep_poll_add(sqe, fd, POLLIN);
    io_uring_sqe_set_data64(sqe, token);
    return 0;
}

int flint_uring_cancel(void *ring, uint64_t target_token)
{
    if (ring == NULL || target_token == 0)
        return -EINVAL;
    int enabled = ensure_enabled(ring);
    if (enabled < 0)
        return enabled;
    /* ADR-017 decision 7: a read the kernel can complete with data before its cancellation takes effect delivers
       that data. With deferred task running, a receive whose data has arrived only completes when the issuer next
       enters for events, after this cancellation would be submitted; run that pending work first, so such a read
       posts its completion with the data, as it does when task work runs at once. Nothing is submitted here. */
    struct flint_uring *owner = ring;
    if ((owner->setup_flags & IORING_SETUP_DEFER_TASKRUN) != 0) {
        int flushed = io_uring_get_events(&owner->ring);
        if (flushed < 0 && flushed != -EINTR && flushed != -EAGAIN && flushed != -EBUSY)
            return flushed;
    }
    struct io_uring_sqe *sqe = reserve(ring);
    if (sqe == NULL)
        return -EAGAIN;
    io_uring_prep_cancel64(sqe, target_token, 0);
    io_uring_sqe_set_data64(sqe, 0);
    return 0;
}

int flint_uring_wait(void *ring, unsigned timeout_ms, uint64_t *token_out, int *result_out)
{
    if (ring == NULL || token_out == NULL || result_out == NULL)
        return -EINVAL;
    struct flint_uring *owner = ring;
    struct io_uring_cqe *cqe = NULL;
    int status = ensure_enabled(owner);
    if (status < 0)
        return status;
    if (timeout_ms == 0) {
        /* A poll: submit what is queued (no syscall when nothing is) and take a completion if one is there. */
        status = io_uring_submit(&owner->ring);
        if (status == -EINTR)
            return 0;
        if (status < 0 && status != -EAGAIN && status != -EBUSY)
            return status;
        status = io_uring_peek_cqe(&owner->ring, &cqe);
    } else {
        /* Submit the queued operations and wait for the first completion in one io_uring_enter (IORING_FEAT_EXT_ARG,
           required at open), where io_uring_submit then io_uring_wait_cqe_timeout took two. */
        struct __kernel_timespec timeout = {
            .tv_sec = timeout_ms / 1000,
            .tv_nsec = (timeout_ms % 1000) * 1000000L,
        };
        status = io_uring_submit_and_wait_timeout(&owner->ring, &cqe, 1, &timeout, NULL);
        if (status == -EAGAIN || status == -EBUSY)
            /* The kernel took no more submissions now: reap what has completed instead. */
            status = io_uring_peek_cqe(&owner->ring, &cqe);
    }
    if (status == -EAGAIN || status == -ETIME || status == -EINTR)
        return 0;
    if (status < 0)
        return status;
    /* A successful submit_and_wait returns the submitted count and may leave cqe unset. */
    if (cqe == NULL && io_uring_peek_cqe(&owner->ring, &cqe) != 0)
        return 0;
    if (owner->pending == 0)
        abort();
    *token_out = io_uring_cqe_get_data64(cqe);
    *result_out = cqe->res;
    io_uring_cqe_seen(&owner->ring, cqe);
    --owner->pending;
    return 1;
}

#endif
