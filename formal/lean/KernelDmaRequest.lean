import Std

/- Serialized single-request abstraction of aclpci_dma_request.c.
   `debt` is ghost ownership reserved before a possibly delivered doorbell.
   Retirement events must be supplied only after hardware-qualified completion.
   This model neither proves that external premise nor C/kernel refinement.
   Fresh initialization is separate from actions; no request reuse is modeled. -/
namespace KernelDmaRequest

inductive Phase where
  | ready | built | flight | terminal
  deriving DecidableEq, Repr

structure State where
  phase : Phase
  owns : Bool
  stopped : Bool
  sequence : Nat
  debt : Bool
  deriving DecidableEq, Repr

def maxTicket : Nat := 2^64 - 1
def initial : State := ⟨.ready, true, false, 0, false⟩

inductive Action where
  | build (success : Bool)
  | submit
  | retire (ticket : Nat) (last : Bool)
  | stop
  | release
  deriving DecidableEq, Repr

def step (s : State) (a : Action) : State :=
  if !s.owns then s else
  match a with
  | .build success =>
      if s.phase = .ready ∧ s.stopped = false then
        { s with phase := if success then .built else .terminal }
      else s
  | .submit =>
      if s.phase = .built ∧ s.stopped = false then
        if s.sequence < maxTicket then
          { s with phase := .flight, sequence := s.sequence + 1, debt := true }
        else { s with phase := .terminal }
      else s
  | .retire ticket last =>
      if s.phase = .flight ∧ ticket = s.sequence then
        { s with phase := if s.stopped || last then .terminal else .ready,
                 debt := false }
      else s
  | .stop =>
      if s.phase = .terminal then s else
        { s with stopped := true,
                 phase := if s.phase = .flight then .flight else .terminal }
  | .release =>
      if s.phase = .terminal then { s with owns := false } else s

def Inv (s : State) : Prop :=
  (s.debt = true ↔ s.phase = .flight) ∧
  (s.owns = false → s.phase = .terminal) ∧ s.sequence ≤ maxTicket

theorem base : Inv initial := by simp [Inv, initial, maxTicket]

theorem induction_step (s : State) (a : Action) (h : Inv s) :
    Inv (step s a) := by
  cases a <;> cases hp : s.phase <;> cases ho : s.owns <;>
    cases hs : s.stopped <;> cases hd : s.debt <;>
    simp_all [Inv, step] <;> split <;> simp_all <;> try omega
  split <;> simp_all

def run : State → List Action → State
  | s, [] => s
  | s, a :: rest => run (step s a) rest

theorem run_inv (s : State) (actions : List Action) (h : Inv s) :
    Inv (run s actions) := by
  induction actions generalizing s with
  | nil => exact h
  | cons a rest ih => exact ih (step s a) (induction_step s a h)

theorem reachable_inv (actions : List Action) : Inv (run initial actions) :=
  run_inv initial actions base

theorem debt_retains_mapping (s : State) (h : Inv s) (hd : s.debt = true) :
    s.owns = true := by
  rcases h with ⟨hp, ho, _⟩
  cases he : s.owns
  · have ht := ho he
    have hf := hp.mp hd
    cases ht.symm.trans hf
  · rfl

theorem release_with_debt_unchanged (s : State) (h : Inv s)
    (hd : s.debt = true) : step s .release = s := by
  simp [step, debt_retains_mapping s h hd, h.1.mp hd]

theorem stop_with_debt_retains (s : State) (h : Inv s) (hd : s.debt = true) :
    (step s .stop).debt = true ∧ (step s .stop).owns = true ∧
    (step s .stop).phase = .flight := by
  simp [step, debt_retains_mapping s h hd, h.1.mp hd, hd]

theorem wrong_ticket_unchanged (s : State) (ticket : Nat) (last : Bool)
    (ht : ticket ≠ s.sequence) : step s (.retire ticket last) = s := by
  simp [step, ht]

theorem released_is_inert (s : State) (a : Action) (h : s.owns = false) :
    step s a = s := by simp [step, h]

theorem submission_has_debt (s : State) (h : s.owns = true)
    (hp : s.phase = .built) (hs : s.stopped = false)
    (hn : s.sequence < maxTicket) :
    (step s .submit).debt = true ∧
    (step s .submit).sequence = s.sequence + 1 := by
  simp [step, h, hp, hs, hn]

theorem exhausted_ticket_never_submits (s : State) (h : s.owns = true)
    (hp : s.phase = .built) (hs : s.stopped = false)
    (hn : s.sequence = maxTicket) :
    (step s .submit).phase = .terminal ∧
    (step s .submit).sequence = maxTicket := by
  simp [step, h, hp, hs, hn]

theorem debt_clears_only_on_matching_retirement (s : State) (a : Action)
    (h : Inv s) (hd : s.debt = true) (hn : (step s a).debt = false) :
    ∃ last, a = .retire s.sequence last := by
  have hp := h.1.mp hd
  have ho := debt_retains_mapping s h hd
  cases a <;> simp_all [step]
  split at hn <;> simp_all

theorem release_requires_no_debt (s : State) (h : Inv s)
    (ho : s.owns = true) (hr : (step s .release).owns = false) :
    s.debt = false := by
  cases hd : s.debt
  · rfl
  · rw [release_with_debt_unchanged s h hd, ho] at hr
    contradiction

#print axioms base
#print axioms induction_step
#print axioms reachable_inv
#print axioms debt_retains_mapping
#print axioms release_with_debt_unchanged
#print axioms stop_with_debt_retains
#print axioms wrong_ticket_unchanged
#print axioms released_is_inert
#print axioms submission_has_debt
#print axioms exhausted_ticket_never_submits
#print axioms debt_clears_only_on_matching_retirement
#print axioms release_requires_no_debt
end KernelDmaRequest
