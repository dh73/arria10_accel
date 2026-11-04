import Std.Tactic

/- Arithmetic model of the masked streaming candidate. No compiler/RTL
   refinement or memory safety beyond index bounds is implied. -/
namespace StreamingMasked

def Visits (n i : Nat) : Prop := ∃ b l,
  b < (n+15)/16 ∧ l < 16 ∧ i = b*16+l ∧ i < n

theorem exact_coverage (n i : Nat) : Visits n i ↔ i < n := by
  constructor
  · rintro ⟨b,l,hb,hl,hi,hn⟩; exact hn
  · intro hi
    refine ⟨i/16,i%16,?_,?_,?_,hi⟩ <;> omega

theorem unique_visit (b l b' l' : Nat) (hl : l < 16) (hl' : l' < 16)
    (same : b*16+l = b'*16+l') : b=b' ∧ l=l' := by omega

theorem zero_empty (i : Nat) : ¬ Visits 0 i := by
  rw [exact_coverage]; omega

-- C++ widens count before adding 15; block and index arithmetic stay in u64.
theorem no_index_wrap (n b l : Nat) (hn : n < 2^32)
    (hb : b < (n+15)/16) (hl : l < 16) :
    n+15 < 2^64 ∧ b*16+l < 2^64 := by omega

def Covered (n k : Nat) : Prop := ∀ i, i < k → Visits n i

theorem base (n : Nat) : Covered n 0 := by intro i h; omega

theorem step (n k : Nat) (h : Covered n k) (hk : k < n) :
    Covered n (k+1) := by
  intro i hi
  by_cases old : i < k
  · exact h i old
  · apply (exact_coverage n i).mpr; omega

#print axioms exact_coverage
#print axioms unique_visit
#print axioms no_index_wrap
#print axioms base
#print axioms step
end StreamingMasked
