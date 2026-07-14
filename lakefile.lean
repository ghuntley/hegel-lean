import Lake
open Lake DSL

package hegel where
  version := v!"0.1.0"
  moreLinkArgs := #[(if System.Platform.isWindows then "" else "-ldl")]

lean_lib Hegel

lean_lib HegelTests where
  srcDir := "Tests"

@[default_target]
lean_exe hegelTests where
  root := `Main
  srcDir := "Tests"

lean_exe nativeIntegrationTests where
  root := `NativeMain
  srcDir := "Tests"

extern_lib hegel_ffi pkg := do
  let source ← inputTextFile <| pkg.dir / "ffi" / "hegel_lean.c"
  let object ← buildO (pkg.buildDir / "ir" / "hegel_lean.o") source
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "hegel_ffi") #[object]
