#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Build an isolated configured-controller/native-return composition.

No licensed source bodies live in this experiment. Exact V4 engine bytes are
required even when a V5 directory is supplied: an editable generated manifest
is not an independent source pin. The write controller must either regenerate
from its original source or match the exact qualified V4 generated digest.
All transformations finish before a new private output directory is created.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
BASE_COMMIT = "4c5c80e00d42d6684d7d297a0fb5f8d6376bbecc"
FORMAT = "dma-fetch-composition-v1"
READ_V5_SHA = "83dc7ced361b0c72dbf42e50b3f632f6d69c1bdc70230962fc93065134ce2741"
CONSUMER_INCLUDE_SHA = "db871305027778c3e03fdef1d56be0fab2115dd2e933a02f4d1591d2c4e09833"
ENGINE_V4_SHA = "3cbb20d52dd12b18ddfd38e2b057b43424e9badb00e9b11229a023d452eec6f9"
WRITE_V4_SHA = "019de60946a09d16053a8cf15148a5fcbea700b1f4c9c44fd12e0485cbdabd65"
FIFO_SHA = "8270ffb30fa3b75eaefd6d3d403335f04dbb0f13c894d35e9f6a6668f29f4bf8"

# Exact dependencies fetched at BASE_COMMIT. Check before importing Python.
DEPENDENCIES = {
    "experiments/dma-fetch-return-v5/tools/build.py": "ea68b982919df955c8dea806b6697e840c8dfbb9d394e75a6d32e272309cf79c",
    "experiments/dma-fetch-return-v5/tools/producer.py": "c72b2c07b4d5bb60e5d10c090c13aecd81e07038feb9201d0002f81cc1d3947e",
    "experiments/dma-fetch-v4/tools/build.py": "16cdb5d2ce303b97a29e25cf692b76fa94971082c5a4f19d21ef6fe93dbd2537",
    "experiments/dma-fetch-v4/rtl/controller_consumer_v4.svh": "362d481d60b1a8b534bcb28c83d2a382cadf94928e6dc85c838a79a8dbbbe5ab",
    "experiments/dma-fetch-v4/rtl/controller_tx_v4.svh": "dd0291be6e02508db0243112552451de33bc4d82a08487c60f8bd10a0a851fa1",
    "experiments/dma-fetch-v4/rtl/dma_fetch_commit_v4.sv": "3a3b013f0be6df7d72aaea973984cecbd9dcce020307fec3fe40259da549ab11",
    "experiments/dma-status-v3/tools/build_candidate.py": "c1d09dce882a16689c6936880f5135ea71ea1829b8f05d8f6a052345c98d2b9c",
    "experiments/dma-status-v3/rtl/dma_owner_v3.sv": "1300a64ad152170defc7f3e25f541da897aac666364c4c9517472207576b33e3",
    "experiments/dma-status-v3/rtl/dma_status_sink_v3.sv": "c19c82a7b68d23a44ad525bb9eeba2ae94d060775d63026a59d039e880cd1e1e",
    "experiments/dma-status-v3/rtl/engine_v3_logic.svh": "6add75b228c0ab0416b6ac62031046f039e270ec8d3333cdd51cad73672ee693",
    "experiments/dma-status-v2/tools/controller_transform.py": "3f7ad0ee119ca2c82b471f4664000d998e08e7039e9b22b42c1366b627a09944",
    "experiments/dma-status-v2/rtl/engine_v2_declarations.svh": "03ae104e42c9d491495db4e922927accf3efa1bb57c01965a8cd2900604ade63",
    "experiments/dma-status-v2/rtl/dma_status_v2_pkg.sv": "f121db6bf413d3a267d3739d7e838da27aabc210402af35beaf97f1b56968510",
    "experiments/dma-fetch-return-v5/rtl/dma_fetch_return_route_v5.sv": "85f210419603136cca05d4993695f03b8308671c62b13b097475628e66996ffa",
    "experiments/dma-fetch-return-v5/rtl/engine_return_declarations_v5.svh": "a7871e903d8715344758812784baa169ba05d237e54b21d323cbd9b1672d8da7",
    "experiments/dma-fetch-return-v5/rtl/engine_return_v5.svh": "26d718e22dcab2e59ca9802a522fd88cb31e56cba53283d0f7c5820a9d4b34f9",
    "experiments/dma-ingress-v1/run.py": "71acad948fc356aada57a3bc6e3ea81f26b764137a126ca7de729b4e965ea485",
}
SOURCES = (
    "dma_status_v2_pkg.sv", "dma_owner_fetch_return_v5.sv",
    "dma_status_sink_fetch_v4.sv", "dma_fetch_commit_return_v5.sv",
    "altpcie_dynamic_control_fetch_return_v5.sv",
    "altpcie_dynamic_control_write_v4.sv",
    "altpcieav_dma_rd_fetch_return_v5.sv", "dma_fetch_return_route_v5.sv",
    "dma_fetch_composition_v1.sv", "dma_fetch_composition_v1_tb.sv",
)
INCLUDES = (
    "controller_consumer_return_v5.svh", "controller_tx_v4.svh",
    "engine_fetch_return_v5.svh", "engine_v2_declarations.svh",
    "engine_return_declarations_v5.svh", "engine_return_v5.svh",
)


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def read_exact(path: Path, pin: str | None = None) -> bytes:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"missing source: {path}")
    raw = path.read_bytes()
    if not raw:
        raise ValueError(f"empty source: {path}")
    if pin is not None and sha(raw) != pin:
        raise ValueError(f"source SHA256 mismatch: {path}; got {sha(raw)}")
    raw.decode("utf-8")
    return raw


