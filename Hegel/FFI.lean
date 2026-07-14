namespace Hegel.FFI

structure RawDate where
  year : Int32
  month : UInt8
  day : UInt8

structure RawTime where
  hour : UInt8
  minute : UInt8
  second : UInt8
  microsecond : UInt32

structure RawDateTime where
  date : RawDate
  time : RawTime

/-- Dynamically loaded Hypothesis/Hegel engine. The object closes the library on finalization. -/
opaque Library : Type

@[extern "lean_hegel_load"]
opaque Library.load (path : @& String) : IO Library

@[extern "lean_hegel_version"]
opaque Library.version (library : @& Library) : IO String

/-- Error context owned by Lean and freed by its external-object finalizer. -/
opaque Context : Type

@[extern "lean_hegel_context_new"]
opaque Library.newContext (library : @& Library) : IO Context

@[extern "lean_hegel_context_last_error"]
opaque Context.lastError (context : @& Context) : IO String

opaque NativeSettings : Type
opaque Run : Type
opaque TestCase : Type
opaque RunResult : Type
opaque Failure : Type

@[extern "lean_hegel_settings_new"]
opaque Context.newSettings (context : @& Context) : IO NativeSettings

@[extern "lean_hegel_settings_set_mode"]
opaque NativeSettings.setMode (context : @& Context) (settings : @& NativeSettings)
    (mode : UInt32) : IO Unit

@[extern "lean_hegel_settings_set_test_cases"]
opaque NativeSettings.setTestCases (context : @& Context) (settings : @& NativeSettings)
    (count : UInt64) : IO Unit

@[extern "lean_hegel_settings_set_verbosity"]
opaque NativeSettings.setVerbosity (context : @& Context) (settings : @& NativeSettings)
    (verbosity : UInt32) : IO Unit

@[extern "lean_hegel_settings_set_backend"]
opaque NativeSettings.setBackend (context : @& Context) (settings : @& NativeSettings)
    (backend : UInt32) : IO Unit

@[extern "lean_hegel_settings_set_phases"]
opaque NativeSettings.setPhases (context : @& Context) (settings : @& NativeSettings)
    (phases : UInt32) : IO Unit

@[extern "lean_hegel_settings_set_suppress_health_checks"]
opaque NativeSettings.setSuppressHealthChecks (context : @& Context)
    (settings : @& NativeSettings) (checks : UInt32) : IO Unit

@[extern "lean_hegel_settings_set_database"]
opaque NativeSettings.setDatabase (context : @& Context) (settings : @& NativeSettings)
    (database : @& String) : IO Unit

@[extern "lean_hegel_settings_set_database_key"]
opaque NativeSettings.setDatabaseKey (context : @& Context) (settings : @& NativeSettings)
    (key : @& String) : IO Unit

@[extern "lean_hegel_settings_set_seed"]
opaque NativeSettings.setSeed (context : @& Context) (settings : @& NativeSettings)
    (seed : UInt64) (hasSeed : Bool) : IO Unit

@[extern "lean_hegel_settings_set_derandomize"]
opaque NativeSettings.setDerandomize (context : @& Context) (settings : @& NativeSettings)
    (enabled : Bool) : IO Unit

@[extern "lean_hegel_settings_set_report_multiple_failures"]
opaque NativeSettings.setReportMultipleFailures (context : @& Context)
    (settings : @& NativeSettings) (enabled : Bool) : IO Unit

@[extern "lean_hegel_run_start"]
opaque Run.start (context : @& Context) (settings : @& NativeSettings) : IO Run

@[extern "lean_hegel_run_output"]
opaque Run.output (run : @& Run) : IO String

@[extern "lean_hegel_next_test_case"]
opaque Run.nextTestCase (context : @& Context) (run : @& Run) : IO (Option TestCase)

@[extern "lean_hegel_test_case_clone"]
opaque TestCase.clone (context : @& Context) (testCase : @& TestCase) : IO TestCase

@[extern "lean_hegel_generate_integer"]
opaque TestCase.generateInteger (context : @& Context) (testCase : @& TestCase)
    (min max : Int64) : IO Int64

@[extern "lean_hegel_generate_integer_big"]
opaque TestCase.generateIntegerBig (context : @& Context) (testCase : @& TestCase)
    (min max : @& ByteArray) : IO ByteArray

@[extern "lean_hegel_generate_boolean"]
opaque TestCase.generateBoolean (context : @& Context) (testCase : @& TestCase)
    (probability : Float) : IO Bool

@[extern "lean_hegel_generate_float"]
opaque TestCase.generateFloat (context : @& Context) (testCase : @& TestCase)
    (min max : Float) (allowNaN allowInfinity excludeMin excludeMax : Bool)
    (smallestNonzeroMagnitude : Float) : IO Float

@[extern "lean_hegel_generate_bytes"]
opaque TestCase.generateBytes (context : @& Context) (testCase : @& TestCase)
    (minSize maxSize : UInt64) : IO ByteArray

@[extern "lean_hegel_generate_text"]
opaque TestCase.generateText (context : @& Context) (testCase : @& TestCase)
    (minSize maxSize : UInt64) (asciiOnly : Bool) : IO String

