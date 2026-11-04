# Physical control binding

Removes fixture-only stop and diagnostic-clear pads from the physical shell.
Epoch loss drives the independent stop input. BAR2 QUIESCE remains the host
stop command; all command, admission and fault connections are preserved.
Pending diagnostics remain latched until coordinated cold reset.

Prepare an unbound template, then regenerate its source/build identity:

```sh
python3 experiments/physical-control-binding-v1/prepare.py \
  --source INPUT_DIRECTORY --out NEW_DIRECTORY
```

Common-reset and reset-containment producers remain required external inputs.
This preparation does not certify reset recovery or physical implementation.
