import Std.Tactic

/- Ordered-read contract for the pipelined DDR mux, within one coordinated
   reset epoch. Entries include owner and a non-reused request identity.
   This is a protocol model, not RTL/ring-buffer refinement. Backend responses
   are ordered and exactly once; no progress or latency bound is assumed. -/
namespace DdrMuxOwnership
structure Entry where
  owner : Bool
  identity : Nat
  deriving DecidableEq
structure State where
  accepted : List Entry
  returned : List Entry
  pending : List Entry
  fault : Bool

def initial : State := ⟨[], [], [], false⟩
def Inv (s : State) : Prop := s.accepted = s.returned ++ s.pending

-- offer denotes actual backend read acceptance, never a stalled command.
-- Apply acceptance before response so empty-queue same-cycle bypass works.
def step (s : State) (offer : Option Entry) (response : Bool) : State :=
  if s.fault then s else
  let q := s.pending ++ offer.toList
  let a := s.accepted ++ offer.toList
  if response then
    match q with
    | [] => { s with fault := true }
    | e :: rest => ⟨a, s.returned ++ [e], rest, false⟩
  else ⟨a, s.returned, q, false⟩

theorem base : Inv initial := rfl

theorem inductive_step (s : State) (offer : Option Entry) (response : Bool)
    (h : Inv s) : Inv (step s offer response) := by
  unfold step
  split
  · exact h
  · split
    · dsimp only
      split
      · exact h
      · rename_i e rest heq
        simp only [Inv] at h ⊢
        rw [h, List.append_assoc, heq]
        simp
    · simp only [Inv] at h ⊢
      rw [h, List.append_assoc]

def run (s : State) (events : List (Option Entry × Bool)) : State :=
  events.foldl (fun st ev => step st ev.1 ev.2) s

theorem trace (events : List (Option Entry × Bool)) : Inv (run initial events) := by
  have general : ∀ es s, Inv s → Inv (run s es) := by
    intro es
    induction es with
    | nil => intro s h; exact h
    | cons ev es ih =>
      intro s h
      exact ih (step s ev.1 ev.2) (inductive_step s ev.1 ev.2 h)
  exact general events initial base

theorem no_extra_responses (s : State) (h : Inv s) :
    s.returned.length ≤ s.accepted.length := by
  unfold Inv at h
  rw [h, List.length_append]
  omega

theorem exact_order (s : State) (h : Inv s) :
    s.accepted.take s.returned.length = s.returned := by
  unfold Inv at h
  rw [h]
  simp

theorem drained (s : State) (h : Inv s) (empty : s.pending = []) :
    s.accepted = s.returned := by
  simpa [Inv, empty] using h

theorem fault_preserves_custody (s : State) (offer : Option Entry) (response : Bool)
    (h : s.fault = true) : step s offer response = s := by
  simp [step, h]

theorem empty_bypass (s : State) (e : Entry)
    (healthy : s.fault = false) (empty : s.pending = []) :
    (step s (some e) true).returned = s.returned ++ [e] ∧
    (step s (some e) true).pending = [] := by
  simp [step, healthy, empty]

end DdrMuxOwnership
#print axioms DdrMuxOwnership.inductive_step
#print axioms DdrMuxOwnership.trace
#print axioms DdrMuxOwnership.exact_order
#print axioms DdrMuxOwnership.empty_bypass
