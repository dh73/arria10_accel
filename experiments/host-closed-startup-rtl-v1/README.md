# Host closure-aware startup through RTL

The production C++ `ClosedStartup` adapter uses the shared driver C sequencer
through a simulated ordered transport. The test reuses the closure router,
control clock crossing and startup fixture from `kernel-startup-closed-rtl-v1`.
Four coordinated-reset epochs complete provision, closure, fence and START.

This validates the host adapter against RTL. Debt and CRA endpoints remain
fixtures; physical device operation, reopen and reset containment are separate.
