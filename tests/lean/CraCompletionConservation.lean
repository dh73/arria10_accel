import Lean.Elab.Tactic.Omega

/-
  Exact two-bit CRA completion accounting model.
  Target toolchain: Lean 4.19.0, with no Mathlib dependency.

  This file is a proof about the recurrence below. It is not a proof that the
  full generated kernel can produce any particular kernel_done waveform, nor
  an HDL equivalence proof, nor evidence of a successful Lean invocation.

  Mapping to the candidate RTL:
    count       finish_counter_NO_SHIFT_REG_q[1:0]
    snapshot    read_clear_safe_snapshot_q[1:0]
    delayed     clear_finish_counter_reg_q
    read        clear_finish_counter_pre_comp_q
    finish      finish_pulse_while_running_q

  Snapshot is reset to zero, captures live on read, and otherwise holds.
  count' uses the existing two-bit adder result and subtracts snapshot only
  when the old delayed flag is set. The read response is old live, sampled
  into the existing 64-bit response register. The response is counted at
  that local emission edge; an upstream response queue is outside this model.

  BASE and STEP are explicit. WORD_REFINEMENT exhausts all 4*4*2*2*2 legal
  word/input combinations; it does not assume no overflow. SERIAL_EPOCH
  derives natural-number conservation and the <=1 bound from a drained
  starting state and at most one qualified finish in one serialized launch
  epoch. Epoch accounting can restart at a drained state without resetting
  the actual CRA. No theorem treats a zero read while a launch is still in
  flight as proof that no completion can arrive later.
-/

namespace CraCompletion

abbrev Word2 := Fin 4

def word2 (n : Nat) : Word2 :=
  ⟨n % 4, Nat.mod_lt n (by decide)⟩

def pulse (b : Bool) : Nat := if b then 1 else 0

structure Cra where
  count : Word2
  snapshot : Word2
  delayed : Bool

def live (s : Cra) : Nat :=
  (s.count.val + 4 - (if s.delayed then s.snapshot.val else 0)) % 4

def rtlStep (s : Cra) (read finish : Bool) : Cra :=
  let adder := (s.count.val + pulse finish) % 4
  { count := word2 (if s.delayed then adder + 4 - s.snapshot.val else adder)
    snapshot := if read then word2 (live s) else s.snapshot
    delayed := read }

def reset : Cra := ⟨word2 0, word2 0, false⟩

-- Finite proof of the actual two-bit arithmetic, including both wraps.
-- `decide` constructs a kernel-checked proof; no native_decide axiom is used.
set_option maxRecDepth 10000 in
set_option maxHeartbeats 0 in
theorem WORD_REFINEMENT :
    ∀ (c t : Word2) (d r f : Bool),
      live (rtlStep ⟨c, t, d⟩ r f) =
        (if r then pulse f else (live ⟨c, t, d⟩ + pulse f) % 4) := by
  decide

theorem rtl_refines (s : Cra) (read finish : Bool) :
    live (rtlStep s read finish) =
      (if read then pulse finish else (live s + pulse finish) % 4) := by
  rcases s with ⟨c, t, d⟩
  exact WORD_REFINEMENT c t d read finish

def returnedNow (value : Nat) (read : Bool) : Nat :=
  if read then value else 0

structure Accounting where
  hw : Cra
  produced : Nat
  returned : Nat

def Conserves (s : Accounting) : Prop :=
  s.returned + live s.hw = s.produced

def advance (s : Accounting) (read finish : Bool) : Accounting :=
  { hw := rtlStep s.hw read finish
    produced := s.produced + pulse finish
    returned := s.returned + returnedNow (live s.hw) read }

def initial : Accounting := ⟨reset, 0, 0⟩

theorem BASE : Conserves initial := by
  rfl

