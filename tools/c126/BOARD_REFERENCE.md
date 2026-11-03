# ES3 DDR reference comparison

The official development-kit archive
`arria10GX_10ax115sf45_fpga_v22.4.0_v1.1.zip` contains ES3 source and images
despite its Production Edition label. Archive SHA-256:
`e4ad7d042be666496ba446f528c14a074b187525d130702fd48fc7c33e92a619`.
Its top-level readme identifies board revision E3p1. The ES3 Golden Top and
DDR4 example both select `10AX115S3F45E2SGE3`.

Relevant archive paths:

- `examples/golden_top/ES3/a10gx_pcie_e3p1_golden_top.zip`
- `examples/memory/ES3/qts_ddr4_x72_1066MHz/`
- `examples/board_test_system/image/ES3/`
- `factory_recovery/build_factory_source/ES3/`
- `board_design_files/arria10_10ax115sf45/schematic/`

The DDR example and C126 agree on 121 explicitly corresponding DDR, OCT and
reference-clock pins. Nine C126 DBI pins have no corresponding assignment in
that example. Six status/reset pins were excluded from this comparison.
Correspondence used signal names, not a search for equal package pins.

| Setting | Vendor ES3 example | C126 |
| --- | --- | --- |
| Physical data width / bits per DQS | 72 / 8 | 72 / 8 |
| Row / column address bits | 17 / 10 | 15 / 10 |
| Bank / bank-group address bits | 2 / 1 | 2 / 1 |
| Ranks per DIMM / DIMMs | 1 / 1 | 1 / 1 |
| Data mask enabled | false | true |
| Read DBI enabled | false | true |
| Write DBI enabled | false | false |
| ECC enabled / automatic correction | true / false | true / false |
| Memory / reference clock setting, MHz | 1066.667 / 133.333 | 1066.667 / 133.333 |

The vendor archive's `ed_synth.qsys` records the `dut` EMIF module at version
15.1. The package release label alone does not establish the version of every
nested design. Neither configuration has been adopted as a physical geometry
measurement of the P12-27065R card.

Before programming, resolve PCB/card revisions, exact memory organization,
DM/DBI wiring and mode compatibility, reset/clock wiring and timing, and a
board-matched recovery procedure. Recovery files in an archive are candidates,
not a tested restoration path. The source differences do not justify silently
changing the preserved C126 project.
