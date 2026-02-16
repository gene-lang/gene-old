import std/[algorithm, json, os, osproc, sequtils, strtabs, strutils, tables, tempfiles]

import ../gene/parser
import ../gene/types except Exception
import ./base

const
  DEFAULT_COMMAND = "deps"
  COMMANDS = @[DEFAULT_COMMAND]
  LOCKFILE_NAME = "package.gene.lock"

type
  DepsError = object of CatchableError

  DepsAction = enum
    DaInstall
    DaUpdate
    DaVerify
    DaGc
    DaClean
    DaHelp

  DependencySpec = object
    name: string
    version_expr: string
    path: string
    git: string
    commit: string
    tag: string
    branch: string
    subdir: string

  PackageManifest = object
    package_root: string
    name: string
    version: string
    globals: seq[string]
    singleton: bool
    native: bool
    native_build: seq[string]
    dependencies: seq[DependencySpec]

  LockSource = object
    source_type: string
    url: string
    path: string
    tag: string
    branch: string
    commit: string
    subdir: string

  LockNode = ref object
    name: string
    resolved: string
    node_id: string
    abs_dir: string
    rel_dir: string
    source: LockSource
    sha256: string
    singleton: bool
    dependencies: OrderedTable[string, string]

  ParsedLockNode = object
    node_id: string
    rel_dir: string
    sha256: string
    source_type: string

  ParsedLock = object
    lock_version: int
    root_dependencies: OrderedTable[string, string]
    nodes: OrderedTable[string, ParsedLockNode]

  DepsOptions = object
    action: DepsAction
    root_dir: string
    allow_native: bool
    update_target: string

  ResolverState = ref object
    project_root: string
    deps_root: string
    tmp_root: string
    lock_path: string
    gene_source_dir: string
    gene_bin: string
    allow_native: bool
    root_dependencies: OrderedTable[string, string]
    nodes: OrderedTable[string, LockNode]
    singleton_nodes: Table[string, string]
    existing_lock: ParsedLock
    warnings: seq[string]

let help_text = """
Usage: gene deps <subcommand> [options]

Subcommands:
  install               Resolve and install dependencies from package.gene
  update [name]         Re-resolve dependencies and rewrite package.gene.lock (targeted update not selective yet)
  verify                Verify package.gene.lock graph + hashes against .gene/deps
  gc                    Remove unreferenced dependency directories under .gene/deps
  clean                 Remove .gene/tmp staging artifacts

Options:
  --root <dir>          Project/package root (defaults to nearest ancestor with package.gene)
  --allow-native        Allow native build command execution during install/update
  -h, --help            Show this help
"""

proc deps_error(msg: string) {.noreturn.} =
  raise newException(DepsError, msg)

proc normalize_rel_path(path: string): string =
  result = path.replace('\\', '/')

proc key_to_symbol_name(k: Key): string =
  get_symbol(symbol_index(k))

proc value_as_string(v: Value, context: string): string =
  case v.kind
  of VkString:
    v.str
  of VkSymbol:
    v.str
  else:
    deps_error(context & ": expected string/symbol, got " & $v.kind)

proc value_as_bool(v: Value): bool =
  case v.kind
  of VkBool:
    v == TRUE
  of VkInt:
    v.to_int() != 0
  else:
    false

proc value_as_string_array(v: Value, context: string): seq[string] =
  if v.kind != VkArray:
    deps_error(context & ": expected array, got " & $v.kind)
  for item in array_data(v):
    result.add(value_as_string(item, context))

proc normalize_manifest_key(raw: string): string =
  if raw.len > 0 and raw[0] == '^':
    raw[1 .. ^1]
  else:
    raw

