import Std

/-!
Pure byte-address mapping lemmas for Lean 4.19.0 (no Mathlib).

This is NOT a proof of the RTL, CDC, ownership, reset, arbitration, liveness,
or vendor descriptor legality. It is a stateless mathematical model, so it
has no stateful base/step claim. `mask k` models bit k of a captured 32-bit
command mask; callers must establish that correspondence in the RTL/tests.

Addresses are natural numbers. The RTL must perform its end calculation in
65 bits BEFORE narrowing the accepted backend address to 25 bits. The bounds
below explain why truncation after acceptance cannot alias a high address.

Run with the exact toolchain:
  lean +leanprover/lean4:v4.19.0 UnalignedHead.lean
-/
namespace DmaUnalignedHead

def aperture : Nat := 2147483648

def base32 (a : Nat) : Nat := 32 * (a / 32)
def base64 (a : Nat) : Nat := 64 * (a / 64)
def half (a : Nat) : Nat := (a % 64) / 32

-- This is byte lane k of the original 256-bit response, without shifting.
def responseByte (a k : Nat) : Nat := base32 a + k
-- The backend sees line index a/64, plus half-select and unchanged byte lane.
def backendByte (a k : Nat) : Nat := base64 a + 32 * half a + k

theorem address_decomposition (a : Nat) : base32 a + a % 32 = a := by
  unfold base32
  omega

theorem line_half_decomposition (a : Nat) :
    base64 a + 32 * half a = base32 a := by
  unfold base64 half base32
  omega

theorem unchanged_lane (a k : Nat) : backendByte a k = responseByte a k := by
  unfold backendByte responseByte
  rw [line_half_decomposition]

theorem backend_lane_in_line (a k : Nat) (hk : k < 32) :
    32 * half a + k < 64 := by
  unfold half
  omega

-- Mask shape for an accepted unaligned read: nonempty, no enabled byte below
-- the requested start. Sparse and sub-DWORD enables above that start are valid.
def ValidHeadMask (a : Nat) (mask : Nat → Bool) : Prop :=
  (∃ k, k < 32 ∧ mask k = true) ∧
  (∀ k, k < 32 → mask k = true → a % 32 ≤ k)

theorem enabled_byte_not_before_start (a k : Nat) (mask : Nat → Bool)
    (hm : ValidHeadMask a mask) (hk : k < 32) (hen : mask k = true) :
    a ≤ responseByte a k := by
  have hlo := hm.2 k hk hen
  have hd := address_decomposition a
  unfold responseByte
  omega

-- The normalized full-beat endpoint is the aperture guard, even for a partial
-- head mask. Equality with 2 GiB is allowed because the endpoint is exclusive.
theorem accepted_beat_bytes_in_aperture (a k : Nat)
    (hend : base32 a + 32 ≤ aperture) (hk : k < 32) :
    responseByte a k < aperture := by
  unfold responseByte
  omega

theorem accepted_address_is_in_aperture (a : Nat)
    (hend : base32 a + 32 ≤ aperture) : a < aperture := by
  have hd := address_decomposition a
  have hr : a % 32 < 32 := Nat.mod_lt a (by decide)
  omega

theorem accepted_line_fits_25_bits (a : Nat)
    (hend : base32 a + 32 ≤ aperture) : a / 64 < 33554432 := by
  have ha := accepted_address_is_in_aperture a hend
  unfold aperture at ha
  omega

-- Consequently, an address at/above 2 GiB cannot be rescued by normalization.
theorem high_address_rejected (a : Nat) (ha : aperture ≤ a) :
    ¬ (base32 a + 32 ≤ aperture) := by
  intro hend
  have hb := accepted_address_is_in_aperture a hend
  omega

theorem final_valid_head (offset : Nat) (h : offset < 32) :
    base32 (aperture - 32 + offset) + 32 = aperture := by
  unfold aperture base32
  omega

-- Stateful burst execution is deliberately outside this model. This lemma
-- only proves range safety for an arbitrary selected beat of an admitted
-- aligned command with a full-precision end calculation.
theorem accepted_burst_byte (a beats i k : Nat)
    (haligned : a % 32 = 0) (hi : i < beats) (hk : k < 32)
    (hend : base32 a + 32 * beats ≤ aperture) :
    a + 32 * i + k < aperture := by
  have hd := address_decomposition a
  omega

end DmaUnalignedHead
