import unittest
import strutils
import gene/types except Exception
import gene/compiler
import gene/vm
from gene/parser import read

import ../helpers

proc manual_cu(instructions: seq[Instruction]): CompilationUnit =
  let cu = compile(@[read("nil")])
  cu.instructions = instructions
  cu.instruction_traces = newSeq[SourceTrace](instructions.len)
  cu

proc new_manual_vm(cu: CompilationUnit): ptr VirtualMachine =
  let vm = new_vm_ptr()
  vm.frame = new_frame()
  vm.frame.stack_index = 0
  vm.frame.scope = new_scope(new_scope_tracker())
  vm.frame.ns = App.app.gene_ns.ref.ns
  vm.cu = cu
  vm.pc = 0
  vm

proc wrap_interface(gene_interface: GeneInterface): Value =
  let r = new_ref(VkInterface)
  r.gene_interface = gene_interface
  r.to_ref_value()

suite "adapter runtime":
  test_vm """
    (do
      (interface B (method b []))
      (interface A (method a []))
      (class C
        (ctor [] nil)
        (method a [] "A")
        (method b [] "B")
      )
      (implement A for C)
      (implement B for C)
      ((B (A (new C))) .b)
    )
  """, "B"

  test_vm """
    (do
      (interface Ageable
        (method age [] -> Int)
      )
      (implement Ageable for Int
        (ctor [birth_year]
          (/_geneinternal/birth_year = birth_year)
        )
        (method age []
          (/_genevalue - /_geneinternal/birth_year)
        )
      )
      ((Ageable 2026 1990) .age)
    )
  """, 36

  test_vm """
    (do
      (interface Sized (method length []))
      (implement Sized for String)
      ((Sized "abc") .length)
    )
  """, 3

  test_vm """
    (do
      (interface Sum3 (method sum3 [a b c]))
      (class C
        (ctor [] nil)
        (method sum3 [a b c] ((a + b) + c))
      )
      (implement Sum3 for C)
      ((Sum3 (new C)) .sum3 1 2 3)
    )
  """, 6

  test_vm """
    (do
      (interface Sum3 (method sum3 [a b c]))
      (class C
        (ctor [] nil)
        (method sum3 [a b c] ((a + b) + c))
      )
      (implement Sum3 for C)
      (var method_name "sum3")
      ((Sum3 (new C)) . method_name 1 2 3)
    )
  """, 6

  test_vm """
    (do
      (interface Readable (method read []))
      (class C
        (ctor [] (/x = 1))
      )
      (implement Readable for C
        (method read [] /_genevalue/x)
      )
      (var r (Readable (new C)))
      (var m r/read)
      (m)
    )
  """, 1

  test_vm """
    (do
      (interface Marker)
      ((Marker .class) .name)
    )
  """, "Interface"

  test_vm """
    (do
      (interface Sized (method length []))
      (implement Sized for String)
      (((Sized "abc") .class) .name)
    )
  """, "Adapter"

  test_vm_error """
    (do
      (interface View)
      (class C (ctor [] nil))
      (implement View for C)
      (var v (View (new C)))
      (v/secret = 1)
    )
  """

  test "IkAdapter remains executable for legacy GIR":
    init_all()

    let gene_interface = new_interface("LegacySized", "tests/adapter")
    gene_interface.add_method("length")
    let interface_val = wrap_interface(gene_interface)

    let impl = new_implementation(gene_interface, App.app.string_class.ref.class)
    App.app.string_class.ref.class.register_implementation(gene_interface, impl)

    let cu = manual_cu(@[
      Instruction(kind: IkStart),
      Instruction(kind: IkPushValue, arg0: interface_val),
      Instruction(kind: IkPushValue, arg0: "abc".to_value()),
      Instruction(kind: IkAdapter),
      Instruction(kind: IkEnd),
    ])
    let vm = new_manual_vm(cu)
    let result = vm.exec()
    free_vm_ptr(vm)

    check result.kind == VkAdapter
    check result.ref.adapter.gene_interface == gene_interface
    check result.ref.adapter.inner == "abc".to_value()

  test "IkUnifiedCallDynamic supports interface targets":
    init_all()

    let gene_interface = new_interface("DynamicSized", "tests/adapter")
    gene_interface.add_method("length")
    let interface_val = wrap_interface(gene_interface)

    let impl = new_implementation(gene_interface, App.app.string_class.ref.class)
    App.app.string_class.ref.class.register_implementation(gene_interface, impl)

    let cu = manual_cu(@[
      Instruction(kind: IkStart),
      Instruction(kind: IkPushValue, arg0: interface_val),
      Instruction(kind: IkCallArgsStart),
      Instruction(kind: IkPushValue, arg0: "abc".to_value()),
      Instruction(kind: IkUnifiedCallDynamic),
      Instruction(kind: IkEnd),
    ])
    let vm = new_manual_vm(cu)
    let result = vm.exec()
    free_vm_ptr(vm)

    check result.kind == VkAdapter
    check result.ref.adapter.gene_interface == gene_interface
    check result.ref.adapter.inner == "abc".to_value()

  test "Computed adapter props reject writes instead of shadowing":
    init_all()

    let gene_interface = new_interface("ClockView", "tests/adapter")
    gene_interface.add_prop("now")

    let impl = new_implementation(gene_interface, App.app.int_class.ref.class)
    impl.map_prop_computed("now", NIL)

    let adapter = new_adapter(gene_interface, 1.to_value(), impl)
    let r = new_ref(VkAdapter)
    r.adapter = adapter
    let adapter_val = r.to_ref_value()
    let binding_name = "__adapter_clock_view__"

    App.app.gene_ns.ns[binding_name.to_key()] = adapter_val
    App.app.global_ns.ns[binding_name.to_key()] = adapter_val

    try:
      discard VM.exec("(" & binding_name & "/now = 5)", "test_code")
      fail()
    except CatchableError as ex:
      check ex.msg.contains("Computed property")
