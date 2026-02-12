import tables, strutils, hashes, os, streams

import ../types
import ../compiler
import ../gir
when not defined(noExtensions):
  import ./extension

type
  ImportItem* = object
    name*: string
    alias*: string
    children*: seq[string]  # For nested imports like n/[a b]

# Forward declarations
proc workspace_src_paths(): seq[string]

# Global module cache
var ModuleCache* = initTable[string, Namespace]()
var ModuleLoadState* = initTable[string, bool]()
var ModuleLoadStack* = newSeq[string]()
var LoadedModuleTypeRegistry* = new_global_type_registry()

let ExportKey* = "__exports__".to_key()

proc reset_loaded_module_type_registry*() =
  LoadedModuleTypeRegistry = new_global_type_registry()

proc register_module_type_registry*(module_path: string, cu: CompilationUnit) =
  if cu == nil:
    return

  var registry = cu.type_registry
  if registry == nil and cu.type_descriptors.len > 0:
    registry = populate_registry(cu.type_descriptors, cu.module_path)
    cu.type_registry = registry
  if registry == nil:
    return

  var resolved_path = registry.module_path
  if resolved_path.len == 0:
    if cu.module_path.len > 0:
      resolved_path = cu.module_path
    else:
      resolved_path = module_path
  if resolved_path.len == 0:
    return

  if registry.module_path.len == 0:
    registry.module_path = resolved_path
  let global_module = get_or_create_module(LoadedModuleTypeRegistry, resolved_path)
  for type_id, desc in registry.descriptors:
    register_type_desc(global_module, type_id, desc, resolved_path)

proc ensure_exports_map(ns: Namespace): Value =
  var exports_val = ns.members.getOrDefault(ExportKey, NIL)
  if exports_val == NIL or exports_val.kind != VkMap:
    exports_val = new_map_value()
    ns.members[ExportKey] = exports_val
  exports_val

proc add_export*(ns: Namespace, name: string) =
  if ns == nil or name.len == 0:
    return
  let exports_val = ensure_exports_map(ns)
  map_data(exports_val)[name.to_key()] = TRUE

proc has_exports*(ns: Namespace): bool =
  if ns == nil:
    return false
  let exports_val = ns.members.getOrDefault(ExportKey, NIL)
  exports_val != NIL and exports_val.kind == VkMap

proc is_exported*(ns: Namespace, path: string): bool =
  if ns == nil:
    return false
  let exports_val = ns.members.getOrDefault(ExportKey, NIL)
  if exports_val == NIL or exports_val.kind != VkMap:
    return true
  let exports_map = map_data(exports_val)
  if exports_map.hasKey(path.to_key()):
    return true
  let parts = path.split("/")
  if parts.len > 1:
    var prefix = ""
    for i in 0..<parts.len - 1:
      if i == 0:
        prefix = parts[i]
      else:
        prefix &= "/" & parts[i]
      if exports_map.hasKey(prefix.to_key()):
        return true
  return false

const
  PackageNameAllowedChars = {'a'..'z', '0'..'9', '-', '_', '+', '&'}

proc validate_package_name(name: string) =
  ## Validate package name against `[a-z][a-z0-9-_+&]*[a-z0-9](/[a-z][a-z0-9-_+&]*[a-z0-9])+`
  let parts = name.split("/")
  if parts.len < 2:
    not_allowed("Package name must have at least two segments")

  let top = parts[0]
  if top == "gene" or top == "genex" or top.startsWith("gene"):
    not_allowed("Package name '" & name & "' uses a reserved namespace")
  if top.len == 1 and (top == "x" or top == "y" or top == "z"):
    discard  # Open namespaces; still validate characters below

  for part in parts:
    if part[0] notin {'a'..'z'}:
      not_allowed("Package segments must start with a lowercase letter: " & part)
    if part[^1] notin {'a'..'z', '0'..'9'}:
      not_allowed("Package segments must end with a letter or digit: " & part)
    for ch in part:
      if ch notin PackageNameAllowedChars:
        not_allowed("Invalid character '" & $ch & "' in package name '" & name & "'")

