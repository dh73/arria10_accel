/-
SPDX-License-Identifier: BSD-3-Clause

Candidate-v2 mathematical accounting model, Lean 4.19.0.

This file proves base/step properties of the transition relation below. It does
NOT translate, elaborate, or establish equivalence with SystemVerilog. The RTL
must separately establish the event-refinement obligations in VALIDATION.md.
Natural counters do not prove finite-width counter nonoverflow.
-/
import Std

namespace RetirementV2

structure Owner where
  id : Nat
  epoch : Nat
  live : Bool
  closed : Bool
  failed : Bool
  sealed : Bool
  issued : Nat
  released : Nat
  tags : Nat
  enqueued : Nat
  accepted : Nat
  commands : Nat
  deriving DecidableEq, Repr

def resetOwner : Owner :=
  ⟨0, 0, false, false, false, false, 0, 0, 0, 0, 0, 0⟩

def OwnerInvariant (s : Owner) : Prop :=
  s.epoch ≤ 255 ∧ s.id < 256 ∧
  s.issued = s.released + s.tags ∧
  s.enqueued = s.accepted + s.commands

/-- Counts denote actual accepted events, each at most once per cycle. -/
structure Events where
  issue : Nat
  releaseTag : Nat
  header : Nat
  acceptCommand : Nat
  close : Bool
  fail : Bool
  deriving DecidableEq, Repr

/-- Release/accept cannot consume debt which is absent even after same-edge
    enqueue. Closed or sealed owners cannot create another memory request. -/
def LegalEvents (s : Owner) (e : Events) : Prop :=
  s.live = true ∧
  e.issue ≤ 1 ∧ e.releaseTag ≤ 1 ∧
  e.header ≤ 1 ∧ e.acceptCommand ≤ 1 ∧
  e.releaseTag ≤ s.tags + e.issue ∧
  e.acceptCommand ≤ s.commands + e.header ∧
  (s.closed = true → e.issue = 0) ∧
  (s.sealed = true → e.issue = 0 ∧ e.header = 0)

def tick (s : Owner) (e : Events) : Owner :=
  { s with
    closed := s.closed || e.close
    failed := s.failed || e.fail
    issued := s.issued + e.issue
    released := s.released + e.releaseTag
    tags := s.tags + e.issue - e.releaseTag
    enqueued := s.enqueued + e.header
    accepted := s.accepted + e.acceptCommand
    commands := s.commands + e.header - e.acceptCommand }

theorem base : OwnerInvariant resetOwner := by
  simp [OwnerInvariant, resetOwner]

/-- Simultaneous up/down events use one arithmetic transition. -/
theorem step (s : Owner) (e : Events)
    (h : OwnerInvariant s) (ok : LegalEvents s e) :
    OwnerInvariant (tick s e) := by
  rcases h with ⟨hepoch, hid, htags, hcommands⟩
  rcases ok with ⟨_, _, _, _, _, hrelease, haccept, _, _⟩
  unfold OwnerInvariant tick
  simp only
  exact ⟨hepoch, hid, by omega, by omega⟩

/-- Failure on this edge participates before status eligibility is evaluated. -/
def SuccessEligible (s : Owner) : Prop :=
  s.live = true ∧ s.closed = true ∧ s.failed = false ∧
  s.sealed = false ∧ s.tags = 0 ∧ s.commands = 0

def sealOwner (s : Owner) : Owner := { s with sealed := true }

theorem seal_step (s : Owner) (h : OwnerInvariant s) :
    OwnerInvariant (sealOwner s) := by
  exact h

theorem success_means_all_accounted_events_retired
    (s : Owner) (h : OwnerInvariant s) (ok : SuccessEligible s) :
    s.issued = s.released ∧ s.enqueued = s.accepted := by
  rcases h with ⟨_, _, ht, hc⟩
  rcases ok with ⟨_, _, _, _, zt, zc⟩
  omega

theorem same_edge_error_blocks_success (s : Owner) (e : Events)
    (hfail : e.fail = true) : ¬ SuccessEligible (tick s e) := by
  intro h
  have hf := h.2.2.1
  simp [tick, hfail] at hf

theorem sealed_owner_does_not_issue (s : Owner) (e : Events)
    (hs : s.sealed = true) (ok : LegalEvents s e) : e.issue = 0 := by
  exact (ok.2.2.2.2.2.2.2.2 hs).1

def allocate (s : Owner) (id : Nat) : Owner :=
  ⟨id, s.epoch + 1, true, false, false, false, 0, 0, 0, 0, 0, 0⟩

def LegalAllocation (s : Owner) (id : Nat) : Prop :=
  s.live = false ∧ s.epoch < 255 ∧ id < 256

