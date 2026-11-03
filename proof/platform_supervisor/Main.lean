import Std

/-!
Executable two-state model of platform_supervisor.sv. Inputs below are the RTL's
already-normalized, synchronous EMIF-domain values. A Fin-indexed Boolean function
represents each bit of a 16/8-bit register. The six legal phase encodings are
represented by an enum; illegal encodings and four-state normalization are RTL
verification obligations. There is no RTL/C++ refinement or physical DDR proof.
No liveness premise is made: a kernel or any DMA debt may remain outstanding
forever. Only the externally coordinated common cold reset starts a new epoch.
-/
namespace PlatformSupervisor

abbrev Bits := Fin 16 → Bool
abbrev AdapterBits := Fin 8 → Bool
def zeroBits : Bits := fun _ => false
def anyBit (x : Bits) : Bool := (List.finRange 16).any x
def breachBit : Fin 16 := 7

theorem anyBit_of_bit (x : Bits) (b : Fin 16) (h : x b = true) :
    anyBit x = true := by
  simp only [anyBit, List.any_eq_true]
  exact ⟨b, List.mem_ofFn.mpr ⟨b, rfl⟩, h⟩

inductive Phase where
  | hold | ready | stopWork | stopAdapter | parked | opening
  deriving DecidableEq, Repr
inductive Command where
  | start | resume | quiesce | recover | invalid
  deriving DecidableEq, Repr

structure FirstFault where
  code : Bits
  adapterCode : AdapterBits
  address : BitVec 35
  addressValid : Bool

structure State where
  phase : Phase
  seenReady : Bool
  started : Bool
  barrierSeen : Bool
  fault : Bool
  history : Bits
  pending : Bits
  first : FirstFault

structure Input where
  coldResetN : Bool
  memoryReady : Bool
  initFailed : Bool
  ecc : Bool
  adapterFault : Bool
  adapterCode : AdapterBits
  adapterAddress : BitVec 35
  adapterAddressValid : Bool
  adapterQuiescing : Bool
  adapterDrained : Bool
  kernelValid : Bool
  kernelStopAck : Bool
  kernelIdle : Bool
  kernelFault : Bool
  hostValid : Bool
  hostStopAck : Bool
  hostDmaDrained : Bool
  hostDescDrained : Bool
  hostWritebackDrained : Bool
  hostFault : Bool
  externalStop : Bool
  cmdValid : Bool
  cmd : Command
  clearValid : Bool
  clearMask : Bits

def initial : State :=
  ⟨.hold, false, false, false, false, zeroBits, zeroBits,
   ⟨zeroBits, fun _ => false, 0, false⟩⟩

def sourcesDrained (i : Input) : Bool :=
  i.kernelValid && i.kernelStopAck && i.kernelIdle && i.hostValid &&
  i.hostStopAck && i.hostDmaDrained && i.hostDescDrained && i.hostWritebackDrained

def closedPhase (p : Phase) : Bool :=
  match p with
  | .hold | .stopAdapter | .parked => true
  | .ready | .stopWork | .opening => false

def adapterQuiesce (s : State) (i : Input) : Bool :=
  !i.coldResetN || closedPhase s.phase

-- Structural closure avoids a combinational fault/admission/barrier loop.
-- Every closedPhase is different from READY, so admission is already closed.
def rawBarrier (s : State) (i : Input) : Bool :=
  i.coldResetN && closedPhase s.phase && sourcesDrained i &&
  i.adapterQuiescing && i.adapterDrained

def contractLost (s : State) (i : Input) : Bool :=
  (((decide (s.phase = .stopAdapter)) || (decide (s.phase = .parked)) ||
    (decide (s.phase = .opening))) && !sourcesDrained i) ||
  (s.barrierSeen && !rawBarrier s i)

def live (s : State) (i : Input) (b : Fin 16) : Bool :=
  i.coldResetN &&
  if h : b.val < 8 then
    match b.val with
    | 0 => i.initFailed
    | 1 => s.seenReady && !i.memoryReady
    | 2 => i.ecc
    | 3 => i.adapterFault || (!adapterQuiesce s i && i.adapterQuiescing)
    | 4 => i.kernelFault
    | 5 => i.hostFault
    | 6 => s.started && (!i.kernelValid || !i.hostValid)
    | _ => contractLost s i
  else i.adapterFault && i.adapterCode ⟨b.val - 8, by omega⟩

