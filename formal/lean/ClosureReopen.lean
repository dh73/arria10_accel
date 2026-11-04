import Std.Tactic

/- Kernel-edge model of closure_reopen_cdc. ack is the synchronized observation,
   left arbitrary. No CDC timing, metastability, mailbox refinement or physical
   reset containment theorem is claimed. A coordinated reset starts a new trace.
   The state update preserves the RTL's old-fault guard on the transition even
   when the same edge records a new overlap fault. -/
namespace ClosureReopen
inductive Phase where
 | idle | waitAck | waitLow
 deriving DecidableEq
structure State where
 phase : Phase
 request : Bool
 opened : Bool
 fault : Bool
 held : Nat
 next : Nat
structure Input where
 consume : Bool
 ack : Bool

def limit : Nat := 2^64-1
def initial : State := ⟨.idle,false,false,false,0,1⟩
def bad (s : State) (i : Input) : Bool :=
 i.consume && (s.phase != .idle || i.ack || s.next == limit)
def step (s : State) (i : Input) : State :=
 let t := {s with fault := s.fault || bad s i}
 if s.fault then t else
 match s.phase with
 | .idle => if i.consume && !i.ack && s.next != limit then
      {t with held := s.next, request := true, opened := false, phase := .waitAck}
    else t
 | .waitAck => if i.ack then {t with request := false, phase := .waitLow} else t
 | .waitLow => if !i.ack then {t with next := s.next+1, opened := true, phase := .idle} else t

def ready (s : State) (i : Input) : Bool :=
 s.opened && s.phase == .idle && !s.fault && !i.consume

theorem reset_base (i : Input) : ready initial i = false ∧ initial.next = 1 := by
 simp [ready,initial]
theorem fault_step (s : State) (i : Input) (h : s.fault = true) :
 (step s i).fault = true := by simp [step,h]
theorem held_while_busy (s : State) (i : Input) (h : s.phase ≠ .idle) :
 (step s i).held = s.held := by
 cases hp : s.phase <;> cases hf : s.fault <;> cases ha : i.ack <;>
 simp_all [step]
theorem round_changes_only_on_return (s : State) (i : Input)
 (h : (step s i).next ≠ s.next) :
 s.phase = .waitLow ∧ i.ack = false ∧ s.fault = false := by
 cases hp : s.phase <;> cases hf : s.fault <;> cases ha : i.ack <;>
 cases hc : i.consume <;> simp_all [step] <;> split at h <;> simp_all

def invariant (s : State) : Prop :=
 s.next ≤ limit ∧ (s.phase ≠ .idle → s.next < limit)
theorem invariant_base : invariant initial := by simp [invariant,initial,limit]
theorem invariant_step (s : State) (i : Input) (h : invariant s) :
 invariant (step s i) := by
 rcases h with ⟨hn,hp⟩
 cases hs : s.phase <;> cases hf : s.fault <;> cases ha : i.ack <;>
 cases hc : i.consume <;> simp_all [step,invariant] <;>
 try omega
 all_goals split <;> simp_all <;> omega


def run : State → List Input → State
 | s, [] => s
 | s, i :: rest => run (step s i) rest

theorem invariant_trace (s : State) (is : List Input) (h : invariant s) :
 invariant (run s is) := by
 induction is generalizing s with
 | nil => exact h
 | cons i rest ih => exact ih _ (invariant_step s i h)

theorem no_wrap (is : List Input) : (run initial is).next ≤ limit :=
 (invariant_trace initial is invariant_base).1

theorem fault_trace (s : State) (is : List Input) (h : s.fault = true) :
 (run s is).fault = true := by
 induction is generalizing s with
 | nil => exact h
 | cons i rest ih => exact ih _ (fault_step s i h)

theorem revoked_denies (s : State) (is : List Input) (i : Input) (h : s.fault = true) :
 ready (run s is) i = false := by simp [ready,fault_trace s is h]

#print axioms invariant_base
#print axioms invariant_step
#print axioms no_wrap
#print axioms held_while_busy
#print axioms round_changes_only_on_return
#print axioms revoked_denies
end ClosureReopen
