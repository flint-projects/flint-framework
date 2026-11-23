module flint.reactor.test_support;

import flint.reactor : Backend;

@safe:

version (OSX)
{
    /// The readiness backend of this target: epoll on Linux, kqueue on macOS (ADR-024).
    enum Backend readinessBackend = Backend.kqueue;
}
else version (Windows)
{
    /// Windows has no readiness backend; its one backend is the IOCP completion port (ADR-026).
    enum Backend readinessBackend = Backend.iocp;
}
else
{
    /// The readiness backend of this target: epoll on Linux, kqueue on macOS (ADR-024).
    enum Backend readinessBackend = Backend.epoll;
}