proc find_package_root*(start_path: string): string =
  ## Walk ancestors starting at a file or directory to find `package.gene`.
  var dir = if fileExists(start_path): parentDir(start_path) else: start_path
  if dir.len == 0:
    return ""
  dir = absolutePath(dir)
  while true:
    if fileExists(joinPath(dir, "package.gene")):
      return dir
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  return ""

proc resolve_package_entrypoint(root: string): tuple[path: string, is_gir: bool] =
  ## Choose package entrypoint in priority order.
  let idx = joinPath(root, "index.gene")
  if fileExists(idx):
    return (absolutePath(idx), false)
  let srcIdx = joinPath(root, "src", "index.gene")
  if fileExists(srcIdx):
    return (absolutePath(srcIdx), false)
  let libIdx = joinPath(root, "lib", "index.gene")
  if fileExists(libIdx):
    return (absolutePath(libIdx), false)
  let girIdx = joinPath(root, "build", "index.gir")
  if fileExists(girIdx):
    return (absolutePath(girIdx), true)
  not_allowed("Package entrypoint not found under " & root)

proc try_resolve_path(base: string, module_path: string): tuple[path: string, is_gir: bool] =
  ## Attempt to resolve a module path under a base directory.
  var candidate = joinPath(base, module_path)
  if module_path.endsWith(".gir") or module_path.endsWith(".gene"):
    if fileExists(candidate):
      return (absolutePath(candidate), module_path.endsWith(".gir"))
  else:
    let withGene = candidate & ".gene"
    if fileExists(withGene):
      return (absolutePath(withGene), false)
    if fileExists(candidate):
      return (absolutePath(candidate), candidate.endsWith(".gir"))
  return ("", false)

proc native_ext_suffix(): string =
  when defined(windows):
    return ".dll"
  elif defined(macosx):
    return ".dylib"
  else:
    return ".so"

proc resolve_native_module(module_path: string, importer_dir: string, package_root: string, package_name: string): string =
  ## Resolve a native module path, honoring package roots and common build locations.
  var normalized = module_path
  if package_name.len > 0:
    let pkg_last = package_name.split("/")[^1]
    if normalized.startsWith(package_name & "/"):
      normalized = normalized[package_name.len + 1 .. ^1]
    elif normalized.startsWith(pkg_last & "/"):
      normalized = normalized[pkg_last.len + 1 .. ^1]

  let base_dir = if importer_dir.len > 0: importer_dir else: getCurrentDir()
  let pkg_dir = if package_root.len > 0: package_root else: base_dir
  let workspace_paths = workspace_src_paths()
  let bases = @[base_dir] & workspace_paths & @[
    pkg_dir,
    joinPath(pkg_dir, "src"),
    joinPath(pkg_dir, "lib"),
    joinPath(pkg_dir, "build")
  ]

  for base in bases:
    let candidate = absolutePath(joinPath(base, normalized))
    if fileExists(candidate):
      return candidate
    let native_candidate = candidate & native_ext_suffix()
    if fileExists(native_candidate):
      return native_candidate

  if package_root.len > 0:
    let base = splitFile(normalized).name
    let build_base = joinPath(package_root, "build", base)
    let build_native = build_base & native_ext_suffix()
    if fileExists(build_native):
      return build_native

  return ""

