import Std.Tactic

/- Transaction-count model for kernel_cra_mailbox.sv within one common-reset
   epoch. `command` is the already validated IDLE command (false=write,
   true=read). PIO setup/result accesses do not generate commands. This models
   control transitions, not an extracted RTL equivalence or CDC proof.
   No fairness, bounded response time, or eventual completion is assumed. -/
namespace KernelCraMailbox
inductive Phase where
 | idle | issueWrite | issueRead | response
 deriving DecidableEq
structure State where
 phase : Phase
 admitted : Nat
 issued : Nat
 completed : Nat
structure Input where
 command : Option Bool
 ready : Bool
 valid : Bool

def issueDebt : Phase → Nat
 | .issueWrite | .issueRead => 1
 | _ => 0

def responseDebt : Phase → Nat
 | .response => 1
 | _ => 0

def initial : State := ⟨.idle, 0, 0, 0⟩

def step (s : State) (i : Input) : State :=
 match s.phase with
 | .idle => match i.command with
   | none => s
   | some read => {s with phase := (if read then .issueRead else .issueWrite), admitted := s.admitted + 1}
 | .issueWrite => if i.ready then
     {s with phase := .idle, issued := s.issued+1, completed := s.completed+1}
   else s
 | .issueRead => if i.ready then
     if i.valid then
       {s with phase := .idle, issued := s.issued+1, completed := s.completed+1}
     else {s with phase := .response, issued := s.issued+1}
   else s
 | .response => if i.valid then
     {s with phase := .idle, completed := s.completed+1}
   else s

def Inv (s : State) : Prop :=
 s.admitted = s.issued + issueDebt s.phase ∧
 s.issued = s.completed + responseDebt s.phase

theorem base : Inv initial := by simp [Inv, initial, issueDebt, responseDebt]

theorem inductive_step (s : State) (i : Input) (h : Inv s) : Inv (step s i) := by
 rcases s with ⟨phase,a,n,c⟩
 rcases i with ⟨cmd,r,v⟩
 cases phase <;> cases cmd with
 | none => cases r <;> cases v <;> simp_all [step, Inv, issueDebt, responseDebt] <;> omega
 | some b => cases b <;> cases r <;> cases v <;>
     simp_all [step, Inv, issueDebt, responseDebt] <;> omega

theorem trace_inv (inputs : List Input) : Inv (inputs.foldl step initial) := by
 have general : ∀ (xs : List Input) (s : State), Inv s → Inv (xs.foldl step s) := by
  intro xs
  induction xs with
  | nil => intro s h; exact h
  | cons i xs ih => intro s h; exact ih (step s i) (inductive_step s i h)
 exact general inputs initial base

theorem no_duplicate (inputs : List Input) :
 (inputs.foldl step initial).completed ≤ (inputs.foldl step initial).issued ∧
 (inputs.foldl step initial).issued ≤ (inputs.foldl step initial).admitted := by
 have h := trace_inv inputs
 unfold Inv at h
 omega

theorem idle_reconciled (s : State) (h : Inv s) (idle : s.phase = .idle) :
 s.admitted = s.issued ∧ s.issued = s.completed := by
 simpa [Inv, idle, issueDebt, responseDebt] using h

theorem response_never_reissues (s : State) (i : Input) (p : s.phase = .response) :
 (step s i).issued = s.issued := by
 simp [step,p]; split <;> rfl
end KernelCraMailbox

#print axioms KernelCraMailbox.inductive_step
#print axioms KernelCraMailbox.trace_inv
#print axioms KernelCraMailbox.no_duplicate
