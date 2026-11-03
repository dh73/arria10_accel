# Shell identity qualification

The read-only 256-byte identity block publishes source/build hashes, explicit
resource mapping, session/epoch and coherent supervisor status. No BAR address
is assumed. The C++ decoder rejects incompatible, torn, stale and malformed
snapshots. A matching snapshot grants no hardware admission.

Four host/generator tests, native RTL-to-C++ transcript checks and thirteen
Lean 4.19 obligations pass. The model covers initialization, preservation,
monotonic publication and sticky sequence exhaustion; it is not RTL refinement.

```sh
cmake -S host -B build/identity -DA10_BUILD_DMA_LIFECYCLE=OFF -DA10_KERNEL_EXECUTOR_SNAPSHOT_ONLY=ON
cmake --build build/identity
ctest --test-dir build/identity --output-on-failure
python3 tests/shell_identity_v1/run.py --host-test build/identity/a10_shell_identity_test --work build/identity-native --vcs "$RTL_COMPILER" --runner "$RTL_RUNNER" --lean "$LEAN_419"
```

The native output directory must be new. Snapshot mode is a test fixture.
Production generation uses `tools/shell_identity_codegen.py prepare` with actual
extracted source and explicit mappings. Its `bind` and `check` operations record
the full output-file hash separately, avoiding a circular bitstream self-hash.
They establish byte associations, not image authenticity or proof of loading.

Next gates: real shell management decode, nonreused context across reset,
continuous driver/device custody and physical loaded-image association.
Production driver admission remains disabled.
