import Hegel.Runner

namespace Hegel.Stateful

/-- Engine-backed values produced by earlier stateful steps. -/
structure Pool (α : Type) where
  private testCase : TestCase
  private id : Int64
  private values : IO.Ref (List (Int64 × α))

def Pool.create (testCase : TestCase) : IO (Pool α) := do
  let id ← testCase.newPoolId
  let values ← IO.mkRef []
  pure { testCase, id, values }

def Pool.size (pool : Pool α) : IO Nat := do
  pure (← pool.values.get).length

def Pool.add (pool : Pool α) (value : α) : IO Unit := do
  let id ← pool.testCase.poolAddId pool.id
  pool.values.modify (fun values => (id, value) :: values)

private def findValue (id : Int64) : List (Int64 × α) → Option α
  | [] => none
  | (candidate, value) :: rest => if candidate = id then some value else findValue id rest

private def removeValue (id : Int64) : List (Int64 × α) → Option (α × List (Int64 × α))
  | [] => none
  | (candidate, value) :: rest =>
    if candidate = id then some (value, rest)
    else (removeValue id rest).map fun (found, tail) => (found, (candidate, value) :: tail)

/-- Draw a previously added value without removing it. -/
def Pool.reusable (pool : Pool α) : Generator NativeGen α := ⟨do
  let id ← pool.testCase.poolGenerateId pool.id false
  match findValue id (← pool.values.get) with
  | some value => pure value
  | none => throw <| IO.userError "libhegel selected an unknown pool variable"⟩

/-- Draw and remove a previously added value. -/
def Pool.consumed (pool : Pool α) : Generator NativeGen α := ⟨do
  let id ← pool.testCase.poolGenerateId pool.id true
  match removeValue id (← pool.values.get) with
  | some (value, remaining) =>
    pool.values.set remaining
    pure value
  | none => throw <| IO.userError "libhegel selected an unknown pool variable"⟩

structure Rule (σ : Type) where
  name : String
  step : TestCase → σ → IO σ

structure Invariant (σ : Type) where
  name : String
  check : σ → IO Bool

private def checkInvariants (state : σ) (invariants : Array (Invariant σ)) : IO Unit := do
  for invariant in invariants do
    unless ← invariant.check state do
      throw <| IO.userError s!"stateful invariant failed: {invariant.name}"

private def runSteps (testCase : TestCase) (machine : Int64)
    (rules : Array (Rule σ)) (invariants : Array (Invariant σ)) : Nat → σ → IO σ
  | 0, state => pure state
  | steps + 1, state => do
    let index := (← testCase.nextRuleId machine).toInt.toNat
    let rule ← match rules[index]? with
      | some rule => pure rule
      | none => throw <| IO.userError s!"libhegel selected invalid rule index {index}"
    testCase.note s!"Step: {rule.name}"
    let next ← rule.step testCase state
    checkInvariants next invariants
    runSteps testCase machine rules invariants steps next

/-- Execute an engine-selected, shrinkable sequence of state-machine rules. -/
def run (testCase : TestCase) (initial : σ) (rules : Array (Rule σ))
    (invariants : Array (Invariant σ) := #[]) (steps := 50) : IO σ := do
  if rules.isEmpty then throw <| IO.userError "a state machine requires at least one rule"
  let machine ← testCase.newStateMachineId (rules.map (·.name)) (invariants.map (·.name))
  checkInvariants initial invariants
  runSteps testCase machine rules invariants steps initial

end Hegel.Stateful