proc apply_manifest_pair(manifest: var PackageManifest, key: string, value: Value, context: string) =
  case key
  of "name":
    manifest.name = value_as_string(value, context & " ^name")
  of "version":
    manifest.version = value_as_string(value, context & " ^version")
  of "globals":
    manifest.globals = value_as_string_array(value, context & " ^globals")
  of "singleton":
    manifest.singleton = value_as_bool(value)
  of "native":
    manifest.native = value_as_bool(value)
  of "native-build":
    manifest.native_build = value_as_string_array(value, context & " ^native-build")
  of "dependencies":
    if value.kind != VkArray:
      deps_error(context & " ^dependencies: expected array, got " & $value.kind)
    for item in array_data(value):
      if item.kind != VkGene or item.gene.type.kind != VkSymbol or item.gene.type.str != "$dep":
        deps_error(context & " ^dependencies: expected ($dep ...), got " & $item)
      if item.gene.children.len < 1:
        deps_error(context & " ^dependencies: $dep requires package name")
      var dep = DependencySpec()
      dep.name = value_as_string(item.gene.children[0], context & " dependency name")
      if item.gene.children.len >= 2:
        dep.version_expr = value_as_string(item.gene.children[1], context & " dependency version")

      for k, v in item.gene.props:
        let prop = key_to_symbol_name(k)
        case prop
        of "path":
          dep.path = value_as_string(v, context & " dependency ^path")
        of "git":
          dep.git = value_as_string(v, context & " dependency ^git")
        of "commit":
          dep.commit = value_as_string(v, context & " dependency ^commit")
        of "tag":
          dep.tag = value_as_string(v, context & " dependency ^tag")
        of "branch":
          dep.branch = value_as_string(v, context & " dependency ^branch")
        of "subdir":
          dep.subdir = value_as_string(v, context & " dependency ^subdir")
        else:
          discard

      manifest.dependencies.add(dep)
  else:
    discard

proc parse_manifest(path: string, package_root: string): PackageManifest =
  if not fileExists(path):
    deps_error("Manifest not found: " & path)

  result = PackageManifest(package_root: package_root)
  let nodes = read_all(readFile(path))
  if nodes.len == 0:
    return

  if nodes.len == 1 and nodes[0].kind == VkMap:
    for k, v in map_data(nodes[0]):
      let key = normalize_manifest_key(key_to_symbol_name(k))
      apply_manifest_pair(result, key, v, path)
    return

  var i = 0
  while i < nodes.len:
    let key_node = nodes[i]
    if key_node.kind == VkSymbol:
      let key = normalize_manifest_key(key_node.str)
      if i + 1 >= nodes.len:
        deps_error(path & ": missing value for key " & key_node.str)
      apply_manifest_pair(result, key, nodes[i + 1], path)
      i += 2
    else:
      inc(i)

proc find_package_root(start: string): string =
  var dir = absolutePath(start)
  if fileExists(dir):
    dir = parentDir(dir)
  while dir.len > 0:
    if fileExists(joinPath(dir, "package.gene")):
      return dir
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  return ""

proc looks_like_gene_source_tree(path: string): bool =
  dirExists(joinPath(path, "src", "gene")) and fileExists(joinPath(path, "gene.nimble"))

proc detect_gene_source_dir(): string =
  let env_override = getEnv("GENE_SOURCE_DIR")
  if env_override.len > 0:
    return absolutePath(env_override)

  let exe_candidate = absolutePath(joinPath(parentDir(getAppFilename()), ".."))
  if looks_like_gene_source_tree(exe_candidate):
    return exe_candidate

  exe_candidate

proc ensure_dir(path: string) =
  if not dirExists(path):
    createDir(path)

proc run_cmd(cmd: string, cwd: string = "", env: StringTableRef = nil): string =
  let res = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut}, env = env, workingDir = cwd)
  if res.exitCode != 0:
    deps_error("Command failed (" & $res.exitCode & "): " & cmd & "\n" & res.output)
  res.output.strip()

proc try_hash_cmd(path: string): string =
  if findExe("shasum").len > 0:
    let hash_output = run_cmd("shasum -a 256 " & quoteShell(path))
    let tokens = hash_output.splitWhitespace()
    if tokens.len > 0:
      return tokens[0]
  if findExe("sha256sum").len > 0:
    let hash_output = run_cmd("sha256sum " & quoteShell(path))
    let tokens = hash_output.splitWhitespace()
    if tokens.len > 0:
      return tokens[0]
  if findExe("openssl").len > 0:
    let hash_output = run_cmd("openssl dgst -sha256 " & quoteShell(path))
    let tokens = hash_output.splitWhitespace()
    if tokens.len > 0:
      return tokens[^1]
  deps_error("No SHA-256 tool found. Install shasum, sha256sum, or openssl.")

