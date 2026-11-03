# Checked scope

RetirementV2.lean is an explicit mathematical transition model, not an RTL translation/equivalence proof. Lean4.19.0 (commit6caaee842e94) checked reset/base, legal-event step, reachable induction, same-edge failure exclusion, increasing nonwrapping epoch, stale/foreign ACK rejection, and finite queue count/capacity. No sorry or custom axioms. Printed dependencies: standard propext and Quot.sound; stale-epoch theorem has none.

The invariant is issued=released+pending_tags and enqueued=accepted+pending_commands. Under legal-event guards, closed+zero-debt+no-failure implies all accounted work retired. Legal events are assumptions to refine against RTL. Natural counters do not prove finite RTL widths. No FIFO data ordering, admission-prefix ordering, fairness, transport integrity, PCIe visibility, Linux barrier semantics or hardware liveness is proved.

Required RTL refinement: exact MRd, tag release, accepted header, and last accepted Avalon events; owner identity throughout pipelines; no illegal header after sealing; finite capacity; exact ACK matching; same-edge error priority. PCIe tags carry no owner epoch after reuse. Reset establishes an accounting base, not a drain of old external traffic or permission to unpin. Local posted acceptance is not host observation.

## Actual invocation

```sh
LEAN_BIN=/absolute/lean-4.19.0-linux/bin/lean sh formal/check_lean.sh
```

The workspace downloaded official Lean4.19.0 release archive, SHA256 `6fe3ce97a58f44e2b3567d455b994eacec5bfe9ae7774f2a573444480ba813fe`. Startup required an isolated compatibility shim redirecting only the process's own /proc/<pid>/exe lookup to /proc/self/exe because of PID namespace mismatch. No proof-checking code changed. Fresh invocation with that runtime exited0 and printed the stated axiom dependencies. Normal host use needs no shim.

## Requested execution discovery

No vcs/vcs-run/lean/lake/elan/jg initially on PATH. An existing /tmp/jasper-v1470-runtime/bin_atlas/jg was found but not invoked. No VCS or Jasper run is claimed.

Inspected Drive formal_tool (`1BzHAtgmvTXQlU_He9Pt89eqbNXpUTgMO`) and logs2 (`1VxmNpFpw2tlEpavMfbLMTctMVeFbff0d`). Read formal_tool/README_CONNECTOR_VERIFIED.txt (`1ZdX_2R_wsvwKovzgEldUyU2G0kwW1lLs`): five checksum-verified runtime parts, extraction/smoke, then local bin_atlas/jg -batch -tcl. Read logs2/logs2_chido/README.md (`1Cl2utlZRwGUz9s-s1f9e8Wt-EpnrbxKO`): native Dollar build/package/test and local launcher.

Callable schemas exposed file access and local execution, not an online EDA job gateway. The bridge-named folder held archived evidence, not a service or fresh result.
