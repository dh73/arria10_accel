import Std

namespace ConfigurationStartupHold

-- 50 MHz + 50 ppm, with integer-Hz arithmetic.
def maximumClockHz : Nat := 50002500
def holdCycles : Nat := 41503

theorem coversStartupBound :
    holdCycles * 1000000 ≥ 830 * maximumClockHz := by decide

theorem previousCycleTooShort :
    (holdCycles - 1) * 1000000 < 830 * maximumClockHz := by decide

-- Abstract saturating counter. Hardware power-up, clock and CDC premises
-- require separate implementation qualification.
def step (limit count : Nat) : Nat :=
  if count < limit then count + 1 else count

def run (limit : Nat) : Nat → Nat
  | 0 => 0
  | n + 1 => step limit (run limit n)

theorem stepBound (limit count : Nat) (h : count ≤ limit) :
    step limit count ≤ limit := by
  unfold step
  split <;> omega

theorem stepMonotone (limit count : Nat) : count ≤ step limit count := by
  unfold step
  split <;> omega

theorem runExact (limit cycles : Nat) : run limit cycles = min cycles limit := by
  induction cycles with
  | zero => simp [run]
  | succ n ih =>
    simp only [run, ih, step]
    split <;> omega

theorem noEarlyRelease (limit cycles : Nat) (h : cycles < limit) :
    run limit cycles < limit := by
  rw [runExact]
  omega

theorem releaseAtBound (limit : Nat) : run limit limit = limit := by
  simp [runExact]

theorem staysReleased (limit cycles : Nat) (h : limit ≤ cycles) :
    run limit cycles = limit := by
  rw [runExact]
  omega

end ConfigurationStartupHold
