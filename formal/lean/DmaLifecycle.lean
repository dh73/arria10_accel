import Std

/-!
A finite-state safety abstraction of one C++ operation-lifecycle record.

The implementation stores many records in a mutex-protected map and uses a
serialized dispatcher.  This model covers the state-changing cases for async
reservation/accept/rejection, null-token blocking calls, terminal assignment,
physical drain, callback claim, orphan release, and generation isolation.
Queueing and C++ mutex scheduling are part of the refinement gap documented in
the accompanying architecture note; hardware drain evidence is an input, never
a theorem of this software model.
-/

namespace DmaLifecycle

inductive Phase where
  | prepared
  | accepted
  | orphan
  | blocking
  | retired
  deriving DecidableEq, Repr

structure Op where
  phase : Phase
  terminal : Bool
  drained : Bool
  callbackCount : Nat
  leaseHeld : Bool
  releaseCount : Nat
  deriving DecidableEq, Repr

structure State where
  generation : Nat
  op : Op
  acceptedDebt : Nat
  heldLeases : Nat
  callbacks : Nat
  releases : Nat
  deriving DecidableEq, Repr

def debtContribution (o : Op) : Nat :=
  if o.phase = .accepted ∧ o.callbackCount = 0 then 1 else 0

def heldContribution (o : Op) : Nat :=
  if o.leaseHeld = true then 1 else 0

/--
`OpInv` is deliberately stronger than an at-most-once counter bound.  It ties
notification to accepted ownership, terminal state, physical drain, and lease
release, while constraining the non-accepted phases to have no callback debt.
-/
def OpInv (o : Op) : Prop :=
  o.callbackCount ≤ 1 ∧
  o.releaseCount ≤ 1 ∧
  (0 < o.callbackCount →
    o.phase = .accepted ∧ o.terminal = true ∧ o.drained = true) ∧
  (0 < o.releaseCount → o.drained = true ∧ o.leaseHeld = false) ∧
  (o.phase = .prepared →
    o.callbackCount = 0 ∧ o.leaseHeld = true ∧ o.releaseCount = 0) ∧
  (o.phase = .accepted →
    o.releaseCount = o.callbackCount ∧
      (o.callbackCount = 0 → o.leaseHeld = true)) ∧
  (o.phase = .orphan →
    o.callbackCount = 0 ∧ o.leaseHeld = true ∧ o.releaseCount = 0) ∧
  (o.phase = .blocking →
    o.callbackCount = 0 ∧ o.releaseCount = 0) ∧
  (o.phase = .retired → o.callbackCount = 0 ∧ o.leaseHeld = false)

def Valid (s : State) : Prop :=
  OpInv s.op ∧
  s.acceptedDebt = debtContribution s.op ∧
  s.heldLeases = heldContribution s.op ∧
  s.callbacks = s.op.callbackCount ∧
  s.releases = s.op.releaseCount

def preparedInit (generation : Nat) : State :=
  { generation := generation
    op :=
      { phase := .prepared
        terminal := false
        drained := false
        callbackCount := 0
        leaseHeld := true
        releaseCount := 0 }
    acceptedDebt := 0
    heldLeases := 1
    callbacks := 0
    releases := 0 }

def blockingInit (generation : Nat) (hasLease : Bool) : State :=
  { generation := generation
    op :=
      { phase := .blocking
        terminal := false
        drained := false
        callbackCount := 0
        leaseHeld := hasLease
        releaseCount := 0 }
    acceptedDebt := 0
    heldLeases := if hasLease = true then 1 else 0
    callbacks := 0
    releases := 0 }

/-- C++ `accept`: only a prepared async reservation creates callback debt. -/
def acceptPrepared (s : State) : State :=
  if s.op.phase = .prepared then
    { s with
      op := { s.op with phase := .accepted }
      acceptedDebt := s.acceptedDebt + 1 }
  else
    s