proc file_hash_sha256(path: string): string =
  try_hash_cmd(path)

proc text_hash_sha256(content: string): string =
  var (tmp_file, tmp_path) = createTempFile("gene_deps_hash_", ".tmp")
  defer:
    if tmp_file != nil:
      close(tmp_file)
    if fileExists(tmp_path):
      removeFile(tmp_path)
  tmp_file.write(content)
  tmp_file.flushFile()
  close(tmp_file)
  tmp_file = nil
  file_hash_sha256(tmp_path)

proc should_skip_hash_rel(rel_path: string): bool =
  let p = normalize_rel_path(rel_path)
  if p == LOCKFILE_NAME:
    return true
  if p.startsWith(".git/") or p == ".git":
    return true
  if p.startsWith(".gene/") or p == ".gene":
    return true
  if p.startsWith("build/") or p == "build":
    return true
  return false

proc dir_hash_sha256(root_dir: string): string =
  if not dirExists(root_dir):
    deps_error("Directory not found for hashing: " & root_dir)
  var files: seq[string] = @[]
  for path in walkDirRec(root_dir):
    let rel = normalize_rel_path(relativePath(path, root_dir))
    if should_skip_hash_rel(rel):
      continue
    files.add(rel)
  files.sort(cmp[string])

  var digest_input = ""
  for rel in files:
    let abs_path = joinPath(root_dir, rel.replace('/', DirSep))
    digest_input &= rel & "\t" & file_hash_sha256(abs_path) & "\n"
  text_hash_sha256(digest_input)

proc path_within(root: string, candidate: string): bool =
  let root_abs = normalize_rel_path(absolutePath(root))
  let cand_abs = normalize_rel_path(absolutePath(candidate))
  let rel = normalize_rel_path(relativePath(cand_abs, root_abs))
  rel == "." or (not rel.startsWith("../") and rel != "..")

proc sanitize_id(raw: string): string =
  result = raw
  for ch in result.mitems:
    if not (ch.isAlphaNumeric or ch in {'-', '_', '.'}):
      ch = '_'
  if result.len == 0:
    result = "local"

proc parse_name(name: string): (string, string) =
  let parts = name.split('/')
  if parts.len != 2:
    deps_error("Package name must be <parent>/<pkg>: " & name)
  (parts[0], parts[1])

proc short_commit(hash: string): string =
  if hash.len >= 8:
    hash[0 .. 7]
  else:
    hash

proc semver_from_tag(tag: string): string =
  var t = tag.strip()
  if t.len > 0 and t[0] == 'v':
    t = t[1 .. ^1]
  let parts = t.split('.')
  if parts.len != 3:
    return ""
  for part in parts:
    if part.len == 0:
      return ""
    for ch in part:
      if not ch.isDigit:
        return ""
  return t

proc copy_tree_filtered(src: string, dst: string) =
  if not dirExists(src):
    deps_error("Dependency source path does not exist: " & src)
  if dirExists(dst):
    removeDir(dst)
  createDir(dst)

  for kind, path in walkDir(src):
    let name = lastPathPart(path)
    if kind == pcDir:
      if name in [".git", ".gene", "build"]:
        continue
      copy_tree_filtered(path, joinPath(dst, name))
    elif kind == pcFile:
      if name == LOCKFILE_NAME:
        continue
      copyFile(path, joinPath(dst, name))

proc emit_bool(v: bool): string =
  if v: "true" else: "false"

proc emit_string(s: string): string =
  escapeJson(s)

proc emit_symbol_key(k: string): string =
  "^" & k

