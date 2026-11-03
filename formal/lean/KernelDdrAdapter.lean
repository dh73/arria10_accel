import Std.Tactic

/-!
  Kernel-to-DDR ownership model, Lean 4.19.0, Std only.

  One logical step is one common EMIF clock edge. Its order is dispatch,
  response, admission. Dispatch only sees the OLD command queue: there is no
  upstream-to-DDR empty-queue fallthrough. Response sees a read dispatched on
  this edge, so zero-latency response is represented. Admission uses capacity
  released on this edge. These are mathematical phases, not extra clocks.

  `serial` is a ghost occurrence label, NOT a hardware signal. Returned-data
  arithmetic, physical FIFO indices, and electrical protocol timing are outside
  this ownership proof. The refinement obligations are listed at the end.
-/

namespace AsusA10.KernelDdrAdapter

structure Tag where
  serial : Nat
  byteAddress : Nat
  lane : Fin 8
  deriving DecidableEq, Repr

inductive Command where
  | read (tag : Tag) (byteEnable : Nat)
  | write (byteAddress wordData byteEnable : Nat)
  deriving DecidableEq, Repr

def commandReads : Command → List Tag
  | .read tag _ => [tag]
  | .write _ _ _ => []

def reads : List Command → List Tag
  | [] => []
  | c :: cs => commandReads c ++ reads cs

@[simp] theorem reads_nil : reads [] = [] := rfl

@[simp] theorem reads_cons (c : Command) (cs : List Command) :
    reads (c :: cs) = commandReads c ++ reads cs := rfl

@[simp] theorem reads_append (a b : List Command) :
    reads (a ++ b) = reads a ++ reads b := by
  induction a with
  | nil => rfl
  | cons c cs ih => simp [reads, ih, List.append_assoc]

@[simp] theorem reads_singleton (c : Command) :
    reads [c] = commandReads c := by simp [reads]

structure State where
  /-- Ghost histories, never implemented as hardware queues. -/
  accepted : List Command := []
  dispatched : List Command := []
  completed : List Tag := []
  /-- Hardware command FIFO, in head-to-tail order. -/
  commands : List Command := []
  /-- Ghost expansion of the RTL issued-read counter, in response order. -/
  issued : List Tag := []
  /-- Hardware read-tag FIFO: queued reads plus downstream accepted reads. -/
  owners : List Tag := []
  fault : Bool := false
  deriving Repr

def initial : State := {}

structure Invariant (commandCapacity readCapacity : Nat) (s : State) : Prop where
  commands_conserved : s.accepted = s.dispatched ++ s.commands
  issued_conserved : reads s.dispatched = s.completed ++ s.issued
  owners_exact : s.owners = s.issued ++ reads s.commands
  commands_bounded : s.commands.length ≤ commandCapacity
  owners_bounded : s.owners.length ≤ readCapacity

/-- One actual downstream command acceptance, or idle if the queue is empty. -/
def dispatch (s : State) : State :=
  match s.commands with
  | [] => s
  | c :: cs => { s with
      dispatched := s.dispatched ++ [c]
      commands := cs
      issued := s.issued ++ commandReads c }

/-- One asserted DDR response. An unowned response faults without completing. -/
def respond (s : State) : State :=
  match s.issued with
  | [] => { s with fault := true }
  | t :: ts => { s with
      completed := s.completed ++ [t]
      issued := ts
      owners := s.owners.tail }

/-- One upstream acceptance. Read credit is reserved here, before dispatch. -/
def admit (s : State) (c : Command) : State :=
  { s with
    accepted := s.accepted ++ [c]
    commands := s.commands ++ [c]
    owners := s.owners ++ commandReads c }

def Room (commandCapacity readCapacity : Nat) (s : State) (c : Command) : Prop :=
  s.commands.length < commandCapacity ∧
  s.owners.length + (commandReads c).length ≤ readCapacity

/-- Reset base: this theorem is for a coordinated cold-reset boundary only. -/
theorem base (commandCapacity readCapacity : Nat) :
    Invariant commandCapacity readCapacity initial := by
  constructor <;> simp [initial, reads]