proc resolve_module_path(module_path: string, importer_dir: string, package_root: string, package_name: string): tuple[path: string, is_gir: bool] =
  ## Resolve a module path relative to importer dir and package root fallbacks.
  var normalized = module_path
  if package_name.len > 0:
    let pkg_last = package_name.split("/")[^1]
    if normalized.startsWith(package_name & "/"):
      normalized = normalized[package_name.len + 1 .. ^1]
    elif normalized.startsWith(pkg_last & "/"):
      normalized = normalized[pkg_last.len + 1 .. ^1]

  let base_dir = if importer_dir.len > 0: importer_dir else: getCurrentDir()
  let pkg_dir = if package_root.len > 0: package_root else: base_dir
  let workspace_paths = workspace_src_paths()
  let candidates = @[base_dir] & workspace_paths & @[
    pkg_dir,
    joinPath(pkg_dir, "src"),
    joinPath(pkg_dir, "lib"),
    joinPath(pkg_dir, "build")
  ]
  for base in candidates:
    let (p, isGir) = try_resolve_path(base, normalized)
    if p.len > 0:
      return (p, isGir)
  if package_root.len > 0:
    let base = splitFile(normalized).name
    let build_base = joinPath(package_root, "build", base)
    let build_gir = build_base & ".gir"
    if fileExists(build_gir):
      return (absolutePath(build_gir), true)
    let build_native = build_base & native_ext_suffix()
    if fileExists(build_native):
      return (build_base, false)  # treat as native; caller will mark is_native
  not_allowed("Module '" & module_path & "' not found under package root '" & pkg_dir & "'")

proc package_search_paths(importer_dir: string): seq[string] =
  ## Build package search paths (minimal MVP).
  result = @[]
  if importer_dir.len > 0:
    result.add(importer_dir)
    result.add(joinPath(importer_dir, "packages"))
  let env_paths = getEnv("GENE_PACKAGE_PATH")
  if env_paths.len > 0:
    for part in env_paths.split(PathSep):
      if part.len > 0:
        result.add(absolutePath(part))

proc workspace_src_paths(): seq[string] =
  ## Build workspace src roots from GENE_WORKSPACE_PATH.
  result = @[]
  let env_paths = getEnv("GENE_WORKSPACE_PATH")
  if env_paths.len == 0:
    return
  for part in env_paths.split(PathSep):
    if part.len == 0:
      continue
    let root = absolutePath(part)
    let (_, tail) = splitPath(root)
    if tail == "src":
      result.add(root)
    else:
      result.add(joinPath(root, "src"))

proc locate_package_root(package_name, importer_dir: string, override_path: string): string =
  ## Locate package root by name or explicit override.
  let importer_root = find_package_root(importer_dir)

  if override_path.len > 0:
    let base_path =
      if override_path.isAbsolute:
        override_path
      elif importer_root.len > 0:
        joinPath(importer_root, override_path)
      else:
        joinPath(importer_dir, override_path)
    let root = find_package_root(base_path)
    if root.len == 0:
      not_allowed("Package path override '" & override_path & "' does not contain package.gene")
    return root

  let name_path = package_name.replace("/", $DirSep)
  # Walk search paths from importer_dir plus ancestors.
  var bases = package_search_paths(importer_dir)
  var walk_dir = importer_dir
  while walk_dir.len > 0:
    let parent = parentDir(walk_dir)
    if parent.len == 0 or parent == walk_dir:
      break
    bases.add(parent)
    walk_dir = parent

  for base in bases:
    let base_abs = absolutePath(base)
    let candidate_full = joinPath(base_abs, name_path)
    if dirExists(candidate_full) or fileExists(candidate_full):
      let root = find_package_root(candidate_full)
      if root.len > 0:
        return root

    let last_part = package_name.split("/")[^1]
    let candidate_short = joinPath(base_abs, last_part)
    if dirExists(candidate_short) or fileExists(candidate_short):
      let root = find_package_root(candidate_short)
      if root.len > 0:
        return root

  # Fallback: try sibling of the current package root using the final segment.
  if importer_root.len > 0:
    let last_part = package_name.split("/")[^1]
    let sibling = joinPath(parentDir(importer_root), last_part)
    let root = find_package_root(sibling)
    if root.len > 0:
      return root
  when not defined(release):
    echo "locate_package_root failed for ", package_name, " (importer_dir=", importer_dir, ")"
  return ""

proc find_native_build(pkg_root: string, resolved_path: string): string =
  ## Look for a compiled native module under build/ matching the module basename.
  let base = splitFile(resolved_path).name
  if pkg_root.len == 0 or base.len == 0:
    return ""
  let candidate = joinPath(pkg_root, "build", base)
  let extPath = candidate & native_ext_suffix()
  if fileExists(extPath):
    return candidate  # load_extension will append the suffix
  return ""