proc write_lockfile(state: ResolverState) =
  var output_text = ""
  proc line(level: int, text: string) =
    output_text &= repeat("  ", level) & text & "\n"

  line(0, "{")
  line(1, "^lock_version 1")

  line(1, "^root_dependencies {")
  var root_names = toSeq(state.root_dependencies.keys)
  root_names.sort(cmp[string])
  for name in root_names:
    line(2, emit_symbol_key(name) & " " & emit_string(state.root_dependencies[name]))
  line(1, "}")

  line(1, "^packages {")
  var node_ids = toSeq(state.nodes.keys)
  node_ids.sort(cmp[string])
  for node_id in node_ids:
    let node = state.nodes[node_id]
    line(2, emit_symbol_key(node.node_id) & " {")
    line(3, "^name " & emit_string(node.name))
    line(3, "^resolved " & emit_string(node.resolved))
    line(3, "^node_id " & emit_string(node.node_id))
    line(3, "^dir " & emit_string(node.rel_dir))

    line(3, "^source {")
    line(4, "^type " & emit_string(node.source.source_type))
    if node.source.url.len > 0:
      line(4, "^url " & emit_string(node.source.url))
    if node.source.path.len > 0:
      line(4, "^path " & emit_string(node.source.path))
    if node.source.tag.len > 0:
      line(4, "^tag " & emit_string(node.source.tag))
    if node.source.branch.len > 0:
      line(4, "^branch " & emit_string(node.source.branch))
    if node.source.commit.len > 0:
      line(4, "^commit " & emit_string(node.source.commit))
    if node.source.subdir.len > 0:
      line(4, "^subdir " & emit_string(node.source.subdir))
    line(3, "}")

    line(3, "^sha256 " & emit_string(node.sha256))
    line(3, "^singleton " & emit_bool(node.singleton))

    line(3, "^dependencies {")
    var deps = toSeq(node.dependencies.keys)
    deps.sort(cmp[string])
    for dep_name in deps:
      line(4, emit_symbol_key(dep_name) & " " & emit_string(node.dependencies[dep_name]))
    line(3, "}")
    line(2, "}")
  line(1, "}")
  line(0, "}")

  writeFile(state.lock_path, output_text)

proc map_lookup(map_val: Value, key: string): Value =
  if map_val.kind != VkMap:
    return NIL
  map_data(map_val).getOrDefault(key.to_key(), NIL)

proc parse_lockfile(path: string): ParsedLock =
  result = ParsedLock(
    lock_version: 0,
    root_dependencies: initOrderedTable[string, string](),
    nodes: initOrderedTable[string, ParsedLockNode]()
  )
  if not fileExists(path):
    return

  let forms = read_all(readFile(path))
  if forms.len == 0 or forms[0].kind != VkMap:
    deps_error("Invalid lockfile format: " & path)
  let root_map = forms[0]

  let lock_v = map_lookup(root_map, "lock_version")
  if lock_v.kind != VkInt:
    deps_error("Invalid lockfile: missing ^lock_version in " & path)
  result.lock_version = lock_v.to_int().int
  if result.lock_version > 1:
    deps_error("Lockfile version " & $result.lock_version &
      " is not supported by this Gene build. Upgrade Gene or regenerate lockfile with gene deps update.")

  let root_deps = map_lookup(root_map, "root_dependencies")
  if root_deps.kind == VkMap:
    for k, v in map_data(root_deps):
      result.root_dependencies[key_to_symbol_name(k)] = value_as_string(v, "lock root dependency")

  let packages = map_lookup(root_map, "packages")
  if packages.kind != VkMap:
    return

  for k, v in map_data(packages):
    if v.kind != VkMap:
      continue
    var node = ParsedLockNode()
    node.node_id = key_to_symbol_name(k)
    node.rel_dir = value_as_string(map_lookup(v, "dir"), "lock node " & node.node_id & " ^dir")
    node.sha256 = value_as_string(map_lookup(v, "sha256"), "lock node " & node.node_id & " ^sha256")
    let source_val = map_lookup(v, "source")
    if source_val.kind == VkMap:
      let source_type = map_lookup(source_val, "type")
      if source_type.kind == VkString:
        node.source_type = source_type.str
    result.nodes[node.node_id] = node