theorem dispatch_step {cc rc : Nat} {s : State}
    (h : Invariant cc rc s) : Invariant cc rc (dispatch s) := by
  cases hc : s.commands with
  | nil => simpa [dispatch, hc] using h
  | cons c cs =>
    constructor
    · simpa [dispatch, hc, List.append_assoc] using h.commands_conserved
    · simpa [dispatch, hc, reads_append, List.append_assoc]
        using congrArg (fun xs => xs ++ commandReads c) h.issued_conserved
    · simpa [dispatch, hc, reads, List.append_assoc] using h.owners_exact
    · have hb := h.commands_bounded
      simp only [hc, List.length_cons] at hb
      simp only [dispatch, hc]
      omega
    · simpa [dispatch, hc] using h.owners_bounded

theorem response_step {cc rc : Nat} {s : State}
    (h : Invariant cc rc s) : Invariant cc rc (respond s) := by
  cases hi : s.issued with
  | nil =>
    constructor
    · simpa [respond, hi] using h.commands_conserved
    · simpa [respond, hi] using h.issued_conserved
    · simpa [respond, hi] using h.owners_exact
    · simpa [respond, hi] using h.commands_bounded
    · simpa [respond, hi] using h.owners_bounded
  | cons t ts =>
    have ho : s.owners = t :: (ts ++ reads s.commands) := by
      simpa [hi] using h.owners_exact
    constructor
    · simpa [respond, hi] using h.commands_conserved
    · simpa [respond, hi, List.append_assoc] using h.issued_conserved
    · simp [respond, hi, ho]
    · simpa [respond, hi] using h.commands_bounded
    · have hb := h.owners_bounded
      simp only [ho, List.length_cons] at hb
      simp only [respond, hi, ho, List.tail_cons]
      omega

theorem admission_step {cc rc : Nat} {s : State} {c : Command}
    (h : Invariant cc rc s) (room : Room cc rc s c) :
    Invariant cc rc (admit s c) := by
  constructor
  · simpa [admit, List.append_assoc] using
      congrArg (fun xs => xs ++ [c]) h.commands_conserved
  · simpa [admit] using h.issued_conserved
  · simpa [admit, reads_append, List.append_assoc] using
      congrArg (fun xs => xs ++ commandReads c) h.owners_exact
  · have hb := room.1
    simp only [admit, List.length_append, List.length_singleton]
    omega
  · simpa [admit, List.length_append] using room.2

structure Event where
  /-- These booleans denote sampled handshakes, not requests before waitrequest. -/
  dispatchFire : Bool
  responseValid : Bool
  /-- Any same-edge diagnostic, including ECC/calibration/protocol faults. -/
  diagnosticFault : Bool
  memoryReady : Bool
  quiesce : Bool
  /-- Some c means c was actually accepted upstream on this edge. -/
  admission : Option Command
  deriving Repr

def beforeAdmission (s : State) (e : Event) : State :=
  let f := { s with fault := s.fault || e.diagnosticFault }
  let d := if e.dispatchFire then dispatch f else f
  if e.responseValid then respond d else d

def step (s : State) (e : Event) : State :=
  let p := beforeAdmission s e
  match e.admission with
  | none => p
  | some c => admit p c

/--
  Signal-to-event obligations. The command-FIFO head is the only dispatchable
  command. New admissions require ready, no quiesce/fault, and both credits.
  Fault/quiesce deliberately do NOT forbid dispatch or response of old work.
-/
def Legal (cc rc : Nat) (s : State) (e : Event) : Prop :=
  (e.dispatchFire = true → s.commands ≠ []) ∧
  match e.admission with
  | none => True
  | some c =>
      e.memoryReady = true ∧ e.quiesce = false ∧
      (beforeAdmission s e).fault = false ∧ Room cc rc (beforeAdmission s e) c

