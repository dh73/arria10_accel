# Descriptor ingress adapter

The write controller presents a retained ready/valid offer. The native write
producer instead enqueues on every cycle with input valid, without testing
ready. Directly connecting these interfaces duplicates an offer during stalls.

`build.py` derives a separately named application candidate from an exact private
source snapshot. It changes only the module name and the native valid connection:

```systemverilog
.WrDmaRxValid_i(AvWrDmaRxValid_i && AvWrDmaRxReady_o)
```

Data and ready remain unchanged. The controller and native FIFO therefore accept
on the same edge. Native ready is derived from FIFO occupancy, independently of
valid; this conversion adds no combinational ready/valid loop or storage.
Reset behavior remains the containing design's responsibility.

This candidate is not integrated or behaviorally qualified. Required integration
coverage includes prolonged native backpressure, queued distinct descriptors,
FIFO wrap, reset, and exactly one native enqueue per controller acceptance.
The earlier containing hierarchy's elaboration does not establish this contract.

```sh
python3 experiments/dma-ingress-v1/build.py \
  --source /absolute/path/to/altpcieav_256_app_fetch_v4.sv \
  --output /new/private/path/altpcieav_256_app_ingress_v1.sv
```