proc run_native_build(state: ResolverState, node: LockNode, manifest: PackageManifest) =
  if not manifest.native:
    return
  if manifest.native_build.len == 0:
    deps_error("Native package " & node.name & " is missing ^native-build commands")

  if not state.allow_native:
    state.warnings.add("Native build skipped for " & node.name & " (use --allow-native)")
    return

  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  if not dirExists(state.gene_source_dir):
    deps_error("Native build requires Gene source checkout; GENE_SOURCE_DIR not found: " & state.gene_source_dir)
  env["GENE_SOURCE_DIR"] = state.gene_source_dir
  env["GENE_BIN"] = state.gene_bin
  env["GENE_PACKAGE_DIR"] = node.abs_dir

  for cmd in manifest.native_build:
    discard run_cmd(cmd, node.abs_dir, env)

proc existing_path_drift_warning(state: ResolverState, node: LockNode) =
  if not state.existing_lock.nodes.hasKey(node.node_id):
    return
  let old = state.existing_lock.nodes[node.node_id]
  if old.source_type == "path" and old.sha256 != node.sha256:
    state.warnings.add("Path dependency drift: " & node.name & " (" & old.sha256 & " -> " & node.sha256 & ")")

proc validate_dependency_source(dep: DependencySpec) =
  if dep.subdir.len > 0 and dep.git.len > 0:
    deps_error("Dependency " & dep.name & " cannot combine ^subdir with ^git")

  let ref_count =
    (if dep.commit.len > 0: 1 else: 0) +
    (if dep.tag.len > 0: 1 else: 0) +
    (if dep.branch.len > 0: 1 else: 0)
  if ref_count > 1:
    deps_error("Dependency " & dep.name & " can specify at most one of ^commit, ^tag, ^branch")

  if dep.git.len == 0 and ref_count > 0:
    deps_error("Dependency " & dep.name & " uses ^commit/^tag/^branch without ^git")
  if (dep.path.len > 0 or dep.subdir.len > 0) and ref_count > 0:
    deps_error("Dependency " & dep.name & " cannot combine ^path/^subdir with ^commit/^tag/^branch")

proc resolve_dependency(state: ResolverState, dep: DependencySpec, owner_root: string, stack: seq[string]): LockNode
proc verify_lock(root: string): string

proc resolve_manifest_dependencies(state: ResolverState, manifest: PackageManifest, owner_root: string, owner_node: LockNode, stack: seq[string]) =
  var seen = initTable[string, string]()
  for dep in manifest.dependencies:
    let child = resolve_dependency(state, dep, owner_root, stack)
    if seen.hasKey(dep.name) and seen[dep.name] != child.node_id:
      deps_error("Dependency conflict in " & (if owner_node != nil: owner_node.name else: manifest.name) &
        ": " & dep.name & " resolves to multiple versions (" & seen[dep.name] & " vs " & child.node_id & ")")
    seen[dep.name] = child.node_id
    if owner_node == nil:
      state.root_dependencies[dep.name] = child.node_id
    else:
      owner_node.dependencies[dep.name] = child.node_id

