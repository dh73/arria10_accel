/-
SPDX-License-Identifier: BSD-3-Clause
Finite owner/receipt lifecycle, Lean 4.19.0. This is an explicit model, not
SystemVerilog elaboration, RTL refinement, or a PCIe/host visibility proof.

An arbitrary owner-slot projection is modeled. Source phases offered, queued,
publishing, fence, and high include every eligible logical copy before/at the
held receipt; low has no eligible copy. Inactive RAM bits are not valid copies. Cumulative accounting
fields are mathematical ghosts; token, phase and outstanding debt are bounded.
There is no reset transition: base is a locally initialized, externally fenced
starting condition, never a claim that reset drains the fabric.
-/
import Std

namespace ReuseV3

inductive OwnerPhase where
  | free | active | sealed | taken
  deriving DecidableEq, Repr

inductive SourcePhase where
  | idle | offered | queued | publishing | fence | high | low
  deriving DecidableEq, Repr

structure Token where
  id : Nat
  generation : Nat
  deriving DecidableEq, Repr

structure State where
  owner : OwnerPhase
  source : SourcePhase
  id : Nat
  generation : Nat
  receipt : Option Token
  closed : Bool
  failed : Bool
  fault : Bool
  issued : Nat
  released : Nat
  tags : Nat
  enqueued : Nat
  accepted : Nat
  commands : Nat
  deriving DecidableEq, Repr

def token (s : State) : Token := ⟨s.id, s.generation⟩

def hasCopy (p : SourcePhase) : Prop :=
  p = .offered ∨ p = .queued ∨ p = .publishing ∨ p = .fence ∨ p = .high

def compatible (s : State) : Prop :=
  match s.owner with
  | .free | .active => s.source = .idle ∨ s.source = .low
  | .sealed => hasCopy s.source
  | .taken => s.source = .high ∨ s.source = .low

def Invariant (s : State) : Prop :=
  s.id < 256 ∧ s.generation ≤ 255 ∧
  (s.owner ≠ .free → 0 < s.generation) ∧
  s.tags ≤ 16 ∧ s.commands ≤ 16 ∧
  s.issued = s.released + s.tags ∧
  s.enqueued = s.accepted + s.commands ∧
  compatible s ∧
  (hasCopy s.source → s.receipt = some (token s)) ∧
  (¬hasCopy s.source → s.receipt = none) ∧
  ((s.owner = .sealed ∨ s.owner = .taken) →
    s.closed = true ∧ s.failed = false ∧ s.tags = 0 ∧ s.commands = 0) ∧
  (s.failed = true → s.owner = .active)

def initial : State :=
  ⟨.free, .idle, 0, 0, none, false, false, false, 0, 0, 0, 0, 0, 0⟩

def nextGeneration (g : Nat) : Nat := if g = 255 then 1 else g + 1

def allocate (s : State) (id : Nat) : State :=
  { s with
    owner := .active
    id := id
    generation := nextGeneration s.generation
    closed := false
    failed := false
    issued := 0
    released := 0
    tags := 0
    enqueued := 0
    accepted := 0
    commands := 0 }

structure Events where
  issue : Nat
  releaseTag : Nat
  header : Nat
  acceptCommand : Nat
  close : Bool
  fail : Bool
  deriving DecidableEq, Repr

def LegalEvents (s : State) (e : Events) : Prop :=
  s.owner = .active ∧ s.fault = false ∧
  e.issue ≤ 1 ∧ e.releaseTag ≤ 1 ∧ e.header ≤ 1 ∧ e.acceptCommand ≤ 1 ∧
  e.releaseTag ≤ s.tags ∧ e.acceptCommand ≤ s.commands ∧
  s.tags + e.issue - e.releaseTag ≤ 16 ∧
  s.commands + e.header - e.acceptCommand ≤ 16 ∧
  (e.issue = 1 → s.closed = false) ∧
  (e.header = 1 → 0 < s.tags)

