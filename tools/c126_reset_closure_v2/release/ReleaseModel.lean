import Std

/- Checked with Lean 4.19.0, including base, step and reachable-state theorem.
   Deterministic event model of c126_reset_release's enabled branch.
   A tick sees the OLD q2; asynchronous loss of qualification resets all state.
   Stalling the clock contributes no tick. Nat held is valid while held < n;
   the intended RTL counter width is max(1,ceil(log2(n))). Representation and
   RTL equivalence are not proved here. These are proposed base/step proofs
   about this model, not an RTL equivalence proof,
   metastability model, timing analysis, clock-availability proof, or hard-IP
   reset contract. No vendor internals, analog pulse width, or POR are assumed
   proven. The initial asserted reset event is a required hardware premise. -/
namespace C126Release

structure State where
  q0 : Bool
  q1 : Bool
  q2 : Bool
  held : Nat
  released : Bool
deriving DecidableEq, Repr

def reset : State := ⟨false, false, false, 0, false⟩

def advance (n : Nat) (s : State) : State :=
  if !s.q2 then
    ⟨true, s.q0, s.q1, 0, false⟩
  else if s.released then
    ⟨true, s.q0, s.q1, s.held, true⟩
  else if s.held = n - 1 then
    ⟨true, s.q0, s.q1, s.held, true⟩
  else
    ⟨true, s.q0, s.q1, s.held + 1, false⟩

def step (n : Nat) (allow qualified : Bool) (s : State) : State :=
  if allow && qualified then advance n s else reset

def nextAge (allow qualified : Bool) (age : Nat) : Nat :=
  if allow && qualified then age + 1 else 0

-- age is a proof-only count of consecutive qualified reference edges.
def Inv (n age : Nat) (s : State) : Prop :=
  s.held < n ∧
  (s.q0 = true → 1 ≤ age) ∧
  (s.q1 = true → 2 ≤ age) ∧
  (s.q2 = true → 3 ≤ age) ∧
  (0 < s.held → s.held + 3 ≤ age) ∧
  (s.released = true → n + 3 ≤ age)

theorem base (n : Nat) (hn : 0 < n) : Inv n 0 reset := by
  simp [Inv, reset, hn]

theorem advance_preserves (n age : Nat) (hn : 0 < n)
    (s : State) (h : Inv n age s) : Inv n (age+1) (advance n s) := by
  rcases s with ⟨q0, q1, q2, held, released⟩
  cases q0 <;> cases q1 <;> cases q2 <;> cases released <;>
    by_cases hlast : held = n - 1 <;>
    simp_all [Inv, advance] <;> omega

theorem induction_step (n age : Nat) (hn : 0 < n)
    (allow qualified : Bool) (s : State) (h : Inv n age s) :
    Inv n (nextAge allow qualified age) (step n allow qualified s) := by
  cases allow <;> cases qualified
  · simpa [step, nextAge] using base n hn
  · simpa [step, nextAge] using base n hn
  · simpa [step, nextAge] using base n hn
  · simpa [step, nextAge] using advance_preserves n age hn s h

theorem asynchronous_assertion (n : Nat) (allow : Bool) (s : State) :
    step n allow false s = reset := by simp [step]

theorem disabled_holds (n : Nat) (qualified : Bool) (s : State) :
    (step n false qualified s).released = false := by simp [step, reset]

def stateAt (n : Nat) (qualified : Nat → Bool) : Nat → State
  | 0 => reset
  | k+1 => step n true (qualified k) (stateAt n qualified k)

def ageAt (qualified : Nat → Bool) : Nat → Nat
  | 0 => 0
  | k+1 => nextAge true (qualified k) (ageAt qualified k)

theorem every_reachable_state (n : Nat) (hn : 0 < n)
    (qualified : Nat → Bool) (k : Nat) :
    Inv n (ageAt qualified k) (stateAt n qualified k) := by
  induction k with
  | zero => exact base n hn
  | succ k ih =>
      exact induction_step n (ageAt qualified k) hn
        true (qualified k) (stateAt n qualified k) ih

theorem release_requires_n_plus_three_edges (n : Nat) (hn : 0 < n)
    (qualified : Nat → Bool) (k : Nat)
    (h : (stateAt n qualified k).released = true) :
    n + 3 ≤ ageAt qualified k := by
  have hi := every_reachable_state n hn qualified k
  exact hi.2.2.2.2.2 h

#print axioms base
#print axioms induction_step
#print axioms release_requires_n_plus_three_edges
end C126Release