proc current_module_path(vm: ptr VirtualMachine): string =
  ## Best-effort retrieval of current module filename.
  if vm.frame != nil and vm.frame.ns != nil:
    let key = "__module_name__".to_key()
    if vm.frame.ns.members.hasKey(key):
      let v = vm.frame.ns.members[key]
      if v.kind == VkString:
        return v.str
    if vm.frame.ns.name.len > 0:
      return vm.frame.ns.name
  return ""

proc split_import_path(name: string): seq[string] =
  ## Split an import path like "genex/http/*" into parts.
  if name.len == 0:
    return @[]
  result = name.split("/")

proc extension_library_path(name: string): string =
  ## Determine default path for a compiled extension library.
  when defined(windows):
    result = "build" / ("lib" & name & ".dll")
  elif defined(macosx):
    result = "build" / ("lib" & name & ".dylib")
  else:
    result = "build" / ("lib" & name & ".so")

proc ensure_genex_extension(vm: ptr VirtualMachine, part: string): Value =
  ## Ensure a genex extension is loaded when accessing genex/<part>.
  if App == NIL or App.kind != VkApplication:
    return NIL
  if App.app.genex_ns.kind != VkNamespace:
    return NIL

  let key = part.to_key()
  var member = App.app.genex_ns.ref.ns.members.getOrDefault(key, NIL)

  if member == NIL:
    when not defined(noExtensions):
      let ext_path = extension_library_path(part)
      if fileExists(ext_path):
        try:
          let ext_ns = load_extension(vm, ext_path)
          if ext_ns != nil:
            member = ext_ns.to_value()
            App.app.genex_ns.ref.ns.members[key] = member
        except CatchableError:
          discard
    # Even if extension loading failed, keep NIL to prevent repeated attempts
  return member

proc resolve_from_root(vm: ptr VirtualMachine, root: Value, parts: seq[string]): Value =
  ## Resolve a path against a root namespace value.
  if parts.len == 0:
    return root

  var current = root
  for part in parts:
    if part.len == 0:
      continue
    if current.kind != VkNamespace:
      return NIL
    let key = part.to_key()
    var next = current.ref.ns.members.getOrDefault(key, NIL)
    if next == NIL and current.kind == VkNamespace and App != NIL and App.kind == VkApplication and App.app.genex_ns.kind == VkNamespace and current.ref.ns == App.app.genex_ns.ref.ns:
      next = ensure_genex_extension(vm, part)
      if next == NIL:
        current.ref.ns.members[key] = NIL
    if next == NIL:
      return NIL
    current = next

  return current

proc import_from_namespace(vm: ptr VirtualMachine, items: seq[ImportItem]): bool =
  ## Try to handle imports targeting known namespaces like gene/* or genex/*.
  var handled = false

  for item in items:
    let parts = split_import_path(item.name)
    if parts.len == 0:
      continue

    var root: Value
    var start_index = 0

    case parts[0]
    of "gene":
      if App == NIL or App.kind != VkApplication:
        continue
      root = App.app.gene_ns
      start_index = 1
    of "genex":
      if App == NIL or App.kind != VkApplication:
        continue
      root = App.app.genex_ns
      start_index = 1
    of "global":
      if App == NIL or App.kind != VkApplication:
        continue
      root = App.app.global_ns
      start_index = 1
    else:
      continue  # Delegate to module loader for unknown roots

    if start_index > parts.len:
      continue

    if parts.len > start_index and parts[^1] == "*":
      let ns_value = resolve_from_root(vm, root, parts[start_index ..< parts.len - 1])
      if ns_value.kind != VkNamespace:
        not_allowed("Cannot import '*' from non-namespace '" & item.name & "'")

      for key, value in ns_value.ref.ns.members:
        if value != NIL:
          vm.frame.ns.members[key] = value
      handled = true
      continue

    let resolved = resolve_from_root(vm, root, parts[start_index ..< parts.len])
    if resolved == NIL:
      not_allowed("Symbol '" & item.name & "' not found in namespace")

    let import_name = if item.alias.len > 0: item.alias else: parts[^1]
    vm.frame.ns.members[import_name.to_key()] = resolved
    handled = true

  return handled

