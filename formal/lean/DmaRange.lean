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

/-- Driver admission additionally rejects unknown capacity and empty requests.
    This is mathematical integer arithmetic after the C checked-add guard;
    it does not model page mapping, hardware execution or C refinement. -/
def DriverAdmission (capacity offset bytes : Nat) : Prop :=
  0 < capacity ∧ 0 < bytes ∧ offset + bytes < 2^64 ∧
    offset + bytes ≤ capacity

theorem driver_admission_range (capacity offset bytes : Nat)
    (h : DriverAdmission capacity offset bytes) :
    ValidRange capacity offset bytes := by
  apply (guard_iff_sum capacity offset bytes).mpr
  exact h.2.2.2

theorem unknown_aperture_denied (offset bytes : Nat) :
    ¬ DriverAdmission 0 offset bytes := by
  simp [DriverAdmission]

/-- A descriptor must be a subrange of the admitted request, not merely start
    inside it. This premise must be established by the actual batch builder. -/
theorem descriptor_subrange (capacity offset bytes consumed count : Nat)
    (h : DriverAdmission capacity offset bytes)
    (within : consumed + count ≤ bytes) :
    ValidRange capacity (offset + consumed) count ∧
    offset + consumed + count < 2^64 := by
  have endpoint := h.2.2
  constructor
  · apply (guard_iff_sum capacity (offset + consumed) count).mpr
    omega
  · omega

/-- Cursor invariant base and step for repeated bounded batch advancement. -/
def CursorWithin (capacity offset bytes consumed : Nat) : Prop :=
  consumed ≤ bytes ∧ ValidRange capacity (offset + consumed) (bytes - consumed)

theorem cursor_base (capacity offset bytes : Nat)
    (h : DriverAdmission capacity offset bytes) :
    CursorWithin capacity offset bytes 0 := by
  simpa [CursorWithin] using And.intro (Nat.zero_le bytes)
    (driver_admission_range capacity offset bytes h)

theorem cursor_step (capacity offset bytes consumed count : Nat)
    (h : CursorWithin capacity offset bytes consumed)
    (within : count ≤ bytes - consumed) :
    CursorWithin capacity offset bytes (consumed + count) := by
  unfold CursorWithin at h ⊢
  have endpoint := (guard_iff_sum capacity (offset + consumed)
    (bytes - consumed)).mp h.2
  constructor
  · omega
  · apply (guard_iff_sum capacity (offset + (consumed + count))
      (bytes - (consumed + count))).mpr
    omega

theorem ddr_line_address_fits (address : Nat) (inside : address < 2^31) :
    address / 64 < 2^25 ∧ address % 64 < 64 := by
  omega

/-- Ordered subtraction checks from the raw PIO window path. Alignment and
    register ownership are separate obligations; this models only bounds. -/
def WindowRange (capacity segment offset bytes : Nat) : Prop :=
  segment ≤ capacity ∧ offset ≤ capacity - segment ∧
    bytes ≤ capacity - segment - offset

theorem window_guard_iff_endpoint (capacity segment offset bytes : Nat) :
    WindowRange capacity segment offset bytes ↔
      segment + offset + bytes ≤ capacity := by
  unfold WindowRange
  omega

theorem window_access_inside (capacity segment offset bytes index : Nat)
    (h : WindowRange capacity segment offset bytes) (hi : index < bytes) :
    segment + offset + index < capacity := by
  have bound := (window_guard_iff_endpoint capacity segment offset bytes).mp h
  omega

theorem window_endpoint_fits (capacity segment offset bytes : Nat)
    (hc : capacity < 2^64) (h : WindowRange capacity segment offset bytes) :
    segment + offset + bytes < 2^64 := by
  have bound := (window_guard_iff_endpoint capacity segment offset bytes).mp h
  omega

/-- Global address conversion uses quotient/remainder by the 64 KiB window.
    A contained original request has an equally contained translated access. -/
theorem translated_window_range (capacity address bytes : Nat)
    (h : ValidRange capacity address bytes) :
    WindowRange capacity ((address / 65536) * 65536) (address % 65536) bytes := by
  apply (window_guard_iff_endpoint _ _ _ _).mpr
  have decomposition := Nat.mod_add_div address 65536
  have bound := (guard_iff_sum capacity address bytes).mp h
  omega

end AsusA10

#print axioms AsusA10.guard_iff_sum
#print axioms AsusA10.every_byte_inside
#print axioms AsusA10.accepted_sum_fits_uint64
#print axioms AsusA10.empty_end_valid
#print axioms AsusA10.ddr_line_address_fits
#print axioms AsusA10.driver_admission_range
#print axioms AsusA10.unknown_aperture_denied
#print axioms AsusA10.descriptor_subrange
#print axioms AsusA10.cursor_base
#print axioms AsusA10.cursor_step
#print axioms AsusA10.window_guard_iff_endpoint
#print axioms AsusA10.window_access_inside
#print axioms AsusA10.window_endpoint_fits
#print axioms AsusA10.translated_window_range
