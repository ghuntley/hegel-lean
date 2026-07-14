import Hegel.FFI
import Hegel.Generator
import Hegel.Settings
import Hegel.Types
import Hegel.BigInt

namespace Hegel

private def verbosityCode : Verbosity → UInt32
  | .quiet => 0 | .normal => 1 | .verbose => 2 | .debug => 3

private def modeCode : Mode → UInt32
  | .testRun => 0 | .singleTestCase => 1

private def backendCode : Backend → UInt32
  | .auto => 0 | .default => 1 | .urandom => 2

private def phaseCode : Phase → UInt32
  | .explicit => 1 | .reuse => 2 | .generate => 4 | .target => 8 | .shrink => 16

private def healthCheckCode : HealthCheck → UInt32
  | .filterTooMuch => 1 | .tooSlow => 2 | .testCasesTooLarge => 4 | .largeInitialTestCase => 8

private def configure (context : FFI.Context) (settings : Settings) : IO FFI.NativeSettings := do
  let native ← context.newSettings
  native.setMode context (modeCode settings.mode)
  native.setTestCases context settings.testCases.toUInt64
  native.setVerbosity context (verbosityCode settings.verbosity)
  native.setBackend context (backendCode settings.backend)
  native.setPhases context (settings.phases.foldl (fun mask phase => mask ||| phaseCode phase) 0)
  native.setSuppressHealthChecks context
    (settings.suppressHealthChecks.foldl (fun mask check => mask ||| healthCheckCode check) 0)
  match settings.database with
  | .unset => pure ()
  | .disabled => native.setDatabase context ""
  | .path path => native.setDatabase context path
  match settings.databaseKey with
  | some key => native.setDatabaseKey context key
  | none => pure ()
  match settings.seed with
  | some seed => native.setSeed context seed true
  | none => native.setSeed context 0 false
  native.setDerandomize context settings.derandomize
  native.setReportMultipleFailures context settings.reportMultipleFailures
  pure native

/-- A test case currently controlled by libhegel. -/
structure TestCase where
  private context : FFI.Context
  private native : FFI.TestCase
  private notes : IO.Ref (Array String)

abbrev NativeGen := ReaderT TestCase IO

instance : DataSource NativeGen where
  chooseNat min max := do
    if min > max then throw <| IO.userError s!"invalid generator bounds [{min}, {max}]"
    if max > 9223372036854775807 then
      throw <| IO.userError "natural-number bound exceeds the native Int64 generator range"
    let tc ← read
    let value ← tc.native.generateInteger tc.context (Int64.ofInt min) (Int64.ofInt max)
    pure value.toInt.toNat
  chooseBool := do
    let tc ← read
    tc.native.generateBoolean tc.context 0.5

def TestCase.draw (testCase : TestCase) (generator : Generator NativeGen α) : IO α :=
  generator.generate testCase

/-- Draw and record a named value for minimal-counterexample diagnostics. -/
def TestCase.drawNamed [Repr α] (testCase : TestCase) (name : String)
    (generator : Generator NativeGen α) : IO α := do
  let value ← testCase.draw generator
  testCase.notes.modify (fun notes => notes.push s!"{name} = {reprStr value}")
  pure value

def TestCase.note (testCase : TestCase) (message : String) : IO Unit :=
  testCase.notes.modify (fun notes => notes.push message)

/-- Clone the native handle onto an independent deterministic choice stream in
the same completion family. Each clone may be driven by a different thread. -/
def TestCase.clone (testCase : TestCase) : IO TestCase := do
  let native ← testCase.native.clone testCase.context
  let notes ← IO.mkRef #[]
  pure { context := testCase.context, native, notes }

/-- Reject the current generated example when a property precondition is false. -/
def TestCase.assume (_testCase : TestCase) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError "libhegel rejected the current test case"

/-- Guide Hegel's targeting phase toward larger observations under `label`. -/
def TestCase.target (testCase : TestCase) (value : Float) (label := "") : IO Unit :=
  testCase.native.target testCase.context value label

def TestCase.newPoolId (testCase : TestCase) : IO Int64 :=
  testCase.native.newPool testCase.context

def TestCase.poolAddId (testCase : TestCase) (pool : Int64) : IO Int64 :=
  testCase.native.poolAdd testCase.context pool

def TestCase.poolGenerateId (testCase : TestCase) (pool : Int64) (consume : Bool) : IO Int64 :=
  testCase.native.poolGenerate testCase.context pool consume

def TestCase.newStateMachineId (testCase : TestCase) (rules invariants : Array String) : IO Int64 :=
  testCase.native.newStateMachine testCase.context rules invariants

