import Std

/- Stateless arithmetic only; not an RTL or completion-liveness proof. -/
namespace ReadmemCount

def beats (length offset : Nat) : Nat := (length + offset + 7) / 8

theorem widened_sum_fits (length offset : Nat)
    (hl : length ≤ 262143) (ho : offset ≤ 7) :
    length + offset < 524288 := by omega

theorem count_fits_fifo (length offset : Nat)
    (hl : length ≤ 262143) (ho : offset ≤ 7) :
    beats length offset ≤ 32769 := by unfold beats; omega

theorem positive_count (length offset : Nat) (hl : 0 < length) :
    0 < beats length offset := by unfold beats; omega

theorem ceiling_covers (length offset : Nat) :
    length + offset ≤ 8 * beats length offset := by unfold beats; omega

theorem ceiling_is_minimal (length offset : Nat) (hl : 0 < length) :
    8 * (beats length offset - 1) < length + offset := by unfold beats; omega

example : beats 262143 1 = 32768 := by decide
example : beats 262143 7 = 32769 := by decide

end ReadmemCount
