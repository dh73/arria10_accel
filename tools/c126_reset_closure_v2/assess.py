"""Fail-closed comparison of native C126 endpoint sets and retained checks."""
from collections import defaultdict
import json
from pathlib import Path
import re

RESET = "global_reset_reset_n[0]"
SOFT = "ed_synth_inst|emif|emif|arch|arch_inst|cal_counter_inst|non_hps.inst_sync_reset_n|din_s1"
STATUS = {"emif_status_local_cal_fail[0]", "emif_status_local_cal_success[0]",
          "emif_tg_0_traffic_gen_fail[0]", "emif_tg_0_traffic_gen_pass[0]",
          "emif_tg_0_traffic_gen_timeout[0]"}


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def tables(path):
    result = defaultdict(list)
    for record in records(path):
        result[record["panel"]].append((record["row"], record["cells"]))
    return {name: [cells for _, cells in sorted(rows)] for name, rows in result.items()}


def norm(value):
    return re.sub(r"[^a-z0-9]", "", value.lower())


def ucp(path):
    pairs = set()
    parsed = 0
    for panel, rows in tables(path).items():
        if not rows:
            continue
        header = [norm(c) for c in rows[0]]
        def column(names):
            hits = [i for i, h in enumerate(header) if h in names]
            need(len(hits) <= 1, f"Ambiguous UCP header: {rows[0]}")
            return hits[0] if hits else None
        source = column({"from", "fromnode", "sourcenode", "startpoint"})
        sink = column({"to", "tonode", "destinationnode", "endpoint"})
        if source is None or sink is None:
            continue
        from_clock = column({"fromclock", "launchclock", "sourceclock"})
        to_clock = column({"toclock", "latchclock", "destinationclock"})
        parsed += 1
        for row in rows[1:]:
            need(len(row) == len(header), f"Ragged native UCP table: {panel}")
            # Row ordinals may renumber after a removal; endpoint/clock identities may not.
            pairs.add((panel, row[source], row[sink],
                       row[from_clock] if from_clock is not None else "",
                       row[to_clock] if to_clock is not None else ""))
    need(parsed > 0, f"No detailed UCP From/To tables recognized in {path}; do not accept a count-only report")
    return pairs


def reset_sinks(pairs):
    return {p[2] for p in pairs if p[1] == RESET}


def status_pairs(pairs):
    return {(p[1], p[2]) for p in pairs if p[2] in STATUS}


def checked_paths(directory, hold_only):
    result = {}
    kinds = ["hold", "removal"] if hold_only else ["setup", "hold", "recovery", "removal"]
    expected = {f"internal_{kind}.jsonl" for kind in kinds}
    expected |= {f"chain_dreg[{stage}]_{kind}.jsonl" for stage in (0, 1)
                 for kind in kinds if kind in {"setup", "hold"}}
    present = {p.name for p in directory.glob("*.jsonl") if p.name.startswith(("internal_", "chain_"))}
    need(present == expected, f"Required timing check matrix differs in {directory}")
    for filename in sorted(expected):
        path = directory / filename
        rows = records(path)
        need(rows, f"Required timed paths missing: {path}; empty is not a passing check")
        for row in rows:
            need(len(row) == 7, f"Unexpected native timing record: {path}")
            slack = float(row[5])
            need(slack >= 0 and slack < float("inf"), f"Non-passing timing path in {path}: {row}")
        result[path.name] = sorted(rows)
    need(result, f"No internal/chain checks found in {directory}")
    return result


def ddr(path):
    data = tables(path)
    checks = 0
    for panel, rows in data.items():
        if not rows:
            continue
        header = [norm(name) for name in rows[0]]
        budget = header == ["operation", "margin"]
        indices = [i for i, name in enumerate(header) if
                   "slack" in name or name in {"setup", "hold", "recovery", "removal"}]
        need(budget or indices, f"Unknown DDR table schema in {panel}: {rows[0]}")
        final_count = 0
        for row in rows[1:]:
            need(len(row) == len(header), f"Ragged DDR table in {panel}")
            need(not any(c.strip().upper() in {"FAIL", "FAILED", "NAN"} for c in row),
                 f"Vendor DDR reports failure/NaN: {panel}: {row}")
            final = budget and norm(row[0]).startswith("final") and norm(row[0]).endswith("margin")
            for i in ([1] if budget else indices):
                text = row[i].strip()
                if not budget and text.upper() in {"N/A", "NA", "--", ""}:
                    continue
                match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))(?:\s*ns)?", text)
                need(match is not None, f"Unknown DDR slack encoding {text!r} in {panel}")
                value = float(match[1])
                need(abs(value) < float("inf"), f"Non-finite DDR value in {panel}")
                # Budget components are signed contributions, not timing slack.
                # The final margin and every reported path slack must pass.
                if not budget or final:
                    need(value >= 0, f"DDR timing failure: {panel}: {row}")
                    checks += 1
            if final:
                final_count += 1
        if budget:
            need(final_count == 1, f"Expected exactly one final DDR margin in {panel}")
    need(checks > 0, f"No numeric vendor DDR slack checks parsed in {path}")
    return data


def assess(out, baseline, mode, status):
    out = Path(out)
    need((out / "native.complete").read_text().strip() == mode, "Missing matching native completion")
    expected = {p["to"] for p in baseline["reset_endpoints"]}
    need(len(expected) == 22 and SOFT in expected, "Wrong expected reset identity set")
    corners = json.loads((out / "corners.json").read_text())
    need(corners, "No native corners")
    deltas = []
    for i, corner in enumerate(corners):
        before = out / "before" / f"corner_{i}"
        old = ucp(before / "ucp.jsonl")
        need(reset_sinks(old) == expected, f"Baseline reset endpoints differ at corner {i}")
        need(len(status_pairs(old)) == baseline["unconstrained_output_pairs"],
             f"Baseline status pair set/count differs at corner {i}")
        need({p[1] for p in status_pairs(old)} == STATUS,
             f"Baseline does not contain exactly the five status sinks at corner {i}")
        old_paths = checked_paths(before, corner["hold_only"])
        old_ddr = ddr(before / "ddr.jsonl")
        if mode == "diagnose":
            continue
        after = out / "after" / f"corner_{i}"
        new = ucp(after / "ucp.jsonl")
        allowed = {p for p in old if (p[1] == RESET and p[2] == SOFT) or (status and p[2] in STATUS)}
        need(new == old - allowed, f"Unexpected new/disappearing unconstrained paths at corner {i}")
        need(reset_sinks(new) == expected - {SOFT}, f"Hard-IP endpoint set changed at corner {i}")
        need((before / "clocks.json").read_text() == (after / "clocks.json").read_text(),
             f"Clock definitions/active clocks changed at corner {i}")
        need(old_paths == checked_paths(after, corner["hold_only"]), f"Internal or synchronizer checks changed at corner {i}")
        need(old_ddr == ddr(after / "ddr.jsonl"), f"Vendor DDR reports changed at corner {i}")
        deltas.append({"corner": corner["name"], "reset_before": 22, "reset_after": 21,
                       "status_pairs_before": len(status_pairs(old)),
                       "status_pairs_after": len(status_pairs(new))})
    return {"diagnostic_completed": True, "partial_candidate_checked": mode == "candidate",
            "status_observation_only": status, "closure_pass": False,
            "reason": "21 hard-IP reset endpoint contracts remain unresolved; no physical acceptance claimed",
            "corners": deltas, "remaining_reset_endpoints": sorted(expected - {SOFT})
            if mode == "candidate" else sorted(expected)}
