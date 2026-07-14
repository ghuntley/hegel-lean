import Hegel

open Hegel

/-- Intentionally buggy: removing duplicates is not a valid implementation of
sorting because it changes the length of the input. -/
def brokenSort (values : List Nat) : List Nat :=
  values.mergeSort.eraseDups

def main (args : List String) : IO UInt32 := do
  let libraryPath := args.head?.getD
    "upstream/hegel-rust/target/release/libhegel_c.so"
  let engine ← FFI.Library.load libraryPath
  let result ← check engine {
      testCases := 100
      database := .disabled
      reportMultipleFailures := false
    } "brokenSort preserves length" fun testCase => do
      let values ← testCase.drawNamed "values"
        (Generator.nativeList (Generator.naturals 0 100) 0 20)
      pure ((brokenSort values).length = values.length)

  IO.println s!"status: {reprStr result.status}"
  for reproduction in result.reproductions do
    unless reproduction.isEmpty do
      IO.println "minimal counterexample:"
      IO.println reproduction
  pure 0
