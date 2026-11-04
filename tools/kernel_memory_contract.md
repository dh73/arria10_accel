# Generated memory dimensions

```sh
python3 tools/kernel_memory_contract.py /path/to/generated-project memory-contract.json
python3 -m unittest discover -s tests/host -p test_kernel_memory_contract.py -v
```

Checks each memory interface in `ipinterfaces.xml` against the exported
`kernel_system.sv` port declarations: data and byte-enable widths, directions,
address width, burst-count width, and required read/write response signals.
Missing, duplicate and mismatched declarations fail. The report includes hashes
of both inputs and the model's declared base and size.

A model aperture is not installed memory capacity. Address units, burst limits,
clock/reset behavior, ordering, and actual link/DDR bandwidth require separate
contracts and tests. Adapter width alone does not establish generated-kernel
width or throughput. This tool performs no device access.
