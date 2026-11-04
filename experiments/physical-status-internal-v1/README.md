# Physical status wiring

The preparation step keeps supervisor and DDR diagnostic status inside the
fabric and selects the ES3 board LED/control constraints. It preserves all
control/reset inputs and instantiated connections. Run it on an unbound source
template before generating the source/build identity.

```sh
python3 experiments/physical-status-internal-v1/prepare.py \
  --source INPUT_DIRECTORY --out NEW_DIRECTORY
```

Reset and containment input producers must still be integrated before fitting.
