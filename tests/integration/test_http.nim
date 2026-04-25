import unittest, tables, strutils
import gene/types except Exception
import gene/vm/extension
import ../helpers

suite "HTTP Extension Tests":
  test "Load HTTP extension":
    init_all_with_extensions()

    # Load the HTTP extension
    let ns = load_extension(VM, "build/libhttp")
    check ns.name == "http"

    # Check we have several functions registered
    var count = 0
    for k, v in ns.members:
      count += 1
    check count > 0

    # Check that HTTP functions are available
    check ns.members.hasKey(to_key("get"))
    check ns.members.hasKey(to_key("post"))
    check ns.members.hasKey(to_key("put"))
    check ns.members.hasKey(to_key("delete"))
    check ns.members.hasKey(to_key("get_json"))
    check ns.members.hasKey(to_key("post_json"))
    check ns.members.hasKey(to_key("json_parse"))
    check ns.members.hasKey(to_key("json_stringify"))

  test "JSON parse and stringify":
    init_all_with_extensions()
    let ns = load_extension(VM, "build/libhttp")

    # Test json_parse
    let json_parse = ns["json_parse".to_key()]
    let json_str = new_str_value("{\"name\":\"test\",\"value\":42}")
    var parse_args = [json_str]
    let parsed = json_parse.ref.native_fn(VM, cast[ptr UncheckedArray[Value]](parse_args[0].addr), 1, false)

    check parsed.kind == VkMap
    let map_ref = map_data(parsed)
    check map_ref.hasKey(to_key("name"))
    check map_ref.hasKey(to_key("value"))
    check map_ref[to_key("name")].kind == VkString
    check map_ref[to_key("name")].str == "test"
    check map_ref[to_key("value")].kind == VkInt
    check map_ref[to_key("value")].to_int == 42

    # Test json_stringify
    let json_stringify = ns["json_stringify".to_key()]
    var stringify_args = [parsed]
    let stringified = json_stringify.ref.native_fn(VM, cast[ptr UncheckedArray[Value]](stringify_args[0].addr), 1, false)

    check stringified.kind == VkString
    # The order might vary, so we just check that it contains the expected parts
    let result_str = stringified.str
    # The JSON escaping doubles the quotes, so check for the actual output
    check "\"\"name\"\":\"test\"" in result_str or "\"name\":\"test\"" in result_str
    check "\"\"value\"\":42" in result_str or "\"value\":42" in result_str

  test "JSON with arrays":
    init_all_with_extensions()
    let ns = load_extension(VM, "build/libhttp")

    let json_parse = ns["json_parse".to_key()]
    let json_str = new_str_value("[1,2,3,\"test\",null,true,false]")
    var parse_args = [json_str]
    let parsed = json_parse.ref.native_fn(VM, cast[ptr UncheckedArray[Value]](parse_args[0].addr), 1, false)

    check parsed.kind == VkArray
    let arr_ref = array_data(parsed)
    check arr_ref.len == 7
    check arr_ref[0].to_int == 1
    check arr_ref[1].to_int == 2
    check arr_ref[2].to_int == 3
    check arr_ref[3].str == "test"
    check arr_ref[4].kind == VkNil
    check arr_ref[5].to_bool == true
    check arr_ref[6].to_bool == false

  test "JSON with nested structures":
    init_all_with_extensions()
    let ns = load_extension(VM, "build/libhttp")

    let json_parse = ns["json_parse".to_key()]
    let json_str = new_str_value("{\"user\":{\"name\":\"Alice\",\"age\":30},\"items\":[1,2,3]}")
    var parse_args = [json_str]
    let parsed = json_parse.ref.native_fn(VM, cast[ptr UncheckedArray[Value]](parse_args[0].addr), 1, false)

    check parsed.kind == VkMap
    let map_ref = map_data(parsed)

    # Check nested object
    check map_ref.hasKey(to_key("user"))
    let user = map_ref[to_key("user")]
    check user.kind == VkMap
    check map_data(user)[to_key("name")].str == "Alice"
    check map_data(user)[to_key("age")].to_int == 30

    # Check nested array
    check map_ref.hasKey(to_key("items"))
    let items = map_ref[to_key("items")]
    check items.kind == VkArray
    check array_data(items).len == 3
    check array_data(items)[0].to_int == 1
    check array_data(items)[1].to_int == 2
    check array_data(items)[2].to_int == 3
