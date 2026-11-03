import Init

set_option maxHeartbeats 0

/-!
Lean 4.19.0, abstract safety obligations for one admitted fetch owner.
This is NOT RTL refinement, a PCIe replay proof, or a liveness proof.

`header` copies the issuing tag's complete immutable context into a command.
The command remains debt until its LAST DESTINATION beat is accepted. Tag
settlement may precede that acceptance. Split completions enqueue independent
commands, so neither tag order nor a global beat count supplies the ordinal.
`settleTag` denotes a validated final source return, including its accepted EOP;
it is not permission to cancel a tag on an error/status/control indication.

The model describes accepted events. A simultaneous RTL event must implement
the corresponding valid serial substeps; this file does not establish that
correspondence. Payload, FIFO capacity, cross-owner arbitration, malformed-TLP
drain, owner status decoding and the consumer's four-phase receipt are outside
this model. Consumer commit/receipt obligations remain in FetchCommit.lean.

All identity fields are finite; the generation rule retains ff -> 1 wrapping.
This model covers one admitted context, not normal lifecycle reuse. Within its
steps identity changes only at a reset with the explicit, unproved environmental
proposition `TransportFenced`: old transport returns are impossible, not merely
that an epoch register changed. Full context reuse needs producer settlement,
accepted End and independently established owner receipt/consumer drainage.
The external custody predicates below do not prove those missing protocols.
Finite token recurrence is permitted; token/epoch values are not authenticators.
-/
namespace DmaFetchReturn

abbrev Tag := Fin 16

structure Key where
  epoch : Fin 4294967296
  generation : Fin 256
  slot : Fin 16
  id : Fin 256
  deriving DecidableEq

structure Context where
  key : Key
  base : Nat
  entries : Nat
  writeTable : Bool
  deriving DecidableEq

structure Command where
  context : Context
  address : Nat
  beats : Nat

structure AcceptedBeat where
  key : Key
  writeTable : Bool
  address : Nat
  index : Nat

def ordinal (c : Context) (address : Nat) : Nat := (address - c.base) / 32
def AddressOK (c : Context) (address : Nat) : Prop :=
  c.base ≤ address ∧ (address - c.base) % 32 = 0 ∧ ordinal c address < c.entries
def accepted (c : Context) (address : Nat) : AcceptedBeat :=
  ⟨c.key, c.writeTable, address, ordinal c address⟩
def BeatOK (c : Context) (beat : AcceptedBeat) : Prop :=
  beat.key = c.key ∧ beat.writeTable = c.writeTable ∧
  beat.index = ordinal c beat.address ∧ AddressOK c beat.address

def QueueOK (c : Context) : List Command → Prop
  | [] => True
  | command :: rest => command.context = c ∧ 0 < command.beats ∧ QueueOK c rest
def LogOK (c : Context) : List AcceptedBeat → Prop
  | [] => True
  | beat :: rest => BeatOK c beat ∧ LogOK c rest

inductive Phase where
  | collecting | offered | accepted
  deriving DecidableEq

structure Bank where
  context : Context
  tags : Tag → Option Context := fun _ => none
  pending : List Command := []
  delivered : List AcceptedBeat := []
  issueClosed : Bool := false
  failed : Bool := false
  phase : Phase := .collecting
  endWord : Option (Key × Bool) := none
  statusSeen : Bool := false
  fault : Bool := false

def initial (c : Context) : Bank := { context := c }
def putTag (tags : Tag → Option Context) (tag : Tag) (value : Option Context) :=
  fun t => if t = tag then value else tags t
def Returned (b : Bank) : Prop := ∀ tag, b.tags tag = none
def Settled (b : Bank) : Prop :=
  b.issueClosed = true ∧ Returned b ∧ b.pending = []

structure Invariant (b : Bank) : Prop where
  tagsOwn : ∀ tag c, b.tags tag = some c → c = b.context
  queue : QueueOK b.context b.pending
  log : LogOK b.context b.delivered
  endSafe : b.phase ≠ .collecting → Settled b
  endSnapshot : b.phase ≠ .collecting →
    b.endWord = some (b.context.key, b.failed)