def effectiveFault (s : State) (i : Input) : Bool :=
  s.fault || anyBit (live s i)
def commandReady (s : State) (i : Input) : Bool :=
  i.coldResetN && decide (s.phase ≠ .opening)
def stopNow (s : State) (i : Input) : Bool :=
  i.externalStop || (commandReady s i && i.cmdValid && decide (i.cmd = .quiesce))
def admissionClosed (s : State) (i : Input) : Bool :=
  !i.coldResetN || (decide (s.phase ≠ .ready)) || effectiveFault s i || stopNow s i
def launchPermit (s : State) (i : Input) : Bool :=
  i.coldResetN && !admissionClosed s i && i.memoryReady && i.kernelValid && i.hostValid &&
  !i.kernelStopAck && !i.hostStopAck
def releaseReady (s : State) (i : Input) : Bool :=
  rawBarrier s i && !s.history breachBit && !live s i breachBit

-- START/RESUME are consumed first, then completed one cycle later. The
-- OPENING phase is a pending request, independent of current command inputs.
-- New commands are not consumed while commandReady is false.
def beginOpen (s : State) (i : Input) : Bool :=
  commandReady s i && i.cmdValid &&
  match i.cmd with
  | .start => !effectiveFault s i && !i.externalStop &&
      decide (s.phase = .hold) && i.memoryReady && releaseReady s i
  | .resume => !effectiveFault s i && !i.externalStop &&
      decide (s.phase = .parked) && i.memoryReady && releaseReady s i
  | _ => false

def finishOpen (s : State) (i : Input) : Bool :=
  decide (s.phase = .opening) && !effectiveFault s i && !i.externalStop &&
  i.memoryReady && sourcesDrained i

def commandAccepted (s : State) (i : Input) : Bool :=
  i.coldResetN && (finishOpen s i ||
    (commandReady s i && i.cmdValid && decide (i.cmd = .quiesce)))

def nextPhase (s : State) (i : Input) : Phase :=
  match s.phase with
  | .hold => if beginOpen s i then .opening
             else if stopNow s i then
               if sourcesDrained i then .stopAdapter else .stopWork
             else .hold
  | .ready => if effectiveFault s i || stopNow s i then .stopWork else .ready
  | .stopWork => if sourcesDrained i then .stopAdapter else .stopWork
  | .stopAdapter => if releaseReady s i then .parked else .stopAdapter
  | .parked => if beginOpen s i then .opening else .parked
  | .opening => if finishOpen s i then .ready else .stopWork

def captureFirst (s : State) (i : Input) : FirstFault :=
  ⟨live s i,
   (fun b => i.adapterFault && i.adapterCode b),
   (if i.adapterFault && i.adapterAddressValid then i.adapterAddress else 0),
   i.adapterFault && i.adapterAddressValid⟩

def step (s : State) (i : Input) : State :=
  if i.coldResetN then
    { phase := nextPhase s i
      seenReady := s.seenReady || i.memoryReady
      started := s.started || finishOpen s i
      barrierSeen := if beginOpen s i then false else s.barrierSeen || releaseReady s i
      fault := effectiveFault s i
      history := fun b => s.history b || live s i b
      pending := fun b => (s.pending b && !(i.clearValid && i.clearMask b)) || live s i b
      first := if s.fault then s.first
               else if anyBit (live s i) then captureFirst s i else s.first }
  else initial

def resetRequest (_s : State) (_i : Input) : Bool := false
def epochAdvance (_s : State) (_i : Input) : Bool := false

-- State properties really checked at the cold-reset base and preserved by step.
def Inv (s : State) : Prop :=
  (∀ b, s.history b = true → s.fault = true) ∧
  (s.phase = .ready → s.started = true)

theorem base : Inv initial := by
  simp [Inv, initial, zeroBits]

theorem history_step (s : State) (i : Input) (b : Fin 16)
    (hr : i.coldResetN = true) (h : s.history b = true) :
    (step s i).history b = true := by
  simp [step, hr, h]