proc resolve_dependency(state: ResolverState, dep: DependencySpec, owner_root: string, stack: seq[string]): LockNode =
  if dep.name.len == 0:
    deps_error("Dependency with empty name")
  validate_dependency_source(dep)

  let (parent_name, pkg_name) = parse_name(dep.name)
  if dep.path.len == 0 and dep.git.len == 0 and dep.subdir.len == 0:
    deps_error("Dependency " & dep.name & " must define one source: ^path, ^subdir, or ^git")

  var source = LockSource()
  var source_abs = ""
  var source_manifest = PackageManifest()
  var commit_hash = ""
  var resolved = ""
  var resolved_id = ""
  var target_abs = ""
  var node_id = ""

  if dep.subdir.len > 0 or dep.path.len > 0:
    source.source_type = "path"
    if dep.subdir.len > 0:
      let candidate = absolutePath(joinPath(owner_root, dep.subdir))
      if not path_within(owner_root, candidate):
        deps_error("Dependency " & dep.name & " ^subdir escapes package root: " & dep.subdir)
      source_abs = candidate
      source.subdir = dep.subdir
      source.path = dep.subdir
    else:
      source_abs =
        if dep.path.isAbsolute: absolutePath(dep.path)
        else: absolutePath(joinPath(owner_root, dep.path))
      source.path = dep.path
    if not dirExists(source_abs):
      deps_error("Dependency source not found for " & dep.name & ": " & source_abs)

    source_manifest = parse_manifest(joinPath(source_abs, "package.gene"), source_abs)
    if source_manifest.version.len > 0:
      resolved = source_manifest.version
    elif dep.version_expr.len > 0 and dep.version_expr != "*":
      resolved = sanitize_id(dep.version_expr)
    else:
      resolved = "local"
    resolved_id = sanitize_id(resolved)
    node_id = dep.name & "@" & resolved_id

    if node_id in stack:
      let start = stack.find(node_id)
      var cycle_path = if start >= 0: stack[start .. ^1] else: stack
      cycle_path.add(node_id)
      deps_error("Dependency cycle detected: " & cycle_path.join(" -> "))

    if state.nodes.hasKey(node_id):
      return state.nodes[node_id]

    target_abs = absolutePath(joinPath(state.deps_root, parent_name, pkg_name, resolved_id))
    if dirExists(target_abs):
      removeDir(target_abs)
    ensure_dir(parentDir(target_abs))
    copy_tree_filtered(source_abs, target_abs)
  else:
    source.source_type = "git"
    source.url = dep.git
    source.tag = dep.tag
    source.branch = dep.branch
    source.commit = dep.commit

    let staging = createTempDir("gene_dep_", "", state.tmp_root)
    let staging_repo = joinPath(staging, "repo")
    try:
      if dep.commit.len > 0:
        discard run_cmd("git clone " & quoteShell(dep.git) & " " & quoteShell(staging_repo))
        discard run_cmd("git checkout " & quoteShell(dep.commit), staging_repo)
      elif dep.tag.len > 0:
        discard run_cmd("git clone --depth 1 --branch " & quoteShell(dep.tag) & " " &
          quoteShell(dep.git) & " " & quoteShell(staging_repo))
      elif dep.branch.len > 0:
        discard run_cmd("git clone --depth 1 --branch " & quoteShell(dep.branch) & " " &
          quoteShell(dep.git) & " " & quoteShell(staging_repo))
      else:
        discard run_cmd("git clone --depth 1 " & quoteShell(dep.git) & " " & quoteShell(staging_repo))

      commit_hash = run_cmd("git rev-parse HEAD", staging_repo)
      source.commit = commit_hash

      let tag_semver = semver_from_tag(dep.tag)
      if dep.commit.len > 0:
        resolved = "sha-" & short_commit(commit_hash)
      elif dep.branch.len > 0:
        resolved = "sha-" & short_commit(commit_hash)
      elif dep.tag.len > 0:
        if tag_semver.len > 0:
          resolved = tag_semver
        elif dep.version_expr.len > 0 and dep.version_expr != "*":
          resolved = sanitize_id(dep.version_expr)
        else:
          deps_error("Dependency " & dep.name &
            " uses non-semver ^tag without explicit version expression")
      else:
        resolved = "sha-" & short_commit(commit_hash)

      resolved_id = sanitize_id(resolved)
      node_id = dep.name & "@" & resolved_id

      if node_id in stack:
        let start = stack.find(node_id)
        var cycle_path = if start >= 0: stack[start .. ^1] else: stack
        cycle_path.add(node_id)
        deps_error("Dependency cycle detected: " & cycle_path.join(" -> "))

      if state.nodes.hasKey(node_id):
        return state.nodes[node_id]

      target_abs = absolutePath(joinPath(state.deps_root, parent_name, pkg_name, resolved_id))
      if dirExists(target_abs):
        removeDir(target_abs)
      ensure_dir(parentDir(target_abs))
      moveDir(staging_repo, target_abs)
    finally:
      if dirExists(staging):
        removeDir(staging)

  if target_abs.len == 0:
    deps_error("Internal error: dependency target directory was not materialized for " & dep.name)
  if node_id.len == 0:
    deps_error("Internal error: dependency node id missing for " & dep.name)

  let rel_dir = normalize_rel_path(relativePath(target_abs, state.project_root))
  let hash = dir_hash_sha256(target_abs)
  let node = LockNode(
    name: dep.name,
    resolved: resolved_id,
    node_id: node_id,
    abs_dir: target_abs,
    rel_dir: rel_dir,
    source: source,
    sha256: hash,
    singleton: false,
    dependencies: initOrderedTable[string, string]()
  )
  state.nodes[node_id] = node
  existing_path_drift_warning(state, node)

  let pkg_manifest = source_manifest
  node.singleton = pkg_manifest.singleton or pkg_manifest.globals.len > 0
  if node.singleton:
    if state.singleton_nodes.hasKey(node.name) and state.singleton_nodes[node.name] != node.node_id:
      deps_error("Global-state conflict: " & node.name &
        " requested as " & state.singleton_nodes[node.name] & " and " & node.node_id)
    state.singleton_nodes[node.name] = node.node_id

  run_native_build(state, node, pkg_manifest)
  resolve_manifest_dependencies(state, pkg_manifest, target_abs, node, stack & @[node_id])
  return node

