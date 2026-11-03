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