theorem before_admission_step {cc rc : Nat} {s : State} (e : Event)
    (h : Invariant cc rc s) :
    Invariant cc rc (beforeAdmission s e) := by
  have hf : Invariant cc rc { s with fault := s.fault || e.diagnosticFault } := by
    constructor
    · exact h.commands_conserved
    · exact h.issued_conserved
    · exact h.owners_exact
    · exact h.commands_bounded
    · exact h.owners_bounded
  cases hd : e.dispatchFire with
  | false =>
    cases hr : e.responseValid with
    | false => simpa [beforeAdmission, hd, hr] using hf
    | true => simpa [beforeAdmission, hd, hr] using response_step hf
  | true =>
    cases hr : e.responseValid with
    | false => simpa [beforeAdmission, hd, hr] using dispatch_step hf
    | true => simpa [beforeAdmission, hd, hr] using response_step (dispatch_step hf)

@[simp] theorem dispatch_preserves_fault (s : State) :
    (dispatch s).fault = s.fault := by
  cases hc : s.commands <;> simp [dispatch, hc]

theorem respond_preserves_sticky_fault (s : State) (h : s.fault = true) :
    (respond s).fault = true := by
  cases hi : s.issued <;> simp [respond, hi, h]

theorem before_admission_sticky_fault (s : State) (e : Event)
    (h : s.fault = true) : (beforeAdmission s e).fault = true := by
  let f : State := { s with fault := s.fault || e.diagnosticFault }
  have hf : f.fault = true := by simp [f, h]
  have hd : (dispatch f).fault = true := by simpa using hf
  cases hD : e.dispatchFire with
  | false =>
    cases hR : e.responseValid with
    | false => simpa [beforeAdmission, hD, hR, f] using hf
    | true => simpa [beforeAdmission, hD, hR, f] using respond_preserves_sticky_fault f hf
  | true =>
    cases hR : e.responseValid with
    | false => simpa [beforeAdmission, hD, hR, f] using hd
    | true => simpa [beforeAdmission, hD, hR, f] using
        respond_preserves_sticky_fault (dispatch f) hd

theorem sticky_fault_step (s : State) (e : Event) (h : s.fault = true) :
    (step s e).fault = true := by
  have hp := before_admission_sticky_fault s e h
  cases he : e.admission <;> simpa [step, he, admit] using hp

theorem fault_blocks_admission {cc rc : Nat} {s : State} {e : Event}
    (legal : Legal cc rc s e) (fault : s.fault = true) : e.admission = none := by
  cases he : e.admission with
  | none => rfl
  | some c =>
    have hl := legal
    simp only [Legal, he] at hl
    have hp := before_admission_sticky_fault s e fault
    have hn := hl.2.2.2.1
    simp_all

/-- Inductive STEP for the actual ordered dispatch/response/admission updates. -/
theorem step_preserves {cc rc : Nat} {s : State} {e : Event}
    (h : Invariant cc rc s) (legal : Legal cc rc s e) :
    Invariant cc rc (step s e) := by
  have hp := before_admission_step e h
  cases he : e.admission with
  | none => simpa [step, he] using hp
  | some c =>
    have hr : Room cc rc (beforeAdmission s e) c := by
      have hl := legal
      simp only [Legal, he] at hl
      exact hl.2.2.2.2
    simpa [step, he] using admission_step hp hr

inductive Reachable (cc rc : Nat) : State → Prop where
  | reset : Reachable cc rc initial
  | tick {s : State} {e : Event} : Reachable cc rc s → Legal cc rc s e →
      Reachable cc rc (step s e)

theorem reachable_invariant {cc rc : Nat} {s : State}
    (h : Reachable cc rc s) : Invariant cc rc s := by
  induction h with
  | reset => exact base cc rc
  | tick _ legal ih => exact step_preserves ih legal

/-- Exact ordered conservation, not merely an occupancy-counter inequality. -/
theorem reads_conserved {cc rc : Nat} {s : State} (h : Invariant cc rc s) :
    reads s.accepted = s.completed ++ s.owners := by
  rw [h.commands_conserved, reads_append, h.issued_conserved, h.owners_exact]
  simp [List.append_assoc]

