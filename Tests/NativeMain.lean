import Hegel

open Hegel

def assertEq [BEq α] [Repr α] (expected actual : α) : IO Unit :=
  unless expected == actual do
    throw <| IO.userError s!"expected {reprStr expected}, got {reprStr actual}"

def main (args : List String) : IO UInt32 := do
  let path := args.head?.getD "upstream/hegel-rust/target/release/libhegel_c.so"
  let library ← Hegel.FFI.Library.load path
  let version ← library.version
  unless !version.isEmpty do throw <| IO.userError "libhegel returned an empty version"

  let settings : Settings := {
    testCases := 20
    seed := some 12345
    derandomize := true
    verbosity := .quiet
    database := .disabled
    reportMultipleFailures := false
  }
  let passing ← check library settings "native passing property" fun tc => do
    let x ← tc.draw (Generator.naturals 0 10)
    pure (x <= 10)
  assertEq .passed passing.status
  assertEq 0 passing.failureCount

  let failing ← check library settings "native failing property" fun tc => do
    let x ← tc.drawNamed "x" (Generator.naturals 0 10)
    pure (x = 0)
  assertEq .failed failing.status
  assertEq 1 failing.failureCount
  unless failing.reproductions.size = 1 && failing.reproductions[0]!.contains "x = " do
    throw <| IO.userError "final replay did not render the named minimal draw"
  let failure ← match failing.failures[0]? with
    | some failure => pure failure
    | none => throw <| IO.userError "failed run did not expose its failure snapshot"
  assertEq "native failing property" failure.origin
  let blob ← match failure.reproductionBlob with
    | some blob => pure blob
    | none => throw <| IO.userError "native failure did not include a reproduction blob"
  unless !blob.isEmpty do throw <| IO.userError "native reproduction blob was empty"
  let replayed ← replay library blob settings fun tc => do
    let x ← tc.draw (Generator.naturals 0 10)
    pure (x = 0)
  assertEq .reproduced replayed

  let stale ← replay library blob settings fun tc => do
    let x ← tc.draw (Generator.naturals 0 10)
    pure (x <= 10)
  assertEq .didNotReproduce stale

  let composite ← check library settings "native composite property" fun tc => do
    let enabled ← tc.draw Generator.booleans
    let values ← tc.draw (Generator.nativeList (Generator.naturals 0 20) 1 5)
    let unique ← tc.draw (Generator.uniqueList (Generator.naturals 0 20) 1 5)
    tc.assume (!enabled || !values.isEmpty)
    tc.target values.length.toFloat "list length"
    pure (values.length >= 1 && values.length <= 5 && values.all (· <= 20) &&
      unique.length >= 1 && unique.length <= 5 && unique.eraseDups.length = unique.length)
  assertEq .passed composite.status
  assertEq 0 composite.failureCount

  let primitives ← check library settings "native primitive property" fun tc => do
    let value ← tc.draw (Generator.floats (-100.0) 100.0)
    let payload ← tc.draw (Generator.bytes 2 12)
    let ascii ← tc.draw (Generator.text 1 10 true)
    let unicode ← tc.draw (Generator.text 1 10)
    pure (value >= -100.0 && value <= 100.0 &&
      payload.size >= 2 && payload.size <= 12 &&
      ascii.length >= 1 && ascii.length <= 10 &&
      unicode.length >= 1 && unicode.length <= 10)
  assertEq .passed primitives.status
  assertEq 0 primitives.failureCount

  let formatted ← check library { settings with testCases := 8 }
      "native formatted string property" fun tc => do
    let email ← tc.draw Generator.emails
    let url ← tc.draw Generator.urls
    let domain ← tc.draw (Generator.domains 100)
    let matched ← tc.draw (Generator.fromRegex "[a-z]{1,5}")
    let even ← tc.draw ((Generator.naturals 0 20).filter (fun n => n % 2 = 0))
    pure (!email.isEmpty && email.contains '@' &&
      (url.startsWith "http://" || url.startsWith "https://") &&
      !domain.isEmpty && domain.length <= 100 &&
      matched.length >= 1 && matched.length <= 5 && even % 2 = 0)
  assertEq .passed formatted.status
  assertEq 0 formatted.failureCount


  let stateful ← check library { settings with testCases := 8 }
      "native stateful property" fun tc => do
    let pool ← Stateful.Pool.create tc
    pool.add 10
    pool.add 20
    let reused ← tc.draw pool.reusable
    let consumed ← tc.draw pool.consumed
    let remaining ← pool.size
    let increment : Stateful.Rule Int := { name := "increment", step := fun _ state => pure (state + 1) }
    let decrement : Stateful.Rule Int := { name := "decrement", step := fun _ state => pure (state - 1) }
    let bounded : Stateful.Invariant Int := {
      name := "bounded"
      check := fun state => pure (state >= -10 && state <= 10)
    }
    let final ← Stateful.run tc 0 #[increment, decrement] #[bounded] 10
    pure ((reused = 10 || reused = 20) && (consumed = 10 || consumed = 20) &&
      remaining = 1 && final >= -10 && final <= 10)
  assertEq .passed stateful.status
  assertEq 0 stateful.failureCount


  let structured ← check library { settings with testCases := 12 }
      "native structured primitive property" fun tc => do
    let date ← tc.draw (Generator.dates
      { year := 2020, month := 1, day := 1 }
      { year := 2021, month := 12, day := 31 })
    let time ← tc.draw Generator.times
    let datetime ← tc.draw (Generator.dateTimes
      { date := { year := 2020, month := 1, day := 1 }, time := { hour := 0, minute := 0, second := 0 } }
      { date := { year := 2021, month := 12, day := 31 },
        time := { hour := 23, minute := 59, second := 59, microsecond := 999999 } })
    let uuid ← tc.draw (Generator.uuids (some 4))
    let ipv4 ← tc.draw Generator.ipv4
    let ipv6 ← tc.draw Generator.ipv6
    let bigMin : Int := -(2^100)
    let bigMax : Int := 2^100
    let big ← tc.draw (Generator.bigIntegers bigMin bigMax)
    pure (date.year >= 2020 && date.year <= 2021 &&
      time.hour <= 23 && time.minute <= 59 && time.second <= 59 &&
      datetime.date.year >= 2020 && datetime.date.year <= 2021 &&
      uuid.size = 16 && (uuid[6]! >>> 4) = 4 && (uuid[8]! >>> 6) = 2 &&
      ipv4.size = 4 && ipv6.size = 16 && big >= bigMin && big <= bigMax)
  assertEq .passed structured.status
  assertEq 0 structured.failureCount

  let captured ← check library { settings with testCases := 1, verbosity := .debug }
      "native output capture" fun tc => do
    let _ ← tc.draw (Generator.naturals 0 10)
    pure true
  assertEq .passed captured.status
  unless !captured.output.isEmpty do
    throw <| IO.userError "debug run produced no captured engine output"

  let cloned ← check library { settings with testCases := 4 }
      "native cloned test case" fun tc => do
    let child ← tc.clone
    let parentValue ← tc.draw (Generator.naturals 0 100)
    let childValue ← child.draw (Generator.naturals 0 100)
    pure (parentValue <= 100 && childValue <= 100)
  assertEq .passed cloned.status
  IO.println s!"Native libhegel {version} integration tests passed"
  pure 0
