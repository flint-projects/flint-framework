#ifndef FLINT_REACTOR_URING_H
#define FLINT_REACTOR_URING_H

#include <stdint.h>

/* One thread owns each ring. Status codes are negative errno values. */
int flint_uring_open(unsigned entries, void **out);

/* Call after all original and cancellation CQEs have drained. */
void flint_uring_close(void *owner);

/* A successful prepare retains the buffer until its original token completes. */
int flint_uring_accept(void *owner, int listener, uint64_t token);
int flint_uring_recv(void *owner, int fd, uint8_t *buffer, unsigned length, uint64_t token);
int flint_uring_send(void *owner, int fd, const uint8_t *buffer, unsigned length, uint64_t token);
int flint_uring_poll_readable(void *owner, int fd, uint64_t token);
int flint_uring_cancel(void *owner, uint64_t target_token);

/* Flush queued SQEs and consume one CQE. Token zero denotes a cancel CQE.
 * Returns 1 for a CQE, 0 for empty/timeout/interruption, or negative errno.
 * A wait error does not retire an operation or release its storage. */
int flint_uring_wait(void *owner, unsigned timeout_ms, uint64_t *token_out, int *result_out);

#endif