proc parse_import_statement*(gene: ptr Gene): tuple[module_path: string, package_name: string, imports: seq[ImportItem]] =
  ## Parse import statement into module path and list of imports
  var module_path = ""
  var package_name = ""
  var imports: seq[ImportItem] = @[]
  var i = 0
  
  while i < gene.children.len:
    let child = gene.children[i]
    
    if child.kind == VkSymbol and child.str == "from":
      # Handle "from module" syntax
      if i + 1 < gene.children.len and gene.children[i + 1].kind == VkString:
        module_path = gene.children[i + 1].str
        i += 2
        continue
      else:
        not_allowed("'from' must be followed by a string module path")
    if child.kind == VkSymbol and child.str == "of":
      # Handle "of package" syntax
      if i + 1 < gene.children.len and gene.children[i + 1].kind == VkString:
        package_name = gene.children[i + 1].str
        i += 2
        continue
      else:
        not_allowed("'of' must be followed by a string package name")
    
    # Parse import items
    case child.kind:
      of VkSymbol:
        let s = child.str
        var item: ImportItem
        
        # Check if symbol contains : for alias syntax (a:alias)
        let colonPos = s.find(':')
        if colonPos > 0 and colonPos < s.len - 1:
          # This is a:alias syntax
          item.name = s[0..<colonPos]
          item.alias = s[colonPos+1..^1]
        else:
          item.name = s
          
          # Check for alias syntax (a:b) as separate gene
          if i + 1 < gene.children.len and gene.children[i + 1].kind == VkGene:
            let alias_gene = gene.children[i + 1].gene
            if alias_gene.type.kind == VkSymbol and alias_gene.type.str == ":" and
               alias_gene.children.len == 1 and alias_gene.children[0].kind == VkSymbol:
              item.alias = alias_gene.children[0].str
              i += 1
        
        imports.add(item)
      
      of VkComplexSymbol:
        # Handle n/f or n/ followed by array
        let parts = child.ref.csymbol
        if parts.len > 0:
          # Check if this is n/ followed by an array [a b]
          if parts[^1] == "" and i + 1 < gene.children.len and gene.children[i + 1].kind == VkArray:
            # This is n/[a b] syntax
            let prefix = parts[0..^2].join("/")
            i += 1  # Move to the array
            let arr = array_data(gene.children[i])
            
            for sub_child in arr:
              if sub_child.kind == VkSymbol:
                let s = sub_child.str
                var item: ImportItem
                
                # Check for alias in symbol
                let colonPos = s.find(':')
                if colonPos > 0 and colonPos < s.len - 1:
                  item.name = prefix & "/" & s[0..<colonPos]
                  item.alias = s[colonPos+1..^1]
                else:
                  item.name = prefix & "/" & s
                
                imports.add(item)
              elif sub_child.kind == VkGene:
                # Could be a:alias inside the brackets
                let sub_g = sub_child.gene
                if sub_g.type.kind == VkSymbol and sub_g.children.len == 1 and
                   sub_g.children[0].kind == VkSymbol:
                  var item = ImportItem(
                    name: prefix & "/" & sub_g.type.str,
                    alias: sub_g.children[0].str
                  )
                  imports.add(item)
          else:
            # Regular n/f syntax
            let fullPath = parts.join("/")
            var item: ImportItem
            
            # Check if last part contains : for alias syntax
            let colonPos = fullPath.find(':')
            if colonPos > 0 and colonPos < fullPath.len - 1:
              # This is n/f:alias syntax
              item.name = fullPath[0..<colonPos]
              item.alias = fullPath[colonPos+1..^1]
            else:
              item.name = fullPath
              
              # Check for alias as separate gene
              if i + 1 < gene.children.len and gene.children[i + 1].kind == VkGene:
                let alias_gene = gene.children[i + 1].gene
                if alias_gene.type.kind == VkSymbol and alias_gene.type.str == ":" and
                   alias_gene.children.len == 1 and alias_gene.children[0].kind == VkSymbol:
                  item.alias = alias_gene.children[0].str
                  i += 1
            
            imports.add(item)
      
      of VkGene:
        # Could be n/[a b] syntax or other complex forms
        let g = child.gene
        if g.type.kind == VkComplexSymbol:
          let parts = g.type.ref.csymbol
          if parts.len >= 2 and g.children.len > 0:
            # This is n/[a b] syntax
            let prefix = parts[0..^2].join("/")
            for sub_child in g.children:
              if sub_child.kind == VkSymbol:
                var item = ImportItem(name: prefix & "/" & sub_child.str)
                imports.add(item)
              elif sub_child.kind == VkGene:
                # Could be a:alias inside the brackets
                let sub_g = sub_child.gene
                if sub_g.type.kind == VkSymbol and sub_g.children.len == 1 and
                   sub_g.children[0].kind == VkSymbol:
                  var item = ImportItem(
                    name: prefix & "/" & sub_g.type.str,
                    alias: sub_g.children[0].str
                  )
                  imports.add(item)
        else:
          not_allowed("Invalid import syntax: " & $child)
      
      else:
        not_allowed("Invalid import item type: " & $child.kind)
    
    i += 1
  
  return (module_path, package_name, imports)