/--
C++ `reject_not_accepted` plus its serialized `ReleaseOnly` dispatch.  The
explicit rejection itself is evidence that hardware did not retain the lease.
-/
def rejectNotAccepted (s : State) : State :=
  if s.op.phase = .prepared then
    { s with
      op :=
        { s.op with
          phase := .retired
          drained := true
          leaseHeld := false
          releaseCount := 1 }
      heldLeases := s.heldLeases - 1
      releases := s.releases + 1 }
  else
    s

/-- C++ `reject_indeterminate`: retain ownership and create no accepted debt. -/
def rejectIndeterminate (s : State) : State :=
  if s.op.phase = .prepared then
    { s with op := { s.op with phase := .orphan } }
  else
    s

/--
Completion or control cancellation may assign a terminal result to prepared or
accepted async work.  It cannot release a lease or claim a callback.
-/
def assignTerminal (s : State) : State :=
  match s.op.phase with
  | .prepared => { s with op := { s.op with terminal := true } }
  | .accepted => { s with op := { s.op with terminal := true } }
  | .orphan => s
  | .blocking => s
  | .retired => s

/-- Real per-operation/global recovery evidence.  No callback is claimed here. -/
def markDrained (s : State) : State :=
  { s with op := { s.op with drained := true } }

def Ready (o : Op) : Prop :=
  o.phase = .accepted ∧
  o.terminal = true ∧
  o.drained = true ∧
  o.callbackCount = 0 ∧
  o.leaseHeld = true

instance (o : Op) : Decidable (Ready o) := by
  unfold Ready
  infer_instance

/--
The dispatcher linearization point for one accepted operation.  The C++ owner
ordering differs before/after the external callback, but both orders retire one
lease and one callback exactly once at this abstract point.
-/
def claimCallback (s : State) : State :=
  if Ready s.op then
    { s with
      op :=
        { s.op with
          callbackCount := 1
          leaseHeld := false
          releaseCount := 1 }
      acceptedDebt := s.acceptedDebt - 1
      heldLeases := s.heldLeases - 1
      callbacks := s.callbacks + 1
      releases := s.releases + 1 }
  else
    s

def OrphanReleasable (o : Op) : Prop :=
  o.phase = .orphan ∧
  o.drained = true ∧
  o.leaseHeld = true ∧
  o.releaseCount = 0

instance (o : Op) : Decidable (OrphanReleasable o) := by
  unfold OrphanReleasable
  infer_instance

def releaseOrphan (s : State) : State :=
  if OrphanReleasable s.op then
    { s with
      op :=
        { s.op with
          phase := .retired
          leaseHeld := false
          releaseCount := 1 }
      heldLeases := s.heldLeases - 1
      releases := s.releases + 1 }
  else
    s

/--
C++ `finish_blocking`: backend return is the MMD blocking-call drain evidence.
A lease-free blocking copy retires without a memory-release action.
-/
def finishBlocking (s : State) : State :=
  if s.op.phase = .blocking then
    if s.op.leaseHeld = true then
      { s with
        op :=
          { s.op with
            phase := .retired
            drained := true
            leaseHeld := false
            releaseCount := 1 }
        heldLeases := s.heldLeases - 1
        releases := s.releases + 1 }
    else
      { s with
        op :=
          { s.op with
            phase := .retired
            drained := true
            leaseHeld := false } }
  else
    s

def applyTerminalIfCurrent (eventGeneration : Nat) (s : State) : State :=
  if eventGeneration = s.generation then assignTerminal s else s

def advanceGeneration (s : State) : State :=
  if s.acceptedDebt = 0 ∧ s.heldLeases = 0 then
    { s with generation := s.generation + 1 }
  else
    s

theorem preparedInit_valid (generation : Nat) :
    Valid (preparedInit generation) := by
  simp [Valid, OpInv, preparedInit, debtContribution, heldContribution]

theorem blockingInit_valid (generation : Nat) (hasLease : Bool) :
    Valid (blockingInit generation hasLease) := by
  cases hasLease <;>
    simp [Valid, OpInv, blockingInit, debtContribution, heldContribution]

