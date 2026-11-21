# Scheduling and resilience

`Scheduler` is driven by `poll(utcSeconds, monotonicNanos)` on its owning thread. The first poll establishes the clocks. Separate deadline heaps keep wall-clock cron decisions independent of monotonic fixed intervals. Fixed-rate jobs keep their original phase and coalesce missed ticks. Fixed-delay jobs derive their next deadline from callback completion. Regressing clocks keep the previous high-water marks.

Cron uses six numeric UTC fields. Day of month and day of week use OR when both restrict the date. Sunday accepts 0 or 7. UTC jobs select absolute instants across local daylight saving transitions. Each invocation has its own child `Context`. Fixed-rate and cron jobs can opt into overlapping delivery on owner fibers, bounded by the open-time active limit. Closing cancels outstanding children and waits on a separate owner task within its context deadline.

`registerScheduled` installs delegates from compile-time annotations. Class registrations retain their instance. Struct values passed by reference are copied into owned storage. Pass a managed struct pointer to register on that instance. `@Retryable` applies to the registered invoker. Direct method calls use the original method body.

`withRetry` accepts an explicit replay guarantee through `RetryPolicy.idempotent`. The optional clock and wait adapter provides deterministic tests. Circuit breaker users pair an admitted call with `record`. Previously admitted completions retire before a half-open probe can start. The rate limiter tracks fractional credits with integer nanosecond arithmetic.

The test suite exercises UTC dates, clock jumps, job cancellation, registration, retry deadlines, circuit transitions and token refill. The feature probe schedules and cancels 100,000 jobs per trial, checks the GC allocation counter around every poll, and compares its callback checksum with the direct-dependency control.