proc resolve_and_write_lock(root: string, allow_native: bool, update_target: string, action_label: string): string =
  let package_root = find_package_root(root)
  if package_root.len == 0:
    deps_error("Could not find package.gene from: " & root)

  let deps_root = absolutePath(joinPath(package_root, ".gene", "deps"))
  let tmp_root = absolutePath(joinPath(package_root, ".gene", "tmp"))
  ensure_dir(absolutePath(joinPath(package_root, ".gene")))
  ensure_dir(deps_root)
  ensure_dir(tmp_root)

  let lock_path = absolutePath(joinPath(package_root, LOCKFILE_NAME))
  let gene_source_dir = detect_gene_source_dir()
  let gene_bin = absolutePath(getAppFilename())
  var state = ResolverState(
    project_root: package_root,
    deps_root: deps_root,
    tmp_root: tmp_root,
    lock_path: lock_path,
    gene_source_dir: gene_source_dir,
    gene_bin: gene_bin,
    allow_native: allow_native,
    root_dependencies: initOrderedTable[string, string](),
    nodes: initOrderedTable[string, LockNode](),
    singleton_nodes: initTable[string, string](),
    existing_lock: parse_lockfile(lock_path),
    warnings: @[]
  )

  let root_manifest = parse_manifest(joinPath(package_root, "package.gene"), package_root)
  if update_target.len > 0:
    state.warnings.add("Targeted update is not yet selective; updating full dependency graph (requested: " & update_target & ")")
  resolve_manifest_dependencies(state, root_manifest, package_root, nil, @["<root>"])
  write_lockfile(state)

  var lines: seq[string] = @[
    action_label,
    "root dependencies: " & $state.root_dependencies.len,
    "resolved nodes: " & $state.nodes.len,
    "lockfile: " & normalize_rel_path(relativePath(lock_path, package_root))
  ]
  for warning in state.warnings:
    lines.add("warning: " & warning)
  lines.join("\n")

proc install_deps(root: string, allow_native: bool): string =
  let package_root = find_package_root(root)
  if package_root.len == 0:
    deps_error("Could not find package.gene from: " & root)

  let lock_path = absolutePath(joinPath(package_root, LOCKFILE_NAME))
  if fileExists(lock_path):
    let verify_output = verify_lock(package_root)
    return "deps install complete\nmode: lockfile\n" & verify_output

  resolve_and_write_lock(package_root, allow_native, "", "deps install complete")

proc update_deps(root: string, allow_native: bool, update_target: string): string =
  resolve_and_write_lock(root, allow_native, update_target, "deps update complete")

proc verify_lock(root: string): string =
  let package_root = find_package_root(root)
  if package_root.len == 0:
    deps_error("Could not find package.gene from: " & root)
  let lock_path = absolutePath(joinPath(package_root, LOCKFILE_NAME))
  if not fileExists(lock_path):
    deps_error("Lockfile not found: " & lock_path)

  let lock = parse_lockfile(lock_path)
  var failures: seq[string] = @[]

  for node_id, node in lock.nodes:
    let abs_dir = absolutePath(joinPath(package_root, node.rel_dir))
    if not dirExists(abs_dir):
      failures.add("missing directory for " & node_id & ": " & node.rel_dir)
      continue
    let actual = dir_hash_sha256(abs_dir)
    if actual != node.sha256:
      failures.add("hash mismatch for " & node_id & ": expected " & node.sha256 & ", got " & actual)

  if failures.len > 0:
    deps_error("verify failed:\n" & failures.join("\n"))
  "deps verify complete\nchecked nodes: " & $lock.nodes.len

