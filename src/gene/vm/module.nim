import tables, strutils, hashes, os, streams

import ../types
import ../compiler
import ../gir
import ../parser
when defined(gene_wasm):
  import ../wasm_host_abi
when not defined(noExtensions):
  import ./extension

type
  ImportItem* = object
    name*: string
    alias*: string
    children*: seq[string]  # For nested imports like n/[a b]

  LockPackageNode = object
    rel_dir: string
    dependencies: Table[string, string]

  LockGraph = object
    root_dependencies: Table[string, string]
    packages: Table[string, LockPackageNode]

  ResolvedModuleCandidate = object
    path: string
    is_gir: bool

# Forward declarations
proc workspace_src_paths(): seq[string]

# Global module cache
var ModuleCache* = initTable[string, Namespace]()
var ModuleLoadState* = initTable[string, bool]()
var ModuleLoadStack* = newSeq[string]()
var LoadedModuleTypeRegistry* = new_global_type_registry()

let ExportKey* = "__exports__".to_key()

const
  MODULE_ERR_NOT_FOUND = "GENE.MODULE.NOT_FOUND"
  MODULE_ERR_AMBIGUOUS = "GENE.MODULE.AMBIGUOUS"
  PACKAGE_ERR_NOT_FOUND = "GENE.PACKAGE.NOT_FOUND"
  PACKAGE_ERR_AMBIGUOUS = "GENE.PACKAGE.AMBIGUOUS"
  PACKAGE_ERR_BOUNDARY = "GENE.PACKAGE.BOUNDARY"
  PACKAGE_ERR_INVALID_LOCK = "GENE.PACKAGE.INVALID_LOCK"

proc canonical_path(path: string): string =
  if path.len == 0:
    return ""
  normalizedPath(absolutePath(path))

proc append_unique(values: var seq[string], value: string) =
  if value.len == 0:
    return
  for existing in values:
    if existing == value:
      return
  values.add(value)

proc append_unique_candidate(candidates: var seq[ResolvedModuleCandidate], candidate: ResolvedModuleCandidate) =
  if candidate.path.len == 0:
    return
  for existing in candidates:
    if existing.path == candidate.path and existing.is_gir == candidate.is_gir:
      return
  candidates.add(candidate)

proc raise_import_error(code: string, message: string,
                        importer_module = "", specifier = "", package_name = "",
                        searched: seq[string] = @[],
                        candidates: seq[string] = @[],
                        cycle: seq[string] = @[]) {.noreturn.} =
  var details: seq[string] = @[]
  if importer_module.len > 0:
    details.add("importer=" & importer_module)
  if specifier.len > 0:
    details.add("specifier=" & specifier)
  if package_name.len > 0:
    details.add("package=" & package_name)
  if searched.len > 0:
    details.add("searched=[" & searched.join(", ") & "]")
  if candidates.len > 0:
    details.add("candidates=[" & candidates.join(", ") & "]")
  if cycle.len > 0:
    details.add("cycle=" & cycle.join(" -> "))
  let suffix = if details.len > 0: " (" & details.join("; ") & ")" else: ""
  not_allowed("[" & code & "] " & message & suffix)

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
  ## Validate package name against `[a-z][a-z0-9-_+&]*[a-z0-9](/...)`.
  ## Single-segment names are allowed as local aliases.
  if name.len == 0:
    not_allowed("Package name cannot be empty")
  let parts = name.split("/")
  if parts.len == 0:
    not_allowed("Package name cannot be empty")

  let top = parts[0]
  if top == "gene" or top == "genex" or top.startsWith("gene"):
    not_allowed("Package name '" & name & "' uses a reserved namespace")
  if top.len == 1 and (top == "x" or top == "y" or top == "z"):
    discard  # Open namespaces; still validate characters below

  for part in parts:
    if part.len == 0:
      not_allowed("Package segments cannot be empty")
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

proc key_to_symbol_name(k: Key): string =
  get_symbol(symbol_index(k))

proc map_lookup(map_val: Value, key: string): Value =
  if map_val.kind != VkMap:
    return NIL
  map_data(map_val).getOrDefault(key.to_key(), NIL)

proc value_as_string(v: Value): string =
  case v.kind
  of VkString, VkSymbol:
    v.str
  else:
    ""

