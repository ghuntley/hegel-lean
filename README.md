# Hegel for Lean

A Lean 4 frontend for [Hegel](https://hegel.dev), the cross-language
property-based testing engine derived from Hypothesis. The frontend intentionally
keeps the native `libhegel` FFI boundary used by the Rust, OCaml, TypeScript, and
Java implementations; it does not replace shrinking with a Lean-only algorithm.

## Build and test

```sh
lake build
lake exe hegelTests
```

## Quickstart

```lean
import Hegel

open Hegel

def main : IO Unit := do
  let engine ← FFI.Library.load "path/to/libhegel_c.so"
  let result ← check engine { testCases := 100, database := .disabled }
      "reverse twice" fun testCase => do
    let values ← testCase.drawNamed "values"
      (Generator.nativeList (Generator.naturals 0 100))
    pure (values.reverse.reverse = values)
  IO.println (reprStr result)
```

The native loader expects a released or locally built `libhegel` shared library.
Build one from the reference checkout with:

```sh
cargo build --release --manifest-path upstream/hegel-rust/hegel-c/Cargo.toml
lake exe nativeIntegrationTests upstream/hegel-rust/target/release/libhegel_c.so
```

Then load `upstream/hegel-rust/target/release/libhegel_c.so` on Linux or the
corresponding `.dylib` on macOS using `Hegel.FFI.Library.load`. The current
native loader uses POSIX `dlopen`; Windows loading is not yet supported.

The included devenv enables the Rust toolchain needed by that command.

## Capabilities

The package currently provides owned library, context, settings, run,
test-case, result, and failure handles; native bounded and arbitrary-precision
integers, booleans, IEEE-754 floats, bytes, text, regex, email, URL, domains,
dates, times, datetimes, UUIDs, and IP addresses; engine-managed lists and unique
collections with shrink spans; assumptions and targeting; detailed failures and
deterministic blob replay; database/phase/backend/health-check settings;
filtering and core combinators; engine-backed pools and rule-based stateful
testing; worker-thread output capture; numeric native control classification;
and cloneable test-case handles. Use `TestCase.drawNamed` and `TestCase.note` to
include Lean values and context in minimal-failure reproductions.

The FFI covers all 62 fallible functions in the libhegel 0.29.0 C header plus
the context constructor and diagnostic accessor.

The upstream implementations used as compatibility references are checked out
under `upstream/`: `hegel-rust`, `hegel-ocaml`, `hegel-typescript`, and
`hegel-java`.
