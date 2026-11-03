# Parent connectivity obligations

The configured parent elaborates, but its diagnostics require source-specific
interpretation before behavioral or hardware acceptance.

| Connection | Source finding | Consequence |
| --- | --- | --- |
| Application `AvWrDmaReadByteEnable_o` | The parent omits it. The write mover generates head/tail masks and all ones only for full reads. | Preserve this mask through the memory-read path, or establish a memory contract permitting over-read and correct payload selection. Elaboration does neither. |
| Application `IntxReq_i` / `IntxAck_o` | Request has no functional reader; acknowledgement is tied low in this application. | The missing connection does not establish working legacy interrupt support. Qualify the selected interrupt path separately. |
| RAM `rden_a`, `clocken2`, `clocken3` | The retained model declares these inputs `tri1`. | Omission resolves high in this model; it is not an unknown-input diagnosis. Intended hardware mode still requires qualification. |
| Simulation PLL `fbclkout` | The generated wrapper passes an undriven wire to `generic_pll.fbclk`. That model declares the input but does not read it. | This diagnostic alone does not demonstrate a broken simulated clock. It establishes no physical PLL feedback contract. |

For example, a one-doubleword tail generates `32'h0000_000F`, not a full
32-byte enable. Dropping it is an interface-semantic gap even if a particular
RAM safely tolerates extra reads. No reachable data-corruption claim is made
without an end-to-end witness.

Other port-width, encrypted-model and transceiver diagnostics remain open.
No warning suppression, RTL replacement or new hardware operation is implied
by this classification.

The updated configured parent also elaborates with fetch-valid and fetch-data
connected through all containing modules. All 97 source/model hashes match
that snapshot. Diagnostic category counts match the preceding build, including
29 width warnings and 49 missing-port lint messages. Those counts do not prove
behavioral equivalence or resolve the obligations above. Full-parent simulation,
fetch-consumer behavior and hardware acceptance remain unqualified.

`tools/build_memory_mask_wrapper.py --parent PARENT --configured TOP --output DIR`
creates a separate fixed-configuration candidate exposing
`wr_dma_read_byte_enable_o[31:0]`. It connects the actual application mask through
the parent and configured top without changing address, burst, read-data or
write-mover logic. Exact input hashes are required. The memory fabric must still
consume that mask; exporting it alone does not close end-to-end semantics.

The mask-exporting parent elaborates successfully with all 99 source/model
hashes verified. Diagnostic counts match the preceding configured parent.
This is structural acceptance only.

## Payload adapter candidate

The retained payload adapter has no read-mask input and initializes DDR read
byte enables to all 64 lanes. Its write path already stores per-beat masks.
`tools/build_payload_mask.py` transforms the exact adapter with SHA-256
`a7a66662e3d15497cf24ade5ce672733104eadbeb670175b542adab6c409c06c`
into a separate `dma_payload_mask_candidate` module. It captures the read mask
on command acceptance, retains it with the existing bundled-data CDC header,
and drives that mask in the addressed 32-byte half of each DDR line. The other
half is disabled. Address, count, response selection and write behavior remain
unchanged by the transformation.

The retained read-memory producer issues masked head/tail commands with
burstcount one; its full-body commands use all 32 byte enables. The candidate
applies a command's accepted mask to every beat, preserving that distinction.
`tests/payload_mask_tb.sv` checks both half-line positions, each single-byte
mask, partial doubleword head/tail masks, burst lengths 1 through 16, command
stalls, asynchronous clocks and mask changes after acceptance. The isolated
simulation passes 124 cases with 364 accepted commands, 364 responses and 499
stall cycles; all five source pins match. The write path is not exercised by
this test. This does not qualify CDC timing, the actual memory controller's
read-mask behavior, descriptor retirement, or the complete parent-to-DDR path.

`rtl/dma_memory_path_candidate.sv` composes the mask-aware payload with the
retained `arria10_dma_ddr_mux`. A separate line requester models contention;
it is not an integrated processor. The mux fault feeds payload memory health,
and the payload's lock preserves burst ownership at the arbiter.
`tests/memory_path_tb.sv` adds partial writes with gaps, readback, competing
line reads, delayed responses and a byte-addressed memory scoreboard. Disabled
read bytes return unknown data so the test cannot rely on their contents.
Native qualification is pending. This composition still excludes the HIP,
descriptor consumer, physical EMIF, CDC constraints and hardware acceptance.