theorem allocation_step (s : Owner) (id : Nat)
    (ok : LegalAllocation s id) : OwnerInvariant (allocate s id) := by
  rcases ok with ⟨_, he, hi⟩
  change s.epoch + 1 ≤ 255 ∧ id < 256 ∧ 0 = 0 + 0 ∧ 0 = 0 + 0
  exact ⟨by omega, hi, rfl, rfl⟩

theorem allocated_epoch_strictly_increases (s : Owner) (id : Nat) :
    s.epoch < (allocate s id).epoch := by
  simp [allocate]

/-- Acknowledgment contains the immutable identity of the queued status.
    `postedAccepted` is only local acceptance, never host visibility evidence. -/
structure Ack where
  id : Nat
  epoch : Nat
  postedAccepted : Bool
  deriving DecidableEq, Repr

def AckMatches (s : Owner) (a : Ack) : Prop :=
  s.live = true ∧ s.sealed = true ∧
  a.id = s.id ∧ a.epoch = s.epoch ∧ a.postedAccepted = true

def acknowledge (s : Owner) : Owner := { s with live := false }

theorem acknowledge_step (s : Owner) (h : OwnerInvariant s) :
    OwnerInvariant (acknowledge s) := by
  exact h

theorem stale_epoch_cannot_ack (s : Owner) (a : Ack)
    (hstale : a.epoch ≠ s.epoch) : ¬ AckMatches s a := by
  intro h
  exact hstale h.2.2.2.1

theorem foreign_id_cannot_ack (s : Owner) (a : Ack)
    (hforeign : a.id ≠ s.id) : ¬ AckMatches s a := by
  intro h
  exact hforeign h.2.2.1

/-- Induction explicitly separates reset, allocation, accounting, sealing, and
    acknowledgment. Every Step is guarded by the relevant protocol condition. -/
inductive OwnerStep : Owner → Owner → Prop where
  | tick {s e} : LegalEvents s e → OwnerStep s (tick s e)
  | allocate {s id} : LegalAllocation s id → OwnerStep s (allocate s id)
  | sealOwner {s} : SuccessEligible s → OwnerStep s (sealOwner s)
  | acknowledge {s a} : AckMatches s a → OwnerStep s (acknowledge s)
  | reset {s} : OwnerStep s resetOwner

inductive Reachable : Owner → Prop where
  | base : Reachable resetOwner
  | step {s s'} : Reachable s → OwnerStep s s' → Reachable s'

theorem reachable_invariant {s : Owner} (h : Reachable s) : OwnerInvariant s := by
  induction h with
  | base => exact base
  | @step s s' _ hstep ih =>
      cases hstep with
      | tick ok => exact step s _ ih ok
      | allocate ok => exact allocation_step s _ ok
      | sealOwner _ => exact seal_step s ih
      | acknowledge _ => exact acknowledge_step s ih
      | reset => exact base

/-- Abstract finite queue conservation. push/pop are accepted handshakes, not
    raw attempts. Empty pop is disallowed; full queue may replace its head. -/
structure Queue where
  count : Nat
  pushed : Nat
  popped : Nat
  deriving DecidableEq, Repr

def resetQueue : Queue := ⟨0, 0, 0⟩

def QueueInvariant (capacity : Nat) (s : Queue) : Prop :=
  s.count ≤ capacity ∧ s.pushed = s.popped + s.count

def QueueLegal (capacity : Nat) (s : Queue) (push pop : Nat) : Prop :=
  push ≤ 1 ∧ pop ≤ 1 ∧ pop ≤ s.count ∧
  s.count + push ≤ capacity + pop

def queueTick (s : Queue) (push pop : Nat) : Queue :=
  ⟨s.count + push - pop, s.pushed + push, s.popped + pop⟩

theorem queue_base (capacity : Nat) : QueueInvariant capacity resetQueue := by
  simp [QueueInvariant, resetQueue]

theorem queue_step (capacity : Nat) (s : Queue) (push pop : Nat)
    (h : QueueInvariant capacity s) (ok : QueueLegal capacity s push pop) :
    QueueInvariant capacity (queueTick s push pop) := by
  rcases h with ⟨hc, hs⟩
  rcases ok with ⟨hp, hpop, hnonempty, hroom⟩
  unfold QueueInvariant queueTick
  simp only
  constructor <;> omega

theorem full_without_pop_refuses_push (capacity : Nat) (s : Queue) (push : Nat)
    (hfull : s.count = capacity) (ok : QueueLegal capacity s push 0) :
    push = 0 := by
  rcases ok with ⟨_, _, _, hroom⟩
  omega

theorem queue_empty_never_pops (capacity : Nat) (s : Queue) (push pop : Nat)
    (hempty : s.count = 0) (ok : QueueLegal capacity s push pop) : pop = 0 := by
  rcases ok with ⟨_, _, hnonempty, _⟩
  omega

#print axioms base
#print axioms step
#print axioms reachable_invariant
#print axioms same_edge_error_blocks_success
#print axioms stale_epoch_cannot_ack
#print axioms queue_step

end RetirementV2