proc package_manifest_name(root: string): string =
  let manifest_path = joinPath(root, "package.gene")
  if not fileExists(manifest_path):
    return ""
  try:
    let forms = read_all(readFile(manifest_path))
    if forms.len == 0:
      return ""
    if forms.len == 1 and forms[0].kind == VkMap:
      return value_as_string(map_lookup(forms[0], "name"))
    var i = 0
    while i + 1 < forms.len:
      let key_node = forms[i]
      if key_node.kind == VkSymbol and (key_node.str == "name" or key_node.str == "^name"):
        return value_as_string(forms[i + 1])
      inc(i)
  except CatchableError:
    discard
  return ""

proc build_package_value(name: string, root: string): Value =
  let pkg = Package(
    dir: root,
    adhoc: root.len == 0,
    ns: if App != NIL and App.kind == VkApplication and App.app.global_ns.kind == VkNamespace:
      App.app.global_ns.ref.ns
    else:
      nil,
    name: if name.len > 0: name else: "gene",
    version: NIL,
    license: NIL,
    globals: @[],
    homepage: "",
    src_path: "src",
    test_path: "tests",
    asset_path: "assets",
    build_path: "build",
    load_paths: @[],
    init_modules: @[],
    props: initTable[Key, Value](),
  )
  let pkg_ref = new_ref(VkPackage)
  pkg_ref.pkg = pkg
  pkg_ref.to_ref_value()

proc package_value_for_module(module_path: string, package_name = "", package_root = ""): Value =
  var resolved_root = package_root
  var resolved_name = package_name

  if resolved_root.len == 0:
    var start_path = ""
    if module_path.len > 0:
      if fileExists(module_path):
        start_path = parentDir(module_path)
      elif module_path.endsWith(".gene") or module_path.endsWith(".gir"):
        start_path = parentDir(module_path)
      elif module_path.contains($DirSep):
        start_path = parentDir(module_path)
    if start_path.len > 0:
      resolved_root = find_package_root(start_path)

  if resolved_root.len > 0:
    let manifest_name = package_manifest_name(resolved_root)
    if manifest_name.len > 0:
      resolved_name = manifest_name

  if resolved_name.len == 0:
    resolved_name = "gene"

  build_package_value(resolved_name, resolved_root)

proc bind_module_package_context*(ns: Namespace, module_path: string,
                                  package_name = "", package_root = "") =
  if ns == nil:
    return
  let pkg_value = package_value_for_module(module_path, package_name, package_root)
  ns.members["pkg".to_key()] = pkg_value
  ns.members["$pkg".to_key()] = pkg_value
  if App != NIL and App.kind == VkApplication:
    if App.app.global_ns.kind == VkNamespace:
      App.app.global_ns.ref.ns["pkg".to_key()] = pkg_value
      App.app.global_ns.ref.ns["$pkg".to_key()] = pkg_value
    if App.app.gene_ns.kind == VkNamespace:
      App.app.gene_ns.ref.ns["pkg".to_key()] = pkg_value
      App.app.gene_ns.ref.ns["$pkg".to_key()] = pkg_value

proc package_root_matches_name(root: string, package_name: string): bool =
  root.len > 0 and package_manifest_name(root) == package_name

proc package_name_parts(package_name: string): tuple[parent: string, pkg: string] =
  let parts = package_name.split("/")
  if parts.len < 2:
    return ("", "")
  (parts[0], parts[1])

proc path_within(base_path: string, candidate_path: string): bool =
  let base_abs = absolutePath(base_path)
  let cand_abs = absolutePath(candidate_path)
  let rel = relativePath(cand_abs, base_abs)
  rel == "." or (not rel.startsWith("..") and rel != "..")

proc find_deps_root(start_path: string): string =
  var dir = absolutePath(start_path)
  while true:
    let deps_root = joinPath(dir, ".gene", "deps")
    if dirExists(deps_root):
      return deps_root
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  return ""

proc init_lock_graph(): LockGraph =
  LockGraph(
    root_dependencies: initTable[string, string](),
    packages: initTable[string, LockPackageNode]()
  )

