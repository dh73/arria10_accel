import Std

set_option maxHeartbeats 0

/-!
Arithmetic obligations for the 256-bit descriptor-return route.
Addresses are unsigned 64-bit values; interval arithmetic is widened to 65 bits.
These are combinational arithmetic theorems under the stated range premises,
not a proof of the RTL counter, handshake, memory visibility or transport fence.
-/
namespace DmaFetchReturnAddress

def u64 : Nat := 18446744073709551616
def u65 : Nat := 36893488147419103232

theorem burstEndFits {address beats : Nat}
    (addressWidth : address < u64) (burstRange : beats ≤ 16) :
    address + beats * 32 < u65 := by
  unfold u64 at addressWidth
  unfold u65
  omega

theorem tableEndFits {base entries : Nat}
    (baseWidth : base < u64) (tableRange : entries ≤ 128) :
    base + entries * 32 < u65 := by
  unfold u64 at baseWidth
  unfold u65
  omega

theorem beatFitsBurst {address accepted beats : Nat}
    (beforeLast : accepted < beats) :
    address + accepted * 32 + 32 ≤ address + beats * 32 := by omega

theorem ordinalFits {delta entries : Nat}
    (entryRange : entries ≤ 128) (admitted : delta / 32 < entries) :
    delta / 32 < 128 ∧ (delta / 32) % 128 = delta / 32 := by omega

theorem alignedAddressRoundtrip {base address : Nat}
    (lowerBound : base ≤ address) (aligned : (address - base) % 32 = 0) :
    base + ((address - base) / 32) * 32 = address := by omega

theorem wholeEntryInside {base address entries : Nat}
    (lowerBound : base ≤ address) (aligned : (address - base) % 32 = 0)
    (admitted : (address - base) / 32 < entries) :
    address + 32 ≤ base + entries * 32 := by omega

-- A valid accepted beat remains within its admitted table. Truncating the
-- computed ordinal to seven bits therefore preserves its value exactly.
theorem sevenBitDestination {base address entries : Nat}
    (lowerBound : base ≤ address) (aligned : (address - base) % 32 = 0)
    (entryRange : entries ≤ 128) (admitted : (address - base) / 32 < entries) :
    base + (((address - base) / 32) % 128) * 32 = address ∧
    address + 32 ≤ base + entries * 32 := by
  have exactIndex := (ordinalFits entryRange admitted).2
  rw [exactIndex]
  exact ⟨alignedAddressRoundtrip lowerBound aligned,
         wholeEntryInside lowerBound aligned admitted⟩

end DmaFetchReturnAddress