-- Only accepted work changes the debt. A rejected route/address/key instead
-- takes `reject`, which preserves all pending commands and tag identities.
inductive Step (TransportFenced : Prop) : Bank → Bank → Prop where
  | issue (b : Bank) (tag : Tag)
      (openPhase : b.phase = .collecting) (issuing : b.issueClosed = false)
      (free : b.tags tag = none) (clear : b.fault = false) :
      Step TransportFenced b { b with tags := putTag b.tags tag (some b.context) }
  | closeIssue (b : Bank) (openPhase : b.phase = .collecting) :
      Step TransportFenced b { b with issueClosed := true }
  | header (b : Bank) (tag : Tag) (command : Command)
      (openPhase : b.phase = .collecting) (clear : b.fault = false)
      (matching : b.tags tag = some command.context) (nonzero : 0 < command.beats) :
      Step TransportFenced b { b with pending := b.pending ++ [command] }
  | settleTag (b : Bank) (tag : Tag)
      (openPhase : b.phase = .collecting) (clear : b.fault = false)
      (matching : b.tags tag = some b.context) :
      Step TransportFenced b { b with tags := putTag b.tags tag none }
  | destinationMore (b : Bank) (command : Command) (tail : List Command) (remaining : Nat)
      (openPhase : b.phase = .collecting) (clear : b.fault = false)
      (head : b.pending = command :: tail) (more : command.beats = remaining + 2)
      (validAddress : AddressOK command.context command.address)
      (route : Bool) (rightRoute : route = command.context.writeTable) :
      Step TransportFenced b { b with
        pending := { command with address := command.address + 32, beats := remaining + 1 } :: tail,
        delivered := accepted command.context command.address :: b.delivered }
  | destinationLast (b : Bank) (command : Command) (tail : List Command)
      (openPhase : b.phase = .collecting) (clear : b.fault = false)
      (head : b.pending = command :: tail) (last : command.beats = 1)
      (validAddress : AddressOK command.context command.address)
      (route : Bool) (rightRoute : route = command.context.writeTable) :
      Step TransportFenced b { b with pending := tail, delivered := accepted command.context command.address :: b.delivered }
  | terminal (b : Bank) (openPhase : b.phase = .collecting) :
      Step TransportFenced b { b with issueClosed := true, failed := true }
  | offerEnd (b : Bank) (openPhase : b.phase = .collecting)
      (clear : b.fault = false) (settled : Settled b) :
      Step TransportFenced b { b with phase := .offered, endWord := some (b.context.key, b.failed) }
  | acceptEnd (b : Bank) (offered : b.phase = .offered) :
      Step TransportFenced b { b with phase := .accepted }
  | status (b : Bank) : Step TransportFenced b { b with statusSeen := true }
  | reject (b : Bank) : Step TransportFenced b { b with fault := true }
  | stall (b : Bank) : Step TransportFenced b b
  | reset (b : Bank) (c : Context) (fence : TransportFenced) :
      Step TransportFenced b (initial c)

private theorem collectingInvariant (b : Bank) (openPhase : b.phase = .collecting)
    (tags : ∀ tag c, b.tags tag = some c → c = b.context)
    (queue : QueueOK b.context b.pending) (log : LogOK b.context b.delivered) :
    Invariant b :=
  ⟨tags, queue, log, fun h => False.elim (h openPhase),
    fun h => False.elim (h openPhase)⟩

private theorem queueAppend (c : Context) (xs : List Command) (command : Command)
    (matching : command.context = c) (nonzero : 0 < command.beats) :
    QueueOK c xs → QueueOK c (xs ++ [command]) := by
  induction xs with
  | nil => intro _; exact ⟨matching, nonzero, True.intro⟩
  | cons x xs ih => intro h; exact ⟨h.1, h.2.1, ih h.2.2⟩

theorem BASE (c : Context) : Invariant (initial c) := by
  refine collectingInvariant (initial c) rfl ?_ True.intro True.intro
  intro tag owner impossible
  cases impossible

theorem STEP {fence : Prop} {b next : Bank}
    (h : Invariant b) (step : Step fence b next) : Invariant next := by
  cases step with
  | issue tag openPhase issuing free clear =>
    refine collectingInvariant _ openPhase ?_ h.queue h.log
    intro t c present
    by_cases same : t = tag
    · simp [putTag, same] at present
      exact present.symm
    · exact h.tagsOwn t c (by simpa [putTag, same] using present)
  | closeIssue openPhase =>
    exact collectingInvariant _ openPhase h.tagsOwn h.queue h.log
  | header tag command openPhase clear matching nonzero =>
    exact collectingInvariant _ openPhase h.tagsOwn
      (queueAppend b.context b.pending command (h.tagsOwn tag _ matching) nonzero h.queue) h.log
  | settleTag tag openPhase clear matching =>
    refine collectingInvariant _ openPhase ?_ h.queue h.log
    intro t c present
    by_cases same : t = tag
    · simp [putTag, same] at present
    · exact h.tagsOwn t c (by simpa [putTag, same] using present)
  | destinationMore command tail remaining openPhase clear head more validAddress route rightRoute =>
    have q := h.queue
    rw [head] at q
    have beat : BeatOK b.context (accepted command.context command.address) := by
      rw [← q.1]
      exact ⟨rfl, rfl, rfl, validAddress⟩
    exact collectingInvariant _ openPhase h.tagsOwn
      ⟨q.1, Nat.zero_lt_succ remaining, q.2.2⟩ ⟨beat, h.log⟩
  | destinationLast command tail openPhase clear head last validAddress route rightRoute =>
    have q := h.queue
    rw [head] at q
    have beat : BeatOK b.context (accepted command.context command.address) := by
      rw [← q.1]
      exact ⟨rfl, rfl, rfl, validAddress⟩
    exact collectingInvariant _ openPhase h.tagsOwn q.2.2 ⟨beat, h.log⟩
  | terminal openPhase =>
    exact collectingInvariant _ openPhase h.tagsOwn h.queue h.log
  | offerEnd openPhase clear settled =>
    exact ⟨h.tagsOwn, h.queue, h.log, fun _ => settled, fun _ => rfl⟩
  | acceptEnd offered =>
    have closed : b.phase ≠ .collecting := by simp [offered]
    exact ⟨h.tagsOwn, h.queue, h.log, fun _ => h.endSafe closed,
      fun _ => h.endSnapshot closed⟩
  | status => exact ⟨h.tagsOwn, h.queue, h.log, h.endSafe, h.endSnapshot⟩
  | reject => exact ⟨h.tagsOwn, h.queue, h.log, h.endSafe, h.endSnapshot⟩
  | stall => exact h
  | reset c fence => exact BASE c

