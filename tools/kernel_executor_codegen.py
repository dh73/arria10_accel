"""Compile an extracted source ABI into private C++ data; never authorizes hardware.

Production builds re-extract XML AND RTL. --snapshot is an explicit test-only
mode using the supplied qualification manifest. Both paths validate the supported
shape and embed source identities; neither claims a physical FPGA image identity.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from kernel_abi import SNAPSHOT_RETIREMENT_SHA256


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def integer(value):
    return type(value) is int


def validate(abi):
    require(isinstance(abi, dict), "ABI must be an object")
    require(abi.get("schema") in (1, 2) and type(abi.get("schema")) is int,
            "unsupported ABI schema")
    require(abi.get("scope") == "generated source only; loaded image not verified",
            "source-only identity scope required")
    require(abi.get("cra_aperture_bytes") == 512 and
            integer(abi.get("cra_aperture_bytes")), "unsupported CRA aperture")
    kernels = abi.get("kernels")
    require(isinstance(kernels, list) and len(kernels) == 2,
            "expected two generated kernels")
    names, bases = set(), set()
    for kernel in kernels:
        require(isinstance(kernel, dict), "kernel must be an object")
        name = kernel.get("name")
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_]+", name)
                and name not in names, "invalid/duplicate kernel name")
        names.add(name)
        for field in ("base", "size", "start_offset", "status_offset",
                      "finish_count_offset", "finished_bit", "finish_count_bits"):
            require(integer(kernel.get(field)), "non-integer kernel field: " + field)
        require(kernel["base"] in (0, 256) and kernel["base"] not in bases and
                kernel["size"] == 256, "unsupported/overlapping kernel windows")
        bases.add(kernel["base"])
        require(kernel["start_offset"] == 8 and kernel["status_offset"] == 0 and
                kernel["finish_count_offset"] == 48 and kernel["finished_bit"] == 1 and
                kernel["finish_count_bits"] == 2 and
                kernel.get("finish_count_clear_on_read") is True,
                "unsupported control/count contract")
        args = kernel.get("arguments")
        require(isinstance(args, list) and (len(args) == 13 if abi["schema"] == 1 else 0 < len(args) <= 32),
                "unsupported argument count")
        occupied, bit = set(), 0
        argument_names = set()
        for index, argument in enumerate(args):
            require(isinstance(argument, dict), "argument must be an object")
            name = argument.get("name")
            require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_]+", name)
                    and name not in argument_names, "invalid/duplicate argument name")
            argument_names.add(name)
            require(argument.get("kind") in ("ACL_ARG_BY_VALUE", "ACL_ARG_MEM_OBJ"),
                    "unsupported argument kind")
            for field in ("size", "rtl_bit_offset", "alignment_bytes"):
                require(integer(argument.get(field)), "non-integer argument field: " + field)
            alignment = argument['alignment_bytes']
            require(0 < alignment <= 1 << 63 and alignment & (alignment-1) == 0,
                    'invalid argument alignment')
            if abi["schema"] == 1:
                require(integer(argument.get("byte_offset")) and
                        argument["byte_offset"] == 128 + index * 8 and
                        argument["size"] == 8 and argument["rtl_bit_offset"] == index * 64,
                        "unsupported argument layout/order")
            else:
                require(argument["size"] in (4, 8) and argument["rtl_bit_offset"] == bit,
                        "unsupported packed argument width/order")
                require(argument["kind"] != "ACL_ARG_MEM_OBJ" or argument["size"] == 8,
                        "unsupported pointer width")
                pieces = argument.get("pieces")
                require(isinstance(pieces, list) and len(pieces) == argument["size"] // 4,
                        "incomplete packed argument")
                for half, piece in enumerate(pieces):
                    require(isinstance(piece, dict) and set(piece) == {
                        "byte_offset", "register_bit_offset", "argument_bit_offset", "bits"},
                        "unsupported packed piece fields")
                    require(all(integer(value) for value in piece.values()),
                            "non-integer packed piece")
                    offset, lane = piece["byte_offset"], piece["register_bit_offset"]
                    require(piece["bits"] == 32 and piece["argument_bit_offset"] == half * 32
                            and lane in (0, 32), "unsupported packed piece width/lane/order")
                    require(offset % 8 == 0 and 128 <= offset <= kernel["size"] - 8,
                            "reserved/out-of-range packed register")
                    require((offset, lane) not in occupied, "overlapping packed piece")
                    occupied.add((offset, lane))
                bit += argument["size"] * 8
    hashes = abi.get("source_sha256")
    require(isinstance(hashes, dict) and len(hashes) == 6,
            "expected XML, top, and both wrapper/agent source identities")
    for path, digest in hashes.items():
        require(isinstance(path, str) and path and not PurePosixPath(path).is_absolute()
                and all(part not in ("", ".", "..") for part in path.split("/"))
                and "\\" not in path, "invalid source path")
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest),
                "invalid SHA-256")
    require("kernel_system.sv" in hashes and
            sum(path.endswith(".bc.xml") for path in hashes) == 1 and
            sum(path.endswith("_function_wrapper.sv") for path in hashes) == 2 and
            sum(path.endswith("_function_cra_agent.sv") for path in hashes) == 2,
            "missing generated top/XML/wrapper/agent identity")
    for kernel in kernels:
        profile = kernel.get('completion_accounting', 'unqualified')
        require(profile in ('unqualified', 'delayed_snapshot_v1'),
                'unsupported completion accounting profile')
        if profile == 'delayed_snapshot_v1':
            path = 'kernel_hdl/{0}/{0}_function_cra_agent.sv'.format(kernel['name'])
            expected = SNAPSHOT_RETIREMENT_SHA256.get(kernel['name'])
            require(expected is not None and hashes.get(path) == expected,
                    'completion accounting profile does not match qualified source')
    return abi


def cpp_string(value):
    # Validated names and path text must remain single portable C++ literals.
    require(all(32 <= ord(c) < 127 for c in value), "non-ASCII source metadata")
    return json.dumps(value, ensure_ascii=True)


def source_contract(abi):
    """Canonical source identity; unsupported metadata is not silently ignored."""
    validate(abi)
    require(set(abi) == {"schema", "scope", "cra_aperture_bytes", "kernels",
                         "source_sha256"}, "unsupported ABI fields")
    required = {"name", "base", "size", "start_offset", "status_offset",
                "finish_count_offset", "finished_bit", "finish_count_bits",
                "finish_count_clear_on_read", "arguments"}
    kernels = []
    for item in abi["kernels"]:
        require(required <= set(item) <= required | {"completion_accounting"},
                "unsupported kernel fields")
        for argument in item["arguments"]:
            require(set(argument) == {"name", "size", "kind", "rtl_bit_offset", "alignment_bytes",
                                      "byte_offset" if abi["schema"] == 1 else "pieces"},
                    "unsupported argument fields")
        kernel = dict(item)
        kernel["completion_accounting"] = item.get("completion_accounting", "unqualified")
        kernels.append(kernel)
    for path in abi["source_sha256"]:
        cpp_string(path)
    return dict(abi, kernels=sorted(kernels, key=lambda k: k["base"]))


def source_contract_sha256(abi):
    data = json.dumps(source_contract(abi), sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("ascii")
    return hashlib.sha256(b"arria10/source-contract/v1\0" + data).hexdigest()


def render(abi, snapshot):
    abi = source_contract(abi)
    lines = ["// Generated by kernel_executor_codegen.py. Do not edit.",
             "// Source identity only: loaded image and CRA mapping require transport verification.",
             "aperture_bytes_ = %d;" % abi["cra_aperture_bytes"],
             "contract_sha256_ = {%s};" % ", ".join(
                 "0x%02x" % b for b in bytes.fromhex(source_contract_sha256(abi))),
             "validation_ = SourceValidation::%s;" %
             ("SuppliedSnapshot" if snapshot else "Reextracted"), "kernels_ = {"]
    for kernel in abi["kernels"]:
        lines.append("  {%s, %s, true, {" % (
            cpp_string(kernel["name"]), ", ".join(str(kernel[field]) for field in (
                "base", "size", "start_offset", "status_offset", "finish_count_offset",
                "finished_bit", "finish_count_bits"))))
        for argument in kernel["arguments"]:
            pieces = argument.get("pieces", [
                dict(byte_offset=argument.get("byte_offset"), register_bit_offset=0,
                     argument_bit_offset=0, bits=32),
                dict(byte_offset=argument.get("byte_offset"), register_bit_offset=32,
                     argument_bit_offset=32, bits=32)])
            lines.append("    {%s, %d, %s, %d, {%s}, UINT64_C(%d)}," % (
                cpp_string(argument["name"]), pieces[0]["byte_offset"],
                "true" if argument["kind"] == "ACL_ARG_MEM_OBJ" else "false",
                argument["size"], ", ".join("{%d, %d, %d}" % (
                    p["byte_offset"], p["register_bit_offset"], p["argument_bit_offset"])
                    for p in pieces), argument["alignment_bytes"]))
        profile = ('DelayedSnapshotV1' if kernel.get('completion_accounting') ==
                   'delayed_snapshot_v1' else 'Unqualified')
        lines.append("  }, CompletionAccounting::%s}," % profile)
    lines += ["};", "hashes_ = {"]
    for path, digest in sorted(abi["source_sha256"].items()):
        lines.append("  {%s, %s}," % (cpp_string(path), cpp_string(digest)))
    lines += ["};", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--source", type=Path)
    mode.add_argument("--snapshot", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--packed", action="store_true",
                        help="extract schema 2 packed 32/64-bit arguments from source")
    args = parser.parse_args()
    if args.source is not None:
        from kernel_abi import extract
        abi = extract(args.source, packed=args.packed)
    else:
        require(not args.packed, "--packed requires --source; snapshot schema is explicit")
        abi = json.loads(args.snapshot.read_text(), object_pairs_hook=unique_object)
    content = render(abi, args.snapshot is not None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Validate completely before replacing an existing build product.
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(content)
    temporary.replace(args.output)


if __name__ == "__main__":
    main()