proc parse_lock_graph(lock_path: string): LockGraph =
  result = init_lock_graph()
  if not fileExists(lock_path):
    return
  try:
    let forms = read_all(readFile(lock_path))
    if forms.len == 0 or forms[0].kind != VkMap:
      return
    let root_map = forms[0]

    let root_deps = map_lookup(root_map, "root_dependencies")
    if root_deps.kind == VkMap:
      for k, v in map_data(root_deps):
        let dep_name = key_to_symbol_name(k)
        let node_id = value_as_string(v)
        if dep_name.len > 0 and node_id.len > 0:
          result.root_dependencies[dep_name] = node_id

    let packages = map_lookup(root_map, "packages")
    if packages.kind != VkMap:
      return

    for k, v in map_data(packages):
      if v.kind != VkMap:
        continue
      let node_id = key_to_symbol_name(k)
      if node_id.len == 0:
        continue
      var node = LockPackageNode(
        rel_dir: value_as_string(map_lookup(v, "dir")),
        dependencies: initTable[string, string]()
      )
      let deps = map_lookup(v, "dependencies")
      if deps.kind == VkMap:
        for dep_key, dep_val in map_data(deps):
          let dep_name = key_to_symbol_name(dep_key)
          let dep_node_id = value_as_string(dep_val)
          if dep_name.len > 0 and dep_node_id.len > 0:
            node.dependencies[dep_name] = dep_node_id
      result.packages[node_id] = node
  except CatchableError:
    discard

proc resolve_package_from_lock(package_name: string, importer_root: string, importer_dir: string):
    tuple[root: string, issue: string] =
  if importer_root.len == 0:
    return ("", "")

  let lock_path = joinPath(importer_root, "package.gene.lock")
  let lock = parse_lock_graph(lock_path)
  if lock.root_dependencies.len == 0 and lock.packages.len == 0:
    return ("", "")

  let importer_abs = absolutePath(importer_dir)
  var importer_node_id = ""
  var best_match_len = -1
  for node_id, node in lock.packages:
    if node.rel_dir.len == 0:
      continue
    let node_abs = absolutePath(joinPath(importer_root, node.rel_dir))
    if path_within(node_abs, importer_abs):
      if node_abs.len > best_match_len:
        best_match_len = node_abs.len
        importer_node_id = node_id

  var dep_node_id = ""
  if importer_node_id.len > 0 and lock.packages.hasKey(importer_node_id):
    dep_node_id = lock.packages[importer_node_id].dependencies.getOrDefault(package_name, "")
  if dep_node_id.len == 0:
    dep_node_id = lock.root_dependencies.getOrDefault(package_name, "")
  if dep_node_id.len == 0:
    return ("", "")
  if not lock.packages.hasKey(dep_node_id):
    return ("", "lockfile references missing package node '" & dep_node_id & "'")

  let dep_node = lock.packages[dep_node_id]
  if dep_node.rel_dir.len == 0:
    return ("", "lockfile package node '" & dep_node_id & "' has empty dir")
  let dep_root = absolutePath(joinPath(importer_root, dep_node.rel_dir))
  if not fileExists(joinPath(dep_root, "package.gene")):
    return ("", "lockfile package root missing package.gene: " & dep_root)
  if not package_root_matches_name(dep_root, package_name):
    return ("", "lockfile package name mismatch at " & dep_root)
  (dep_root, "")

proc resolve_package_from_deps(package_name: string, importer_dir: string):
    tuple[root: string, ambiguous: seq[string]] =
  let deps_root = find_deps_root(importer_dir)
  if deps_root.len == 0:
    return ("", @[])

  let (parent_name, pkg_name) = package_name_parts(package_name)
  if parent_name.len == 0 or pkg_name.len == 0:
    return ("", @[])
  let pkg_base = joinPath(deps_root, parent_name, pkg_name)
  if not dirExists(pkg_base):
    return ("", @[])

  var matches: seq[string] = @[]
  for kind, path in walkDir(pkg_base):
    if kind != pcDir:
      continue
    let candidate_root = absolutePath(path)
    if package_root_matches_name(candidate_root, package_name):
      matches.add(candidate_root)

  if matches.len == 1:
    return (matches[0], @[])
  if matches.len > 1:
    return ("", matches)
  return ("", @[])

