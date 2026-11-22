module flint.reactor.test_support;

import flint.reactor : Backend;

@safe:

version (OSX)
{
    /// The readiness backend of this target: epoll on Linux, kqueue on macOS (ADR-024).
    enum Backend readinessBackend = Backend.kqueue;
}
else
{
    /// The readiness backend of this target: epoll on Linux, kqueue on macOS (ADR-024).
    enum Backend readinessBackend = Backend.epoll;
}