theorem acceptPrepared_preserves {s : State} (h : Valid s) :
    Valid (acceptPrepared s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  by_cases hc : callbackCount = 0 <;>
    cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    simp [acceptPrepared, Valid, OpInv, debtContribution,
      heldContribution, hc] at * <;>
    omega

theorem rejectNotAccepted_preserves {s : State} (h : Valid s) :
    Valid (rejectNotAccepted s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    simp [rejectNotAccepted, Valid, OpInv, debtContribution,
      heldContribution] at * <;>
    omega

theorem rejectIndeterminate_preserves {s : State} (h : Valid s) :
    Valid (rejectIndeterminate s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    simp [rejectIndeterminate, Valid, OpInv, debtContribution,
      heldContribution] at * <;>
    omega

theorem assignTerminal_preserves {s : State} (h : Valid s) :
    Valid (assignTerminal s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    simp [assignTerminal, Valid, OpInv, debtContribution,
      heldContribution] at * <;>
    omega

theorem markDrained_preserves {s : State} (h : Valid s) :
    Valid (markDrained s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    simp [markDrained, Valid, OpInv, debtContribution,
      heldContribution] at * <;>
    omega

theorem claimCallback_preserves {s : State} (h : Valid s) :
    Valid (claimCallback s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    by_cases hcallback : callbackCount = 0 <;>
    simp [claimCallback, Ready, Valid, OpInv, debtContribution,
      heldContribution, hcallback] at * <;>
    omega

theorem releaseOrphan_preserves {s : State} (h : Valid s) :
    Valid (releaseOrphan s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    by_cases hrelease : releaseCount = 0 <;>
    simp [releaseOrphan, OrphanReleasable, Valid, OpInv,
      debtContribution, heldContribution, hrelease] at * <;>
    omega

theorem finishBlocking_preserves {s : State} (h : Valid s) :
    Valid (finishBlocking s) := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases leaseHeld <;>
    simp [finishBlocking, Valid, OpInv, debtContribution,
      heldContribution] at * <;>
    omega

def acceptedInit (generation : Nat) : State :=
  acceptPrepared (preparedInit generation)

def orphanInit (generation : Nat) : State :=
  rejectIndeterminate (preparedInit generation)

theorem acceptedInit_valid (generation : Nat) :
    Valid (acceptedInit generation) := by
  exact acceptPrepared_preserves (preparedInit_valid generation)

theorem orphanInit_valid (generation : Nat) :
    Valid (orphanInit generation) := by
  exact rejectIndeterminate_preserves (preparedInit_valid generation)

theorem applyTerminalIfCurrent_preserves {s : State}
    (eventGeneration : Nat) (h : Valid s) :
    Valid (applyTerminalIfCurrent eventGeneration s) := by
  by_cases hg : eventGeneration = s.generation
  · rw [applyTerminalIfCurrent, if_pos hg]
    exact assignTerminal_preserves h
  · rw [applyTerminalIfCurrent, if_neg hg]
    exact h

theorem stale_generation_no_effect {s : State} {eventGeneration : Nat}
    (h : eventGeneration ≠ s.generation) :
    applyTerminalIfCurrent eventGeneration s = s := by
  simp [applyTerminalIfCurrent, h]

theorem advanceGeneration_preserves {s : State} (h : Valid s) :
    Valid (advanceGeneration s) := by
  by_cases hready : s.acceptedDebt = 0 ∧ s.heldLeases = 0
  · rw [advanceGeneration, if_pos hready]
    simpa [Valid] using h
  · rw [advanceGeneration, if_neg hready]
    exact h

theorem assignTerminal_keeps_ownership (s : State) :
    (assignTerminal s).heldLeases = s.heldLeases ∧
    (assignTerminal s).releases = s.releases ∧
    (assignTerminal s).callbacks = s.callbacks := by
  cases hp : s.op.phase <;> simp [assignTerminal, hp]

theorem markDrained_keeps_notification_counts (s : State) :
    (markDrained s).callbacks = s.callbacks ∧
    (markDrained s).releases = s.releases := by
  simp [markDrained]

theorem acceptPrepared_creates_one_debt {s : State}
    (hphase : s.op.phase = .prepared) :
    (acceptPrepared s).acceptedDebt = s.acceptedDebt + 1 := by
  simp [acceptPrepared, hphase]

theorem rejectNotAccepted_has_no_debt {s : State}
    (h : Valid s) (hphase : s.op.phase = .prepared) :
    (rejectNotAccepted s).acceptedDebt = 0 := by
  have hdebt : s.acceptedDebt = 0 := by
    simpa [debtContribution, hphase] using h.2.1
  simp [rejectNotAccepted, hphase, hdebt]

theorem finishBlocking_never_callbacks (s : State) :
    (finishBlocking s).callbacks = s.callbacks := by
  by_cases hp : s.op.phase = .blocking
  · by_cases hl : s.op.leaseHeld = true <;>
      simp [finishBlocking, hp, hl]
  · simp [finishBlocking, hp]

theorem claimCallback_idempotent (s : State) :
    claimCallback (claimCallback s) = claimCallback s := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases terminal <;> cases drained <;> cases callbackCount <;>
    cases leaseHeld <;>
    simp [claimCallback, Ready]

theorem releaseOrphan_idempotent (s : State) :
    releaseOrphan (releaseOrphan s) = releaseOrphan s := by
  rcases s with ⟨generation, op, acceptedDebt, heldLeases, callbacks, releases⟩
  rcases op with
    ⟨phase, terminal, drained, callbackCount, leaseHeld, releaseCount⟩
  cases phase <;> cases drained <;> cases leaseHeld <;> cases releaseCount <;>
    simp [releaseOrphan, OrphanReleasable]

theorem ready_claims_exactly_once {s : State} (hready : Ready s.op) :
    (claimCallback s).op.callbackCount = 1 ∧
    (claimCallback s).op.leaseHeld = false ∧
    (claimCallback s).op.releaseCount = 1 := by
  simp [claimCallback, hready]

theorem terminal_without_drain_cannot_notify {s : State}
    (haccepted : s.op.phase = .accepted)
    (hterminal : s.op.terminal = true)
    (hnotDrained : s.op.drained = false) :
    claimCallback s = s := by
  simp [claimCallback, Ready, haccepted, hterminal, hnotDrained]

theorem drain_without_terminal_cannot_notify {s : State}
    (haccepted : s.op.phase = .accepted)
    (hnotTerminal : s.op.terminal = false)
    (hdrained : s.op.drained = true) :
    claimCallback s = s := by
  simp [claimCallback, Ready, haccepted, hnotTerminal, hdrained]

theorem callback_implies_terminal_drain {s : State} (h : Valid s)
    (hcallback : 0 < s.op.callbackCount) :
    s.op.phase = .accepted ∧ s.op.terminal = true ∧ s.op.drained = true := by
  rcases h.1 with
    ⟨_, _, hsafe, _, _, _, _, _, _⟩
  exact hsafe hcallback

theorem release_implies_drain_and_no_lease {s : State} (h : Valid s)
    (hrelease : 0 < s.op.releaseCount) :
    s.op.drained = true ∧ s.op.leaseHeld = false := by
  rcases h.1 with
    ⟨_, _, _, hsafe, _, _, _, _, _⟩
  exact hsafe hrelease

theorem exactly_once_upper_bound {s : State} (h : Valid s) :
    s.op.callbackCount ≤ 1 :=
  h.1.1

theorem release_once_upper_bound {s : State} (h : Valid s) :
    s.op.releaseCount ≤ 1 :=
  h.1.2.1

theorem orphan_never_callbacks {s : State} (h : Valid s)
    (horphan : s.op.phase = .orphan) : s.op.callbackCount = 0 := by
  rcases h.1 with
    ⟨_, _, _, _, _, _, horphanShape, _, _⟩
  exact (horphanShape horphan).1

theorem blocking_never_callbacks {s : State} (h : Valid s)
    (hblocking : s.op.phase = .blocking) : s.op.callbackCount = 0 := by
  rcases h.1 with
    ⟨_, _, _, _, _, _, _, hblockingShape, _⟩
  exact (hblockingShape hblocking).1

inductive LedgerValid : List Op → Prop where
  | nil : LedgerValid []
  | cons {op : Op} {rest : List Op} :
      OpInv op → LedgerValid rest → LedgerValid (op :: rest)

theorem callback_sum_le_length {ops : List Op} (h : LedgerValid ops) :
    (ops.map (fun op => op.callbackCount)).sum ≤ ops.length := by
  induction h with
  | nil => simp
  | @cons op rest hop _ ih =>
      simp only [List.map_cons, List.sum_cons, List.length_cons]
      have hhead : op.callbackCount ≤ 1 := hop.1
      omega

theorem release_sum_le_length {ops : List Op} (h : LedgerValid ops) :
    (ops.map (fun op => op.releaseCount)).sum ≤ ops.length := by
  induction h with
  | nil => simp
  | @cons op rest hop _ ih =>
      simp only [List.map_cons, List.sum_cons, List.length_cons]
      have hhead : op.releaseCount ≤ 1 := hop.2.1
      omega

inductive Transition : State → State → Prop where
  | acceptPrepared (s : State) : Transition s (acceptPrepared s)
  | rejectNotAccepted (s : State) : Transition s (rejectNotAccepted s)
  | rejectIndeterminate (s : State) : Transition s (rejectIndeterminate s)
  | assignTerminal (s : State) : Transition s (assignTerminal s)
  | markDrained (s : State) : Transition s (markDrained s)
  | claimCallback (s : State) : Transition s (claimCallback s)
  | releaseOrphan (s : State) : Transition s (releaseOrphan s)
  | finishBlocking (s : State) : Transition s (finishBlocking s)
  | currentTerminal (generation : Nat) (s : State) :
      Transition s (applyTerminalIfCurrent generation s)
  | advanceGeneration (s : State) : Transition s (advanceGeneration s)
  | duplicateOrStale (s : State) : Transition s s

theorem transition_preserves {s s' : State} (h : Valid s)
    (step : Transition s s') : Valid s' := by
  cases step with
  | acceptPrepared => exact acceptPrepared_preserves h
  | rejectNotAccepted => exact rejectNotAccepted_preserves h
  | rejectIndeterminate => exact rejectIndeterminate_preserves h
  | assignTerminal => exact assignTerminal_preserves h
  | markDrained => exact markDrained_preserves h
  | claimCallback => exact claimCallback_preserves h
  | releaseOrphan => exact releaseOrphan_preserves h
  | finishBlocking => exact finishBlocking_preserves h
  | currentTerminal generation =>
      exact applyTerminalIfCurrent_preserves generation h
  | advanceGeneration => exact advanceGeneration_preserves h
  | duplicateOrStale => exact h

/-- Reachability closes the invariant proof over arbitrary finite transition traces. -/
inductive Reachable : State → Prop where
  | fromPrepared (generation : Nat) : Reachable (preparedInit generation)
  | fromBlocking (generation : Nat) (hasLease : Bool) :
      Reachable (blockingInit generation hasLease)
  | step {s s' : State} : Reachable s → Transition s s' → Reachable s'

theorem reachable_valid {s : State} (h : Reachable s) : Valid s := by
  induction h with
  | fromPrepared generation => exact preparedInit_valid generation
  | fromBlocking generation hasLease =>
      exact blockingInit_valid generation hasLease
  | step _ transition ih => exact transition_preserves ih transition

theorem reachable_exactly_once {s : State} (h : Reachable s) :
    s.op.callbackCount ≤ 1 :=
  exactly_once_upper_bound (reachable_valid h)

theorem reachable_release_once {s : State} (h : Reachable s) :
    s.op.releaseCount ≤ 1 :=
  release_once_upper_bound (reachable_valid h)

theorem reachable_callback_requires_terminal_drain {s : State}
    (h : Reachable s) (hcallback : 0 < s.op.callbackCount) :
    s.op.phase = .accepted ∧ s.op.terminal = true ∧ s.op.drained = true :=
  callback_implies_terminal_drain (reachable_valid h) hcallback

/-!
Conditional progress only: terminal state and actual drain evidence are explicit
premises.  There is intentionally no theorem asserting that hardware eventually
stops fetching descriptors or touching payload/writeback memory.
-/
theorem fair_drain_conditional_progress {s : State}
    (hphase : s.op.phase = .accepted)
    (hterminal : s.op.terminal = true)
    (hdrained : s.op.drained = true)
    (hcallback : s.op.callbackCount = 0)
    (hlease : s.op.leaseHeld = true) :
    (claimCallback s).op.callbackCount = 1 := by
  have hready : Ready s.op :=
    ⟨hphase, hterminal, hdrained, hcallback, hlease⟩
  exact (ready_claims_exactly_once hready).1

end DmaLifecycle

#print axioms DmaLifecycle.preparedInit_valid
#print axioms DmaLifecycle.blockingInit_valid
#print axioms DmaLifecycle.acceptPrepared_preserves
#print axioms DmaLifecycle.rejectNotAccepted_preserves
#print axioms DmaLifecycle.rejectIndeterminate_preserves
#print axioms DmaLifecycle.assignTerminal_preserves
#print axioms DmaLifecycle.markDrained_preserves
#print axioms DmaLifecycle.claimCallback_preserves
#print axioms DmaLifecycle.releaseOrphan_preserves
#print axioms DmaLifecycle.finishBlocking_preserves
#print axioms DmaLifecycle.acceptedInit_valid
#print axioms DmaLifecycle.orphanInit_valid
#print axioms DmaLifecycle.applyTerminalIfCurrent_preserves
#print axioms DmaLifecycle.stale_generation_no_effect
#print axioms DmaLifecycle.advanceGeneration_preserves
#print axioms DmaLifecycle.assignTerminal_keeps_ownership
#print axioms DmaLifecycle.markDrained_keeps_notification_counts
#print axioms DmaLifecycle.acceptPrepared_creates_one_debt
#print axioms DmaLifecycle.rejectNotAccepted_has_no_debt
#print axioms DmaLifecycle.finishBlocking_never_callbacks
#print axioms DmaLifecycle.claimCallback_idempotent
#print axioms DmaLifecycle.releaseOrphan_idempotent
#print axioms DmaLifecycle.ready_claims_exactly_once
#print axioms DmaLifecycle.terminal_without_drain_cannot_notify
#print axioms DmaLifecycle.drain_without_terminal_cannot_notify
#print axioms DmaLifecycle.callback_implies_terminal_drain
#print axioms DmaLifecycle.release_implies_drain_and_no_lease
#print axioms DmaLifecycle.exactly_once_upper_bound
#print axioms DmaLifecycle.release_once_upper_bound
#print axioms DmaLifecycle.orphan_never_callbacks
#print axioms DmaLifecycle.blocking_never_callbacks
#print axioms DmaLifecycle.callback_sum_le_length
#print axioms DmaLifecycle.release_sum_le_length
#print axioms DmaLifecycle.transition_preserves
#print axioms DmaLifecycle.reachable_valid
#print axioms DmaLifecycle.reachable_exactly_once
#print axioms DmaLifecycle.reachable_release_once
#print axioms DmaLifecycle.reachable_callback_requires_terminal_drain
#print axioms DmaLifecycle.fair_drain_conditional_progress
