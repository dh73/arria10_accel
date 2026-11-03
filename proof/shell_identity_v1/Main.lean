import Std
set_option maxHeartbeats 0

-- Abstract reset-free publication model; no RTL/CDC/driver refinement claim.
namespace ShellIdentityV1
def maxSeq : Nat := 2 ^ 32 - 1
structure State where
  seq : Nat
  valid : Bool
  exhausted : Bool
  deriving DecidableEq, Repr
def WellFormed (s : State) : Prop :=
  s.seq ≤ maxSeq ∧ (s.exhausted = true → s.valid = false) ∧
  (s.valid = true → 0 < s.seq)
def cold : State := ⟨0, false, false⟩
def guard (s : State) : Nat := if s.valid = true then s.seq else 0
def publish (s : State) : State :=
  if s.exhausted = true then { s with valid := false }
  else if s.seq < maxSeq then ⟨s.seq + 1, true, false⟩
  else { s with valid := false, exhausted := true }
inductive Event where
  | hold | invalidate | publish
  deriving DecidableEq, Repr
def step (s : State) : Event → State
  | .hold => s
  | .invalidate => { s with valid := false }
  | .publish => publish s
-- Reset is absent: reset requires external invalidation and a new session.
def run (s : State) : List Event → State
  | [] => s
  | e :: es => run (step s e) es

theorem cold_wellFormed : WellFormed cold := by simp [WellFormed, cold]
theorem cold_invalid : cold.valid = false ∧ guard cold = 0 := by simp [cold, guard]
theorem exhausted_denies_valid (s : State) (h : WellFormed s)
    (hx : s.exhausted = true) : s.valid = false := h.2.1 hx
theorem publish_wellFormed (s : State) (h : WellFormed s) :
    WellFormed (publish s) := by
  by_cases hx : s.exhausted = true
  · simpa [publish, hx, WellFormed] using h.1
  · by_cases hb : s.seq < maxSeq
    · simp [publish, hx, hb, WellFormed] <;> omega
    · simpa [publish, hx, hb, WellFormed] using h.1
theorem step_wellFormed (s : State) (e : Event) (h : WellFormed s) :
    WellFormed (step s e) := by
  cases e with
  | hold => exact h
  | invalidate => simpa [step, WellFormed] using h.1
  | publish => exact publish_wellFormed s h
theorem run_wellFormed (s : State) (es : List Event) (h : WellFormed s) :
    WellFormed (run s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (step s e) (step_wellFormed s e h)
theorem step_monotone (s : State) (e : Event) :
    s.seq ≤ (step s e).seq := by
  cases e with
  | hold => exact Nat.le_refl _
  | invalidate => exact Nat.le_refl _
  | publish =>
    by_cases hx : s.exhausted = true
    · simp [step, publish, hx]
    · by_cases hb : s.seq < maxSeq <;> simp [step, publish, hx, hb] <;> omega
theorem run_monotone (s : State) (es : List Event) :
    s.seq ≤ (run s es).seq := by
  induction es generalizing s with
  | nil => exact Nat.le_refl _
  | cons e es ih => exact Nat.le_trans (step_monotone s e) (ih (step s e))
theorem step_exhausted (s : State) (e : Event) (h : s.exhausted = true) :
    (step s e).exhausted = true := by cases e <;> simp [step, publish, h]
theorem run_exhausted (s : State) (es : List Event)
    (h : s.exhausted = true) : (run s es).exhausted = true := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (step s e) (step_exhausted s e h)
theorem publication_progress (s : State) :
    s.seq < (publish s).seq ∨ (publish s).exhausted = true := by
  by_cases hx : s.exhausted = true
  · simp [publish, hx]
  · by_cases hb : s.seq < maxSeq <;> simp [publish, hx, hb] <;> omega
theorem publication_visible (s : State) (es : List Event)
    (h : Event.publish ∈ es) :
    s.seq < (run s es).seq ∨ (run s es).exhausted = true := by
  induction es generalizing s with
  | nil => simp at h
  | cons e es ih =>
    simp only [List.mem_cons] at h
    rcases h with he | ht
    · subst e
      rcases publication_progress s with increase | poisoned
      · exact Or.inl (Nat.lt_of_lt_of_le increase (run_monotone (publish s) es))
      · exact Or.inr (run_exhausted (publish s) es poisoned)
    · rcases ih (step s e) ht with increase | poisoned
      · exact Or.inl (Nat.lt_of_le_of_lt (step_monotone s e) increase)
      · exact Or.inr poisoned
-- Hardware use additionally requires atomic publication, faithful ordered reads,
-- nonreused external session identity and continuous configuration custody.
theorem equal_brackets_exclude_publication
    (s : State) (es : List Event) (hw : WellFormed s)
    (h0 : s.valid = true) (h1 : (run s es).valid = true)
    (same : guard s = guard (run s es)) : Event.publish ∉ es := by
  intro occurs
  have hf := run_wellFormed s es hw
  have seqSame : s.seq = (run s es).seq := by simpa [guard, h0, h1] using same
  rcases publication_visible s es occurs with increase | poisoned
  · omega
  · have invalid := hf.2.1 poisoned
    simp [h1] at invalid
end ShellIdentityV1