theorem ownership_count_partition {cc rc : Nat} {s : State}
    (h : Invariant cc rc s) :
    s.owners.length = s.issued.length + (reads s.commands).length := by
  simpa only [List.length_append] using congrArg List.length h.owners_exact

theorem issued_bounded {cc rc : Nat} {s : State} (h : Invariant cc rc s) :
    s.issued.length ≤ rc := by
  have hp := ownership_count_partition h
  have hb := h.owners_bounded
  omega

theorem response_owns_head {cc rc : Nat} {s : State} {t : Tag} {ts : List Tag}
    (h : Invariant cc rc s) (issued : s.issued = t :: ts) :
    s.owners = t :: (ts ++ reads s.commands) ∧
    (respond s).completed = s.completed ++ [t] ∧
    (respond s).owners = ts ++ reads s.commands := by
  have ho : s.owners = t :: (ts ++ reads s.commands) := by
    simpa [issued] using h.owners_exact
  exact ⟨ho, by simp [respond, issued], by simp [respond, issued, ho]⟩

theorem unowned_response_never_completes (s : State) (empty : s.issued = []) :
    (respond s).completed = s.completed ∧
    (respond s).owners = s.owners ∧
    (respond s).commands = s.commands ∧ (respond s).fault = true := by
  simp [respond, empty]

theorem zero_latency_owned {s : State} {t : Tag} {be : Nat} {cs : List Command}
    (q : s.commands = Command.read t be :: cs) (empty : s.issued = []) :
    (respond (dispatch s)).completed = s.completed ++ [t] ∧
    (respond (dispatch s)).issued = [] := by
  simp [dispatch, q, empty, commandReads, respond]

/-- An existing owner is still consumed on an error/fault edge; no retry/reset. -/
theorem fault_response_still_reconciles {s : State} {t : Tag} {ts : List Tag}
    (issued : s.issued = t :: ts) :
    (respond { s with fault := true }).completed = s.completed ++ [t] ∧
    (respond { s with fault := true }).fault = true := by
  simp [respond, issued]

theorem fault_only_retains_work (s : State) :
    let e : Event := ⟨false, false, true, false, true, none⟩
    (step s e).commands = s.commands ∧
    (step s e).owners = s.owners ∧
    (step s e).issued = s.issued ∧ (step s e).fault = true := by
  simp [step, beforeAdmission]

theorem completion_count_bounded {cc rc : Nat} {s : State}
    (h : Invariant cc rc s) : s.completed.length ≤ (reads s.accepted).length := by
  have hc := congrArg List.length (reads_conserved h)
  simp only [List.length_append] at hc
  omega

/--
  Drained covers upstream accepted commands, queued commands, and downstream
  read ownership. It says nothing about an unaccepted request still held by the
  kernel, nor about physical persistence of a write accepted by DDR.
-/
def Drained (s : State) : Prop :=
  s.commands = [] ∧ s.owners = [] ∧ s.issued = []

private theorem nil_of_length_zero {α : Type} (xs : List α)
    (h : xs.length = 0) : xs = [] := by
  cases xs <;> simp_all

theorem drained_iff_reconciled {cc rc : Nat} {s : State}
    (h : Invariant cc rc s) :
    Drained s ↔ s.accepted = s.dispatched ∧ reads s.accepted = s.completed := by
  constructor
  · intro hd
    constructor
    · simpa [hd.1] using h.commands_conserved
    · simpa [hd.2.1] using reads_conserved h
  · rintro ⟨ha, hr⟩
    have lc := congrArg List.length h.commands_conserved
    have la := congrArg List.length ha
    simp only [List.length_append] at lc
    have hcnil : s.commands = [] := nil_of_length_zero s.commands (by omega)
    have li := congrArg List.length h.issued_conserved
    have lr : (reads s.dispatched).length = s.completed.length := by
      simpa [ha] using congrArg List.length hr
    simp only [List.length_append] at li
    have hinil : s.issued = [] := nil_of_length_zero s.issued (by omega)
    have honil : s.owners = [] := by
      simpa [hinil, hcnil, reads] using h.owners_exact
    exact ⟨hcnil, honil, hinil⟩

