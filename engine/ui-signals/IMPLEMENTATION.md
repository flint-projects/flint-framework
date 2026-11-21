# flint:ui-signals

Provide zeroed slabs for signals, observers, the dirty queue, and optional
computed slots and edges. The graph owns their use for its lifetime. A
generation identifies each live signal slot. Disposing an input with a
live computed dependant returns a conflict.

Set scalar values and bind text to host-issued handles. A signal enters the
dirty queue only once before the next flush. Flush evaluates the affected
computed signals in creation order and checks capacity for every pending
text command before publishing. Observers emit in registration order.
Equal-value sets avoid dirty admission, and an idle flush needs no traversal.

The native and wasm32 fixtures replay the same signal and error trace and
compare the resulting frame bytes. The native probes run complete 100,000-set
trials at 1, 1,000 and 10,000 signals and verify every patch, as well as a
zero-patch equal-value frame. The browser counter uses the same graph through
its scalar wasm32 exports.