proc resolve_package_from_registry(package_name: string, importer_root: string, importer_dir: string):
    tuple[root: string, issue: string] =
  if App == NIL or App.kind != VkApplication or App.app.global_ns.kind != VkNamespace:
    return ("", "")

  let deps_registry = App.app.global_ns.ref.ns.members.getOrDefault("__deps__".to_key(), NIL)
  if deps_registry == NIL or deps_registry.kind != VkMap:
    return ("", "")

  let dep_entry = map_data(deps_registry).getOrDefault(package_name.to_key(), NIL)
  if dep_entry == NIL:
    return ("", "")
  if dep_entry.kind != VkMap:
    return ("", "dependency override entry for '" & package_name & "' must be a map")

  let raw_path = value_as_string(map_lookup(dep_entry, "path"))
  if raw_path.len == 0:
    return ("", "dependency override for '" & package_name & "' is missing ^path")

  let base_path =
    if raw_path.isAbsolute:
      raw_path
    elif importer_root.len > 0:
      joinPath(importer_root, raw_path)
    else:
      joinPath(importer_dir, raw_path)

  let root = find_package_root(base_path)
  if root.len == 0:
    return ("", "dependency override path does not contain package.gene: " & base_path)
  (canonical_path(root), "")

proc resolve_package_entrypoint(root: string, importer_module = "", package_name = ""): tuple[path: string, is_gir: bool] =
  ## Choose package entrypoint in priority order.
  let idx = joinPath(root, "index.gene")
  if fileExists(idx):
    return (canonical_path(idx), false)
  let srcIdx = joinPath(root, "src", "index.gene")
  if fileExists(srcIdx):
    return (canonical_path(srcIdx), false)
  let libIdx = joinPath(root, "lib", "index.gene")
  if fileExists(libIdx):
    return (canonical_path(libIdx), false)
  let girIdx = joinPath(root, "build", "index.gir")
  if fileExists(girIdx):
    return (canonical_path(girIdx), true)
  raise_import_error(PACKAGE_ERR_NOT_FOUND, "Package entrypoint not found under " & root,
    importer_module = importer_module, package_name = package_name)

proc package_module_bases(package_root: string): seq[string] =
  if package_root.len == 0:
    return @[]
  @[
    package_root,
    joinPath(package_root, "src"),
    joinPath(package_root, "lib"),
    joinPath(package_root, "build"),
  ]

proc collect_resolve_candidates(base: string, module_path: string): seq[ResolvedModuleCandidate] =
  if base.len == 0 or module_path.len == 0:
    return @[]

  let candidate = joinPath(base, module_path)
  if module_path.endsWith(".gir") or module_path.endsWith(".gene"):
    if fileExists(candidate):
      append_unique_candidate(result, ResolvedModuleCandidate(
        path: canonical_path(candidate),
        is_gir: module_path.endsWith(".gir")
      ))
    return result

  let with_gene = candidate & ".gene"
  if fileExists(with_gene):
    append_unique_candidate(result, ResolvedModuleCandidate(path: canonical_path(with_gene), is_gir: false))

  if fileExists(candidate):
    append_unique_candidate(result, ResolvedModuleCandidate(
      path: canonical_path(candidate),
      is_gir: candidate.endsWith(".gir")
    ))