proc clean_tmp(root: string): string =
  let package_root = find_package_root(root)
  if package_root.len == 0:
    deps_error("Could not find package.gene from: " & root)
  let tmp_root = absolutePath(joinPath(package_root, ".gene", "tmp"))
  if dirExists(tmp_root):
    removeDir(tmp_root)
  "deps clean complete"

proc gc_deps(root: string): string =
  let package_root = find_package_root(root)
  if package_root.len == 0:
    deps_error("Could not find package.gene from: " & root)
  let deps_root = absolutePath(joinPath(package_root, ".gene", "deps"))
  let lock_path = absolutePath(joinPath(package_root, LOCKFILE_NAME))
  if not fileExists(lock_path):
    deps_error("Lockfile not found: " & lock_path)
  if not dirExists(deps_root):
    return "deps gc complete\nremoved nodes: 0"

  let lock = parse_lockfile(lock_path)
  var keep = initTable[string, bool]()
  for _, node in lock.nodes:
    keep[normalize_rel_path(node.rel_dir)] = true

  var removed = 0
  for parent_kind, parent_path in walkDir(deps_root):
    if parent_kind != pcDir:
      continue
    for pkg_kind, pkg_path in walkDir(parent_path):
      if pkg_kind != pcDir:
        continue
      for ver_kind, ver_path in walkDir(pkg_path):
        if ver_kind != pcDir:
          continue
        let rel = normalize_rel_path(relativePath(ver_path, package_root))
        if not keep.hasKey(rel):
          removeDir(ver_path)
          inc(removed)

  "deps gc complete\nremoved nodes: " & $removed

proc parse_options(args: seq[string]): DepsOptions =
  if args.len == 0:
    return DepsOptions(action: DaHelp)

  case args[0]
  of "install":
    result.action = DaInstall
  of "update":
    result.action = DaUpdate
  of "verify":
    result.action = DaVerify
  of "gc":
    result.action = DaGc
  of "clean":
    result.action = DaClean
  of "-h", "--help", "help":
    result.action = DaHelp
  else:
    deps_error("Unknown deps subcommand: " & args[0])

  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--allow-native":
      result.allow_native = true
      inc(i)
      continue
    if arg == "--root":
      if i + 1 >= args.len:
        deps_error("--root requires a directory path")
      result.root_dir = args[i + 1]
      i += 2
      continue
    if result.action == DaUpdate and result.update_target.len == 0 and not arg.startsWith("-"):
      result.update_target = arg
      inc(i)
      continue
    deps_error("Unknown argument: " & arg)

proc handle*(cmd: string, args: seq[string]): CommandResult =
  try:
    let options = parse_options(args)
    if options.action == DaHelp:
      return success(help_text.strip())

    let root =
      if options.root_dir.len > 0: options.root_dir
      else: getCurrentDir()

    case options.action
    of DaInstall:
      success(install_deps(root, options.allow_native))
    of DaUpdate:
      success(update_deps(root, options.allow_native, options.update_target))
    of DaVerify:
      success(verify_lock(root))
    of DaGc:
      success(gc_deps(root))
    of DaClean:
      success(clean_tmp(root))
    of DaHelp:
      success(help_text.strip())
  except DepsError as e:
    failure(e.msg)
  except ParseError as e:
    failure("Parse error: " & e.msg)
  except CatchableError as e:
    failure(e.msg)

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("deps <install|update|verify|gc|clean>: manage package dependencies")
  manager.add_help("  deps install [--root <dir>] [--allow-native]")
  manager.add_help("  deps verify [--root <dir>]")

when isMainModule:
  let cmd = DEFAULT_COMMAND
  let result = handle(cmd, commandLineParams())
  if result.success:
    if result.output.len > 0:
      echo result.output
  else:
    if result.error.len > 0:
      stderr.writeLine("Error: " & result.error)
    quit(1)
