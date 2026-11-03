"""Compile an extracted source ABI into private C++ data; never authorizes hardware.

Production builds re-extract XML AND RTL. --snapshot is an explicit test-only
mode using the supplied qualification manifest. Both paths validate the supported
shape and embed source identities; neither claims a physical FPGA image identity.
"""
import argparse
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
    require(abi.get("schema") == 1 and type(abi.get("schema")) is int,
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
        require(isinstance(args, list) and len(args) == 13, "expected thirteen arguments")
        argument_names = set()
        for index, argument in enumerate(args):
            require(isinstance(argument, dict), "argument must be an object")
            name = argument.get("name")
            require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_]+", name)
                    and name not in argument_names, "invalid/duplicate argument name")
            argument_names.add(name)
            for field in ("byte_offset", "size", "rtl_bit_offset"):
                require(integer(argument.get(field)), "non-integer argument field: " + field)
            require(argument["byte_offset"] == 128 + index * 8 and
                    argument["size"] == 8 and argument["rtl_bit_offset"] == index * 64,
                    "unsupported argument layout/order")
            require(argument.get("kind") in ("ACL_ARG_BY_VALUE", "ACL_ARG_MEM_OBJ"),
                    "unsupported argument kind")
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


def render(abi, snapshot):
    validate(abi)
    lines = ["// Generated by kernel_executor_codegen.py. Do not edit.",
             "// Source identity only: loaded image and CRA mapping require transport verification.",
             "aperture_bytes_ = %d;" % abi["cra_aperture_bytes"],
             "validation_ = SourceValidation::%s;" %
             ("SuppliedSnapshot" if snapshot else "Reextracted"), "kernels_ = {"]
    for kernel in abi["kernels"]:
        lines.append("  {%s, %s, true, {" % (
            cpp_string(kernel["name"]), ", ".join(str(kernel[field]) for field in (
                "base", "size", "start_offset", "status_offset", "finish_count_offset",
                "finished_bit", "finish_count_bits"))))
        for argument in kernel["arguments"]:
            lines.append("    {%s, %d, %s}," % (cpp_string(argument["name"]),
                argument["byte_offset"], "true" if argument["kind"] == "ACL_ARG_MEM_OBJ" else "false"))
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
    args = parser.parse_args()
    if args.source is not None:
        from kernel_abi import extract
        abi = extract(args.source)
    else:
        abi = json.loads(args.snapshot.read_text(), object_pairs_hook=unique_object)
    content = render(abi, args.snapshot is not None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Validate completely before replacing an existing build product.
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(content)
    temporary.replace(args.output)


if __name__ == "__main__":
    main()
