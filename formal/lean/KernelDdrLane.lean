import Std.Tactic

namespace AsusA10.KernelDdrLane

/-- Byte address to a 64-byte DDR line. -/
def line (address : Nat) : Nat := address / 64

/-- 8-byte lane within a DDR line. Requires an aligned accepted request. -/
def lane (address : Nat) : Nat := (address % 64) / 8

theorem lane_bounded (address : Nat) : lane address < 8 := by
  unfold lane
  omega

theorem aligned_offset (address : Nat) (aligned : address % 8 = 0) :
    address % 64 = 8 * lane address := by
  unfold lane
  omega

theorem reconstruct (address : Nat) (aligned : address % 8 = 0) :
    64 * line address + 8 * lane address = address := by
  have h := aligned_offset address aligned
  unfold line
  omega

theorem transfer_stays_in_line (address byte : Nat)
    (aligned : address % 8 = 0) (byteInWord : byte < 8) :
    (address + byte) / 64 = line address := by
  have h := aligned_offset address aligned
  have l := lane_bounded address
  unfold line
  omega

theorem byte_position (address byte : Nat)
    (aligned : address % 8 = 0) (byteInWord : byte < 8) :
    (address + byte) % 64 = 8 * lane address + byte := by
  have h := aligned_offset address aligned
  have l := lane_bounded address
  omega

theorem aperture_bounds (address : Nat)
    (aligned : address % 8 = 0) (inside : address < 2^31) :
    line address < 2^25 ∧ address + 8 ≤ 2^31 := by
  unfold line
  omega

end AsusA10.KernelDdrLane

#print axioms AsusA10.KernelDdrLane.lane_bounded
#print axioms AsusA10.KernelDdrLane.aligned_offset
#print axioms AsusA10.KernelDdrLane.reconstruct
#print axioms AsusA10.KernelDdrLane.transfer_stays_in_line
#print axioms AsusA10.KernelDdrLane.byte_position
#print axioms AsusA10.KernelDdrLane.aperture_bounds
