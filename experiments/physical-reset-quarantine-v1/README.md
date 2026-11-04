# Physical reset quarantine

`physical_reset_quarantine.sv` sequences initial startup and managed epoch
recovery on an independent control clock. Five asynchronous loss inputs cover
NPOR, PERST, HIP application reset, memory-controller reset and reference-clock
qualification. Loss withdraws admission and preserves transaction custody.

Initial startup requires a separately established clean-epoch certificate.
Managed recovery requires fresh boundary closure and drain acknowledgements,
then fresh flush acknowledgements after reset. All certificates remain required
through managed release. Losing one after reset release holds isolation without
asserting another custody-clearing reset. A renewed domain loss also invalidates
managed release. Only qualified configuration recovery clears terminal failure.

The boundary isolation, acknowledgement producers, CDC transport and physical
reset timing are integration obligations. A reset indication, calibration result
or quiet interval is insufficient evidence that old traffic has been flushed.

`configuration_startup_hold.sv` supplies a separate configuration-only hold.
The board BOM's 50 MHz ±50 ppm oscillator requires 41,503 cycles to cover the
830 µs initialization bound. It has no runtime reset input and does not grant
epoch admission. Internal initialization-clock selection and fitted power-up
behavior must match the implementation. See [AN 784](https://cdrdv2-public.intel.com/705720/an784-18-0-683856-705720.pdf).

`tb.sv` checks stopped-clock loss capture, stale and partial acknowledgements,
managed recovery, certificate loss during release, retained custody/history,
and the complete startup-counter interval. These are component tests, not
whole-platform or physical acceptance.