def verify_dependencies(repo: Path = REPO) -> None:
    for relative, pin in DEPENDENCIES.items():
        read_exact(repo / relative, pin)


def private_output(value: Path, inputs: list[Path]) -> Path:
    out = value.expanduser().resolve()
    if out.exists():
        raise ValueError(f"output must be new: {out}")
    for parent in (out, *out.parents):
        if (parent / ".git").exists():
            raise ValueError("generated derivatives and simulation output must stay outside every Git checkout")
    for value in inputs:
        source = value.expanduser().resolve()
        if out == source or out.is_relative_to(source) or source.is_relative_to(out):
            raise ValueError(f"output overlaps an input: {source}")
    return out


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load transformer: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_v5():
    verify_dependencies()
    # Avoid inheriting an unrelated Python module named producer from sys.path.
    load_module(REPO / "experiments/dma-fetch-return-v5/tools/producer.py", "producer")
    return load_module(REPO / "experiments/dma-fetch-return-v5/tools/build.py",
                       "composition_frozen_v5")


def derive(engine: Path, write_controller: Path | None, controller: Path | None,
           v5_generated: Path | None, witness_original: bool) -> tuple[dict[str, bytes], dict]:
    upstream = load_v5()
    originals = {}

    def source(path: Path, pin: str | None = None) -> bytes:
        raw = read_exact(path, pin)
        originals[str(path.expanduser().resolve())] = sha(raw)
        return raw

    engine_raw = source(engine, ENGINE_V4_SHA)
    generated = upstream.derive(engine_raw)
    write_name = "altpcie_dynamic_control_write_v4.sv"
    if write_controller is not None:
        # In addition to the frozen builder's original-source check, pin the
        # entire write output, including its retained legacy status region.
        generated[write_name] = upstream.V4.write_controller(source(write_controller))
        if sha(generated[write_name].encode()) != WRITE_V4_SHA:
            raise ValueError("regenerated write controller differs from the exact V4 pin")
    elif v5_generated is not None:
        generated[write_name] = source(v5_generated / write_name, WRITE_V4_SHA).decode("utf-8")
    else:
        raise ValueError("--controller also requires --write-controller (original licensed source)")
    read_name = "altpcie_dynamic_control_fetch_return_v5.sv"
    if controller is not None:
        generated[read_name] = upstream.controller(source(controller, upstream.V4.CONTROLLER_SHA))
        if sha(generated[read_name].encode()) != READ_V5_SHA:
            raise ValueError("regenerated V5 read controller differs from supplied source identity")
    elif v5_generated is not None:
        generated[read_name] = source(v5_generated / read_name, READ_V5_SHA).decode("utf-8")
        # Recompute every existing V5 source. Never accept an edited manifest
        # and edited engine as proof of the engine's provenance.
        for name, text in generated.items():
            raw = source(v5_generated / name)
            if raw != text.encode("utf-8"):
                raise ValueError(f"V5 file does not regenerate from pinned inputs: {name}")
    else:
        raise ValueError("one of --controller or --v5-generated is required")
    if sha(generated["controller_consumer_return_v5.svh"].encode()) != CONSUMER_INCLUDE_SHA:
        raise ValueError("controller consumer include differs from supplied source identity")
    seed_hashes = {name: sha(text.encode("utf-8")) for name, text in generated.items()}
    # Isolated sizing candidate shared by both consumer-order variants.
    # The original engine and v1-v3 evidence remain unmodified.
    engine_name = "altpcieav_dma_rd_fetch_return_v5.sv"
    sizing_path = ROOT / "tools/request_sizing.py"
    source(sizing_path)
    sizing = load_module(sizing_path, "composition_request_sizing")
    generated[engine_name] = sizing.repair(generated[engine_name])
    repair_path = ROOT / "tools/repair.py"
    source(repair_path)
    if not witness_original:
        repair = load_module(repair_path, "composition_order_repair")
        generated = repair.derive(generated)
    if not isinstance(generated, dict) or not all(isinstance(v, str) for v in generated.values()):
        raise ValueError("repair must return a complete mapping of UTF-8 source names to text")
    generated["dma_status_v2_pkg.sv"] = source(
        REPO / "experiments/dma-status-v2/rtl/dma_status_v2_pkg.sv",
        DEPENDENCIES["experiments/dma-status-v2/rtl/dma_status_v2_pkg.sv"]).decode("utf-8")
    for relative in ("rtl/dma_fetch_composition_v1.sv", "tests/dma_fetch_composition_v1_tb.sv"):
        path = ROOT / relative
        generated[path.name] = source(path).decode("utf-8")
    missing = set(SOURCES + INCLUDES) - generated.keys()
    if missing:
        raise ValueError(f"incomplete generated composition: {sorted(missing)}")
    raw_outputs = {name: text.encode("utf-8") for name, text in generated.items()}
    for name in raw_outputs:
        if Path(name).name != name or name in (".", ".."):
            raise ValueError(f"nonlocal generated output name: {name}")
    report = {
        "format": FORMAT, "base_commit": BASE_COMMIT,
        "variant": "original-order-witness" if witness_original else "ordered-composition",
        "dependency_sha256": DEPENDENCIES, "inputs": originals,
        "seed_outputs": seed_hashes,
        "outputs": {name: sha(raw) for name, raw in raw_outputs.items()},
        "changed_seed_outputs": [name for name, old in seed_hashes.items()
                                 if sha(raw_outputs[name]) != old],
        "compile_sources": list(SOURCES), "include_sources": list(INCLUDES),
        "production_contract_valid": False, "driver_admission_enabled": False,
        "native_vcs_executed": False, "rtl_refinement_proved": False,
        "request_sizing_candidate": "current_remaining_mrrs_page_min",
    }
    return raw_outputs, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True, help="exact private V4 engine")
    parser.add_argument("--write-controller", type=Path,
                        help="original licensed altpcie_dynamic_control.sv; required with --controller")
    read = parser.add_mutually_exclusive_group(required=True)
    read.add_argument("--controller", type=Path, help="exact private V3 read controller")
    read.add_argument("--v5-generated", type=Path, help="existing complete V5 generated directory")
    parser.add_argument("--witness-original", action="store_true",
                        help="leave original copier unchanged for the expected order-failure witness")
    parser.add_argument("--out", type=Path, required=True, help="new private directory outside Git")
    args = parser.parse_args()
    try:
        inputs = [ROOT, args.engine]
        inputs += [v for v in (args.controller, args.write_controller, args.v5_generated) if v is not None]
        out = private_output(args.out, inputs)
        generated, report = derive(args.engine, args.write_controller, args.controller,
                                   args.v5_generated, args.witness_original)
        report["builder_sha256"] = sha(Path(__file__).read_bytes())
        out.mkdir(mode=0o700, parents=True, exist_ok=False)
        for name, raw in generated.items():
            (out / name).write_bytes(raw)
        (out / "source_manifest.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"GENERATED ONLY ({report['variant']}): {out}; no simulator or proof executed")
        return 0
    except (OSError, ValueError, KeyError, UnicodeError) as error:
        parser.exit(2, f"REFUSED: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
