import Std.Tactic

namespace AsusA10

/-- Nat abstraction of the subtraction-based uint64_t guard in dma_range.hpp. -/
def ValidRange (capacity offset bytes : Nat) : Prop :=
  offset ≤ capacity ∧ bytes ≤ capacity - offset

theorem guard_iff_sum (capacity offset bytes : Nat) :
    ValidRange capacity offset bytes ↔ offset + bytes ≤ capacity := by
  unfold ValidRange
  omega

theorem every_byte_inside (capacity offset bytes index : Nat)
    (valid : ValidRange capacity offset bytes) (access : index < bytes) :
    offset + index < capacity := by
  have bound := (guard_iff_sum capacity offset bytes).mp valid
  omega

theorem accepted_sum_fits_uint64 (capacity offset bytes : Nat)
    (capacityFits : capacity < 2^64) (valid : ValidRange capacity offset bytes) :
    offset + bytes < 2^64 := by
  have bound := (guard_iff_sum capacity offset bytes).mp valid
  omega

theorem empty_end_valid (capacity : Nat) : ValidRange capacity capacity 0 := by
  unfold ValidRange
  omega

theorem ddr_line_address_fits (address : Nat) (inside : address < 2^31) :
    address / 64 < 2^25 ∧ address % 64 < 64 := by
  omega

end AsusA10

#print axioms AsusA10.guard_iff_sum
#print axioms AsusA10.every_byte_inside
#print axioms AsusA10.accepted_sum_fits_uint64
#print axioms AsusA10.empty_end_valid
#print axioms AsusA10.ddr_line_address_fits
