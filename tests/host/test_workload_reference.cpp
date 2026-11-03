#include "asus_a10/workload_reference.hpp"
#include <iostream>

// Python unbounded-integer golden values, including both products overflowing 32 bits.
static_assert(asus_a10::workload_reference(0x00000000U, 0x00000000U, 0x00000000U) == 0x00000000U);
static_assert(asus_a10::workload_reference(0xffffffffU, 0xffffffffU, 0xffffffffU) == 0xf2328bb8U);
static_assert(asus_a10::workload_reference(0xffffffffU, 0x00000000U, 0x00000000U) == 0xddbcab7aU);
static_assert(asus_a10::workload_reference(0x00000000U, 0xffffffffU, 0x0000001fU) == 0xfaef9c1bU);
static_assert(asus_a10::workload_reference(0x80000000U, 0x7fffffffU, 0x0000000dU) == 0xcbd392f3U);
static_assert(asus_a10::workload_reference(0x12345678U, 0x87654321U, 0x0000001eU) == 0x59d21a3fU);
static_assert(asus_a10::workload_reference(0xffffffffU, 0xffffffffU, 0x00000020U) == 0xc943935dU);
static_assert(asus_a10::workload_reference(0xffffffffU, 0xffffffffU, 0x80000000U) == 0xc6683f04U);
int main() { std::cout << "workload reference golden vectors: PASS\n"; }
