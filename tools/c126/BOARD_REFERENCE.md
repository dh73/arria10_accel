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

## Baseboard DM/DBI routing

The archive's `A10GX_PCIE_E3p1.pdf`, document `150-0321301-E3`
(`6XX-44366R`), revision E3.1 dated 2016-08-10, supplies a baseboard route
for all nine C126 DBI assignments. Sheets 4 and 8 identify FPGA pins;
sheet 17 identifies contacts on HiLo connector J14. The rows below were
checked against rendered schematic pages and the unchanged C126 QSF.

| C126 DBI bit | FPGA pin | Baseboard net | J14 contact |
| --- | --- | --- | --- |
| 0 | E26 | MEM_DMA0 | B10 |
| 1 | G27 | MEM_DMA1 | C4 |
| 2 | A29 | MEM_DMA2 | B17 |
| 3 | F30 | MEM_DMA3 | F17 |
| 4 | AB32 | MEM_DMB0 | M16 |
| 5 | AG31 | MEM_DMB1 | U16 |
| 6 | Y35 | MEM_DMB2 | U11 |
| 7 | AC34 | MEM_DMB3 | U6 |
| 8 | A32 | MEM_DQ_ADDR_CMD0 | R6 |

Their absence from the DDR example's QSF does not imply absent baseboard
routing. Conversely, these routes do not establish the daughtercard-side
connections or DM/DBI mode compatibility. In particular, bit 8 uses a generic
address/command/data connector net; its memory-device function requires the
P12-27065R card schematic. The installed PCB revision remains unverified.

An [Altera support reply](https://community.altera.com/discussions/boards-and-dev-kits/stratix-10-development-kit-hilo-connector/349694/replies/351202)
provides a HiLo DDR4 schematic candidate, `150-0330621-A1 (6XX-44270)`,
revision A. Its indexed text identifies Micron `MT40A256M16HA-093E:A` and
`MT40A512M8HX-093E:A`, rather than the reported Elpida devices. Direct PDF
retrieval was refused; this candidate has not received local visual or hash
qualification. Neither its title nor connector compatibility establishes a
match to P12-27065R. Its wiring and memory geometry are not adopted.
