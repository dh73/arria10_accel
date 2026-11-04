# Full-aperture initialization test

`ddr_full_scrub_tb.sv` exercises the default 25-bit line address space without
reducing `LAST_ADDRESS`. It checks all 33,554,432 accepted 64-byte zero writes,
covering a 2-GiB payload aperture. Every address, data word, byte enable and
burst count is checked before acceptance. Periodic backpressure exercises
stable offers; a waiting client remains blocked until the final scrub write.
The next accepted client read must retain its original address and mask.

```sh
mkdir "$OUT"
"$RTL_COMPILER" -full64 -sverilog -timescale=1ns/1ps \
  +define+ARRIA10_ASSERTIONS -top ddr_full_scrub_tb \
  third_party/arria10-ddr-init/arria10_ddr_init.sv \
  tests/vcs/ddr_full_scrub_tb.sv \
  -Mdir="$OUT/csrc" -o "$OUT/simv"
"$RTL_RUNNER" "$OUT/simv" -no_save
```

Require exactly one `DDR_FULL_SCRUB_PASS` with `lines=33554432`,
`payload_bytes=2147483648`, positive stalls and `client_reads=1`, with no
assertion failures or native errors. The qualified run reports 706,408 stall
cycles. This is interface sequence validation: the fixture does not model
physical memory, ECC generation, calibration, or achieved clock frequency.
