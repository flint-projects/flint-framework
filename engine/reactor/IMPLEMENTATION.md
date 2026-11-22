# Reactor

The reactor reserves connection slots, operation buffers, timers and a task fiber pool before admitting work. Each connection and fiber stays on its owning loop. Slot generations identify connections and operations across reuse. Timeouts and cancellation select an outcome without retiring buffers early. A read the kernel completed with data before its cancellation took effect is delivered as a successful completion with that data on both io_uring and epoll; a read that ends without data stays cancelled or timed out (ADR-017 decision 7). Writes copy scoped caller bytes into an operation slot. Reads expose received bytes only for the duration of their completion callback.

A task fiber that waits for progress registers a `TaskWaker` from `currentWaker()`. The completion, timer or task that makes progress calls `wake` on the same loop, and the loop resumes the fiber on its next pass instead of at the yield deadline. Generations reject handles from finished tasks. `yieldUntil(deadline, watched)` adds a caller context to the per-pass cancellation check (`tests/wake.d`).

Linux automatic mode probes the pinned liburing provider and selects epoll if io_uring is unavailable or denied. Explicit io_uring selection reports the failed capability. Each loop processes bounded callback batches, records its preferred CPU and reports allocator and OS counters after shutdown.

Run the Linux package checks with the pinned toolchains.

```sh
dub test :reactor --compiler=dmd
dub test :reactor --compiler=ldc2
python3 tools/gates.py --package reactor --gate structural
```

With the generated liburing flags in place, the loopback tests execute both Linux backends. The setup-denial fixture applies seccomp only to the test process and checks automatic epoll fallback with the provider present.

```sh
cc -Wall -Wextra -Werror packages/reactor/bench/fixtures/deny_uring_setup.c -o /tmp/flint-deny-uring
/tmp/flint-deny-uring packages/reactor/flint-reactor-test-unittest
```

The feature and direct-provider probes share the TCP traffic generator. They exercise 1, 64 and 1024 persistent clients with 64- and 4096-byte payloads, verify admission at capacity, cancel outstanding reads and check the result of every echo. Compare checksums and backend names across the same build profile. Set `FLINT_REACTOR_PROBE_BACKEND=epoll` to select the readiness path for both programs. Set `FLINT_REACTOR_PROBE_SAMPLE_DIR` to a separate directory for each run to retain latency samples in order.