proc compile_module*(path: string): CompilationUnit =
  ## Compile a module from file and return its compilation unit
  # Read module file
  let abs_path = absolutePath(path)
  if abs_path.endsWith(".gir"):
    let loaded = load_gir(abs_path)
    register_module_type_registry(abs_path, loaded)
    return loaded

  var actual_path = abs_path
  if not path.endsWith(".gene"):
    actual_path = abs_path & ".gene"
  if not fileExists(actual_path):
    if actual_path != abs_path and fileExists(abs_path):
      actual_path = abs_path
    else:
      not_allowed("Failed to open module '" & path & "'")

  let gir_path = get_gir_path(actual_path, "build")
  if fileExists(gir_path) and is_gir_up_to_date(gir_path, actual_path):
    try:
      let loaded = load_gir(gir_path)
      register_module_type_registry(actual_path, loaded)
      return loaded
    except CatchableError:
      discard

  let stream = newFileStream(actual_path, fmRead)
  if stream.isNil:
    not_allowed("Failed to open module '" & actual_path & "'")
  defer:
    stream.close()

  let compiled = parse_and_compile(stream, actual_path, module_mode = true, run_init = false)
  register_module_type_registry(actual_path, compiled)
  try:
    save_gir(compiled, gir_path, actual_path)
  except CatchableError:
    discard
  return compiled

proc load_module*(vm: ptr VirtualMachine, path: string): Namespace =
  ## Load a module from file and return its namespace
  # Check cache first
  if ModuleCache.hasKey(path):
    return ModuleCache[path]
  
  # Create namespace for module
  let module_ns = new_namespace(App.app.global_ns.ref.ns, path)
  module_ns.members["__is_main__".to_key()] = FALSE
  module_ns.members["__module_name__".to_key()] = path.to_value()
  module_ns.members["gene".to_key()] = App.app.gene_ns
  module_ns.members["genex".to_key()] = App.app.genex_ns
  
  # Compile the module to ensure it's valid
  discard compile_module(path)
  
  # The VM will execute this module when needed
  # For now, just cache the empty namespace
  # The actual execution will happen when the import is processed
  
  # Cache the module
  ModuleCache[path] = module_ns
  
  return module_ns

proc resolve_import_value*(ns: Namespace, path: string): Value =
  ## Resolve a value from a namespace given a path like "n/f"
  let parts = path.split("/")
  var current_ns = ns
  var final_value = NIL
  
  for i, part in parts:
    let key = part.to_key()
    if not current_ns.members.hasKey(key):
      not_allowed("Symbol '" & part & "' not found in namespace")
    
    let value = current_ns.members[key]
    
    if i == parts.len - 1:
      # Last part - this is our result
      final_value = value
    else:
      # Intermediate part - must be a namespace
      if value.kind != VkNamespace:
        not_allowed("'" & part & "' is not a namespace")
      current_ns = value.ref.ns
  
  return final_value