inductive Reachable (fence : Prop) (c : Context) : Bank → Prop where
  | base : Reachable fence c (initial c)
  | step {b next : Bank} : Reachable fence c b → Step fence b next → Reachable fence c next

theorem reachableInvariant {fence : Prop} {c : Context} {b : Bank}
    (reachable : Reachable fence c b) : Invariant b := by
  induction reachable with
  | base => exact BASE c
  | step previous transition ih => exact STEP ih transition

-- Includes incomplete/error/aborted fetches: End certifies no remaining return
-- debt. Completeness and executable commit are separate consumer obligations.
theorem closeCertificate {b : Bank} (h : Invariant b) (offered : b.phase = .offered) :
    Settled b ∧ b.endWord = some (b.context.key, b.failed) :=
  ⟨h.endSafe (by simp [offered]), h.endSnapshot (by simp [offered])⟩

theorem statusDoesNotGateClose (fence : Prop) (b : Bank)
    (openPhase : b.phase = .collecting) (clear : b.fault = false) (settled : Settled b) :
    Step fence b { b with phase := .offered, endWord := some (b.context.key, b.failed) } :=
  .offerEnd b openPhase clear settled

theorem retainedEnd {fence : Prop} {b next : Bank} (step : Step fence b next)
    (offered : b.phase = .offered) (noResetFence : ¬ fence) :
    next.endWord = b.endWord := by
  cases step <;> simp_all [initial]

-- Scoped to this admitted context. Normal validated lifecycle reuse is not a
-- Step constructor, so this theorem does not prohibit the real allocator's reuse.
theorem immutableContext {fence : Prop} {b next : Bank} (step : Step fence b next)
    (noResetFence : ¬ fence) : next.context = b.context := by
  cases step <;> simp_all [initial]

theorem terminalRetainsDebt (b : Bank) :
    ({ b with issueClosed := true, failed := true } : Bank).tags = b.tags ∧
    ({ b with issueClosed := true, failed := true } : Bank).pending = b.pending :=
  ⟨rfl, rfl⟩

private theorem logEntry (c : Context) (xs : List AcceptedBeat) :
    LogOK c xs → ∀ beat, beat ∈ xs → BeatOK c beat := by
  induction xs with
  | nil => intro _ beat impossible; cases impossible
  | cons x xs ih =>
    intro h beat member
    cases List.mem_cons.mp member with
    | inl same => cases same; exact h.1
    | inr rest => exact ih h.2 beat rest

theorem acceptedAddressOrdinal {b : Bank} (h : Invariant b) (beat : AcceptedBeat)
    (member : beat ∈ b.delivered) :
    beat.key = b.context.key ∧ beat.writeTable = b.context.writeTable ∧
    beat.index = (beat.address - b.context.base) / 32 ∧ AddressOK b.context beat.address :=
  logEntry b.context b.delivered h.log beat member

-- These are REQUIRED separate evidence, not modeled receipt/drain results.
-- Full context reuse is stricter than the owner's earlier slot-release event.
structure ReusePreconditions (b : Bank) (OwnerReceiptClosed ConsumerDrained : Prop) : Prop where
  endAccepted : b.phase = .accepted
  settled : Settled b
  clean : b.failed = false
  noFault : b.fault = false
  ownerReceipt : OwnerReceiptClosed
  consumerDrained : ConsumerDrained

theorem reuseFromSeparateEvidence {b : Bank} {OwnerReceiptClosed ConsumerDrained : Prop}
    (h : Invariant b) (endAccepted : b.phase = .accepted)
    (clean : b.failed = false) (noFault : b.fault = false)
    (receipt : OwnerReceiptClosed) (drained : ConsumerDrained) :
    ReusePreconditions b OwnerReceiptClosed ConsumerDrained :=
  ⟨endAccepted, h.endSafe (by simp [endAccepted]), clean, noFault, receipt, drained⟩

-- Exact allocator arithmetic on legal generation bytes (cold 0, live 1..255).
-- The closed calculation proves recurrence, not transport replay exclusion.
def nextGeneration (g : Nat) : Nat := if g = 255 then 1 else g + 1
def generationAfter (g : Nat) : Nat → Nat
  | 0 => g
  | n + 1 => generationAfter (nextGeneration g) n

theorem generationWrap : nextGeneration 255 = 1 := rfl
set_option maxRecDepth 4096 in
theorem generationRecurs : generationAfter 1 255 = 1 := by decide

end DmaFetchReturn
