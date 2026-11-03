# ES3 DDR reference reset wiring

Source: the ES3 DDR example in the archive identified in
[BOARD_REFERENCE.md](BOARD_REFERENCE.md). This is a static source trace, not
a timing or hardware qualification.

The example's `qts_ddr4.v:46-47` connects the 50 MHz clock and external
`cpu_resetn` to `ed_synth`. In `ed_synth/synth/ed_synth.v:397-426`, the
controller feeding the EMIF global reset has two inputs, synchronization mode
`none`, reset-request support disabled, and an unconnected clock. Its inputs
are the software reset pulse and the inverted external reset.

The accompanying reset-controller implementation directly forwards the OR of
its inputs in that configuration. With the inversion at the EMIF connection
(`ed_synth.v:130`), the resulting logic is:

```text
emif.global_reset_n = cpu_resetn && !software_reset_pulse
```

The separate controller for 50 MHz peripherals uses two-stage deassertion
synchronization (`ed_synth.v:460-488`). This synchronization does not sit in
the external-reset path to EMIF. The software pulse generator is clocked at
50 MHz and produces a one-cycle pulse following its CSR trigger; its counter
does not stretch that output to fifteen cycles.

`qts_ddr4.sdc:59` applies a false path from `cpu_resetn`. The file declares
the reference clock at 133.333 MHz and the peripheral clock at 50 MHz, with
asynchronous clock grouping. These constraints do not demonstrate recovery
or removal timing at C126's hard-IP endpoints.

C126 must retain its separate reset-release qualification: external reset
pulse and clock-stability requirements, hard-IP reset contract, and applicable
timing checks. Neither the combinational merge nor the broad false path is
adopted as a closure repair. The preserved C126 project is unchanged.
