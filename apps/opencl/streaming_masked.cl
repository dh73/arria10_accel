// Single work item; disjoint, 64-byte-aligned buffers of count uint elements.
// One masked 16-lane loop handles full and partial blocks. External port width
// and throughput must be established from generated RTL and measurement.
__kernel void stream_copy_masked(__global const uint *restrict input,
                                __global uint *restrict output, uint count) {
  const ulong blocks = ((ulong)count + 15) / 16;
  for (ulong block = 0; block < blocks; ++block) {
    #pragma unroll
    for (uint lane = 0; lane < 16; ++lane) {
      const ulong i = block * 16 + lane;
      if (i < (ulong)count) output[i] = input[i];
    }
  }
}

__kernel void stream_triad_masked(__global const uint *restrict a,
                                 __global const uint *restrict b,
                                 __global uint *restrict output,
                                 uint scale, uint count) {
  const ulong blocks = ((ulong)count + 15) / 16;
  for (ulong block = 0; block < blocks; ++block) {
    #pragma unroll
    for (uint lane = 0; lane < 16; ++lane) {
      const ulong i = block * 16 + lane;
      if (i < (ulong)count) output[i] = a[i] + b[i] * scale;
    }
  }
}
