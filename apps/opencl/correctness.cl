// Two single-work-item kernels. Enqueue each with global size = local size = 1.
// Buffers must be disjoint and contain at least count uint elements.
// The host must order pass2 after pass1 and readback after pass2 completion.
__kernel void correctness_pass1(__global const uint *restrict a,
                                __global const uint *restrict b,
                                __global uint *restrict temporary,
                                uint count) {
  for (ulong position = 0; position < (ulong)count; ++position) {
    uint i = (uint)position;
    uint value = a[i] * 0x9e3779b1U + b[i] + i * 0x85ebca6bU;
    value ^= a[i] >> ((i % 13U) + 1U);
    uint shift = (i % 31U) + 1U;
    temporary[i] = (value << shift) | (value >> (32U - shift));
  }
}

__kernel void correctness_pass2(__global const uint *restrict temporary,
                                __global const uint *restrict b,
                                __global uint *restrict output,
                                uint count) {
  for (ulong position = 0; position < (ulong)count; ++position) {
    uint i = (uint)position;
    uint value = temporary[i] ^ (temporary[i] >> 16U);
    value *= 0x7feb352dU;
    value ^= value >> 15U;
    value *= 0x846ca68bU;
    value ^= value >> 16U;
    uint rotated = b[i] ^ i;
    output[i] = value + ((rotated << 7U) | (rotated >> 25U));
  }
}
