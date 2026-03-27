# Test suite for Interface and Adapter feature
# Run with: nim c -r tests/test_adapter.nim

import unittest
import ../src/gene/types except Exception
import ../src/gene/types/interfaces
import tables

suite "Interface Type Tests":
  test "Create interface":
    let iface = new_interface("TestInterface")
    check iface.name == "TestInterface"
    check iface.methods.len == 0
    check iface.props.len == 0
  
  test "Add method to interface":
    let iface = new_interface("Readable")
    iface.add_method("read")
    check iface.methods.len == 1
    check iface.has_method("read".to_key())
  
  test "Add property to interface":
    let iface = new_interface("Named")
    iface.add_prop("name")
    check iface.props.len == 1
    check iface.has_prop("name".to_key())
  
  test "Add readonly property":
    let iface = new_interface("Constant")
    iface.add_prop("value", readonly = true)
    check iface.props["value".to_key()].readonly == true

suite "Implementation Tests":
  test "Create implementation":
    let iface = new_interface("TestInterface")
    let impl = new_implementation(iface)
    check impl.gene_interface == iface
    check impl.method_mappings.len == 0
    check impl.prop_mappings.len == 0
  
  test "Map method rename":
    let iface = new_interface("Readable")
    let impl = new_implementation(iface)
    impl.map_method_rename("read", "getData")
    check impl.method_mappings.has_key("read".to_key())
    check impl.method_mappings["read".to_key()].kind == AmkRename
    check impl.method_mappings["read".to_key()].inner_name == "getData".to_key()
  
  test "Map method computed":
    let iface = new_interface("Transformable")
    let impl = new_implementation(iface)
    impl.map_method_computed("transform", NIL)  # NIL for test
    check impl.method_mappings.has_key("transform".to_key())
    check impl.method_mappings["transform".to_key()].kind == AmkComputed
  
  test "Map property rename":
    let iface = new_interface("Named")
    let impl = new_implementation(iface)
    impl.map_prop_rename("name", "label")
    check impl.prop_mappings.has_key("name".to_key())
    check impl.prop_mappings["name".to_key()].kind == AmkRename
    check impl.prop_mappings["name".to_key()].inner_name == "label".to_key()
  
  test "Map property hidden":
    let iface = new_interface("Secure")
    let impl = new_implementation(iface)
    impl.map_prop_hidden("password")
    check impl.prop_mappings.has_key("password".to_key())
    check impl.prop_mappings["password".to_key()].kind == AmkHidden

suite "Adapter Tests":
  test "Create adapter":
    let iface = new_interface("TestInterface")
    let impl = new_implementation(iface)
    let inner = "test".to_value()
    let adapter = new_adapter(iface, inner, impl)
    check adapter.gene_interface == iface
    check adapter.inner == inner
    check adapter.implementation == impl
  
  test "Adapter has own data":
    let iface = new_interface("TestInterface")
    let impl = new_implementation(iface)
    let inner = "test".to_value()
    let adapter = new_adapter(iface, inner, impl)
    adapter.own_data["extra".to_key()] = 42.to_value()
    check adapter.own_data.has_key("extra".to_key())

suite "Adapter Registry Tests":
  test "Register implementation":
    let iface = new_interface("Readable")
    let impl = new_implementation(iface)
    register_implementation("FileStream", impl)
    let found = find_implementation("FileStream", "Readable")
    check not found.is_nil
    check found.gene_interface.name == "Readable"
  
  test "Find non-existent implementation":
    let found = find_implementation("NonExistent", "SomeInterface")
    check found.is_nil

suite "Inline Implementation Tests":
  test "Register inline implementation":
    register_inline_implementation("MyClass", "MyInterface")
    check has_inline_implementation("MyClass", "MyInterface")
  
  test "Check non-existent inline implementation":
    check not has_inline_implementation("UnknownClass", "UnknownInterface")

when isMainModule:
  echo "Running adapter tests..."
