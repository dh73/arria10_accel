import Std.Tactic

/- Abstract composition of Provision, RoundFence and START. A verified event
   means the selected component has checked its complete response, including
   immutable context and request identity. This proves composition ordering;
   it assumes those component contracts and does not prove C++/RTL refinement,
   MMIO ordering, physical drain, reset containment or device admission. -/
namespace PlatformStartup
inductive Phase where
  | provision | fence | command | accepted | failed
  deriving DecidableEq
inductive Outcome where
  | pending | verified | failure
structure State where
  phase : Phase
  provisioned : Bool
  settled : Bool
  deriving DecidableEq

def initial : State := ⟨.provision, false, false⟩
def step (s : State) (o : Outcome) : State :=
 match s.phase, o with
 | .accepted, _ | .failed, _ => s
 | _, .pending => s
 | _, .failure => {s with phase := .failed}
 | .provision, .verified => {s with phase := .fence, provisioned := true}
 | .fence, .verified => {s with phase := .command, settled := true}
 | .command, .verified => {s with phase := .accepted}

def Inv (s : State) : Prop :=
 (s.settled = true → s.provisioned = true) ∧
 (s.phase = .fence → s.provisioned = true) ∧
 (s.phase = .command ∨ s.phase = .accepted →
   s.provisioned = true ∧ s.settled = true)

theorem base : Inv initial := by simp [Inv, initial]
theorem preservation (s : State) (o : Outcome) (h : Inv s) : Inv (step s o) := by
 cases s with
 | mk phase provisioned settled =>
   cases phase <;> cases o <;> simp_all [Inv, step]

def run : State → List Outcome → State
 | s, [] => s
 | s, e :: es => run (step s e) es

theorem trace_preservation (es : List Outcome) (s : State) (h : Inv s) : Inv (run s es) := by
 induction es generalizing s with
 | nil => exact h
 | cons e es ih => exact ih _ (preservation s e h)

theorem reachable_order (es : List Outcome) : Inv (run initial es) :=
 trace_preservation es initial base

theorem terminal_sticky (s : State) (o : Outcome)
 (h : s.phase = .failed ∨ s.phase = .accepted) : step s o = s := by
 rcases h with h | h <;> simp [step, h]

theorem terminal_trace (s : State) (es : List Outcome)
 (h : s.phase = .failed ∨ s.phase = .accepted) : run s es = s := by
 induction es with
 | nil => rfl
 | cons e es ih => simp [run, terminal_sticky s e h, ih]

#print axioms reachable_order
#print axioms terminal_trace
end PlatformStartup
