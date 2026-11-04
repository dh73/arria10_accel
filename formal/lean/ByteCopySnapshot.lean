import Std.Tactic

/- Model of DriverByteCopy's capture-before-write algorithm. The initial source
   snapshot must be completed and immutable before any destination chunk writes.
   Each chunk changes exactly its selected bytes. Addresses here are unbounded
   Naturals: C++ aperture/overflow checks, DMA/RTL refinement, concurrent external
   writers and physical visibility are separate obligations. -/
namespace ByteCopySnapshot
abbrev Memory := Nat → UInt8

def expected (initial snapshot : Memory) (destination done : Nat) : Memory :=
  fun a => if destination ≤ a ∧ a < destination + done
           then snapshot (a - destination) else initial a

def writeChunk (memory snapshot : Memory) (destination done count : Nat) : Memory :=
  fun a => if destination + done ≤ a ∧ a < destination + done + count
           then snapshot (a - destination) else memory a

theorem base (initial snapshot : Memory) (destination : Nat) :
    expected initial snapshot destination 0 = initial := by
  funext a
  have h : ¬ (destination ≤ a ∧ a < destination + 0) := by omega
  simp only [expected]
  rw [if_neg h]

theorem step (initial snapshot : Memory) (destination done count : Nat) :
    writeChunk (expected initial snapshot destination done) snapshot destination done count =
      expected initial snapshot destination (done + count) := by
  funext a
  by_cases hn : destination ≤ a ∧ a < destination + (done + count)
  · by_cases hc : destination + done ≤ a ∧ a < destination + done + count
    · simp [writeChunk, expected, hc, hn]
    · have hp : destination ≤ a ∧ a < destination + done := by omega
      simp [writeChunk, expected, hc, hn, hp]
  · have hc : ¬ (destination + done ≤ a ∧ a < destination + done + count) := by omega
    have hp : ¬ (destination ≤ a ∧ a < destination + done) := by omega
    simp [writeChunk, expected, hc, hn, hp]

def run (memory snapshot : Memory) (destination done : Nat) : List Nat → Memory
  | [] => memory
  | count :: counts => run (writeChunk memory snapshot destination done count)
      snapshot destination (done + count) counts

theorem invariant (initial snapshot : Memory) (destination done : Nat) (counts : List Nat) :
    run (expected initial snapshot destination done) snapshot destination done counts =
      expected initial snapshot destination (done + counts.sum) := by
  induction counts generalizing done with
  | nil => simp [run]
  | cons count counts ih =>
    simp only [run, step]
    rw [ih]
    simp [Nat.add_assoc]

theorem overlap_copy (initial : Memory) (source destination : Nat) (counts : List Nat) :
    run initial (fun offset => initial (source + offset)) destination 0 counts =
      fun a => if destination ≤ a ∧ a < destination + counts.sum
               then initial (source + (a - destination)) else initial a := by
  have h := invariant initial (fun offset => initial (source + offset)) destination 0 counts
  simpa [base, expected] using h

-- The host planner maximizes the complete-DWORD bulk between masked edges.
def head (address size : Nat) : Nat :=
  if address % 4 = 0 then 0 else min size (4 - address % 4)
def bulk (address size : Nat) : Nat := (size - head address size) / 4 * 4
def tail (address size : Nat) : Nat := (size - head address size) % 4

theorem partition (address size : Nat) :
    head address size + bulk address size + tail address size = size := by
  have h : head address size ≤ size := by
    unfold head
    split <;> omega
  unfold bulk tail
  omega

theorem edge_bounds (address size : Nat) :
    head address size ≤ 3 ∧ tail address size ≤ 3 := by
  unfold tail head
  split <;> omega

theorem bulk_aligned (address size : Nat) : bulk address size % 4 = 0 := by
  unfold bulk
  omega

theorem bulk_address_aligned (address size : Nat) (h : 0 < bulk address size) :
    (address + head address size) % 4 = 0 := by
  unfold bulk head at *
  split at h <;> split <;> omega

#print axioms base
#print axioms step
#print axioms invariant
#print axioms overlap_copy
#print axioms partition
#print axioms edge_bounds
#print axioms bulk_aligned
#print axioms bulk_address_aligned
end ByteCopySnapshot
