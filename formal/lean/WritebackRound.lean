import Std.Tactic
/- Serial protocol abstraction between coordinated cold resets. An Ack event
   summarizes all eight context/round echoes and the ordered READY read; it is
   not a theorem about MMIO ordering, CDC, or RTL refinement. The caller retains
   immutable context and coherent producer closure. The RTL checks these too.
   No reset transition is modeled: old DMA containment is a separate contract. -/
namespace WritebackRound
structure State where
  round : Nat
  armed : Bool
  acknowledged : Bool
  fault : Bool
  awaitOpen : Bool
  deriving DecidableEq

def initial : State := ⟨1, false, false, false, false⟩
def settled (s : State) : Bool := s.armed && s.acknowledged && !s.fault
inductive Event where
  | arm (closed txEmpty : Bool)
  | ack (echoRound : Nat) (closed : Bool)
  | consume (closed simultaneousMmio : Bool)
  | observedOpen
  | closureLost

def step (limit : Nat) (s : State) : Event → State
  | .arm closed txEmpty =>
    if !s.fault && !s.awaitOpen && closed && txEmpty then {s with armed := true} else s
  | .ack echoed closed =>
    if s.armed && !s.fault && closed && echoed == s.round then
      {s with acknowledged := true}
    else {s with fault := true}
  | .consume closed mmio =>
    if settled s && closed && !mmio && s.round < limit then
      ⟨s.round + 1, false, false, false, true⟩
    else {s with fault := true}
  | .observedOpen => {s with awaitOpen := false}
  | .closureLost => {s with fault := true}

def run (limit : Nat) : State → List Event → State
  | s, [] => s
  | s, e :: es => run limit (step limit s e) es

theorem reset_base (limit : Nat) (h : 1 ≤ limit) :
    1 ≤ initial.round ∧ initial.round ≤ limit ∧ settled initial = false := by
  simp [initial, settled, h]

theorem round_step (limit : Nat) (s : State) (e : Event)
    (bounds : 1 ≤ s.round ∧ s.round ≤ limit) :
    1 ≤ (step limit s e).round ∧ (step limit s e).round ≤ limit := by
  cases e <;> simp only [step]
  all_goals first | exact bounds | (split <;> simp_all <;> omega)

theorem round_trace (limit : Nat) (s : State) (es : List Event)
    (bounds : 1 ≤ s.round ∧ s.round ≤ limit) :
    1 ≤ (run limit s es).round ∧ (run limit s es).round ≤ limit := by
  induction es generalizing s with
  | nil => exact bounds
  | cons e es ih => exact ih (step limit s e) (round_step limit s e bounds)

theorem consume_invalidates (limit : Nat) (s : State) (closed mmio : Bool) :
    settled (step limit s (.consume closed mmio)) = false := by
  simp only [step]
  split <;> simp [settled]

theorem consume_advances (limit : Nat) (s : State)
    (ready : settled s = true) (room : s.round < limit) :
    (step limit s (.consume true false)).round = s.round + 1 := by
  simp [step, ready, room]

theorem stale_ack_faults (limit : Nat) (s : State) (n : Nat) (closed : Bool)
    (stale : n ≠ s.round) :
    (step limit s (.ack n closed)).fault = true := by
  simp [step, stale]

theorem exhausted_refuses (limit : Nat) (s : State) (closed mmio : Bool)
    (full : s.round = limit) :
    (step limit s (.consume closed mmio)).round = s.round ∧
    (step limit s (.consume closed mmio)).fault = true := by
  simp [step, full]

#print axioms round_trace
#print axioms consume_invalidates
#print axioms stale_ack_faults
#print axioms exhausted_refuses
end WritebackRound
