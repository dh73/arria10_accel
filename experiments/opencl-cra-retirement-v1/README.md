# OpenCL completion retirement

The test drives normal start and completion inputs while reading the generated
copy and triad completion counters. It covers isolated and consecutive reads
with completion on five neighboring clock edges.

The original counters lose completions in this test. The isolated correction
subtracts the previously returned snapshot instead of clearing the whole counter.
Both corrected counters conserve one completion across all 20 timing cases.

Generated source is retained separately. This test does not establish whole-kernel
retirement, hardware timing or physical operation.