proc resolve_module_path(module_path: string, importer_dir: string, package_root: string,
                         package_name: string, importer_module = "",
                         enforce_package_boundary = false): tuple[path: string, is_gir: bool] =
  ## Resolve a module path using deterministic precedence tiers.
  var normalized = module_path
  if package_name.len > 0:
    let pkg_last = package_name.split("/")[^1]
    if normalized.startsWith(package_name & "/"):
      normalized = normalized[package_name.len + 1 .. ^1]
    elif normalized.startsWith(pkg_last & "/"):
      normalized = normalized[pkg_last.len + 1 .. ^1]

  let importer_base = canonical_path(if importer_dir.len > 0: importer_dir else: getCurrentDir())
  let package_bases = package_module_bases(package_root)
  let workspace_bases = workspace_src_paths()

  let tier_labels = @["importer", "package", "workspace"]
  let tier_bases = @[
    @[importer_base],
    package_bases,
    workspace_bases,
  ]

  var searched: seq[string] = @[]
  for tier_idx in 0..<tier_bases.len:
    var bases: seq[string] = @[]
    for base in tier_bases[tier_idx]:
      append_unique(bases, canonical_path(base))

    if bases.len == 0:
      continue

    var tier_matches: seq[ResolvedModuleCandidate] = @[]
    for base in bases:
      append_unique(searched, base)
      for candidate in collect_resolve_candidates(base, normalized):
        append_unique_candidate(tier_matches, candidate)

    if package_root.len > 0 and tier_labels[tier_idx] == "package" and not normalized.endsWith(".gir"):
      let build_base = joinPath(package_root, "build", splitFile(normalized).name)
      let build_gir = build_base & ".gir"
      if fileExists(build_gir):
        append_unique_candidate(tier_matches, ResolvedModuleCandidate(path: canonical_path(build_gir), is_gir: true))

    if tier_matches.len == 1:
      let resolved = tier_matches[0]
      if enforce_package_boundary and package_root.len > 0:
        let package_root_abs = canonical_path(package_root)
        if not path_within(package_root_abs, resolved.path):
          raise_import_error(PACKAGE_ERR_BOUNDARY,
            "Resolved module escapes package root",
            importer_module = importer_module,
            specifier = module_path,
            package_name = package_name,
            candidates = @[resolved.path],
            searched = searched)
      return (resolved.path, resolved.is_gir)
    if tier_matches.len > 1:
      var candidate_paths: seq[string] = @[]
      for entry in tier_matches:
        candidate_paths.add(entry.path)
      raise_import_error(MODULE_ERR_AMBIGUOUS,
        "Module specifier matched multiple candidates in the '" & tier_labels[tier_idx] & "' tier",
        importer_module = importer_module,
        specifier = module_path,
        package_name = package_name,
        searched = searched,
        candidates = candidate_paths)

  raise_import_error(MODULE_ERR_NOT_FOUND, "Module '" & module_path & "' was not found",
    importer_module = importer_module,
    specifier = module_path,
    package_name = package_name,
    searched = searched)

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

  let importer_base = canonical_path(if importer_dir.len > 0: importer_dir else: getCurrentDir())
  let package_bases = package_module_bases(package_root)
  let workspace_bases = workspace_src_paths()
  let tier_bases = @[
    @[importer_base],
    package_bases,
    workspace_bases,
  ]

  for bases in tier_bases:
    var unique_bases: seq[string] = @[]
    for base in bases:
      append_unique(unique_bases, canonical_path(base))
    for base in unique_bases:
      let candidate = canonical_path(joinPath(base, normalized))
      if fileExists(candidate):
        return candidate
      let native_candidate = candidate & native_ext_suffix()
      if fileExists(native_candidate):
        return canonical_path(native_candidate)
      let ext_dir_candidate = canonical_path(joinPath(base, "build", "extensions", normalized))
      if fileExists(ext_dir_candidate):
        return ext_dir_candidate
      let ext_dir_native = ext_dir_candidate & native_ext_suffix()
      if fileExists(ext_dir_native):
        return canonical_path(ext_dir_native)

  if package_root.len > 0:
    let base = splitFile(normalized).name
    let build_base = joinPath(package_root, "build", base)
    let build_native = build_base & native_ext_suffix()
    if fileExists(build_native):
      return canonical_path(build_native)
    let build_ext_base = joinPath(package_root, "build", "extensions", base)
    let build_ext_native = build_ext_base & native_ext_suffix()
    if fileExists(build_ext_native):
      return canonical_path(build_ext_native)

  return ""

proc package_search_paths(importer_dir: string): seq[string] =
  ## Build package search paths (minimal MVP).
  result = @[]
  if importer_dir.len > 0:
    result.add(canonical_path(importer_dir))
    result.add(canonical_path(joinPath(importer_dir, "packages")))
  let env_paths = getEnv("GENE_PACKAGE_PATH")
  if env_paths.len > 0:
    for part in env_paths.split(PathSep):
      if part.len > 0:
        result.add(canonical_path(part))

