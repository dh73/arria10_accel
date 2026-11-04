import Std.Tactic
/- Request-custody abstraction between coordinated resets. Capture summarizes
   the RTL's full staging/mask/permission/magic checks. Finish is the matched
   supervisor completion event. This does not prove CDC or physical ordering. -/
namespace SupervisorCommand
structure State where
  lastId : Nat
  active : Option Nat
  completed : Option Nat
  deriving DecidableEq

def initial : State := ⟨0, none, none⟩
def capture (s : State) (id : Nat) (valid : Bool) : State :=
  if s.active = none ∧ valid = true ∧ s.lastId < id then
    {s with lastId := id, active := some id}
  else s

def finish (s : State) : State :=
  match s.active with
  | none => s
  | some id => {s with active := none, completed := some id}

inductive Event where
 | commit (id : Nat) (valid : Bool)
 | complete

def step (s : State) : Event → State
 | .commit id valid => capture s id valid
 | .complete => finish s

def invariant (s : State) : Prop :=
 (∀ id, s.active = some id → id = s.lastId ∧ 0 < id) ∧
 (∀ id, s.completed = some id → id ≤ s.lastId ∧ 0 < id)

def run : State → List Event → State
 | s, [] => s
 | s, e :: es => run (step s e) es

theorem base : invariant initial := by simp [invariant, initial]
theorem monotone_step (s : State) (e : Event) : s.lastId ≤ (step s e).lastId := by
 cases e with
 | commit id valid => simp only [step, capture];split <;> simp_all <;> omega
 | complete => simp only [step, finish];split <;> simp

theorem capture_preserves (s : State) (id : Nat) (valid : Bool) (h : invariant s) :
 invariant (capture s id valid) := by
 unfold capture
 split
 · rename_i allowed
   constructor
   · intro n hn; simp only [Option.some.injEq] at hn;subst n;exact ⟨rfl, by omega⟩
   · intro n hn;have old := h.2 n hn;exact ⟨by dsimp; omega, old.2⟩
 · exact h

theorem finish_preserves (s : State) (h : invariant s) : invariant (finish s) := by
 unfold finish
 split
 · exact h
 · rename_i id active
   constructor
   · simp
   · intro n hn;simp only [Option.some.injEq] at hn;subst n
     have old := h.1 id active;exact ⟨by dsimp; omega, old.2⟩

theorem invariant_step (s : State) (e : Event) (h : invariant s) : invariant (step s e) := by
 cases e with
 | commit id valid => exact capture_preserves s id valid h
 | complete => exact finish_preserves s h

theorem invariant_trace (s : State) (es : List Event) (h : invariant s) : invariant (run s es) := by
 induction es generalizing s with
 | nil => exact h
 | cons e es ih => exact ih (step s e) (invariant_step s e h)

theorem busy_retains (s : State) (active id : Nat) (valid : Bool) (h : s.active = some active) :
 capture s id valid = s := by simp [capture, h]
theorem stale_refused (s : State) (id : Nat) (valid : Bool) (h : id ≤ s.lastId) :
 capture s id valid = s := by simp [capture, Nat.not_lt.mpr h]

#print axioms invariant_trace
#print axioms monotone_step
#print axioms busy_retains
#print axioms stale_refused
end SupervisorCommand