proc execute_module*(vm: ptr VirtualMachine, path: string, module_ns: Namespace): Value =
  ## Execute a module in its namespace context
  # This will be called from vm.nim where exec is available
  raise new_exception(types.Exception, "execute_module should be overridden by vm.nim")

proc handle_import*(vm: ptr VirtualMachine, import_gene: ptr Gene): tuple[path: string, imports: seq[ImportItem], ns: Namespace, is_native: bool, handled: bool] =
  ## Parse import statement and prepare for execution
  let (raw_module_path, package_from_stmt, imports) = parse_import_statement(import_gene)
  
  if raw_module_path.len == 0:
    if import_from_namespace(vm, imports):
      return ("", @[], nil, false, true)
    else:
      not_allowed("Module path not specified in import statement")
  
  var package_name = package_from_stmt
  if "pkg".to_key() in import_gene.props and package_name.len == 0:
    let pkg_val = import_gene.props["pkg".to_key()]
    if pkg_val.kind == VkString or pkg_val.kind == VkSymbol:
      package_name = pkg_val.str
  var package_path_override = ""
  if "path".to_key() in import_gene.props:
    let path_val = import_gene.props["path".to_key()]
    if path_val.kind == VkString or path_val.kind == VkSymbol:
      package_path_override = path_val.str
  
  # Check if this is a native extension
  var is_native = false
  if "native".to_key() in import_gene.props:
    is_native = import_gene.props["native".to_key()].to_bool()

  # Determine importer directory
  let importer_module = current_module_path(vm)
  let importer_dir = if importer_module.len > 0: parentDir(importer_module) else: getCurrentDir()

  var resolved_path = raw_module_path
  var is_gir = false

  var package_root = ""

  if package_name.len > 0:
    validate_package_name(package_name)
    package_root = locate_package_root(package_name, importer_dir, package_path_override)
    if package_root.len == 0:
      not_allowed("Package '" & package_name & "' not found")
    if raw_module_path == "index":
      let entry = resolve_package_entrypoint(package_root)
      resolved_path = entry.path
      is_gir = entry.is_gir
    else:
      let (p, girFlag) = resolve_module_path(raw_module_path, package_root, package_root, package_name)
      resolved_path = p
      is_gir = girFlag
  else:
    package_root = find_package_root(importer_dir)
    if is_native:
      let native_path = resolve_native_module(raw_module_path, importer_dir, package_root, "")
      if native_path.len == 0:
        not_allowed("Native module '" & raw_module_path & "' not found")
      resolved_path = native_path
      is_gir = false
    else:
      let (p, girFlag) = resolve_module_path(raw_module_path, importer_dir, package_root, "")
      resolved_path = p
      is_gir = girFlag

  if is_native and resolved_path.len == 0:
    let native_path = resolve_native_module(raw_module_path, importer_dir, package_root, package_name)
    if native_path.len == 0:
      not_allowed("Native module '" & raw_module_path & "' not found")
    resolved_path = native_path
    is_gir = false

  if not is_native:
    let native_candidate = find_native_build(package_root, resolved_path)
    if native_candidate.len > 0:
      resolved_path = native_candidate
      is_native = true

  # Check cache first
  if ModuleCache.hasKey(resolved_path):
    let module_ns = ModuleCache[resolved_path]
    return (resolved_path, imports, module_ns, is_native, false)
  
  # Module not cached, need to compile and execute it (or load as native)
  let module_ns = new_namespace(App.app.global_ns.ref.ns, resolved_path)
  module_ns.members["__is_main__".to_key()] = FALSE
  module_ns.members["__module_name__".to_key()] = resolved_path.to_value()
  module_ns.members["gene".to_key()] = App.app.gene_ns
  module_ns.members["genex".to_key()] = App.app.genex_ns
  if is_gir:
    module_ns.members["__compiled__".to_key()] = TRUE
  return (resolved_path, imports, module_ns, is_native, false)