def tick (s : State) (e : Events) : State :=
  { s with
    closed := s.closed || e.close
    failed := s.failed || e.fail
    issued := s.issued + e.issue
    released := s.released + e.releaseTag
    tags := s.tags + e.issue - e.releaseTag
    enqueued := s.enqueued + e.header
    accepted := s.accepted + e.acceptCommand
    commands := s.commands + e.header - e.acceptCommand }

def Eligible (s : State) : Prop :=
  s.owner = .active ∧ s.source = .idle ∧ s.fault = false ∧
  s.closed = true ∧ s.failed = false ∧ s.tags = 0 ∧ s.commands = 0

def sealOwner (s : State) : State :=
  { s with owner := .sealed, source := .offered, receipt := some (token s) }

def enqueue (s : State) : State := { s with source := .queued }
def deliver (s : State) : State := { s with source := .publishing }
def publish (s : State) : State := { s with source := .high }
def fetchPublish (s : State) : State := { s with source := .fence }
def fetchFence (s : State) : State := { s with source := .high }
def take (s : State) : State := { s with owner := .taken }
def drop (s : State) : State := { s with source := .low, receipt := none }
def release (s : State) : State := { s with owner := .free }
def rearm (s : State) : State := { s with source := .idle }
def setFault (s : State) : State := { s with fault := true }

/-- Guards concern actual phases. In particular allocation does NOT assume
receipt emptiness, and release does NOT assume it: those are proved below. -/
inductive Step : State → State → Prop where
  | hold {s} : Step s s
  | allocate {s id} : s.owner = .free → s.fault = false → id < 256 →
      Step s (allocate s id)
  | tick {s e} : LegalEvents s e → Step s (tick s e)
  | sealOwner {s} : Eligible s → Step s (sealOwner s)
  | enqueue {s} : s.source = .offered → Step s (enqueue s)
  | deliver {s} : s.source = .queued → Step s (deliver s)
  | publish {s} : s.source = .publishing → Step s (publish s)
  | fetchPublish {s} : s.source = .publishing → Step s (fetchPublish s)
  | fetchFence {s} : s.source = .fence → Step s (fetchFence s)
  | take {s} : s.owner = .sealed → s.source = .high → s.fault = false →
      Step s (take s)
  | drop {s} : s.owner = .taken → s.source = .high → Step s (drop s)
  | release {s} : s.owner = .taken → s.source = .low → s.fault = false →
      Step s (release s)
  | rearm {s} : s.owner ≠ .taken → s.source = .low → Step s (rearm s)
  | fault {s} : Step s (setFault s)

inductive Reachable : State → Prop where
  | base : Reachable initial
  | step {s t} : Reachable s → Step s t → Reachable t

theorem base : Invariant initial := by
  simp [Invariant, initial, compatible, hasCopy]

theorem nextGeneration_bounds {g : Nat} (h : g ≤ 255) :
    0 < nextGeneration g ∧ nextGeneration g ≤ 255 := by
  unfold nextGeneration
  split <;> omega

theorem allocation_step {s : State} {id : Nat}
    (h : Invariant s) (free : s.owner = .free) (hid : id < 256) :
    Invariant (allocate s id) := by
  rcases h with ⟨_, hg, _, _, _, _, _, hc, hsome, hnone, _, _⟩
  have hb := nextGeneration_bounds hg
  have hs : s.source = .idle ∨ s.source = .low := by
    cases hsource : s.source <;> simp_all [compatible]
  rcases hs with hs | hs <;>
    simp_all [Invariant, allocate, compatible, hasCopy, token]

theorem event_step {s : State} {e : Events}
    (h : Invariant s) (ok : LegalEvents s e) : Invariant (tick s e) := by
  rcases h with ⟨hi, hg, hpos, ht, hc, hread, hcommand, hcompat,
    hsome, hnone, _, _⟩
  rcases ok with ⟨ha, _, _, _, _, _, hr, hw, htb, hcb, _, _⟩
  have hs : s.source = .idle ∨ s.source = .low := by
    cases hsource : s.source <;> simp_all [compatible]
  have eqr : s.issued + e.issue =
      s.released + e.releaseTag + (s.tags + e.issue - e.releaseTag) := by omega
  have eqc : s.enqueued + e.header =
      s.accepted + e.acceptCommand +
      (s.commands + e.header - e.acceptCommand) := by omega
  rcases hs with hs | hs <;>
    simp_all [Invariant, tick, compatible, hasCopy, token]

