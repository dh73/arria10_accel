import Std

/-!
Abstract fetch-bank custody model for Lean 4.19.0. This is not RTL refinement.
`Step` describes accepted events; stalls are stuttering steps. A token contains
every identity field, including an abstract reset epoch. A production adapter
must establish that identity before invoking these abstract events.

The ordinal list is a finite set represented without Mathlib. A clean end can
seal only a complete set; a matching failed/partial end or abort poisons an
uncommitted bank. Poison is retained. A postcommit abort sets a retained fault
without pretending that already released descriptors can be rolled back.

The model is scoped to one coordinated-reset epoch. It proves neither reset
transport fencing, bounded generation/epoch recurrence, liveness/fairness,
physical memory visibility, nor equivalence to the SystemVerilog implementation.
-/
namespace DmaFetch

structure Token where
  id : Fin 256
  slot : Fin 16
  generation : Fin 256
  epoch : Nat
  deriving DecidableEq

inductive Receipt where
  | idle | valid | consumed | validLow | closed
  deriving DecidableEq

structure Bank where
  owner : Option Token := none
  expected : Nat := 0
  seen : List Nat := []
  sealed : Bool := false
  poison : Bool := false
  committed : Bool := false
  released : Nat := 0
  receipt : Receipt := .idle
  fault : Bool := false

def empty : Bank := {}
def issued (token : Token) (n : Nat) : Bank :=
  { owner := some token, expected := n }
def Complete (b : Bank) : Prop :=
  forall k, k < b.expected -> k ∈ b.seen
def Recyclable (b : Bank) : Prop :=
  b.committed = true ∧ b.released = b.expected ∧
  b.receipt = .closed ∧ b.poison = false ∧ b.fault = false

structure Invariant (b : Bank) : Prop where
  sealedComplete : b.sealed = true -> Complete b
  committedSafe : b.committed = true ->
    b.sealed = true ∧ b.poison = false ∧ ∃ token, b.owner = some token
  releaseSafe : 0 < b.released -> b.committed = true
  receiptSafe : b.receipt ≠ .idle -> b.committed = true
  bounded : b.released ≤ b.expected
  unique : b.seen.Nodup
  inRange : forall k, k ∈ b.seen -> k < b.expected

-- Fault diagnostics are sticky. Only a fault-free completed bank is recyclable.
-- A caller must classify error/partial/duplicate/late ingress as `fail`, not
-- `payload` or `seal`. Pure PAUSE is represented by `pause`, never by `fail`.
inductive Step : Bank -> Bank -> Prop where
  | issue (b : Bank) (token : Token) (n : Nat)
      (vacant : b.owner = none) (clear : b.fault = false)
      (fetch : 128 ≤ token.id.val) (generation : token.generation.val ≠ 0)
      (nonempty : 0 < n) : Step b (issued token n)
  | payload (b : Bank) (token : Token) (k : Nat)
      (matching : b.owner = some token) (pending : b.committed = false)
      (openBank : b.sealed = false) (clean : b.poison = false)
      (fresh : k ∉ b.seen) (within : k < b.expected) :
      Step b { b with seen := k :: b.seen }
  | seal (b : Bank) (token : Token)
      (matching : b.owner = some token) (pending : b.committed = false)
      (openBank : b.sealed = false) (clean : b.poison = false)
      (complete : Complete b) : Step b { b with sealed := true }
  | fail (b : Bank) (token : Token)
      (matching : b.owner = some token) (pending : b.committed = false) :
      Step b { b with poison := true, sealed := false, fault := true }
  | pause (b : Bank) (token : Token) (matching : b.owner = some token) : Step b b
  -- Exact success is an already decoded ABI success. Full token equality is
  -- required; low-seven-bit aliases and late-generation matches are excluded.
  -- Completeness follows from the sealedComplete invariant, not a delay.
  | success (b : Bank) (token : Token)
      (matching : b.owner = some token) (pending : b.committed = false)
      (sealed : b.sealed = true) (clean : b.poison = false)
      (clear : b.fault = false) : Step b { b with committed := true }
  | dispatch (b : Bank) (committed : b.committed = true)
      (clear : b.fault = false) (room : b.released < b.expected) :
      Step b { b with released := b.released + 1 }
  -- Receipt closure and descriptor dispatch may interleave in either order.
  | receiptRaise (b : Bank) (committed : b.committed = true)
      (idle : b.receipt = .idle) : Step b { b with receipt := .valid }
  | receiptConsume (b : Bank) (valid : b.receipt = .valid) :
      Step b { b with receipt := .consumed }
  | receiptLower (b : Bank) (consumed : b.receipt = .consumed) :
      Step b { b with receipt := .validLow }
  | receiptClose (b : Bank) (low : b.receipt = .validLow) :
      Step b { b with receipt := .closed }
  | wrongToken (b : Bank) (token : Token) (wrong : b.owner ≠ some token) :
      Step b { b with fault := true }
  | postCommitAbort (b : Bank) (committed : b.committed = true) :
      Step b { b with fault := true }
  | stall (b : Bank) : Step b b
  | recycle (b : Bank) (ready : Recyclable b) : Step b empty

theorem BASE : Invariant empty := by
  constructor <;> simp [empty, Complete]

