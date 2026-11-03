// Single-work-item streaming kernels; global size = local size = 1.
// All buffers are disjoint, 64-byte aligned, and contain count uint elements.
// uint16 is a 512-bit language vector, not proof of a 512-bit external port.
__kernel void stream_copy512(__global const uint16 *restrict input,
                             __global uint16 *restrict output, uint count) {
  ulong blocks = (ulong)count / 16;
  for (ulong i = 0; i < blocks; ++i) output[i] = input[i];
  __global const uint *scalar_in = (__global const uint *)input;
  __global uint *scalar_out = (__global uint *)output;
  for (ulong i = blocks * 16; i < (ulong)count; ++i)
    scalar_out[i] = scalar_in[i];
}

__kernel void stream_triad512(__global const uint16 *restrict a,
                              __global const uint16 *restrict b,
                              __global uint16 *restrict output,
                              uint scale, uint count) {
  ulong blocks = (ulong)count / 16;
  for (ulong i = 0; i < blocks; ++i) output[i] = a[i] + b[i] * scale;
  __global const uint *scalar_a = (__global const uint *)a;
  __global const uint *scalar_b = (__global const uint *)b;
  __global uint *scalar_out = (__global uint *)output;
  for (ulong i = blocks * 16; i < (ulong)count; ++i)
    scalar_out[i] = scalar_a[i] + scalar_b[i] * scale;
}
