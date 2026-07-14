namespace Hegel

inductive Verbosity where | quiet | normal | verbose | debug
  deriving Repr, BEq

inductive Mode where | testRun | singleTestCase
  deriving Repr, BEq

inductive Backend where | auto | default | urandom
  deriving Repr, BEq

inductive Database where
  | unset
  | disabled
  | path (value : String)
  deriving Repr, BEq

inductive Phase where | explicit | reuse | generate | target | shrink
  deriving Repr, BEq

inductive HealthCheck where
  | filterTooMuch | tooSlow | testCasesTooLarge | largeInitialTestCase
  deriving Repr, BEq

structure Settings where
  mode : Mode := .testRun
  testCases : Nat := 100
  seed : Option UInt64 := none
  derandomize : Bool := false
  verbosity : Verbosity := .normal
  backend : Backend := .auto
  database : Database := .unset
  databaseKey : Option String := none
  phases : Array Phase := #[.explicit, .reuse, .generate, .target, .shrink]
  suppressHealthChecks : Array HealthCheck := #[]
  reportMultipleFailures : Bool := false
  deriving Repr, BEq

end Hegel