theorem STEP {b next : Bank} (h : Invariant b) (step : Step b next) :
    Invariant next := by
  cases step with
  | issue token n vacant clear fetch generation nonempty =>
    constructor <;> simp [issued, Complete]
  | payload token k matching pending openBank clean fresh within =>
    refine ⟨?_, ?_, h.releaseSafe, h.receiptSafe, h.bounded, ?_, ?_⟩
    · intro sealed
      simp [openBank] at sealed
    · intro committed
      simp [pending] at committed
    · exact List.nodup_cons.mpr ⟨fresh, h.unique⟩
    · intro i member
      simp only [List.mem_cons] at member
      rcases member with rfl | member
      · exact within
      · exact h.inRange i member
  | «seal» token matching pending openBank clean complete =>
    refine ⟨?_, ?_, h.releaseSafe, h.receiptSafe, h.bounded, h.unique, h.inRange⟩
    · intro _
      exact complete
    · intro committed
      simp [pending] at committed
  | fail token matching pending =>
    refine ⟨?_, ?_, h.releaseSafe, h.receiptSafe, h.bounded, h.unique, h.inRange⟩
    · intro sealed
      simp at sealed
    · intro committed
      simp [pending] at committed
  | pause token matching => exact h
  | success token matching pending sealed clean clear =>
    refine ⟨h.sealedComplete, ?_, ?_, ?_, h.bounded, h.unique, h.inRange⟩
    · intro _
      exact ⟨sealed, clean, ⟨token, matching⟩⟩
    · intro _
      rfl
    · intro _
      rfl
  | dispatch committed clear room =>
    refine ⟨h.sealedComplete, h.committedSafe, ?_, h.receiptSafe, ?_,
      h.unique, h.inRange⟩
    · intro _
      exact committed
    · exact Nat.succ_le_of_lt room
  | receiptRaise committed idle =>
    exact ⟨h.sealedComplete, h.committedSafe, h.releaseSafe,
      fun _ => committed, h.bounded, h.unique, h.inRange⟩
  | receiptConsume valid =>
    have committed := h.receiptSafe (by simp [valid])
    exact ⟨h.sealedComplete, h.committedSafe, h.releaseSafe,
      fun _ => committed, h.bounded, h.unique, h.inRange⟩
  | receiptLower consumed =>
    have committed := h.receiptSafe (by simp [consumed])
    exact ⟨h.sealedComplete, h.committedSafe, h.releaseSafe,
      fun _ => committed, h.bounded, h.unique, h.inRange⟩
  | receiptClose low =>
    have committed := h.receiptSafe (by simp [low])
    exact ⟨h.sealedComplete, h.committedSafe, h.releaseSafe,
      fun _ => committed, h.bounded, h.unique, h.inRange⟩
  | wrongToken token wrong =>
    exact ⟨h.sealedComplete, h.committedSafe, h.releaseSafe, h.receiptSafe,
      h.bounded, h.unique, h.inRange⟩
  | postCommitAbort committed =>
    exact ⟨h.sealedComplete, h.committedSafe, h.releaseSafe, h.receiptSafe,
      h.bounded, h.unique, h.inRange⟩
  | stall => exact h
  | recycle ready => exact BASE

inductive Reachable : Bank -> Prop where
  | base : Reachable empty
  | step {b next : Bank} : Reachable b -> Step b next -> Reachable next

theorem reachableInvariant {b : Bank} (reachable : Reachable b) : Invariant b := by
  induction reachable with
  | base => exact BASE
  | step previous transition ih => exact STEP ih transition

theorem commitCertificate {b : Bank} (h : Invariant b) (hc : b.committed = true) :
    Complete b ∧ b.sealed = true ∧ b.poison = false := by
  rcases h.committedSafe hc with ⟨sealed, clean, _⟩
  exact ⟨h.sealedComplete sealed, sealed, clean⟩

theorem releaseCertificate {b : Bank} (h : Invariant b) (hr : 0 < b.released) :
    b.committed = true ∧ Complete b ∧ b.sealed = true ∧ b.poison = false := by
  exact ⟨h.releaseSafe hr, commitCertificate h (h.releaseSafe hr)⟩

-- No successor may change a live bank's owner before both obligations close.
theorem noReuseWhileCustody {b next : Bank} (step : Step b next)
    (live : b.owner ≠ none) (held : ¬ Recyclable b) : next.owner = b.owner := by
  cases step <;> simp_all [issued, empty]

theorem recycleNeedsBoth {b : Bank} (ready : Recyclable b) :
    b.released = b.expected ∧ b.receipt = .closed :=
  ⟨ready.2.1, ready.2.2.1⟩

theorem poisonBlocksRecycle {b : Bank} (poison : b.poison = true) :
    ¬ Recyclable b := by
  intro ready
  have clean := ready.2.2.2.1
  simp [poison] at clean

theorem poisonRetained {b next : Bank} (step : Step b next)
    (live : b.owner ≠ none) (poison : b.poison = true) : next.poison = true := by
  cases step <;> simp_all [issued, empty, Recyclable]

-- Diagnostics may change on rejection; all executable-custody state is retained.
def custody (b : Bank) :
    Option Token × Nat × List Nat × Bool × Bool × Bool × Nat × Receipt :=
  (b.owner, b.expected, b.seen, b.sealed, b.poison, b.committed, b.released, b.receipt)

theorem exactTokenRejectRetainsBank (b : Bank) :
    custody { b with fault := true } = custody b := rfl

theorem rejectedAbortRetainsCommit (b : Bank) :
    ({ b with fault := true } : Bank).committed = b.committed := rfl

end DmaFetch