proc workspace_src_paths(): seq[string] =
  ## Build workspace src roots from GENE_WORKSPACE_PATH.
  result = @[]
  let env_paths = getEnv("GENE_WORKSPACE_PATH")
  if env_paths.len == 0:
    return
  for part in env_paths.split(PathSep):
    if part.len == 0:
      continue
    let root = canonical_path(part)
    let (_, tail) = splitPath(root)
    if tail == "src":
      result.add(canonical_path(root))
    else:
      result.add(canonical_path(joinPath(root, "src")))

proc locate_package_root(package_name, importer_dir: string, override_path: string,
                         importer_module = ""): string =
  ## Locate package root by name or explicit override.
  let importer_base = canonical_path(if importer_dir.len > 0: importer_dir else: getCurrentDir())
  let importer_root = find_package_root(importer_base)
  var searched: seq[string] = @[]

  if override_path.len > 0:
    let base_path =
      if override_path.isAbsolute:
        override_path
      elif importer_root.len > 0:
        joinPath(importer_root, override_path)
      else:
        joinPath(importer_base, override_path)
    append_unique(searched, canonical_path(base_path))
    let root = find_package_root(base_path)
    if root.len == 0:
      raise_import_error(PACKAGE_ERR_NOT_FOUND,
        "Package path override '" & override_path & "' does not contain package.gene",
        importer_module = importer_module,
        package_name = package_name,
        searched = searched)
    return canonical_path(root)

  let dep_result = resolve_package_from_registry(package_name, importer_root, importer_base)
  if dep_result.root.len > 0:
    return canonical_path(dep_result.root)
  if dep_result.issue.len > 0:
    raise_import_error(PACKAGE_ERR_NOT_FOUND,
      "Invalid dependency override for package '" & package_name & "': " & dep_result.issue,
      importer_module = importer_module,
      package_name = package_name)

  let lock_result = resolve_package_from_lock(package_name, importer_root, importer_base)
  if lock_result.root.len > 0:
    return canonical_path(lock_result.root)
  if lock_result.issue.len > 0:
    raise_import_error(PACKAGE_ERR_INVALID_LOCK,
      "Invalid lockfile dependency for package '" & package_name & "': " & lock_result.issue,
      importer_module = importer_module,
      package_name = package_name)

  let deps_result = resolve_package_from_deps(package_name, importer_base)
  if deps_result.root.len > 0:
    return canonical_path(deps_result.root)
  if deps_result.ambiguous.len > 1:
    var candidates: seq[string] = @[]
    for candidate in deps_result.ambiguous:
      candidates.add(canonical_path(candidate))
    raise_import_error(PACKAGE_ERR_AMBIGUOUS,
      "Multiple materialized dependency roots match package '" & package_name & "'",
      importer_module = importer_module,
      package_name = package_name,
      candidates = candidates)

  let name_path = package_name.replace("/", $DirSep)
  # Walk search paths from importer_dir plus ancestors.
  var bases = package_search_paths(importer_base)
  var walk_dir = importer_base
  while walk_dir.len > 0:
    let parent = parentDir(walk_dir)
    if parent.len == 0 or parent == walk_dir:
      break
    bases.add(parent)
    walk_dir = parent

  var search_matches: seq[string] = @[]
  let last_part = package_name.split("/")[^1]
  for base in bases:
    let base_abs = canonical_path(base)
    append_unique(searched, base_abs)
    let candidate_full = joinPath(base_abs, name_path)
    append_unique(searched, canonical_path(candidate_full))
    if dirExists(candidate_full) or fileExists(candidate_full):
      let root = find_package_root(candidate_full)
      if package_root_matches_name(root, package_name):
        append_unique(search_matches, canonical_path(root))

    let candidate_short = joinPath(base_abs, last_part)
    append_unique(searched, canonical_path(candidate_short))
    if dirExists(candidate_short) or fileExists(candidate_short):
      let root = find_package_root(candidate_short)
      if package_root_matches_name(root, package_name):
        append_unique(search_matches, canonical_path(root))

  if search_matches.len == 1:
    return search_matches[0]
  if search_matches.len > 1:
    raise_import_error(PACKAGE_ERR_AMBIGUOUS,
      "Multiple package roots match package '" & package_name & "'",
      importer_module = importer_module,
      package_name = package_name,
      searched = searched,
      candidates = search_matches)

  # Fallback: try sibling of the current package root using the final segment.
  if importer_root.len > 0:
    let sibling = joinPath(parentDir(importer_root), last_part)
    append_unique(searched, canonical_path(sibling))
    if dirExists(sibling) or fileExists(sibling):
      let root = find_package_root(sibling)
      if package_root_matches_name(root, package_name):
        return canonical_path(root)

  raise_import_error(PACKAGE_ERR_NOT_FOUND,
    "Package '" & package_name & "' was not found",
    importer_module = importer_module,
    package_name = package_name,
    searched = searched)

