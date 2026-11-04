import Std.Tactic

/- Event model of dma_status_reset_guard's retained state and two health flops.
   ProducerReset represents a pulse satisfying asynchronous-clear requirements,
   including while the destination clock is stopped. Tick is one destination
   edge after producer reset deassertion. No physical CDC/refinement claim.
   Snapshot validity is arbitrary, so transport freshness is not assumed here.
   Common reset starts a new epoch and is deliberately outside Event. -/
namespace DmaStatusResetGuard
structure State where
  h0 : Bool
  h1 : Bool
  armed : Bool
  lost : Bool

def initial : State := ⟨false, false, false, false⟩
inductive Event where
  | producerReset
  | tick

def step (s : State) : Event → State
  | .producerReset => {s with h0 := false, h1 := false}
  | .tick => ⟨true, s.h0, s.armed || s.h1,
                s.lost || (s.armed && !s.h1)⟩
def valid (s : State) (snapshot : Bool) : Bool :=
  s.h1 && s.armed && !s.lost && snapshot
def Blocked (s : State) : Prop :=
  s.lost = true ∨ (s.armed = true ∧ s.h1 = false)

theorem reset_base (snapshot : Bool) : valid initial snapshot = false := by
  simp [valid, initial]

theorem reset_blocks (s : State) (h : s.armed = true) :
    Blocked (step s .producerReset) := by
  simp [Blocked, step, h]

theorem blocked_step (s : State) (e : Event) (h : Blocked s) :
    Blocked (step s e) := by
  rcases s with ⟨a,b,c,d⟩
  cases e <;> cases a <;> cases b <;> cases c <;> cases d <;>
    simp_all [Blocked, step]

theorem blocked_invalid (s : State) (snapshot : Bool) (h : Blocked s) :
    valid s snapshot = false := by
  rcases h with h | ⟨ha,hb⟩
  · simp [valid, h]
  · simp [valid, hb]

def run : State → List Event → State
  | s, [] => s
  | s, e :: es => run (step s e) es

theorem blocked_trace (s : State) (es : List Event) (h : Blocked s) :
    Blocked (run s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (step s e) (blocked_step s e h)

theorem reset_never_revalidates (s : State) (es : List Event)
    (snapshot : Bool) (h : s.armed = true) :
    valid (run (step s .producerReset) es) snapshot = false :=
  blocked_invalid _ snapshot (blocked_trace _ es (reset_blocks s h))

#print axioms reset_base
#print axioms blocked_step
#print axioms reset_never_revalidates
end DmaStatusResetGuard