theorem quiesce_blocks_admission {cc rc : Nat} {s : State} {e : Event}
    (legal : Legal cc rc s e) (q : e.quiesce = true) : e.admission = none := by
  cases he : e.admission with
  | none => rfl
  | some c =>
    have hq : e.quiesce = false := by
      have hl := legal
      simp only [Legal, he] at hl
      exact hl.2.2.1
    simp_all

theorem drained_without_admission_stays_drained (s : State) (e : Event)
    (hd : Drained s) (none : e.admission = none) : Drained (step s e) := by
  rcases hd with ⟨hc, ho, hi⟩
  cases hD : e.dispatchFire <;> cases hR : e.responseValid <;>
    simp [step, none, beforeAdmission, hD, hR, dispatch, respond, hc, ho, hi, Drained]

theorem quiescent_drained_absorbing {cc rc : Nat} {s : State} {e : Event}
    (legal : Legal cc rc s e) (q : e.quiesce = true) (hd : Drained s) :
    Drained (step s e) :=
  drained_without_admission_stays_drained s e hd (quiesce_blocks_admission legal q)

/-!
  Refinement/assumptions, deliberately not hidden as axioms:
  * Each `admission` is exactly read/write && !kernel_waitrequest for a legal
    aligned single-beat request; no floating kernel enable participates.
  * `dispatchFire` is exactly (ddr_read || ddr_write) && !ddr_waitrequest.
    It dispatches the old command-FIFO head. The RTL held-offer latch, including
    signal stability while stalled and on readiness loss, needs RTL refinement.
  * `issued` is a ghost list whose length refines issued_count. `owners` and
    `commands` must refine the actual circular FIFOs, pointers and memory.
  * DDR responses are ordered, at most one per edge, exactly one per accepted
    read; the only allowed empty-issued response is same-edge accepted read.
    An otherwise unowned response is detected. With no response IDs, a duplicate
    or reordered physical response while owners remain cannot be distinguished;
    backend exactly-once ordering is an assumption, not a proved RTL guarantee.
  * The kernel consumes every asserted read response (no response backpressure).
    Response data lane extraction is separate from this ownership theorem.
  * Fault/quiesce stop admissions; accepted work remains owned. A fault does
    not promise eventual drain. Liveness requires eventual acceptance and read
    return; permanent calibration failure can prevent it.
  * Initial/reset is a coordinated kernel/adapter/EMIF cold reset discarding the
    complete old epoch. A core-only reset is not a transition in this model.
  * Host software must observe sticky fault and withhold success credit even
    after all traffic is reconciled. DDR write acceptance is not persistence.
-/

end AsusA10.KernelDdrAdapter

#print axioms AsusA10.KernelDdrAdapter.base
#print axioms AsusA10.KernelDdrAdapter.step_preserves
#print axioms AsusA10.KernelDdrAdapter.sticky_fault_step
#print axioms AsusA10.KernelDdrAdapter.fault_blocks_admission
#print axioms AsusA10.KernelDdrAdapter.reachable_invariant
#print axioms AsusA10.KernelDdrAdapter.reads_conserved
#print axioms AsusA10.KernelDdrAdapter.ownership_count_partition
#print axioms AsusA10.KernelDdrAdapter.issued_bounded
#print axioms AsusA10.KernelDdrAdapter.response_owns_head
#print axioms AsusA10.KernelDdrAdapter.unowned_response_never_completes
#print axioms AsusA10.KernelDdrAdapter.zero_latency_owned
#print axioms AsusA10.KernelDdrAdapter.fault_response_still_reconciles
#print axioms AsusA10.KernelDdrAdapter.fault_only_retains_work
#print axioms AsusA10.KernelDdrAdapter.completion_count_bounded
#print axioms AsusA10.KernelDdrAdapter.drained_iff_reconciled
#print axioms AsusA10.KernelDdrAdapter.quiescent_drained_absorbing