proc find_native_build(pkg_root: string, resolved_path: string): string =
  ## Look for a compiled native module under build/ matching the module basename.
  let base = splitFile(resolved_path).name
  if pkg_root.len == 0 or base.len == 0:
    return ""
  let candidate = canonical_path(joinPath(pkg_root, "build", base))
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

proc extension_library_filename(name: string): string =
  ## Determine extension library filename (without directory).
  when defined(windows):
    result = "lib" & name & ".dll"
  elif defined(macosx):
    result = "lib" & name & ".dylib"
  else:
    result = "lib" & name & ".so"

proc extension_library_candidates(name: string): seq[string] =
  ## Candidate lookup paths for a genex extension library.
  let lib_name = extension_library_filename(name)

  # 1) Relative to cwd.
  result.add(extension_library_path(name))

  # 2) Relative to GENE_HOME (if provided).
  let gene_home = getEnv("GENE_HOME", "")
  if gene_home.len > 0:
    append_unique(result, joinPath(gene_home, "build", lib_name))

  # 3) Relative to the executable directory (e.g. <repo>/bin/gene -> <repo>/build).
  let app_file = getAppFilename()
  if app_file.len > 0:
    let app_dir = parentDir(app_file)
    if app_dir.len > 0:
      append_unique(result, joinPath(parentDir(app_dir), "build", lib_name))

proc ensure_genex_extension*(vm: ptr VirtualMachine, part: string): Value =
  ## Ensure a genex extension is loaded when accessing genex/<part>.
  if App == NIL or App.kind != VkApplication:
    return NIL
  if App.app.genex_ns.kind != VkNamespace:
    return NIL

  let key = part.to_key()
  var member = App.app.genex_ns.ref.ns.members.getOrDefault(key, NIL)

  if member == NIL:
    when defined(gene_wasm):
      raise_wasm_unsupported("dynamic_extension_loading")
    when not defined(noExtensions):
      let candidates = extension_library_candidates(part)
      var ext_path = ""
      for candidate in candidates:
        if fileExists(candidate):
          ext_path = candidate
          break
      if ext_path.len == 0:
        # Missing extension is treated as unavailable so callers can probe with
        # conditionals like: (if genex/sqlite ... else ...).
        return NIL
      let ext_ns = load_extension(vm, ext_path)
      if ext_ns == nil:
        not_allowed("[GENE.EXT.INIT_FAILED] Extension did not publish namespace: " & ext_path)
      member = ext_ns.to_value()
      App.app.genex_ns.ref.ns.members[key] = member
  return member

