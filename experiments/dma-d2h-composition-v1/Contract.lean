import Std
import Lean.Elab.Tactic.Omega

/-!
Lean 4.19 obligations for controller_retirement_v1.svh.

This is an unbounded transition-level reservation/metadata model, not a claim
that the RTL has been translated to Lean or that PCIe posted writes are visible.
The RTL assertions/fixture must establish the correspondence:
  issue  = v4_tx_fire; receive = c1_status_fire; retire = c1_retire.
The receive guard includes exact raw status / saved expected-ID equality.
The retire guard includes a checked completion and either explicit mode-0 skip
or the last required accepted DCM phase. No fairness or timeout is assumed.
-/

namespace D2HComposition

def capacity : Nat := 128

structure Counts where
  reserved : Nat
  pending : Nat
  completed : Nat
  deriving DecidableEq, Repr

def Valid (s : Counts) : Prop :=
  s.reserved = s.pending + s.completed ∧ s.reserved ≤ capacity

structure Events where
  issue : Nat
  receive : Nat
  retire : Nat
  deriving DecidableEq, Repr

def Enabled (s : Counts) (e : Events) : Prop :=
  e.issue ≤ 1 ∧ e.receive ≤ 1 ∧ e.retire ≤ 1 ∧
  (e.issue = 1 → s.reserved < capacity) ∧
  e.receive ≤ s.pending ∧ e.retire ≤ s.completed

def step (s : Counts) (e : Events) : Counts := {
  reserved := s.reserved + e.issue - e.retire
  pending := s.pending + e.issue - e.receive
  completed := s.completed + e.receive - e.retire
}

theorem reset_valid : Valid ⟨0, 0, 0⟩ := by
  simp [Valid, capacity]

-- Covers all simultaneous issue/receive/retire cases, including wrap epochs.
theorem step_preserves (s : Counts) (e : Events)
    (hv : Valid s) (he : Enabled s e) : Valid (step s e) := by
  rcases hv with ⟨haccount, hcapacity⟩
  rcases he with ⟨hi, hc, hr, hadmit, hreceive, hretire⟩
  unfold Valid step
  dsimp
  unfold capacity at *
  constructor <;> omega

-- A no-ready status cannot overfill the queue: its capacity was reserved at
-- descriptor issue, even if DCM has made no progress at all.
theorem receive_has_capacity (s : Counts) (e : Events)
    (hv : Valid s) (he : Enabled s e) :
    s.completed + e.receive ≤ capacity := by
  rcases hv with ⟨haccount, hcapacity⟩
  rcases he with ⟨hi, hc, hr, hadmit, hreceive, hretire⟩
  omega

theorem full_stops_issue (s : Counts) (e : Events)
    (he : Enabled s e) (hf : s.reserved = capacity) : e.issue = 0 := by
  rcases he with ⟨hi, hc, hr, hadmit, hreceive, hretire⟩
  omega

theorem no_unowned_retire (s : Counts) (e : Events)
    (he : Enabled s e) (hz : s.completed = 0) : e.retire = 0 := by
  rcases he with ⟨hi, hc, hr, hadmit, hreceive, hretire⟩
  omega

-- The valid gate is stable during native ready stalls: without this sole
-- issuer accepting, reservation capacity cannot become less available.
theorem held_offer_keeps_credit (s : Counts) (e : Events)
    (hi : e.issue = 0) (hc : s.reserved < capacity) :
    (step s e).reserved < capacity := by
  unfold step
  dsimp
  omega

inductive Reachable : Counts → Prop where
  | reset : Reachable ⟨0, 0, 0⟩
  | transition {s : Counts} (e : Events) :
      Reachable s → Enabled s e → Reachable (step s e)

theorem every_reachable_state_valid {s : Counts} (h : Reachable s) : Valid s := by
  induction h with
  | reset => exact reset_valid
  | transition e hreach henabled ih => exact step_preserves _ e ih henabled

theorem reachable_no_status_overflow {s : Counts} (e : Events)
    (h : Reachable s) (he : Enabled s e) :
    s.completed + e.receive ≤ capacity :=
  receive_has_capacity s e (every_reachable_state_valid h) he

structure Entry where
  id : Fin 128
  headerBase : Nat
  msiAddress : Nat
  msiData : Nat
  endpoint : Bool
  msiEnabled : Bool
  reportStatus : Bool
  deriving DecidableEq, Repr

def nativeSuccess (e : Entry) : Nat := 256 + e.id.val
def statusAddress (e : Entry) : Nat := e.headerBase + 4 * e.id.val

-- Native bit 8 is success. ep_last_to_rc[8] is an unrelated endpoint marker.
theorem failure_word_cannot_match (e : Entry) (raw : Nat) (hfail : raw < 256) :
    raw ≠ nativeSuccess e := by
  unfold nativeSuccess
  omega

theorem matched_success_has_expected_id (a b : Entry)
    (h : nativeSuccess a = nativeSuccess b) : a.id = b.id := by
  apply Fin.ext
  unfold nativeSuccess at h
  omega

-- The caller must supply an aligned, non-wrapping status header aperture.
-- This makes the natural-number address model agree with the RTL's 64 bits.
theorem status_address_no_wrap (e : Entry)
    (hbase : e.headerBase + 508 < 2^64) :
    statusAddress e % 2^64 = statusAddress e := by
  apply Nat.mod_eq_of_lt
  have hid := e.id.isLt
  unfold statusAddress
  omega

-- Interleaved IDs select the saved ID's slot; they do not select a counter's
-- current position. Distinct IDs in one header aperture have distinct slots.
theorem distinct_ids_distinct_slots (a b : Entry)
    (hbase : a.headerBase = b.headerBase) (hid : a.id ≠ b.id) :
    statusAddress a ≠ statusAddress b := by
  intro heq
  apply hid
  apply Fin.ext
  unfold statusAddress at heq
  omega

inductive Phase where
  | status
  | msi
  | done
  deriving DecidableEq, Repr

structure Held where
  saved : Entry
  phase : Phase
  deriving DecidableEq, Repr

def advance (h : Held) (waitrequest : Bool) : Held :=
  if waitrequest then h else
    match h.phase with
    | .status =>
        { h with phase := if h.saved.endpoint && h.saved.msiEnabled then .msi else .done }
    | .msi => { h with phase := .done }
    | .done => h

theorem wait_keeps_all_metadata (h : Held) : advance h true = h := by
  rfl

theorem phase_advance_keeps_metadata (h : Held) (w : Bool) :
    (advance h w).saved = h.saved := by
  cases h with
  | mk saved phase => cases w <;> cases phase <;> simp [advance]

-- With MSI required, status-write acceptance cannot return the reservation.
theorem status_is_not_retirement_when_msi_pending (e : Entry)
    (hend : e.endpoint = true) (hen : e.msiEnabled = true) :
    (advance ⟨e, .status⟩ false).phase = .msi := by
  simp [advance, hend, hen]

-- A host-visibility theorem is intentionally absent: the model ends at the
-- locally accepted DCM phase. PCIe ordering and posted-write visibility are
-- separate downstream obligations; production_driver_contract_valid=false.
end D2HComposition
