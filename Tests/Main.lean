import Hegel

open Hegel

structure ScriptState where choices : List Nat

abbrev Script := StateT ScriptState (Except String)

instance : DataSource Script where
  chooseNat min max := do
    let state ← get
    match state.choices with
    | [] => throw "choice script exhausted"
    | x :: xs =>
      if x < min || x > max then throw s!"choice {x} outside [{min}, {max}]"
      set ({ choices := xs } : ScriptState)
      pure x
  chooseBool := do
    let state ← get
    match state.choices with
    | [] => throw "choice script exhausted"
    | x :: xs =>
      if x > 1 then throw s!"choice {x} outside [0, 1]"
      set ({ choices := xs } : ScriptState)
      pure (x = 1)

def assertEq [Repr α] (expected actual : α) : IO Unit :=
  unless reprStr expected = reprStr actual do
    throw <| IO.userError s!"expected {reprStr expected}, got {reprStr actual}"

def runScript (g : Generator Script α) (choices : List Nat) : Except String α :=
  (g.generate.run { choices }).map Prod.fst

def main : IO Unit := do
  assertEq (.ok true) (runScript Generator.booleans [1])
  assertEq (.ok (some 7)) (runScript (Generator.option (Generator.naturals 0 10)) [1, 7])
  assertEq (.ok [4, 5, 6]) (runScript (Generator.list (Generator.naturals 0 9) 1 4) [3, 4, 5, 6])
  assertEq (.error "choice 8 outside [0, 3]")
    (runScript (Generator.oneOf (Generator.pure "a") #[Generator.pure "b", Generator.pure "c", Generator.pure "d"]) [8])
  let integerCases : List Int :=
    [-129, -128, -127, -1, 0, 1, 127, 128, 255, 256, 2^100, -(2^100)]
  for value in integerCases do
    assertEq (some value) (TwosComplement.decode (TwosComplement.encode value))
  assertEq 1 (TwosComplement.encode (-128)).size
  assertEq 2 (TwosComplement.encode 128).size
  IO.println "Hegel Lean tests passed"
