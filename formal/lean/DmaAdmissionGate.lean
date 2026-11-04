/- Admission custody between coordinated cold resets. Known Boolean inputs
   model the RTL's exact-value classifiers; no four-state RTL refinement or
   PCIe settlement theorem is claimed. The upstream holds its offer until ACK.
   An external upstreamClosed certificate covers host/transport handoffs. -/
namespace DmaAdmissionGate
structure Offer where
  write : Bool
  address : Nat
  data : Nat
  byteEnable : Nat
  deriving DecidableEq

structure Input where
  offer : Option Offer
  permit : Bool
  stop : Bool
  upstreamClosed : Bool
  ack : Bool

abbrev State := Option Offer
def initial : State := none
def admitted (i : Input) (o : Offer) : Bool :=
  !o.write || (i.permit && !i.stop)
def step (s : State) (i : Input) : State :=
  match s with
  | some o => if i.ack then none else some o
  | none => match i.offer with
    | none => none
    | some o => if admitted i o then some o else none

def writeOwned (s : State) (i : Input) : Prop :=
  (∃ o, s = some o ∧ o.write = true) ∨
  (s = none ∧ ∃ o, i.offer = some o ∧ o.write = true ∧ admitted i o = true)
def stopAck (s : State) (i : Input) : Prop :=
  i.stop = true ∧ i.upstreamClosed = true ∧ ¬ writeOwned s i

def run : State → List Input → State
  | s, [] => s
  | s, i :: rest => run (step s i) rest

theorem initial_empty : initial = none := rfl
theorem capture_base (i : Input) (o : Offer)
    (offered : i.offer = some o) (allowed : admitted i o = true) :
    step initial i = some o := by simp [step, initial, offered, allowed]

theorem retain_step (o : Offer) (i : Input) (stalled : i.ack = false) :
    step (some o) i = some o := by simp [step, stalled]

theorem retain_trace (o : Offer) (xs : List Input)
    (stalled : ∀ i ∈ xs, i.ack = false) : run (some o) xs = some o := by
  induction xs with
  | nil => rfl
  | cons i rest ih =>
    have h := stalled i (by simp)
    simp only [run, retain_step o i h]
    exact ih (by intro j hj; exact stalled j (by simp [hj]))

theorem stopped_write_denied (i : Input) (o : Offer)
    (offered : i.offer = some o) (write : o.write = true) (stopped : i.stop = true) :
    step none i = none := by simp [step, offered, admitted, write, stopped]

theorem reads_remain_available (i : Input) (o : Offer)
    (offered : i.offer = some o) (read : o.write = false) :
    step none i = some o := by simp [step, offered, admitted, read]

theorem owned_write_blocks_stop (o : Offer) (i : Input) (write : o.write = true) :
    ¬ stopAck (some o) i := by
  intro h
  exact h.2.2 (Or.inl ⟨o, rfl, write⟩)

theorem capture_blocks_stop (i : Input) (o : Offer)
    (offered : i.offer = some o) (write : o.write = true)
    (allowed : admitted i o = true) : ¬ stopAck none i := by
  intro h
  exact h.2.2 (Or.inr ⟨rfl, o, offered, write, allowed⟩)

theorem stop_requires_external_closure (s : State) (i : Input)
    (h : stopAck s i) : i.upstreamClosed = true := h.2.1

#print axioms retain_trace
#print axioms stopped_write_denied
#print axioms owned_write_blocks_stop
#print axioms capture_blocks_stop
end DmaAdmissionGate