def TestCase.nextRuleId (testCase : TestCase) (machine : Int64) : IO Int64 :=
  testCase.native.stateMachineNextRule testCase.context machine

private partial def collectNative (testCase : TestCase) (collection : Int64)
    (element : Generator NativeGen α) (accumulator : List α) : IO (List α) := do
  if ← testCase.native.collectionMore testCase.context collection then
    testCase.native.startSpan testCase.context 2
    let value ← element.generate testCase
    testCase.native.stopSpan testCase.context false
    collectNative testCase collection element (value :: accumulator)
  else
    pure accumulator.reverse

private partial def collectUnique [BEq α] (testCase : TestCase) (collection : Int64)
    (element : Generator NativeGen α) (accumulator : List α) : IO (List α) := do
  if ← testCase.native.collectionMore testCase.context collection then
    testCase.native.startSpan testCase.context 2
    let value ← element.generate testCase
    if accumulator.contains value then
      testCase.native.stopSpan testCase.context true
      testCase.native.collectionReject testCase.context collection "duplicate element"
      collectUnique testCase collection element accumulator
    else
      testCase.native.stopSpan testCase.context false
      collectUnique testCase collection element (value :: accumulator)
  else
    pure accumulator.reverse

/-- Variable-length lists controlled by libhegel's collection primitive.

Unlike choosing a length as a plain integer, this preserves element-aware span
metadata so the native shrinker can delete and simplify list elements. -/
def Generator.nativeList (element : Generator NativeGen α)
    (minSize := 0) (maxSize := 10) : Generator NativeGen (List α) := ⟨do
  if minSize > maxSize then
    throw <| IO.userError s!"invalid list-size bounds [{minSize}, {maxSize}]"
  let testCase ← read
  testCase.native.startSpan testCase.context 1
  let collection ← testCase.native.newCollection testCase.context
    minSize.toUInt64 maxSize.toUInt64
  let result ← collectNative testCase collection element []
  testCase.native.stopSpan testCase.context false
  return result⟩

/-- Engine-managed unique lists, the representation-neutral foundation for sets. -/
def Generator.uniqueList [BEq α] (element : Generator NativeGen α)
    (minSize := 0) (maxSize := 10) : Generator NativeGen (List α) := ⟨do
  if minSize > maxSize then
    throw <| IO.userError s!"invalid unique-list bounds [{minSize}, {maxSize}]"
  let testCase ← read
  testCase.native.startSpan testCase.context 3
  let collection ← testCase.native.newCollection testCase.context
    minSize.toUInt64 maxSize.toUInt64
  let result ← collectUnique testCase collection element []
  testCase.native.stopSpan testCase.context false
  return result⟩

structure FloatOptions where
  allowNaN : Bool := false
  allowInfinity : Bool := false
  excludeMin : Bool := false
  excludeMax : Bool := false
  smallestNonzeroMagnitude : Float := 5e-324
  deriving Repr

/-- Native IEEE-754 double generation with Hegel's float-aware shrinker. -/
def Generator.floats (min max : Float) (options : FloatOptions := {}) : Generator NativeGen Float := ⟨do
  let testCase ← read
  testCase.native.generateFloat testCase.context min max options.allowNaN
    options.allowInfinity options.excludeMin options.excludeMax options.smallestNonzeroMagnitude⟩

/-- Native byte-array generation. The engine owns its temporary buffer; the FFI
copies it into a Lean `ByteArray` and releases the engine allocation immediately. -/
def Generator.bytes (minSize := 0) (maxSize := 64) : Generator NativeGen ByteArray := ⟨do
  if minSize > maxSize then
    throw <| IO.userError s!"invalid byte-array bounds [{minSize}, {maxSize}]"
  let testCase ← read
  testCase.native.generateBytes testCase.context minSize.toUInt64 maxSize.toUInt64⟩

/-- Native Unicode text generation, measured in Unicode scalar values. -/
def Generator.text (minSize := 0) (maxSize := 64) (asciiOnly := false) : Generator NativeGen String := ⟨do
  if minSize > maxSize then
    throw <| IO.userError s!"invalid text bounds [{minSize}, {maxSize}]"
  let testCase ← read
  testCase.native.generateText testCase.context minSize.toUInt64 maxSize.toUInt64 asciiOnly⟩

/-- RFC 5321/5322 email addresses from libhegel's native generator. -/
def Generator.emails : Generator NativeGen String := ⟨do
  let testCase ← read
  testCase.native.generateFormattedString testCase.context 0 "" 0 false⟩

/-- RFC 3986 HTTP/HTTPS URLs from libhegel's native generator. -/
def Generator.urls : Generator NativeGen String := ⟨do
  let testCase ← read
  testCase.native.generateFormattedString testCase.context 1 "" 0 false⟩