theorem live_history_step (s : State) (i : Input) (b : Fin 16)
    (hr : i.coldResetN = true) (h : live s i b = true) :
    (step s i).history b = true := by
  simp [step, hr, h]

theorem sticky_fault_step (s : State) (i : Input)
    (hr : i.coldResetN = true) (h : s.fault = true) :
    (step s i).fault = true := by
  simp [step, hr, effectiveFault, h]

theorem fault_loss_requires_reset (s : State) (i : Input)
    (hf : s.fault = true) (hn : (step s i).fault = false) :
    i.coldResetN = false := by
  cases hr : i.coldResetN
  · rfl
  · have hp := sticky_fault_step s i hr hf
    simp [hn] at hp

theorem first_fault_step (s : State) (i : Input)
    (hr : i.coldResetN = true) (h : s.fault = true) :
    (step s i).first = s.first := by
  simp [step, hr, h]

theorem ready_started_step (s : State) (i : Input)
    (h : s.phase = .ready → s.started = true) :
    (step s i).phase = .ready → (step s i).started = true := by
  cases hr : i.coldResetN
  · simp [step, hr, initial]
  · simp only [step, hr, Bool.true_eq, ↓reduceIte]
    cases hp : s.phase <;> simp only [nextPhase, hp]
    · split
      · simp_all
      · split
        · split <;> simp_all
        · simp_all
    · split <;> simp_all
    · split <;> simp_all
    · split <;> simp_all
    · split <;> simp_all
    · split <;> simp_all

theorem induction_step (s : State) (i : Input) (h : Inv s) : Inv (step s i) := by
  constructor
  · intro b hb
    cases hr : i.coldResetN
    · simp [step, hr, initial, zeroBits] at hb
    · simp only [step, hr, Bool.true_eq, ↓reduceIte] at hb ⊢
      simp only [Bool.or_eq_true] at hb
      rcases hb with old | fresh
      · simp [effectiveFault, h.1 b old]
      · simp [effectiveFault, anyBit_of_bit _ _ fresh]
  · exact ready_started_step s i h.2

