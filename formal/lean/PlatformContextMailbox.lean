import Std.Tactic

/- Register-transition model of platform_context_mailbox. Each Word event is
   one full, serialized write; partial/simultaneous/invalid writes are Bad.
   Read-only events do not change this state. Coordinated cold reset starts a
   new trace. No CDC, host identity, reset containment or RTL refinement claim. -/
namespace PlatformContextMailbox
structure State where
  words : Fin 6 → Nat
  staged : Fin 6 → Bool
  bound : Bool
  fault : Bool
  epoch : Nat
  session : Nat

def initial : State := ⟨fun _ => 0, fun _ => false, false, false, 0, 0⟩
def epochValue (s : State) := s.words 0 + 4294967296 * s.words 1
def sessionValue (s : State) := s.words 2 + 4294967296 * s.words 3 +
  4294967296^2 * s.words 4 + 4294967296^3 * s.words 5

abbrev complete (s : State) : Prop := ∀ i, s.staged i = true
inductive Event where
  | word (index : Fin 6) (value : Nat)
  | commit
  | bad
  | read

def step (s : State) : Event → State
  | .read => s
  | .bad => {s with fault := true}
  | .word index value =>
    if s.bound || s.fault then {s with fault := true}
    else {s with words := fun i => if i = index then value else s.words i,
                 staged := fun i => if i = index then true else s.staged i}
  | .commit =>
    if s.bound || s.fault then {s with fault := true}
    else if complete s ∧ epochValue s > 0 ∧ sessionValue s > 0 then
      {s with bound := true, epoch := epochValue s, session := sessionValue s}
    else {s with fault := true}

def Invariant (s : State) : Prop := s.bound = true → s.epoch > 0 ∧ s.session > 0

theorem reset_base : Invariant initial ∧ initial.bound = false ∧ initial.fault = false := by
  simp [Invariant, initial]

theorem bound_immutable (s : State) (e : Event) (h : s.bound = true) :
    (step s e).bound = true ∧ (step s e).epoch = s.epoch ∧
    (step s e).session = s.session := by
  cases e <;> simp [step, h]

theorem fault_sticky (s : State) (e : Event) (h : s.fault = true) :
    (step s e).fault = true := by
  cases e <;> simp [step, h]

theorem invariant_step (s : State) (e : Event) (h : Invariant s) :
    Invariant (step s e) := by
  cases e <;> simp only [step]
  · split <;> exact h
  · split
    · exact h
    · split
      · rename_i valid
        exact fun _ => ⟨valid.2.1, valid.2.2⟩
      · exact h
  · exact h
  · exact h

def run : State → List Event → State
  | s, [] => s
  | s, e :: es => run (step s e) es

theorem trace_invariant (s : State) (events : List Event) (h : Invariant s) :
    Invariant (run s events) := by
  induction events generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (step s e) (invariant_step s e h)

theorem bound_trace (s : State) (events : List Event) (h : s.bound = true) :
    (run s events).bound = true ∧ (run s events).epoch = s.epoch ∧
    (run s events).session = s.session := by
  induction events generalizing s with
  | nil => exact ⟨h, rfl, rfl⟩
  | cons e es ih =>
    have hs := bound_immutable s e h
    have ht := ih (step s e) hs.1
    exact ⟨ht.1, ht.2.1.trans hs.2.1, ht.2.2.trans hs.2.2⟩

#print axioms trace_invariant
#print axioms bound_trace
#print axioms fault_sticky
end PlatformContextMailbox