-- Exact natural-number conservation requires no loss to modulo-four wrap.
-- This is not taken as an unproved serialized-driver premise: the later
-- SERIAL_STEP and SERIAL_EPOCH derive it from the one-completion budget.
theorem STEP (s : Accounting) (read finish : Bool)
    (h : Conserves s) (capacity : live s.hw + pulse finish < 4) :
    Conserves (advance s read finish) := by
  change (s.returned + returnedNow (live s.hw) read) +
      live (rtlStep s.hw read finish) = s.produced + pulse finish
  rw [rtl_refines]
  unfold Conserves at h
  cases read <;> simp [returnedNow, Nat.mod_eq_of_lt capacity] <;> omega

theorem SERIAL_STEP (s : Accounting) (read finish : Bool)
    (h : Conserves s) (oneCompletion : s.produced + pulse finish ≤ 1) :
    Conserves (advance s read finish) := by
  have capacity : live s.hw + pulse finish < 4 := by
    unfold Conserves at h
    omega
  exact STEP s read finish h capacity

structure Event where
  read : Bool
  finish : Bool

def finishes : List Event → Nat
  | [] => 0
  | e :: es => pulse e.finish + finishes es

def run : Accounting → List Event → Accounting
  | s, [] => s
  | s, e :: es => run (advance s e.read e.finish) es

theorem run_produced (s : Accounting) (es : List Event) :
    (run s es).produced = s.produced + finishes es := by
  induction es generalizing s with
  | nil => rfl
  | cons e es ih =>
    simp only [run, finishes]
    rw [ih]
    change (s.produced + pulse e.finish) + finishes es =
      s.produced + (pulse e.finish + finishes es)
    omega

theorem run_conserves (s : Accounting) (es : List Event)
    (h : Conserves s) (budget : s.produced + finishes es ≤ 1) :
    Conserves (run s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih =>
    have oneCompletion : s.produced + pulse e.finish ≤ 1 := by
      simp only [finishes] at budget
      omega
    have next : Conserves (advance s e.read e.finish) :=
      SERIAL_STEP s e.read e.finish h oneCompletion
    have tailBudget :
        (advance s e.read e.finish).produced + finishes es ≤ 1 := by
      change (s.produced + pulse e.finish) + finishes es ≤ 1
      simp only [finishes] at budget
      omega
    exact ih (advance s e.read e.finish) next tailBudget

-- This is a reset of the ghost accounting only, not a hardware reset.
def epochInitial (hw : Cra) : Accounting := ⟨hw, 0, 0⟩

theorem DRAINED_BASE (hw : Cra) (drained : live hw = 0) :
    Conserves (epochInitial hw) := by
  simpa [Conserves, epochInitial] using drained

theorem SERIAL_EPOCH (hw : Cra) (es : List Event)
    (drained : live hw = 0) (oneCompletion : finishes es ≤ 1) :
    (run (epochInitial hw) es).returned +
      live (run (epochInitial hw) es).hw = finishes es := by
  have h : Conserves (run (epochInitial hw) es) :=
    run_conserves (epochInitial hw) es (DRAINED_BASE hw drained)
      (by simpa [epochInitial] using oneCompletion)
  unfold Conserves at h
  rw [run_produced] at h
  simpa [epochInitial] using h

theorem SERIAL_BOUND (hw : Cra) (es : List Event)
    (drained : live hw = 0) (oneCompletion : finishes es ≤ 1) :
    live (run (epochInitial hw) es).hw ≤ 1 ∧
      (run (epochInitial hw) es).returned ≤ 1 := by
  have h := SERIAL_EPOCH hw es drained oneCompletion
  omega

theorem DRAINED_TOTAL (hw : Cra) (es : List Event)
    (drained : live hw = 0) (oneCompletion : finishes es ≤ 1)
    (finallyDrained : live (run (epochInitial hw) es).hw = 0) :
    (run (epochInitial hw) es).returned = finishes es := by
  have h := SERIAL_EPOCH hw es drained oneCompletion
  omega

end CraCompletion
