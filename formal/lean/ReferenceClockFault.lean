import Std.Tactic

/- Output-state abstraction of reference_clock_monitor. Cadence qualification
   and violation events abstract the counter/CDC predicates. This proves fault
   retention, not those predicates, clock frequency, physical reset or RTL
   refinement. External reset begins a new trace and is not an Event. -/
namespace ReferenceClockFault
structure State where
  qualified : Bool
  fault : Bool

def initial : State := ⟨false, false⟩
inductive Event where
  | hold
  | qualificationReached
  | cadenceViolation

def step (s : State) (e : Event) : State :=
  if s.fault then s else
  match e with
  | .hold => s
  | .qualificationReached => ⟨true, false⟩
  | .cadenceViolation => if s.qualified then ⟨false, true⟩ else s

def Safe (s : State) : Prop := s.fault = true → s.qualified = false

theorem base : Safe initial := by simp [Safe, initial]

theorem safe_step (s : State) (e : Event) (h : Safe s) :
    Safe (step s e) := by
  rcases s with ⟨q,f⟩
  cases e <;> cases q <;> cases f <;> simp_all [Safe, step]

theorem fault_step (s : State) (e : Event) (h : s.fault = true) :
    step s e = s := by simp [step, h]

def run : State → List Event → State
  | s, [] => s
  | s, e :: es => run (step s e) es

theorem fault_trace (s : State) (es : List Event) (h : s.fault = true) :
    run s es = s := by
  induction es with
  | nil => rfl
  | cons e es ih => simpa [run, fault_step s e h] using ih

theorem violation_blocks (s : State) (h : s.qualified = true)
    (safe : Safe s) : step s .cadenceViolation = ⟨false, true⟩ := by
  rcases s with ⟨q,f⟩
  cases q <;> cases f <;> simp_all [Safe, step]

theorem no_clock_return_recovery (s : State) (es : List Event)
    (h : s.qualified = true) (safe : Safe s) :
    (run (step s .cadenceViolation) es).qualified = false := by
  rw [violation_blocks s h safe]
  rw [fault_trace _ es rfl]

#print axioms base
#print axioms safe_step
#print axioms fault_trace
#print axioms no_clock_return_recovery
end ReferenceClockFault