theorem launch_safe (s : State) (i : Input) (h : launchPermit s i = true) :
    s.phase = .ready ∧ s.fault = false ∧ anyBit (live s i) = false ∧
    stopNow s i = false ∧ admissionClosed s i = false ∧ i.memoryReady = true ∧
    i.kernelValid = true ∧ i.hostValid = true ∧
    i.kernelStopAck = false ∧ i.hostStopAck = false := by
  simp only [launchPermit, Bool.and_eq_true, Bool.not_eq_true'] at h
  rcases h with ⟨⟨⟨⟨⟨⟨hr, hc⟩, hm⟩, hk⟩, hh⟩, hka⟩, hha⟩
  have hx := hc
  simp [admissionClosed, effectiveFault] at hx
  exact ⟨hx.1.1.2, hx.1.2.1, hx.1.2.2, hx.2, hc, hm, hk, hh, hka, hha⟩

theorem release_safe (s : State) (i : Input) (h : releaseReady s i = true) :
    admissionClosed s i = true ∧ adapterQuiesce s i = true ∧
    i.coldResetN = true ∧ i.kernelValid = true ∧ i.kernelStopAck = true ∧
    i.kernelIdle = true ∧ i.hostValid = true ∧ i.hostStopAck = true ∧
    i.hostDmaDrained = true ∧ i.hostDescDrained = true ∧
    i.hostWritebackDrained = true ∧ i.adapterQuiescing = true ∧
    i.adapterDrained = true ∧ s.history breachBit = false ∧
    live s i breachBit = false := by
  have hb := h
  simp only [releaseReady, rawBarrier, sourcesDrained, Bool.and_eq_true,
    Bool.not_eq_true'] at hb
  rcases hb with ⟨⟨⟨⟨⟨⟨hr, hp⟩, hs⟩, hq⟩, hd⟩, hh⟩, hl⟩
  have hc : admissionClosed s i = true := by
    cases he : s.phase <;> simp_all [closedPhase, admissionClosed]
  have ha : adapterQuiesce s i = true := by simp [adapterQuiesce, hp]
  exact ⟨hc, ha, hr, hs.1.1.1.1.1.1.1, hs.1.1.1.1.1.1.2,
    hs.1.1.1.1.1.2, hs.1.1.1.1.2, hs.1.1.1.2, hs.1.1.2,
    hs.1.2, hs.2, hq, hd, hh, hl⟩

theorem release_excludes_launch (s : State) (i : Input)
    (h : releaseReady s i = true) : launchPermit s i = false := by
  simp [launchPermit, (release_safe s i h).1]

theorem live_adapter_stop_blocks_launch (s : State) (i : Input)
    (hr : i.coldResetN = true) (hp : s.phase = .ready)
    (hq : i.adapterQuiescing = true) : launchPermit s i = false := by
  have hl : live s i 3 = true := by
    change (i.coldResetN &&
      (i.adapterFault || (!adapterQuiesce s i && i.adapterQuiescing))) = true
    simp [hr, hp, hq, adapterQuiesce, closedPhase]
  have hf := anyBit_of_bit (live s i) 3 hl
  simp [launchPermit, admissionClosed, effectiveFault, hf]

theorem opening_gates (s : State) (i : Input)
    (hr : i.coldResetN = true) (hp : s.phase = .opening) :
    commandReady s i = false ∧ launchPermit s i = false ∧
    adapterQuiesce s i = false ∧ admissionClosed s i = true := by
  simp [commandReady, launchPermit, admissionClosed, adapterQuiesce, closedPhase, hr, hp]

theorem opening_completion_safe (s : State) (i : Input)
    (hp : s.phase = .opening) (ha : commandAccepted s i = true) :
    effectiveFault s i = false ∧ i.externalStop = false ∧
    i.memoryReady = true ∧ sourcesDrained i = true := by
  have h : i.coldResetN = true ∧
      ((effectiveFault s i = false ∧ i.externalStop = false) ∧
        i.memoryReady = true) ∧ sourcesDrained i = true := by
    simpa [commandAccepted, commandReady, finishOpen, hp] using ha
  exact ⟨h.2.1.1.1, h.2.1.1.2, h.2.1.2, h.2.2⟩

theorem opening_live_error_rejects (s : State) (i : Input)
    (hr : i.coldResetN = true) (hp : s.phase = .opening)
    (hq : i.adapterQuiescing = true) : commandAccepted s i = false := by
  have hl : live s i 3 = true := by
    change (i.coldResetN &&
      (i.adapterFault || (!adapterQuiesce s i && i.adapterQuiescing))) = true
    simp [hr, hp, hq, adapterQuiesce, closedPhase]
  have hf := anyBit_of_bit (live s i) 3 hl
  simp [commandAccepted, commandReady, finishOpen, effectiveFault, hf, hp]

theorem begin_is_not_completion (s : State) (i : Input)
    (hb : beginOpen s i = true) : commandAccepted s i = false := by
  cases hc : i.cmd <;> cases hp : s.phase <;>
    simp_all [beginOpen, commandReady, commandAccepted, finishOpen]

theorem active_stop_work_keeps_memory_open (s : State) (i : Input)
    (hr : i.coldResetN = true) (hp : s.phase = .stopWork)
    (hd : sourcesDrained i = false) :
    (step s i).phase = .stopWork ∧ adapterQuiesce s i = false := by
  simp [step, hr, nextPhase, hp, hd, adapterQuiesce, closedPhase]

theorem stop_from_ready_preserves_memory (s : State) (i : Input)
    (hr : i.coldResetN = true) (hp : s.phase = .ready)
    (hs : (effectiveFault s i || stopNow s i) = true) :
    (step s i).phase = .stopWork ∧ adapterQuiesce (step s i) i = false := by
  simp only [step, hr, Bool.true_eq, ↓reduceIte, nextPhase, hp, hs]
  simp [adapterQuiesce, hr, closedPhase]

theorem stopped_hold_keeps_closed_barrier (s : State) (i : Input)
    (hr : i.coldResetN = true) (hp : s.phase = .hold)
    (hs : stopNow s i = true) (ho : beginOpen s i = false)
    (hd : sourcesDrained i = true) :
    (step s i).phase = .stopAdapter ∧ adapterQuiesce (step s i) i = true := by
  simp [step, hr, nextPhase, hp, hs, ho, hd, adapterQuiesce, closedPhase]

theorem live_wins_clear (s : State) (i : Input) (b : Fin 16)
    (hr : i.coldResetN = true) (hl : live s i b = true) :
    (step s i).pending b = true := by
  simp [step, hr, hl]

theorem fault_blocks_commands (s : State) (i : Input)
    (hf : effectiveFault s i = true)
    (hc : i.cmd = .start ∨ i.cmd = .resume) : commandAccepted s i = false := by
  rcases hc with hc | hc <;> simp [commandAccepted, finishOpen, hc, hf]

theorem no_software_recovery (s : State) (i : Input) :
    resetRequest s i = false ∧ epochAdvance s i = false ∧
    (i.cmd = .recover → commandReady s i = true → commandAccepted s i = false) := by
  refine ⟨rfl, rfl, ?_⟩
  intro hc hr
  have hp : s.phase ≠ .opening := by
    intro hp
    simp [commandReady, hp] at hr
  simp [commandAccepted, finishOpen, hc, hp]

theorem coordinated_reset_base (s : State) (i : Input)
    (hr : i.coldResetN = false) : step s i = initial := by simp [step, hr]

def run : State → List Input → State
  | s, [] => s
  | s, i :: is => run (step s i) is

theorem reachable_inv (is : List Input) : Inv (run initial is) := by
  have aux : ∀ (is : List Input) (s : State), Inv s → Inv (run s is) := by
    intro xs
    induction xs with
    | nil => intro s hs; exact hs
    | cons i is ih => intro s hs; exact ih (step s i) (induction_step s i hs)
  exact aux is initial base

theorem sticky_fault_trace (s : State) (is : List Input)
    (hr : ∀ i ∈ is, i.coldResetN = true) (hf : s.fault = true) :
    (run s is).fault = true := by
  induction is generalizing s with
  | nil => exact hf
  | cons i is ih =>
    exact ih (step s i) (fun j hj => hr j (List.mem_cons_of_mem i hj))
      (sticky_fault_step s i (hr i (by simp)) hf)

theorem history_trace (s : State) (is : List Input) (b : Fin 16)
    (hr : ∀ i ∈ is, i.coldResetN = true) (hh : s.history b = true) :
    (run s is).history b = true := by
  induction is generalizing s with
  | nil => exact hh
  | cons i is ih =>
    exact ih (step s i) (fun j hj => hr j (List.mem_cons_of_mem i hj))
      (history_step s i b (hr i (by simp)) hh)

theorem first_fault_trace (s : State) (is : List Input)
    (hr : ∀ i ∈ is, i.coldResetN = true) (hf : s.fault = true) :
    (run s is).first = s.first := by
  induction is generalizing s with
  | nil => rfl
  | cons i is ih =>
    exact (ih (step s i) (fun j hj => hr j (List.mem_cons_of_mem i hj))
      (sticky_fault_step s i (hr i (by simp)) hf)).trans
        (first_fault_step s i (hr i (by simp)) hf)

#eval Lean.versionString
#print axioms base
#print axioms induction_step
#print axioms reachable_inv
#print axioms launch_safe
#print axioms release_safe
#print axioms release_excludes_launch
#print axioms live_adapter_stop_blocks_launch
#print axioms opening_gates
#print axioms opening_completion_safe
#print axioms opening_live_error_rejects
#print axioms begin_is_not_completion
#print axioms history_step
#print axioms history_trace
#print axioms sticky_fault_step
#print axioms sticky_fault_trace
#print axioms fault_loss_requires_reset
#print axioms first_fault_step
#print axioms first_fault_trace
#print axioms active_stop_work_keeps_memory_open
#print axioms stop_from_ready_preserves_memory
#print axioms stopped_hold_keeps_closed_barrier
#print axioms live_wins_clear
#print axioms fault_blocks_commands
#print axioms no_software_recovery
#print axioms coordinated_reset_base
end PlatformSupervisor
