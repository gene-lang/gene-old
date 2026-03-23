import unittest, os, tables, strutils
import std/tempfiles

import gene/types except Exception
import gene/vm
import gene/vm/module
import gene/repl_session
import commands/run as run_command
import commands/eval as eval_command
import commands/package_context

proc reset_module_cache() =
  ModuleCache = initTable[string, Namespace]()
  ModuleLoadState = initTable[string, bool]()
  ModuleLoadStack = @[]

proc write_package(root: string, name: string, index_body: string, main_rel = "src/main.gene", main_body = "") =
  createDir(root)
  createDir(root / "src")
  writeFile(root / "package.gene", "^name \"" & name & "\"\n^version \"0.1.0\"\n")
  writeFile(root / "src" / "index.gene", index_body)
  if main_body.len > 0:
    let main_path = root / main_rel
    createDir(parentDir(main_path))
    writeFile(main_path, main_body)

proc restore_env(name: string, value: string, had_value: bool) =
  if had_value:
    putEnv(name, value)
  else:
    delEnv(name)

suite "CLI package context":
  test "run resolves package by name, exposes $app, and preserves cwd":
    reset_module_cache()
    let original_dir = getCurrentDir()
    let old_pkg_path = getEnv("GENE_PACKAGE_PATH", "")
    let had_pkg_path = existsEnv("GENE_PACKAGE_PATH")
    let store_root = createTempDir("gene_cli_pkg_store_", "")
    let launch_dir = createTempDir("gene_cli_pkg_launch_", "")
    let package_root = store_root / "x" / "geneclaw"

    defer:
      setCurrentDir(original_dir)
      restore_env("GENE_PACKAGE_PATH", old_pkg_path, had_pkg_path)
      if dirExists(store_root):
        removeDir(store_root)
      if dirExists(launch_dir):
        removeDir(launch_dir)

    putEnv("GENE_PACKAGE_PATH", store_root)
    setCurrentDir(launch_dir)
    let launch_cwd = getCurrentDir()
    createDir(store_root / "x")
    write_package(
      package_root,
      "x/geneclaw",
      "(fn version [] 42)\n",
      main_body = "(ifel ((cwd) == \"" & launch_cwd & "\") 1 (throw \"bad cwd\"))\n" &
                  "(var current_pkg $pkg/.name)\n" &
                  "(ifel (current_pkg == \"x/geneclaw\") 1 (throw \"bad pkg\"))\n" &
                  "(var app_pkg $app/.pkg/.name)\n" &
                  "(ifel (app_pkg == \"x/geneclaw\") 1 (throw \"bad app pkg\"))\n"
    )

    let result = run_command.handle("run", @["--pkg", "x/geneclaw", "src/main.gene"])
    if not result.success:
      checkpoint(result.error)
    check result.success

  test "eval uses package path context, exposes $app, and preserves cwd":
    reset_module_cache()
    let original_dir = getCurrentDir()
    let launch_dir = createTempDir("gene_cli_eval_launch_", "")
    let package_root = createTempDir("gene_cli_eval_pkg_", "")

    write_package(package_root, "x/evalpkg", "(fn answer [] 7)\n")

    defer:
      setCurrentDir(original_dir)
      if dirExists(launch_dir):
        removeDir(launch_dir)
      if dirExists(package_root):
        removeDir(package_root)

    setCurrentDir(launch_dir)
    let launch_cwd = getCurrentDir()

    let result = eval_command.handle("eval", @[
      "--pkg", package_root,
      "(import answer from \"index\")",
      "(ifel ((cwd) == \"" & launch_cwd & "\") 1 (throw \"bad cwd\"))",
      "(var current_pkg $pkg/.name)",
      "(ifel (current_pkg == \"x/evalpkg\") 1 (throw \"bad pkg\"))",
      "(var app_pkg $app/.pkg/.name)",
      "(ifel (app_pkg == \"x/evalpkg\") 1 (throw \"bad app pkg\"))",
      "(ifel ((answer) == 7) 1 (throw \"bad import\"))",
    ])
    if not result.success:
      checkpoint(result.error)
    check result.success

  test "eval auto-discovers package context from cwd and exposes $app":
    reset_module_cache()
    let original_dir = getCurrentDir()
    let package_root = createTempDir("gene_cli_eval_auto_pkg_", "")
    let launch_dir = package_root / "sandbox"

    write_package(package_root, "x/autoeval", "(fn answer [] 9)\n")
    createDir(launch_dir)

    defer:
      setCurrentDir(original_dir)
      if dirExists(package_root):
        removeDir(package_root)

    setCurrentDir(launch_dir)
    let launch_cwd = getCurrentDir()

    let result = eval_command.handle("eval", @[
      "(import answer from \"index\")",
      "(ifel ((cwd) == \"" & launch_cwd & "\") 1 (throw \"bad cwd\"))",
      "(var current_pkg $pkg/.name)",
      "(ifel (current_pkg == \"x/autoeval\") 1 (throw \"bad pkg\"))",
      "(var app_pkg $app/.pkg/.name)",
      "(ifel (app_pkg == \"x/autoeval\") 1 (throw \"bad app pkg\"))",
      "(ifel ((answer) == 9) 1 (throw \"bad import\"))",
    ])
    if not result.success:
      checkpoint(result.error)
    check result.success

  test "eval fails on unresolved symbol":
    reset_module_cache()
    let result = eval_command.handle("eval", @["haha"])
    check not result.success
    check result.error.contains("^code \"GENE.SCOPE.UNDEFINED_VAR\"")
    check result.error.contains("^message \"haha is not defined\"")

  test "repl package context resolves imports and exposes $app":
    reset_module_cache()
    let original_dir = getCurrentDir()
    let launch_dir = createTempDir("gene_cli_repl_launch_", "")
    let package_root = createTempDir("gene_cli_repl_pkg_", "")

    write_package(package_root, "x/replpkg", "(fn answer [] 5)\n")

    defer:
      setCurrentDir(original_dir)
      if dirExists(launch_dir):
        removeDir(launch_dir)
      if dirExists(package_root):
        removeDir(package_root)

    setCurrentDir(launch_dir)
    let launch_cwd = getCurrentDir()

    init_app_and_vm()
    init_stdlib()
    set_program_args("<repl>", @[])

    let pkg_ctx = resolve_cli_package_context(package_root, getCurrentDir(), "<repl>")
    let module_name = virtual_module_name(pkg_ctx, "repl", "<repl>")
    let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
    configure_main_namespace(ns, module_name, pkg_ctx)
    let scope_tracker = new_scope_tracker()
    let scope = new_scope(scope_tracker)

    let result = run_repl_script(VM, @[
      "(import answer from \"index\")",
      "(ifel ((cwd) == \"" & launch_cwd & "\") 1 (throw \"bad cwd\"))",
      "(var current_pkg $pkg/.name)",
      "(ifel (current_pkg == \"x/replpkg\") 1 (throw \"bad pkg\"))",
      "(var app_pkg $app/.pkg/.name)",
      "(ifel (app_pkg == \"x/replpkg\") 1 (throw \"bad app pkg\"))",
      "(ifel ((answer) == 5) 1 (throw \"bad import\"))",
    ], scope_tracker, scope, ns, module_name)

    check result == 1.to_value()