theorem seal_step {s : State} (h : Invariant s) (ok : Eligible s) :
    Invariant (sealOwner s) := by
  rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, _, _, _, _, _⟩
  rcases ok with ⟨ho, hs, _, hclosed, hfailed, htags, hcommands⟩
  simp_all [Invariant, sealOwner, compatible, hasCopy, token]

theorem step {s t : State} (h : Invariant s) (st : Step s t) : Invariant t := by
  cases st with
  | hold => exact h
  | allocate ho _ hi => exact allocation_step h ho hi
  | tick ok => exact event_step h ok
  | sealOwner ok => exact seal_step h ok
  | enqueue hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      cases ho : s.owner <;>
        simp_all [Invariant, enqueue, compatible, hasCopy, token]
  | deliver hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      cases ho : s.owner <;>
        simp_all [Invariant, deliver, compatible, hasCopy, token]
  | publish hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      cases ho : s.owner <;>
        simp_all [Invariant, publish, compatible, hasCopy, token]
  | fetchPublish hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      cases ho : s.owner <;>
        simp_all [Invariant, fetchPublish, compatible, hasCopy, token]
  | fetchFence hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      cases ho : s.owner <;>
        simp_all [Invariant, fetchFence, compatible, hasCopy, token]
  | take ho hs _ =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      simp_all [Invariant, take, compatible, hasCopy, token]
  | drop ho hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      simp_all [Invariant, drop, compatible, hasCopy, token]
  | release ho hs _ =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      simp_all [Invariant, release, compatible, hasCopy, token]
  | rearm ho hs =>
      rcases h with ⟨hi, hg, hp, ht, hc, hr, hw, hcompat, hsome, hnone, hsuccess, hfail⟩
      cases howner : s.owner <;>
        simp_all [Invariant, rearm, compatible, hasCopy, token]
  | fault => exact h

theorem reachable_invariant {s : State} (h : Reachable s) : Invariant s := by
  induction h with
  | base => exact base
  | step _ st ih => exact step ih st

/-- Free ownership implies every eligible success/receipt copy has gone.
This is derived from reachable structural phases, not an allocation premise. -/
theorem free_has_no_old_receipt {s : State}
    (h : Reachable s) (hf : s.owner = .free) :
    ¬hasCopy s.source ∧ s.receipt = none := by
  have hi := reachable_invariant h
  rcases hi with ⟨_, _, _, _, _, _, _, hc, _, hn, _, _⟩
  have hs : ¬hasCopy s.source := by
    cases hsource : s.source <;> simp_all [compatible, hasCopy]
  exact ⟨hs, hn hs⟩

/-- A finite generation can wrap precisely because the receipt channel has
already relinquished the preceding ownership. No nonwrapping bound is used. -/
theorem allocation_reuse_safe {s : State} {id : Nat}
    (h : Reachable s) (hf : s.owner = .free) (noFault : s.fault = false)
    (hid : id < 256) :
    Reachable (allocate s id) ∧ ¬hasCopy s.source ∧ s.receipt = none ∧
    0 < (allocate s id).generation ∧ (allocate s id).generation ≤ 255 := by
  have hclear := free_has_no_old_receipt h hf
  have hg := nextGeneration_bounds (reachable_invariant h).2.1
  exact ⟨Reachable.step h (.allocate hf noFault hid), hclear.1, hclear.2, hg⟩

theorem wrap_is_reusable {s : State} {id : Nat}
    (h : Reachable s) (hf : s.owner = .free) (noFault : s.fault = false)
    (hid : id < 256) (h255 : s.generation = 255) :
    Reachable (allocate s id) ∧ (allocate s id).generation = 1 ∧
    s.receipt = none := by
  have hs := allocation_reuse_safe h hf noFault hid
  exact ⟨hs.1, by simp [allocate, nextGeneration, h255], hs.2.2.1⟩

