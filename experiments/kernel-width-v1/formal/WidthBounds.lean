import Std
set_option maxHeartbeats 0

namespace WidthBounds
-- Byte addresses; these are arithmetic obligations, not an RTL refinement proof.
def Supported (bytes : Nat) : Prop :=
  bytes = 8 ∨ bytes = 16 ∨ bytes = 32 ∨ bytes = 64

theorem supported_positive {bytes : Nat} (h : Supported bytes) : 0 < bytes := by
  rcases h with h | h | h | h <;> omega

theorem aligned_lane_fits {address bytes : Nat}
    (hw : Supported bytes) (ha : address % bytes = 0) :
    address % 64 + bytes ≤ 64 := by
  rcases hw with h | h | h | h <;> subst bytes <;> omega

theorem enabled_byte_within_line {address bytes lane : Nat}
    (hw : Supported bytes) (ha : address % bytes = 0) (hl : lane < bytes) :
    address % 64 + lane < 64 := by
  have := aligned_lane_fits hw ha
  omega

theorem line_address_fits {address : Nat} (h : address < 2^31) :
    address / 64 < 2^25 := by omega

theorem aligned_request_within_aperture {address bytes : Nat}
    (hw : Supported bytes) (ha : address % bytes = 0)
    (hr : address < 2^31) : address + bytes ≤ 2^31 := by
  rcases hw with h | h | h | h <;> subst bytes <;> omega

theorem lane_mapping_reconstructs {address lane : Nat} :
    address / 64 * 64 + address % 64 + lane = address + lane := by omega

-- Iterating over every byte in the admitted transfer preserves line containment.
def CursorValid (address bytes cursor : Nat) : Prop :=
  cursor ≤ bytes ∧ address % 64 + cursor ≤ 64

theorem cursor_base {address bytes : Nat}
    (hw : Supported bytes) (ha : address % bytes = 0) :
    CursorValid address bytes 0 := by
  have := aligned_lane_fits hw ha
  unfold CursorValid
  omega

theorem cursor_step {address bytes cursor : Nat}
    (hw : Supported bytes) (ha : address % bytes = 0)
    (_hv : CursorValid address bytes cursor) (more : cursor < bytes) :
    CursorValid address bytes (cursor + 1) := by
  have := aligned_lane_fits hw ha
  unfold CursorValid
  omega

theorem cursor_byte_address {address bytes cursor : Nat}
    (hw : Supported bytes) (ha : address % bytes = 0)
    (hr : address < 2^31) (more : cursor < bytes) :
    address / 64 * 64 + address % 64 + cursor < 2^31 := by
  have := aligned_request_within_aperture hw ha hr
  rw [lane_mapping_reconstructs]
  omega
end WidthBounds
