/- Immutable-context model between coordinated cold resets.
   Input none represents any invalid or incoherent context. The model assumes
   the input classifier matches the RTL validity check; no CDC/RTL refinement
   or physical reset proof is asserted. -/
namespace PlatformContextGuard
structure Context where
  session : Nat
  epoch : Nat
  deriving DecidableEq
structure State where
  bound : Option Context
  fault : Bool
  deriving DecidableEq

def initial : State := ⟨none, false⟩
def step (s : State) (input : Option Context) : State :=
  match s.bound with
  | none => ⟨input, s.fault⟩
  | some c => ⟨some c, s.fault || decide (input ≠ some c)⟩
def live (s : State) (input : Option Context) : Prop :=
  ∃ c, s.bound = some c ∧ s.fault = false ∧ input = some c

def run : State → List (Option Context) → State
  | s, [] => s
  | s, i :: rest => run (step s i) rest

theorem reset_has_no_binding : initial.bound = none ∧ initial.fault = false := by
  constructor <;> rfl

theorem capture_base (c : Context) : step initial (some c) = ⟨some c, false⟩ := by
  rfl

theorem binding_step (s : State) (c : Context) (i : Option Context)
    (bound : s.bound = some c) : (step s i).bound = some c := by
  simp [step, bound]

theorem binding_trace (s : State) (c : Context) (xs : List (Option Context))
    (bound : s.bound = some c) : (run s xs).bound = some c := by
  induction xs generalizing s with
  | nil => exact bound
  | cons i rest ih => exact ih (step s i) (binding_step s c i bound)

theorem fault_step (s : State) (i : Option Context)
    (faulted : s.fault = true) : (step s i).fault = true := by
  cases h : s.bound <;> simp [step, h, faulted]

theorem fault_trace (s : State) (xs : List (Option Context))
    (faulted : s.fault = true) : (run s xs).fault = true := by
  induction xs generalizing s with
  | nil => exact faulted
  | cons i rest ih => exact ih (step s i) (fault_step s i faulted)

theorem mismatch_fault (s : State) (c : Context) (i : Option Context)
    (bound : s.bound = some c) (changed : i ≠ some c) :
    (step s i).fault = true := by
  simp [step, bound, changed]

theorem mismatch_blocks_immediately (s : State) (c : Context) (i : Option Context)
    (bound : s.bound = some c) (changed : i ≠ some c) : ¬ live s i := by
  rintro ⟨other, ho, _, hi⟩
  have eq : c = other := Option.some.inj (bound.symm.trans ho)
  exact changed (eq ▸ hi)

theorem mismatch_never_reopens (s : State) (c : Context) (i later : Option Context)
    (rest : List (Option Context)) (bound : s.bound = some c)
    (changed : i ≠ some c) : ¬ live (run (step s i) rest) later := by
  have faulted := fault_trace (step s i) rest (mismatch_fault s c i bound changed)
  rintro ⟨_, _, clean, _⟩
  simp [faulted] at clean

#print axioms binding_trace
#print axioms mismatch_never_reopens
end PlatformContextGuard
