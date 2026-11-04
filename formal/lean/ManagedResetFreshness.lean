import Std

namespace ManagedResetFreshness

-- One boundary bit of flush_low_seen after the epoch-entry clear.
-- Each call is one monitor-clock sample while epoch_reset_request is high.
-- CDC, certificate provenance and RTL refinement remain separate obligations.
def step (seenLow ack : Bool) : Bool := seenLow || !ack

def run (ack : Nat → Bool) : Nat → Bool
  | 0 => false
  | n + 1 => step (run ack n) (ack n)

def certified (seenLow ack resetObserved receiptFault : Bool) : Bool :=
  seenLow && ack && resetObserved && !receiptFault

theorem base (ack : Nat → Bool) : run ack 0 = false := rfl

theorem highStep (seen : Bool) : step seen true = seen := by
  cases seen <;> decide

theorem noSampledLow (ack : Nat → Bool) (n : Nat)
    (h : ∀ k, k < n → ack k = true) : run ack n = false := by
  induction n with
  | zero => rfl
  | succ n ih =>
    have earlier : ∀ k, k < n → ack k = true := by
      intro k hk
      exact h k (by omega)
    simp [run, ih earlier, h n (by omega), step]

theorem staleHighNeverCertifies (ack : Nat → Bool) (n : Nat)
    (h : ∀ k, k < n → ack k = true) (resetObserved fault : Bool) :
    certified (run ack n) (ack n) resetObserved fault = false := by
  simp [certified, noSampledLow ack n h]

theorem certificateRequiresAll (seen ack resetObserved fault : Bool)
    (h : certified seen ack resetObserved fault = true) :
    seen = true ∧ ack = true ∧ resetObserved = true ∧ fault = false := by
  cases seen <;> cases ack <;> cases resetObserved <;> cases fault <;>
    simp_all [certified]

theorem noResetObservation (seen ack fault : Bool) :
    certified seen ack false fault = false := by simp [certified]

theorem faultBlocks (seen ack resetObserved : Bool) :
    certified seen ack resetObserved true = false := by simp [certified]

end ManagedResetFreshness
