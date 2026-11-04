import Std.Tactic

/- Destination-edge model of fetch_context_binding. Snapshot values are arbitrary
   coherent CDC outputs; CDC timing/metastability and RTL refinement are not
   proved here. Naturals denote unsigned session/epoch values: the invariants
   hold without narrowing either field. Coordinated cold reset begins a new
   trace; exclusion of old descriptor completions is an external requirement. -/
namespace FetchContextBinding
structure State where
  bound : Bool
  fault : Bool
  session : Nat
  epoch : Nat
structure Snapshot where
  valid : Bool
  live : Bool
  session : Nat
  epoch : Nat

def initial : State := ⟨false, false, 0, 0⟩
def step (s : State) (i : Snapshot) : State :=
  if i.valid then
    if s.bound then
      {s with fault := s.fault || !i.live || (i.session != s.session) || (i.epoch != s.epoch)}
    else if s.fault || !i.live then s
    else if i.session == 0 || i.epoch == 0 then {s with fault := true}
    else ⟨true, false, i.session, i.epoch⟩
  else s

def ready (s : State) : Bool := s.bound && !s.fault
def token (s : State) : Nat := if s.bound then 1 else 0

theorem reset_base : ready initial = false ∧ token initial = 0 := by
  simp [ready, token, initial]

theorem identity_step (s : State) (i : Snapshot) (h : s.bound = true) :
    (step s i).bound = true ∧ (step s i).session = s.session ∧
    (step s i).epoch = s.epoch := by
  cases hv : i.valid <;> simp [step, hv, h]

theorem fault_step (s : State) (i : Snapshot) (h : s.fault = true) :
    (step s i).fault = true := by
  cases hv : i.valid <;> cases hb : s.bound <;> simp [step, hv, hb, h]

theorem fault_denies (s : State) (h : s.fault = true) : ready s = false := by
  simp [ready, h]

def run : State → List Snapshot → State
  | s, [] => s
  | s, i :: rest => run (step s i) rest

theorem identity_trace (s : State) (is : List Snapshot) (h : s.bound = true) :
    (run s is).bound = true ∧ (run s is).session = s.session ∧
    (run s is).epoch = s.epoch := by
  induction is generalizing s with
  | nil => exact ⟨h, rfl, rfl⟩
  | cons i rest ih =>
    obtain ⟨hb, hs, he⟩ := identity_step s i h
    obtain ⟨hb', hs', he'⟩ := ih (step s i) hb
    exact ⟨hb', hs'.trans hs, he'.trans he⟩

theorem fault_trace (s : State) (is : List Snapshot) (h : s.fault = true) :
    (run s is).fault = true := by
  induction is generalizing s with
  | nil => exact h
  | cons i rest ih => exact ih (step s i) (fault_step s i h)

theorem retained_token (s : State) (is : List Snapshot) (h : s.bound = true) :
    token (run s is) = 1 := by
  simp [token, (identity_trace s is h).1]

theorem no_fault_recovery (s : State) (is : List Snapshot) (h : s.fault = true) :
    ready (run s is) = false := fault_denies _ (fault_trace s is h)

#print axioms reset_base
#print axioms identity_step
#print axioms fault_step
#print axioms identity_trace
#print axioms retained_token
#print axioms no_fault_recovery
end FetchContextBinding
