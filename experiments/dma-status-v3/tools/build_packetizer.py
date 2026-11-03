#!/usr/bin/env python3
"""Build source-pinned private D2H packetizer derivatives.

No vendor implementation is distributed here.  Supply the original files from
the user's existing installation.  The aligner is currently an identity
transform: the full-wrapper test must discover any additional reachable data
defect before a data-path correction is added.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re


WRAPPER_SHA = "5faf8d9c622e7aeff2f3f77b94e3dddd9b6cac17272892a8b5493412986ee4fe"
ALIGNER_SHA = "792d039c00e605df32157b7de48e749ea6c1343639832527aa170e3100b344fa"
TLPGEN_SHA = "c4a38772eec21339f84a1a9e183e111302d0263693e1e230ba1171bab7b7a01f"


def require_sha(raw: bytes, expected: str, name: str) -> None:
    actual = hashlib.sha256(raw).hexdigest()
    if actual != expected:
        raise ValueError(f"{name}: expected original SHA-256 {expected}, got {actual}")


def unique_sub(raw: bytes, pattern: bytes, replacement: bytes, label: str) -> bytes:
    """Refuse ambiguous edits, even after the exact original-byte hash check."""
    matches = list(re.finditer(pattern, raw))
    if len(matches) != 1:
        raise ValueError(f"{label}: expected exactly one source span, got {len(matches)}")
    match = matches[0]
    return raw[: match.start()] + replacement + raw[match.end() :]


def transform_aligner(raw: bytes) -> bytes:
    require_sha(raw, ALIGNER_SHA, "altpcieav_dma_wr_wdalign_2.sv")
    return raw


def transform_tlpgen(raw: bytes) -> bytes:
    require_sha(raw, TLPGEN_SHA, "altpcieav_dma_wr_tlpgen_2.sv")
    # Guard the premise of the repair: FIFO data/request have one output
    # register while the original status is the preceding SEND/EOP event.
    for pattern, label in (
        (rb"tx_output_fifo_wrreq_reg\s*<=\s*tx_output_fifo_wrreq\s*;", "FIFO request register"),
        (rb"tx_output_fifo_data_reg\s*<=\s*tx_output_fifo_data\s*;", "FIFO data register"),
        (
            rb"assign\s+desc_completed\s*=\s*tlpgen_send_state\s*&\s*eop_flag\s*&\s*descriptor_done\s*;",
            "final-packet SEND event",
        ),
    ):
        if len(re.findall(pattern, raw)) != 1:
            raise ValueError(f"Unexpected {label}")

    raw = unique_sub(
        raw,
        rb"assign\s+WrDmaDescID_o\s*=\s*\{\s*23'h0\s*,\s*1'b1\s*,\s*desc_id\s*\}\s*;",
        b"// Descriptor ID is staged with the status and output FIFO beat below.",
        "original descriptor ID assignment",
    )
    raw = unique_sub(
        raw,
        rb"assign\s+WrDMADescDone_o\s*=\s*desc_completed\s*;",
        b"""// Owned correction: consumers sample this status on the same edge as
// the registered TxFifoWrReq_o/Data_o final beat.  This is FIFO enqueue,
// conditional on the existing grant/reserved-capacity contract, not PCIe
// delivery, host visibility, or a completion acknowledgement from the host.
always @(posedge Clk_i)
begin
    if (Srst_i) begin
        WrDMADescDone_o <= 1'b0;
        WrDmaDescID_o <= 32'h0;
    end else begin
        WrDMADescDone_o <= desc_completed;
        WrDmaDescID_o <= {23'h0, 1'b1, desc_id};
    end
end""",
        "original early descriptor status assignment",
    )
    return raw


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tlpgen-source", type=Path, required=True)
    parser.add_argument("--aligner-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    # Validate all inputs before creating either derivative.
    outputs = {
        "altpcieav_dma_wr_tlpgen_2.sv": transform_tlpgen(args.tlpgen_source.read_bytes()),
        "altpcieav_dma_wr_wdalign_2.sv": transform_aligner(args.aligner_source.read_bytes()),
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for filename in outputs:
        if (args.output_dir / filename).exists():
            raise FileExistsError(args.output_dir / filename)
    for filename, content in outputs.items():
        target = args.output_dir / filename
        with target.open("xb") as handle:
            handle.write(content)
        print(f"{filename} sha256={hashlib.sha256(content).hexdigest()}")


if __name__ == "__main__":
    main()