@[extern "lean_hegel_generate_formatted_string"]
opaque TestCase.generateFormattedString (context : @& Context) (testCase : @& TestCase)
    (kind : UInt32) (parameter : @& String) (number : UInt64) (flag : Bool) : IO String

@[extern "lean_hegel_generate_date"]
opaque TestCase.generateDate (context : @& Context) (testCase : @& TestCase)
    (minYear : Int32) (minMonth minDay : UInt8)
    (maxYear : Int32) (maxMonth maxDay : UInt8) : IO ByteArray

@[extern "lean_hegel_generate_time"]
opaque TestCase.generateTime (context : @& Context) (testCase : @& TestCase)
    (minHour minMinute minSecond : UInt8) (minMicrosecond : UInt32)
    (maxHour maxMinute maxSecond : UInt8) (maxMicrosecond : UInt32) : IO ByteArray

@[extern "lean_hegel_generate_datetime"]
opaque TestCase.generateDateTime (context : @& Context) (testCase : @& TestCase)
    (minYear : Int32) (minMonth minDay minHour minMinute minSecond : UInt8)
    (minMicrosecond : UInt32) (maxYear : Int32)
    (maxMonth maxDay maxHour maxMinute maxSecond : UInt8) (maxMicrosecond : UInt32) : IO ByteArray

@[extern "lean_hegel_generate_uuid"]
opaque TestCase.generateUUID (context : @& Context) (testCase : @& TestCase)
    (version : UInt8) (hasVersion : Bool) : IO ByteArray

@[extern "lean_hegel_generate_ipv4"]
opaque TestCase.generateIPv4 (context : @& Context) (testCase : @& TestCase) : IO ByteArray

@[extern "lean_hegel_generate_ipv6"]
opaque TestCase.generateIPv6 (context : @& Context) (testCase : @& TestCase) : IO ByteArray

@[extern "lean_hegel_start_span"]
opaque TestCase.startSpan (context : @& Context) (testCase : @& TestCase)
    (label : UInt64) : IO Unit

@[extern "lean_hegel_stop_span"]
opaque TestCase.stopSpan (context : @& Context) (testCase : @& TestCase)
    (discard : Bool) : IO Unit

@[extern "lean_hegel_new_collection"]
opaque TestCase.newCollection (context : @& Context) (testCase : @& TestCase)
    (min max : UInt64) : IO Int64

@[extern "lean_hegel_collection_more"]
opaque TestCase.collectionMore (context : @& Context) (testCase : @& TestCase)
    (id : Int64) : IO Bool

@[extern "lean_hegel_collection_reject"]
opaque TestCase.collectionReject (context : @& Context) (testCase : @& TestCase)
    (id : Int64) (reason : @& String) : IO Unit

@[extern "lean_hegel_target"]
opaque TestCase.target (context : @& Context) (testCase : @& TestCase)
    (value : Float) (label : @& String) : IO Unit

@[extern "lean_hegel_new_pool"]
opaque TestCase.newPool (context : @& Context) (testCase : @& TestCase) : IO Int64

@[extern "lean_hegel_pool_add"]
opaque TestCase.poolAdd (context : @& Context) (testCase : @& TestCase)
    (pool : Int64) : IO Int64

@[extern "lean_hegel_pool_generate"]
opaque TestCase.poolGenerate (context : @& Context) (testCase : @& TestCase)
    (pool : Int64) (consume : Bool) : IO Int64

@[extern "lean_hegel_new_state_machine"]
opaque TestCase.newStateMachine (context : @& Context) (testCase : @& TestCase)
    (rules invariants : @& Array String) : IO Int64

@[extern "lean_hegel_state_machine_next_rule"]
opaque TestCase.stateMachineNextRule (context : @& Context) (testCase : @& TestCase)
    (machine : Int64) : IO Int64

@[extern "lean_hegel_mark_complete"]
opaque TestCase.markComplete (context : @& Context) (testCase : @& TestCase)
    (status : UInt32) (origin : @& String) : IO Unit

@[extern "lean_hegel_run_result"]
opaque Run.result (context : @& Context) (run : @& Run) : IO RunResult

@[extern "lean_hegel_run_result_status"]
opaque RunResult.status (context : @& Context) (result : @& RunResult) : IO UInt32

@[extern "lean_hegel_run_result_failure_count"]
opaque RunResult.failureCount (context : @& Context) (result : @& RunResult) : IO USize

@[extern "lean_hegel_run_result_error"]
opaque RunResult.error (context : @& Context) (result : @& RunResult) : IO String

@[extern "lean_hegel_run_result_failure"]
opaque RunResult.failure (context : @& Context) (result : @& RunResult)
    (index : USize) : IO Failure

@[extern "lean_hegel_failure_origin"]
opaque Failure.origin (context : @& Context) (failure : @& Failure) : IO String

@[extern "lean_hegel_failure_blob"]
opaque Failure.reproductionBlob (context : @& Context) (failure : @& Failure) : IO String

@[extern "lean_hegel_test_case_from_blob"]
opaque TestCase.fromBlob (context : @& Context) (settings : @& NativeSettings)
    (blob : @& String) : IO TestCase

end Hegel.FFI
