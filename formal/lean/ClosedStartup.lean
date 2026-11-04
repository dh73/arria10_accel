import Std.Tactic

/- Ordering model for closure-aware startup. A verified event assumes the
   component checked its complete context/round/response. This is not C/RTL
   refinement, physical MMIO ordering, drain or device admission proof.
   Revocation invalidates even an accepted START and never erases custody. -/
namespace ClosedStartup
inductive Phase where
 | provision | closure | fence | command | accepted | failed
 deriving DecidableEq
inductive Event where
 | pending | verified | failure | revoke
structure State where
 phase : Phase
 provisioned : Bool
 closed : Bool
 settled : Bool
 deriving DecidableEq

def initial : State := ⟨.provision,false,false,false⟩
def step (s : State) (e : Event) : State :=
 match s.phase,e with
 | .failed,_ => s
 | _,.revoke => {s with phase := .failed}
 | .accepted,_ => s
 | _,.pending => s
 | _,.failure => {s with phase := .failed}
 | .provision,.verified => {s with phase := .closure,provisioned := true}
 | .closure,.verified => {s with phase := .fence,closed := true}
 | .fence,.verified => {s with phase := .command,settled := true}
 | .command,.verified => {s with phase := .accepted}

def Inv (s : State) : Prop :=
 (s.closed = true → s.provisioned = true) ∧
 (s.settled = true → s.closed = true) ∧
 (s.phase = .closure → s.provisioned = true) ∧
 (s.phase = .fence → s.provisioned = true ∧ s.closed = true) ∧
 (s.phase = .command ∨ s.phase = .accepted →
   s.provisioned = true ∧ s.closed = true ∧ s.settled = true)

theorem base : Inv initial := by simp [Inv,initial]
theorem preservation (s : State) (e : Event) (h : Inv s) : Inv (step s e) := by
 cases s with
 | mk phase provisioned closed settled =>
  cases phase <;> cases e <;> simp_all [Inv,step]

def run : State → List Event → State
 | s,[] => s
 | s,e::es => run (step s e) es

theorem trace_preservation (s : State) (es : List Event) (h : Inv s) : Inv (run s es) := by
 induction es generalizing s with
 | nil => exact h
 | cons e es ih => exact ih _ (preservation s e h)

theorem accepted_requires_closure (es : List Event)
 (h : (run initial es).phase = .accepted) :
 (run initial es).provisioned = true ∧ (run initial es).closed = true ∧
 (run initial es).settled = true :=
 (trace_preservation initial es base).2.2.2.2 (Or.inr h)

theorem failed_sticky (s : State) (es : List Event) (h : s.phase = .failed) :
 run s es = s := by
 induction es with
 | nil => rfl
 | cons e es ih => simp [run,step,h,ih]

theorem revoke_step (s : State) : (step s .revoke).phase = .failed := by
 cases h : s.phase <;> simp [step,h]

theorem revoke_forever (s : State) (es : List Event) :
 (run (step s .revoke) es).phase = .failed := by
 rw [failed_sticky _ es (revoke_step s)];exact revoke_step s

theorem revoke_retains_custody (s : State) :
 (step s .revoke).provisioned = s.provisioned ∧
 (step s .revoke).closed = s.closed ∧ (step s .revoke).settled = s.settled := by
 cases h : s.phase <;> simp [step,h]

#print axioms base
#print axioms preservation
#print axioms accepted_requires_closure
#print axioms revoke_forever
#print axioms revoke_retains_custody
end ClosedStartup
