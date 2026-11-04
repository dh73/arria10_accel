import Init

set_option maxHeartbeats 0

-- Abstract DWORD arithmetic only. No RTL timing or finite-width refinement.
namespace RequestSizing

def size (remaining mrrs page : Nat) : Nat := min remaining (min mrrs page)

theorem remaining_bound (r m p : Nat) : size r m p ≤ r := by
  simp only [size, Nat.min_def]; split <;> split <;> omega

theorem mrrs_bound (r m p : Nat) : size r m p ≤ m := by
  simp only [size, Nat.min_def]; split <;> split <;> omega

theorem page_bound (r m p : Nat) : size r m p ≤ p := by
  simp only [size, Nat.min_def]; split <;> split <;> omega

theorem positive (r m p : Nat) (hr : 0 < r) (hm : 0 < m) (hp : 0 < p) :
    0 < size r m p := by
  simp only [size, Nat.min_def]; split <;> split <;> omega

-- BASE: zero bytes issued and the initial remaining amount conserve the total.
theorem base (total : Nat) : 0 + total = total := by omega

-- STEP: one accepted request transfers exactly its size from remaining to issued.
theorem step (total issued remaining m p : Nat)
    (h : issued + remaining = total) :
    (issued + size remaining m p) + (remaining - size remaining m p) = total := by
  have bound := remaining_bound remaining m p
  omega

theorem progress (r m p : Nat) (hr : 0 < r) (hm : 0 < m) (hp : 0 < p) :
    r - size r m p < r := by
  have h := positive r m p hr hm hp
  omega

-- page denotes the DWORD distance to the next 4 KiB boundary.
theorem no_page_crossing (offset r m : Nat) (h : offset < 1024) :
    offset + size r m (1024 - offset) ≤ 1024 := by
  have bound := page_bound r m (1024 - offset)
  omega

-- A delayed selector that chooses a newly loaded count violates the contract.
theorem stale_selector_witness : ¬ (1000 ≤ (32 : Nat)) := by decide

#print axioms step
#print axioms positive
#print axioms no_page_crossing
end RequestSizing
