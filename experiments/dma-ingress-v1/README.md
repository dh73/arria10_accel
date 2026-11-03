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

## Native ingress regression

`run.py` compares the original and adapted port expressions against the actual
native producer and descriptor FIFO. `ingress_tb.sv` retains each offer until
accepted and checks every descriptor popped from the native FIFO. The positive
case requires 192 admissions, enqueues, pops and commands across four reset
epochs, with observed backpressure. The original case must produce the specific
extra-enqueue failure; unrelated errors cannot satisfy the negative control.
Memory responses and the downstream metadata consumer are fixture drivers.
This does not exercise the full controller, packetizer or board.

Supply the exact application, corrected count producer, FIFO and compatible
model sources as private inputs. Tool commands are explicit; executable symlinks
are preserved. Preparation records hashes and commands without executing them:

```sh
python3 experiments/dma-ingress-v1/run.py \
  --application /private/application.sv --producer /private/producer.sv \
  --fifo /private/fifo.sv --model /private/altera_mf.v \
  --lpm /private/220model.v --compiler /absolute/compiler \
  --runner /absolute/runner --output /new/private/build --prepare-only
```

For execution, omit `--prepare-only` and select another fresh output directory.

Observed native result: the original connection enqueued five descriptors for
four accepted offers. The adapted connection passed 192 distinct descriptors,
2,333 stalled-offer cycles and four reset epochs with matching enqueue/pop/command
counts. Seven input hashes and both native logs were checked. Existing producer
literal-width, RAM-port and metadata-count-width warnings remain recorded; this
result is not a blanket warning waiver. Full-controller integration remains open.

The prepared `controller_ingress_tb.sv` composition replaces the synthetic offer
source with the actual write controller. It configures descriptor-table fetching
through CSRs, supplies 48 distinct descriptors through DTS, and checks all native
FIFO pops and memory commands while the native producer applies backpressure.
Run with both `--controller` and `--controller-tx` pointing to the source-pinned
v4 controller and its include. Compatible model files are explicit inputs.
This composition is prepared but not yet qualified; its memory-return and
metadata-consumer fixtures still exclude packetization and host retirement.