/-- RFC 1035 fully-qualified domain names. -/
def Generator.domains (maxLength := 255) : Generator NativeGen String := ⟨do
  let testCase ← read
  testCase.native.generateFormattedString testCase.context 2 "" maxLength.toUInt64 false⟩

/-- Strings generated from a Python-compatible regular expression. -/
def Generator.fromRegex (pattern : String) (fullMatch := true) : Generator NativeGen String := ⟨do
  let testCase ← read
  testCase.native.generateFormattedString testCase.context 3 pattern 0 fullMatch⟩

/-- Proleptic Gregorian dates, shrunk toward 2000-01-01. -/
private def readUInt32LE (bytes : ByteArray) (offset : Nat) : UInt32 :=
  bytes[offset]!.toUInt32 |||
    (bytes[offset + 1]!.toUInt32 <<< 8) |||
    (bytes[offset + 2]!.toUInt32 <<< 16) |||
    (bytes[offset + 3]!.toUInt32 <<< 24)

private def decodeDate (bytes : ByteArray) (offset := 0) : Date := {
  year := Int32.ofInt (readUInt32LE bytes offset).toNat
  month := bytes[offset + 4]!
  day := bytes[offset + 5]!
}

private def decodeTime (bytes : ByteArray) (offset := 0) : Time := {
  hour := bytes[offset]!
  minute := bytes[offset + 1]!
  second := bytes[offset + 2]!
  microsecond := readUInt32LE bytes (offset + 3)
}

def Generator.dates (min : Date := { year := 1, month := 1, day := 1 })
    (max : Date := { year := 9999, month := 12, day := 31 }) : Generator NativeGen Date := ⟨do
  let testCase ← read
  let value ← testCase.native.generateDate testCase.context
    min.year min.month min.day max.year max.month max.day
  return decodeDate value⟩

/-- Times of day at microsecond resolution. -/
def Generator.times (min : Time := { hour := 0, minute := 0, second := 0 })
    (max : Time := { hour := 23, minute := 59, second := 59, microsecond := 999999 }) : Generator NativeGen Time := ⟨do
  let testCase ← read
  let value ← testCase.native.generateTime testCase.context
    min.hour min.minute min.second min.microsecond max.hour max.minute max.second max.microsecond
  return decodeTime value⟩

/-- Atomic bounded datetime generation. -/
def Generator.dateTimes (min : DateTime) (max : DateTime) : Generator NativeGen DateTime := ⟨do
  let testCase ← read
  let value ← testCase.native.generateDateTime testCase.context
    min.date.year min.date.month min.date.day min.time.hour min.time.minute min.time.second
    min.time.microsecond max.date.year max.date.month max.date.day max.time.hour max.time.minute
    max.time.second max.time.microsecond
  return { date := decodeDate value, time := decodeTime value 6 }⟩

/-- UUID bytes in network order; an optional version forces the RFC 4122 version/variant bits. -/
def Generator.uuids (version : Option UInt8 := none) : Generator NativeGen ByteArray := ⟨do
  let testCase ← read
  match version with
  | some version => testCase.native.generateUUID testCase.context version true
  | none => testCase.native.generateUUID testCase.context 0 false⟩

/-- Arbitrary-precision signed integers using libhegel's big-integer draw. -/
def Generator.bigIntegers (min max : Int) : Generator NativeGen Int := ⟨do
  if min > max then throw <| IO.userError s!"invalid integer bounds [{min}, {max}]"
  let testCase ← read
  let encoded ← testCase.native.generateIntegerBig testCase.context
    (TwosComplement.encode min) (TwosComplement.encode max)
  match TwosComplement.decode encoded with
  | some value => return value
  | none => throw <| IO.userError "libhegel returned an empty arbitrary-integer encoding"⟩

def Generator.ipv4 : Generator NativeGen ByteArray := ⟨do
  let testCase ← read
  testCase.native.generateIPv4 testCase.context⟩

def Generator.ipv6 : Generator NativeGen ByteArray := ⟨do
  let testCase ← read
  testCase.native.generateIPv6 testCase.context⟩

private partial def filterNative (testCase : TestCase) (generator : Generator NativeGen α)
    (predicate : α → Bool) : IO α := do
  testCase.native.startSpan testCase.context 12
  let value ← generator.generate testCase
  if predicate value then
    testCase.native.stopSpan testCase.context false
    pure value
  else
    testCase.native.stopSpan testCase.context true
    filterNative testCase generator predicate

/-- Retry within a discarded native span until `predicate` holds. -/
def Generator.filter (predicate : α → Bool)
    (generator : Generator NativeGen α) : Generator NativeGen α := ⟨do
  let testCase ← read
  filterNative testCase generator predicate⟩

