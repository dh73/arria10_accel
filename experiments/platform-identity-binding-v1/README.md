# Physical shell identity binding

Binds a prepared source/build identity and the selected copy/triad CRA hashes
into a new shell copy. Source/build digests use little-endian register byte
order; kernel profile hashes retain their literal bit-vector representation.
An already-bound, missing or duplicate parameter is rejected.

Run `python3 -m unittest discover -s experiments/platform-identity-binding-v1`.
Preparation does not establish compilation, timing or physical acceptance.
