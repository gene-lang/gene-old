{.push warning[ResultShadowed]: off.}
import tables, strutils, uri
import ../gene/types

# Helper to create native function value
proc wrap_native_fn(fn: NativeFn): Value =
  let r = new_ref(VkNativeFn)
  r.native_fn = fn
  return r.to_ref_value()

# Helper to convert props to HTML attributes
proc props_to_attrs(props: Table[Key, Value]): string =
  var attrs: seq[string] = @[]
  for k, v in props:
    let key_val = cast[Value](k)
    let key_str = if key_val.kind == VkSymbol:
      key_val.str
    else:
      continue

    # Skip special keys that start with _
    if key_str.startsWith("_"):
      continue

    let val_str = case v.kind:
      of VkString: v.str
      of VkInt: $v.to_int
      of VkBool: $v.to_bool
      of VkMap:
        # Handle style maps like {^font-size "12px"}
        var style_parts: seq[string] = @[]
        for sk, sv in map_data(v):
          let style_key = cast[Value](sk)
          if style_key.kind == VkSymbol:
            let style_val = if sv.kind == VkString: sv.str else: $sv
            style_parts.add(style_key.str & ": " & style_val)
        style_parts.join("; ")
      else: $v

    attrs.add(key_str & "=\"" & val_str.replace("\"", "&quot;") & "\"")

  if attrs.len > 0:
    return " " & attrs.join(" ")
  else:
    return ""

