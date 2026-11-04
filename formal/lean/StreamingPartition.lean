import Std.Tactic

/- Index arithmetic of streaming_unrolled_ip.cpp. This proves the partition
   used by the loops, not compiler refinement, memory ordering or throughput.
   Addresses and disjoint allocation validity remain backend contracts. -/
namespace StreamingPartition

def Full (n i : Nat) : Prop :=
  ∃ block lane, block < n / 16 ∧ lane < 16 ∧ i = block * 16 + lane

def Tail (n i : Nat) : Prop := n / 16 * 16 ≤ i ∧ i < n

theorem full_iff (n i : Nat) : Full n i ↔ i < n / 16 * 16 := by
  constructor
  · rintro ⟨block, lane, hb, hl, hi⟩
    omega
  · intro hi
    refine ⟨i / 16, i % 16, ?_, ?_, ?_⟩ <;> omega

theorem complete (n i : Nat) : i < n ↔ Full n i ∨ Tail n i := by
  rw [full_iff]
  unfold Tail
  omega

theorem no_overlap (n i : Nat) : ¬ (Full n i ∧ Tail n i) := by
  rw [full_iff]
  unfold Tail
  omega

theorem unique_lane (b l b' l' : Nat) (hl : l < 16) (hl' : l' < 16)
    (same : b * 16 + l = b' * 16 + l') : b = b' ∧ l = l' := by
  omega

theorem zero_has_no_access (i : Nat) : ¬ Full 0 i ∧ ¬ Tail 0 i := by
  rw [full_iff]
  unfold Tail
  omega

theorem tail_short (n : Nat) : n - n / 16 * 16 < 16 := by omega

-- Every generated index fits the original 32-bit element count and therefore
-- the uint64_t block/index expressions; no wrapped loop index is required.
theorem index_bound (n i : Nat) (hn : n < 2^32)
    (access : Full n i ∨ Tail n i) : i < 2^32 ∧ i < 2^64 := by
  have hi := (complete n i).mpr access
  omega

-- Base and step of the element-prefix coverage model. The next index is
-- covered by exactly one branch, with unique full-block coordinates above.
def Covered (n k : Nat) : Prop := ∀ i, i < k → Full n i ∨ Tail n i

theorem base (n : Nat) : Covered n 0 := by
  intro i hi
  omega

theorem step (n k : Nat) (before : Covered n k) (hk : k < n) :
    Covered n (k+1) := by
  intro i hi
  by_cases h : i < k
  · exact before i h
  · have eq : i = k := by omega
    subst i
    exact (complete n k).mp hk

#print axioms complete
#print axioms no_overlap
#print axioms unique_lane
#print axioms index_bound
#print axioms base
#print axioms step
end StreamingPartition
