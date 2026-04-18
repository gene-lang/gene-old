import unittest, os, tables

import ../src/gene/types except Exception
import ../src/gene/vm
import ../src/gene/vm/module
import ./helpers

suite "Bootstrap publication":
  test "bootstrap freeze captures init-time namespace snapshots without blocking runtime namespace state":
    init_all()
    check App != NIL
    check App.kind == VkApplication
    check App.app.bootstrap_frozen
    check App.app.bootstrap_gene_ns_snapshot.kind == VkMap
    check App.app.bootstrap_genex_ns_snapshot.kind == VkMap
    check map_is_frozen(App.app.bootstrap_gene_ns_snapshot)
    check map_is_frozen(App.app.bootstrap_genex_ns_snapshot)

    let program_key = "program".to_key()
    check map_data(App.app.bootstrap_gene_ns_snapshot).hasKey(program_key)
    check map_data(App.app.bootstrap_gene_ns_snapshot)[program_key].str == ""

    set_program_args("bootstrap-publication-test", @["--phase0"])
    check App.app.gene_ns.ref.ns[program_key].str == "bootstrap-publication-test"
    check map_data(App.app.bootstrap_gene_ns_snapshot)[program_key].str == ""

    let module_source = absolutePath("tmp/bootstrap_publication_module.gene")
    createDir(parentDir(module_source))
    writeFile(module_source, "(var exported 1)")
    defer:
      if fileExists(module_source):
        removeFile(module_source)

    let module_ns = load_module(VM, module_source)
    check module_ns != nil
    check module_publication_is_actor_local()

  test "bootstrap freeze stops extending the shared interned-string table":
    init_all()
    check string_intern_table_frozen()

    let before = interned_string_entry_count()
    let probe = "bootstrap-freeze-probe-" & $before
    discard intern_str_value(probe)
    let after = interned_string_entry_count()
    check after == before
