import Std.Tactic

/- Arithmetic model of Capture's high/low/high stamps and intervening words.
   Assumptions: ordered reads, one common reset epoch, no sequence wrap,
   atomic snapshot publication, and payload immutable at a given sequence.
   These are interface contracts, not a proof of RTL refinement or PCIe order. -/
namespace DdrSnapshot

def radix : Nat := 4294967296

theorem stamp_exact (a b c : Nat) (ab : a ≤ b) (bc : b ≤ c)
    (sameHigh : a / radix = c / radix) :
    (a / radix) * radix + b % radix = b := by
  unfold radix at *
  omega

theorem unchanged_between (a x b : Nat) (ax : a ≤ x) (xb : x ≤ b)
    (same : a = b) : x = a := by omega

-- Base and step for a monotonically advancing, non-wrapping sequence trace.
def advance (s : Nat) (capture : Bool) : Nat :=
  if capture then s + 1 else s

theorem reset_base : (0 : Nat) ≤ 0 := Nat.le_refl 0

theorem advance_step (s : Nat) (capture : Bool) : s ≤ advance s capture := by
  cases capture <;> simp [advance]

-- Each of the fourteen sampled DWORDs is from the same snapshot when the
-- exact surrounding stamps agree. Includes both halves of every counter.
theorem words_coherent (payload : Nat → Nat → Nat)
    (seq word : Nat → Nat) (first last : Nat)
    (bounds : ∀ i, i < 14 → first ≤ seq i ∧ seq i ≤ last)
    (sampled : ∀ i, i < 14 → word i = payload (seq i) i)
    (accepted : first = last) :
    ∀ i, i < 14 → word i = payload first i := by
  intro i hi
  have h := unchanged_between first (seq i) last (bounds i hi).1
    (bounds i hi).2 accepted
  simpa [h] using sampled i hi

theorem accepted_capture_coherent (a b c d e f : Nat)
    (ab : a ≤ b) (bc : b ≤ c) (de : d ≤ e) (ef : e ≤ f)
    (beforeHigh : a / radix = c / radix)
    (afterHigh : d / radix = f / radix)
    (accepted : (a / radix) * radix + b % radix =
                (d / radix) * radix + e % radix)
    (payload : Nat → Nat → Nat) (seq word : Nat → Nat)
    (bounds : ∀ i, i < 14 → b ≤ seq i ∧ seq i ≤ e)
    (sampled : ∀ i, i < 14 → word i = payload (seq i) i) :
    ∀ i, i < 14 → word i = payload b i := by
  rw [stamp_exact a b c ab bc beforeHigh,
      stamp_exact d e f de ef afterHigh] at accepted
  exact words_coherent payload seq word b e bounds sampled accepted

end DdrSnapshot