/-- A held/high ACK cannot free the owner. There is one take, followed by an
actual source low phase before a release. Holds are idempotent stutters. -/
theorem high_never_releases {s t : State}
    (ho : s.owner = .taken) (hs : s.source = .high) (st : Step s t) :
    t.owner = .taken := by
  cases st <;> simp_all [allocate, LegalEvents, tick, Eligible, sealOwner,
    enqueue, deliver, publish, fetchPublish, fetchFence, take, drop, release, rearm, setFault]

/-- Once fault is observed, even an already taken receipt cannot release.
For same-edge external faults the RTL must evaluate its fault next-state before
applying release, as the implementation does; that is a refinement obligation. -/
theorem fault_blocks_release {s t : State}
    (ho : s.owner = .taken) (hf : s.fault = true) (st : Step s t) :
    t.owner = .taken := by
  cases st <;> simp_all [allocate, LegalEvents, tick, Eligible, sealOwner,
    enqueue, deliver, publish, fetchPublish, fetchFence, take, drop, release,
    rearm, setFault]

theorem taken_low_has_no_copy {s : State}
    (h : Reachable s) (hs : s.source = .low) : s.receipt = none := by
  exact (reachable_invariant h).2.2.2.2.2.2.2.2.2.1 (by simp [hasCopy, hs])

theorem success_accounts_for_all_work {s : State}
    (h : Reachable s) (ho : s.owner = .sealed ∨ s.owner = .taken) :
    s.issued = s.released ∧ s.enqueued = s.accepted := by
  rcases reachable_invariant h with ⟨_, _, _, _, _, hr, hw, _, _, _, hsuccess, _⟩
  rcases hsuccess ho with ⟨_, _, ht, hc⟩
  omega

theorem same_edge_error_blocks_success (s : State) (e : Events)
    (hf : e.fail = true) : ¬Eligible (tick s e) := by
  intro h
  have failure := h.2.2.2.2.1
  simp [tick, hf] at failure

/-- Errors keep ownership; none of the release transitions is enabled. -/
theorem failure_quarantines {s t : State}
    (h : Reachable s) (hf : s.failed = true) (st : Step s t) :
    t.owner = .active ∧ t.failed = true := by
  have ho := (reachable_invariant h).2.2.2.2.2.2.2.2.2.2.2 hf
  cases st <;> simp_all [allocate, LegalEvents, tick, Eligible, sealOwner,
    enqueue, deliver, publish, fetchPublish, fetchFence, take, drop, release, rearm, setFault]

/-- Malformed identity is rejected by the owner before entering taken.
A byte-identical replay after generation reuse is NOT distinguishable by this
predicate; its exclusion follows only from the connected producer lifecycle. -/
def AckMatches (s : State) (a : Token) : Prop :=
  s.owner = .sealed ∧ s.source = .high ∧ a = token s ∧ s.fault = false

theorem foreign_ack_rejected {s : State} {a : Token}
    (h : a ≠ token s) : ¬AckMatches s a := by
  intro hm
  exact h hm.2.2.1


/-- Pointwise lifting to sixteen slots. This transfers the proved single-slot
property; it does not prove the RTL admission FIFO or cross-slot arbitration. -/
theorem sixteen_slots_have_no_free_copies (slots : Fin 16 → State)
    (h : ∀ i, Reachable (slots i)) :
    ∀ i, (slots i).owner = .free →
      ¬hasCopy (slots i).source ∧ (slots i).receipt = none := by
  intro i hf
  exact free_has_no_old_receipt (h i) hf

/-- Finite words necessarily recur: wrapping the diagnostic generation yields
exactly the old generation-one identity. Word comparison alone is insufficient. -/
theorem wrap_can_repeat_word (s : State) (id : Nat) (hg : s.generation = 255) :
    token (allocate s id) = ⟨id, 1⟩ := by
  simp [token, allocate, nextGeneration, hg]

#print axioms base
#print axioms step
#print axioms reachable_invariant
#print axioms allocation_reuse_safe
#print axioms wrap_is_reusable
#print axioms high_never_releases
#print axioms fault_blocks_release
#print axioms success_accounts_for_all_work
#print axioms same_edge_error_blocks_success
#print axioms failure_quarantines

end ReuseV3