proc try_member_missing_handlers*(vm: ptr VirtualMachine, ns: Namespace, name: string): Value =
  ## Try each on_member_missing handler on a namespace.
  ## Returns the first non-NIL result (cached in ns.members), or NIL.
  ## The namespace is passed as self (for IkSelf//.name) but not to the matcher.
  if ns.on_member_missing.len == 0:
    return NIL
  let name_val = name.to_value()
  # Create a namespace Value for self
  let ns_ref = new_ref(VkNamespace)
  ns_ref.ns = ns
  let ns_value = ns_ref.to_ref_value()
  for handler in ns.on_member_missing:
    let handler_result = vm_exec_callable_with_self(vm, handler, ns_value, @[name_val])
    if handler_result != NIL:
      ns.members[name.to_key()] = handler_result
      return handler_result
  return NIL

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
    if next == NIL:
      next = try_member_missing_handlers(vm, current.ref.ns, part)
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
  let abs_path = canonical_path(path)
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
  let cache_key = canonical_path(path)
  # Check cache first
  if ModuleCache.hasKey(cache_key):
    return ModuleCache[cache_key]
  
  # Create namespace for module
  let module_ns = new_namespace(App.app.global_ns.ref.ns, cache_key)
  module_ns.members["__is_main__".to_key()] = FALSE
  module_ns.members["__module_name__".to_key()] = cache_key.to_value()
  module_ns.members["gene".to_key()] = App.app.gene_ns
  module_ns.members["genex".to_key()] = App.app.genex_ns
  bind_module_package_context(module_ns, cache_key)
  
  # Compile the module to ensure it's valid
  discard compile_module(cache_key)
  
  # The VM will execute this module when needed
  # For now, just cache the empty namespace
  # The actual execution will happen when the import is processed
  
  # Cache the module
  ModuleCache[cache_key] = module_ns
  
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

  when defined(gene_wasm):
    raise_wasm_unsupported("module_file_loading")
  
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
  let importer_dir =
    if importer_module.len > 0: canonical_path(parentDir(importer_module))
    else: canonical_path(getCurrentDir())

  var resolved_path = raw_module_path
  var is_gir = false

  var package_root = ""

  if package_name.len > 0:
    if package_path_override.len == 0:
      validate_package_name(package_name)
    package_root = locate_package_root(package_name, importer_dir, package_path_override, importer_module)
    if raw_module_path == "index":
      let entry = resolve_package_entrypoint(package_root, importer_module, package_name)
      resolved_path = entry.path
      is_gir = entry.is_gir
    else:
      let (p, girFlag) = resolve_module_path(raw_module_path, importer_dir, package_root, package_name,
        importer_module = importer_module, enforce_package_boundary = true)
      resolved_path = p
      is_gir = girFlag
  else:
    package_root = find_package_root(importer_dir)
    if is_native:
      let native_path = resolve_native_module(raw_module_path, importer_dir, package_root, "")
      if native_path.len == 0:
        raise_import_error(MODULE_ERR_NOT_FOUND, "Native module '" & raw_module_path & "' was not found",
          importer_module = importer_module, specifier = raw_module_path)
      resolved_path = native_path
      is_gir = false
    else:
      let (p, girFlag) = resolve_module_path(raw_module_path, importer_dir, package_root, "",
        importer_module = importer_module)
      resolved_path = p
      is_gir = girFlag

  if is_native and resolved_path.len == 0:
    let native_path = resolve_native_module(raw_module_path, importer_dir, package_root, package_name)
    if native_path.len == 0:
      raise_import_error(MODULE_ERR_NOT_FOUND, "Native module '" & raw_module_path & "' was not found",
        importer_module = importer_module, specifier = raw_module_path, package_name = package_name)
    resolved_path = native_path
    is_gir = false

  if not is_native:
    let native_candidate = find_native_build(package_root, resolved_path)
    if native_candidate.len > 0:
      resolved_path = native_candidate
      is_native = true

  resolved_path = canonical_path(resolved_path)
  if package_name.len > 0 and package_root.len > 0 and resolved_path.len > 0:
    let package_root_abs = canonical_path(package_root)
    if not path_within(package_root_abs, resolved_path):
      raise_import_error(PACKAGE_ERR_BOUNDARY,
        "Resolved import path escapes package root",
        importer_module = importer_module,
        specifier = raw_module_path,
        package_name = package_name,
        candidates = @[resolved_path])

  # Check cache first
  if ModuleCache.hasKey(resolved_path):
    let module_ns = ModuleCache[resolved_path]
    bind_module_package_context(module_ns, resolved_path, package_name, package_root)
    return (resolved_path, imports, module_ns, is_native, false)
  
  # Module not cached, need to compile and execute it (or load as native)
  let module_ns = new_namespace(App.app.global_ns.ref.ns, resolved_path)
  module_ns.members["__is_main__".to_key()] = FALSE
  module_ns.members["__module_name__".to_key()] = resolved_path.to_value()
  module_ns.members["gene".to_key()] = App.app.gene_ns
  module_ns.members["genex".to_key()] = App.app.genex_ns
  bind_module_package_context(module_ns, resolved_path, package_name, package_root)
  if is_gir:
    module_ns.members["__compiled__".to_key()] = TRUE
  return (resolved_path, imports, module_ns, is_native, false)