# Generic HTML tag function
proc html_tag(tag_name: string, vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  var attrs = ""
  var content = ""
  let pos_count = get_positional_count(arg_count, has_keyword_args)
  # Keyword args are passed as a map at args[0] when present
  if has_keyword_args and arg_count > 0 and args[0].kind == VkMap:
    attrs = props_to_attrs(map_data(args[0]))

  # All positional args are content
  for i in 0..<pos_count:
    let arg = get_positional_arg(args, i, has_keyword_args)
    if arg.kind == VkString:
      content &= arg.str
    else:
      content &= $arg

  let html = "<" & tag_name & attrs & ">" & content & "</" & tag_name & ">"
  return new_str_value(html)

# Self-closing tag helper
proc html_self_closing_tag(tag_name: string, vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  var attrs = ""

  # Check for keyword args (props)
  if has_keyword_args and arg_count > 0 and args[0].kind == VkMap:
    attrs = props_to_attrs(map_data(args[0]))

  let html = "<" & tag_name & attrs & " />"
  return new_str_value(html)

type LinkInfo = object
  text: string
  url: string

proc decode_html_entities(input: string): string =
  result = input
  result = result.replace("&nbsp;", " ")
  result = result.replace("&amp;", "&")
  result = result.replace("&lt;", "<")
  result = result.replace("&gt;", ">")
  result = result.replace("&quot;", "\"")
  result = result.replace("&apos;", "'")

proc normalize_whitespace(input: string): string =
  var buf = newStringOfCap(input.len)
  var in_space = false
  for ch in input:
    if ch in {' ', '\t', '\r', '\n', '\c', '\L'}:
      if not in_space:
        buf.add(' ')
        in_space = true
    else:
      buf.add(ch)
      in_space = false
  buf.strip()

proc get_attr_value(tag: string, name: string): string =
  var i = 0
  let target = name.toLowerAscii()
  while i < tag.len:
    while i < tag.len and tag[i].isSpaceAscii():
      inc i
    let start = i
    while i < tag.len and ((tag[i].isAlphaAscii() or tag[i].isDigit()) or tag[i] in {'-', '_'}):
      inc i
    if i == start:
      inc i
      continue
    let attr = tag[start..<i].toLowerAscii()
    while i < tag.len and tag[i].isSpaceAscii():
      inc i
    var value = ""
    if i < tag.len and tag[i] == '=':
      inc i
      while i < tag.len and tag[i].isSpaceAscii():
        inc i
      if i < tag.len and (tag[i] == '"' or tag[i] == '\''):
        let quote = tag[i]
        inc i
        let val_start = i
        while i < tag.len and tag[i] != quote:
          inc i
        value = tag[val_start..<i]
        if i < tag.len:
          inc i
      else:
        let val_start = i
        while i < tag.len and not tag[i].isSpaceAscii() and tag[i] != '>':
          inc i
        value = tag[val_start..<i]
    if attr == target:
      return value
  ""

proc resolve_href(base_url: string, href: string): string =
  if href.len == 0:
    return href
  let lower = href.toLowerAscii()
  if lower.startsWith("http://") or lower.startsWith("https://"):
    return href
  if lower.startsWith("mailto:") or lower.startsWith("javascript:") or lower.startsWith("tel:") or lower.startsWith("data:"):
    return href
  if lower.startsWith("//"):
    if base_url.len == 0:
      return href
    try:
      let base = parseUri(base_url)
      if base.scheme.len > 0:
        return base.scheme & ":" & href
    except CatchableError:
      discard
    return href
  if base_url.len == 0:
    return href
  try:
    let base = parseUri(base_url)
    if base.scheme.len == 0 or base.hostname.len == 0:
      return href
    let combined = combine(base, parseUri(href))
    return $combined
  except CatchableError:
    return href

proc extract_text_with_links(html: string, text_out: var string, links_out: var seq[LinkInfo], include_refs: bool, base_url: string) =
  let lower_html = html.toLowerAscii()
  var i = 0
  var buf = newStringOfCap(html.len)
  var inside_link = false
  var link_text = ""
  var link_href = ""

  proc append_char(ch: char) =
    buf.add(ch)
    if inside_link:
      link_text.add(ch)

  while i < html.len:
    let ch = html[i]
    if ch == '<':
      var j = i + 1
      var is_close = false
      if j < html.len and html[j] == '/':
        is_close = true
        inc j
      while j < html.len and html[j].isSpaceAscii():
        inc j
      let name_start = j
      while j < html.len and ((html[j].isAlphaAscii() or html[j].isDigit()) or html[j] in {'-', '_'}):
        inc j
      let tag_name = if j > name_start: lower_html[name_start..<j] else: ""
      var in_quote = false
      var quote_char = '\0'
      while j < html.len:
        let tc = html[j]
        if in_quote:
          if tc == quote_char:
            in_quote = false
        else:
          if tc == '"' or tc == '\'':
            in_quote = true
            quote_char = tc
          elif tc == '>':
            break
        inc j
      let tag_end = j
      let tag_content = if tag_end > i + 1: html[i + 1 ..< tag_end] else: ""

      if tag_name in ["script", "style", "noscript"] and not is_close:
        let close_tag = "</" & tag_name
        let close_idx = lower_html.find(close_tag, tag_end)
        if close_idx >= 0:
          let close_end = lower_html.find(">", close_idx)
          if close_end >= 0:
            i = close_end + 1
            continue
        break

      if tag_name == "a":
        if not is_close:
          inside_link = true
          link_text = ""
          link_href = get_attr_value(tag_content, "href")
        else:
          if inside_link:
            let cleaned = normalize_whitespace(link_text).strip()
            if cleaned.len > 0 and link_href.len > 0:
              let idx = links_out.len + 1
              let resolved_href = resolve_href(base_url, link_href)
              links_out.add(LinkInfo(text: cleaned, url: resolved_href))
              if include_refs:
                buf.add(" [" & $idx & "]")
            inside_link = false
            link_text = ""
            link_href = ""
      elif tag_name in ["br", "p", "div", "li", "ul", "ol", "section", "article", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6"]:
        buf.add(" ")

      i = tag_end + 1
      continue

    elif ch == '&':
      append_char(ch)
      inc i
      continue
    else:
      append_char(ch)
      inc i
      continue

  text_out = normalize_whitespace(decode_html_entities(buf))

proc vm_extract_text(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "html.extract_text requires html string")
  let html_val = get_positional_arg(args, 0, has_keyword_args)
  if html_val.kind != VkString:
    raise new_exception(types.Exception, "html.extract_text requires html string")
  var text = ""
  var links: seq[LinkInfo] = @[]
  extract_text_with_links(html_val.str, text, links, false, "")
  text.to_value()

proc vm_extract_text_with_links(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "html.extract_text_with_links requires html string")
  let html_val = get_positional_arg(args, 0, has_keyword_args)
  if html_val.kind != VkString:
    raise new_exception(types.Exception, "html.extract_text_with_links requires html string")
  var text = ""
  var links: seq[LinkInfo] = @[]
  var base_url = ""
  let pos_count = get_positional_count(arg_count, has_keyword_args)
  if pos_count >= 2:
    let base_val = get_positional_arg(args, 1, has_keyword_args)
    case base_val.kind
    of VkString:
      base_url = base_val.str
    of VkNil:
      base_url = ""
    else:
      raise new_exception(types.Exception, "html.extract_text_with_links base_url must be a string")
  extract_text_with_links(html_val.str, text, links, true, base_url)
  let result = new_map_value()
  map_data(result) = initTable[Key, Value]()
  map_data(result)["text".to_key()] = text.to_value()
  let links_arr = new_array_value()
  for i, link in links:
    let link_map = new_map_value()
    map_data(link_map) = initTable[Key, Value]()
    map_data(link_map)["index".to_key()] = (i + 1).to_value()
    map_data(link_map)["text".to_key()] = link.text.to_value()
    map_data(link_map)["url".to_key()] = link.url.to_value()
    array_data(links_arr).add(link_map)
  map_data(result)["links".to_key()] = links_arr
  result

# Define all HTML tag functions
proc tag_HTML(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("html", vm, args, arg_count, has_keyword_args)
proc tag_HEAD(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("head", vm, args, arg_count, has_keyword_args)
proc tag_TITLE(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("title", vm, args, arg_count, has_keyword_args)
proc tag_BODY(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("body", vm, args, arg_count, has_keyword_args)
proc tag_DIV(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("div", vm, args, arg_count, has_keyword_args)
proc tag_SPAN(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("span", vm, args, arg_count, has_keyword_args)
proc tag_P(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("p", vm, args, arg_count, has_keyword_args)
proc tag_H1(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("h1", vm, args, arg_count, has_keyword_args)
proc tag_H2(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("h2", vm, args, arg_count, has_keyword_args)
proc tag_H3(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("h3", vm, args, arg_count, has_keyword_args)
proc tag_UL(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("ul", vm, args, arg_count, has_keyword_args)
proc tag_OL(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("ol", vm, args, arg_count, has_keyword_args)
proc tag_LI(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("li", vm, args, arg_count, has_keyword_args)
proc tag_FORM(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("form", vm, args, arg_count, has_keyword_args)
proc tag_INPUT(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_self_closing_tag("input", vm, args, arg_count, has_keyword_args)
proc tag_BUTTON(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("button", vm, args, arg_count, has_keyword_args)
proc tag_LABEL(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("label", vm, args, arg_count, has_keyword_args)
proc tag_A(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("a", vm, args, arg_count, has_keyword_args)
proc tag_IMG(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_self_closing_tag("img", vm, args, arg_count, has_keyword_args)
proc tag_TABLE(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("table", vm, args, arg_count, has_keyword_args)
proc tag_TR(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("tr", vm, args, arg_count, has_keyword_args)
proc tag_TD(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("td", vm, args, arg_count, has_keyword_args)
proc tag_TH(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("th", vm, args, arg_count, has_keyword_args)
proc tag_HEADER(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("header", vm, args, arg_count, has_keyword_args)
proc tag_FOOTER(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("footer", vm, args, arg_count, has_keyword_args)
proc tag_SCRIPT(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("script", vm, args, arg_count, has_keyword_args)
proc tag_STYLE(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("style", vm, args, arg_count, has_keyword_args)
proc tag_LINK(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_self_closing_tag("link", vm, args, arg_count, has_keyword_args)
proc tag_META(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_self_closing_tag("meta", vm, args, arg_count, has_keyword_args)
proc tag_SVG(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_tag("svg", vm, args, arg_count, has_keyword_args)
proc tag_LINE(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = html_self_closing_tag("line", vm, args, arg_count, has_keyword_args)

# Register functions in namespace
proc init_html_module*() =
  VmCreatedCallbacks.add proc() =
    {.cast(gcsafe).}:
      # Ensure App is initialized
      if App == NIL or App.kind != VkApplication:
        return

      if App.app.genex_ns == NIL:
        return

      var html_ns = new_namespace("html")

      # Create tags namespace for wildcard import
      var tags_ns = new_namespace("tags")

      proc register_tag(name: string, fn: NativeFn) =
        let tag_val = wrap_native_fn(fn)
        tags_ns[name.to_key()] = tag_val
        App.app.global_ns.ref.ns[name.to_key()] = tag_val

      # Register all tag functions in tags namespace
      register_tag("HTML", tag_HTML)
      register_tag("HEAD", tag_HEAD)
      register_tag("TITLE", tag_TITLE)
      register_tag("BODY", tag_BODY)
      register_tag("DIV", tag_DIV)
      register_tag("SPAN", tag_SPAN)
      register_tag("P", tag_P)
      register_tag("H1", tag_H1)
      register_tag("H2", tag_H2)
      register_tag("H3", tag_H3)
      register_tag("UL", tag_UL)
      register_tag("OL", tag_OL)
      register_tag("LI", tag_LI)
      register_tag("FORM", tag_FORM)
      register_tag("INPUT", tag_INPUT)
      register_tag("BUTTON", tag_BUTTON)
      register_tag("LABEL", tag_LABEL)
      register_tag("A", tag_A)
      register_tag("IMG", tag_IMG)
      register_tag("TABLE", tag_TABLE)
      register_tag("TR", tag_TR)
      register_tag("TD", tag_TD)
      register_tag("TH", tag_TH)
      register_tag("HEADER", tag_HEADER)
      register_tag("FOOTER", tag_FOOTER)
      register_tag("SCRIPT", tag_SCRIPT)
      register_tag("STYLE", tag_STYLE)
      register_tag("LINK", tag_LINK)
      register_tag("META", tag_META)
      register_tag("SVG", tag_SVG)
      register_tag("LINE", tag_LINE)

      # Register tags namespace
      html_ns["tags".to_key()] = tags_ns.to_value()

      html_ns["extract_text".to_key()] = wrap_native_fn(vm_extract_text)
      html_ns["extract_text_with_links".to_key()] = wrap_native_fn(vm_extract_text_with_links)

      # Register html namespace under genex
      App.app.genex_ns.ref.ns["html".to_key()] = html_ns.to_value()

# Auto-initialize on import
init_html_module()