inductive RunStatus where | passed | failed | error
  deriving Repr, BEq

structure FailureInfo where
  origin : String
  reproductionBlob : Option String
  deriving Repr, BEq

structure RunSummary where
  status : RunStatus
  failureCount : Nat
  failures : Array FailureInfo := #[]
  error : Option String := none
  output : String := ""
  reproductions : Array String := #[]
  deriving Repr, BEq

private partial def runLoop (context : FFI.Context) (run : FFI.Run)
    (origin : String) (property : TestCase → IO Bool) : IO Unit := do
  match ← run.nextTestCase context with
  | none => pure ()
  | some native =>
    let notes ← IO.mkRef #[]
    let testCase : TestCase := { context, native, notes }
    try
      let holds ← property testCase
      if holds then native.markComplete context 0 ""
      else native.markComplete context 3 origin
    catch error =>
      let message := toString error
      if message.contains "HEGEL_RESULT:-1:" then
        native.markComplete context 2 ""
      else if message.contains "HEGEL_RESULT:-2:" || message.contains "libhegel rejected the current test case" then
        native.markComplete context 1 ""
      else
        native.markComplete context 3 origin
    runLoop context run origin property

private def reproduceNotes (library : FFI.Library) (settings : Settings)
    (blob : String) (property : TestCase → IO Bool) : IO String := do
  let context ← library.newContext
  let nativeSettings ← configure context settings
  let native ← FFI.TestCase.fromBlob context nativeSettings blob
  let notes ← IO.mkRef #[]
  let testCase : TestCase := { context, native, notes }
  try
    let holds ← property testCase
    native.markComplete context (if holds then 0 else 3) (if holds then "" else "Lean final replay")
  catch error =>
    notes.modify (fun messages => messages.push s!"exception: {toString error}")
    native.markComplete context 3 "Lean final replay"
  pure <| String.intercalate "\n" (← notes.get).toList

/-- Run a property against the native Hypothesis-derived Hegel engine.

The property returns `true` when valid and `false` when it has found the bug
identified by `origin`. Keeping the origin stable is essential for shrinking. -/
def check (library : FFI.Library) (settings : Settings := {})
    (origin : String := "Lean property") (property : TestCase → IO Bool) : IO RunSummary := do
  let context ← library.newContext
  let nativeSettings ← configure context settings
  let run ← FFI.Run.start context nativeSettings
  runLoop context run origin property
  let result ← run.result context
  let statusCode ← result.status context
  let failureCount ← result.failureCount context
  let status := if statusCode = 0 then .passed else if statusCode = 1 then .failed else .error
  let mut failures := #[]
  for index in [0:failureCount.toNat] do
    let failure ← result.failure context index.toUSize
    let failureOrigin ← failure.origin context
    let blob ← failure.reproductionBlob context
    failures := failures.push {
      origin := failureOrigin
      reproductionBlob := if blob.isEmpty then none else some blob
    }
  let errorMessage ← result.error context
  let output ← run.output
  let mut reproductions := #[]
  for failure in failures do
    match failure.reproductionBlob with
    | some blob => reproductions := reproductions.push (← reproduceNotes library settings blob property)
    | none => reproductions := reproductions.push ""
  pure {
    status
    failureCount := failureCount.toNat
    failures
    error := if errorMessage.isEmpty then none else some errorMessage
    output
    reproductions
  }

inductive ReplayResult where
  | reproduced
  | didNotReproduce
  | incompatible (message : String)
  deriving Repr, BEq

/-- Replay a minimal counterexample encoded by a previous `check` result. -/
def replay (library : FFI.Library) (blob : String) (settings : Settings := {})
    (property : TestCase → IO Bool) : IO ReplayResult := do
  let context ← library.newContext
  let nativeSettings ← configure context settings
  let native ← FFI.TestCase.fromBlob context nativeSettings blob
  let notes ← IO.mkRef #[]
  let testCase : TestCase := { context, native, notes }
  try
    let holds ← property testCase
    if holds then
      native.markComplete context 0 ""
      pure .didNotReproduce
    else
      native.markComplete context 3 "Lean replay"
      pure .reproduced
  catch error =>
    let message := toString error
    if message.contains "HEGEL_RESULT:-1:" then
      native.markComplete context 2 ""
      pure (.incompatible message)
    else if message.contains "HEGEL_RESULT:-2:" || message.contains "libhegel rejected the current test case" then
      native.markComplete context 1 ""
      pure .didNotReproduce
    else
      native.markComplete context 3 "Lean replay"
      pure .reproduced

end Hegel
