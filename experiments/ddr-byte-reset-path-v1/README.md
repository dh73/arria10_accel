# Byte-readback reset and error containment

`tb.sv` connects the readback mailbox to the selected shared-memory arbiter.
Backend reset is injected during a stalled write, a stalled read and an
outstanding read response. Each case retains pending custody, blocks stale
responses and prevents replay after backend recovery. A separate case checks
that an error-marked matching read response cannot complete the command.

This digital composition test does not establish physical reset timing or
safe board recovery.
