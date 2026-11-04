# Closure-aware kernel startup composition

The shared C startup sequencer drives provision, upstream closure, drain fence
and START through the BAR2 router and clock crossing. The closure mailbox must
acknowledge the bound context before the initial fence can settle.

Four coordinated-reset epochs pass. Response sampling covers both immediate
local-mailbox replies and delayed control-domain replies. Debt and CRA endpoints
are fixtures; this test does not qualify reopen, Linux device operation, physical
clock crossings or board behavior.
