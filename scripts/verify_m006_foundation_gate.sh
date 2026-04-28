#!/usr/bin/env bash
# Repeatable M006/S05 Gradual Typing Coherence Foundation gate.
# Run from the repository root with:
#   bash scripts/verify_m006_foundation_gate.sh

set -euo pipefail

phase() {
  printf '\n== %s ==\n' "$1"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "required tracked input is missing: $path"
}

require_executable_or_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "required command/file is missing: $path"
}

require_rg() {
  local pattern="$1"
  shift
  printf '+ rg -n %q ' "$pattern"
  printf '%q ' "$@"
  printf '\n'
  rg -n "$pattern" "$@"
}

require_output_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    printf 'Missing expected text in %s: %s\n' "$file" "$needle" >&2
    printf '%s\n' '--- captured output (truncated to 4000 bytes) ---' >&2
    python3 - "$file" <<'PY' >&2
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as handle:
    data = handle.read(4000)
print(data)
PY
    printf '%s\n' '--- end captured output ---' >&2
    exit 1
  fi
}

require_output_absent() {
  local file="$1"
  local needle="$2"
  if grep -Fq "$needle" "$file"; then
    printf 'Unexpected text in %s: %s\n' "$file" "$needle" >&2
    printf '%s\n' '--- captured output (truncated to 4000 bytes) ---' >&2
    python3 - "$file" <<'PY' >&2
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as handle:
    data = handle.read(4000)
print(data)
PY
    printf '%s\n' '--- end captured output ---' >&2
    exit 1
  fi
}

# Repository-root preflight: this script intentionally does not cd. Keeping all
# paths root-relative makes accidental use of ignored planning artifacts obvious.
phase "Preflight: root-relative tracked inputs"
require_file "gene.nimble"
require_file "src/gene.nim"
require_file "tests/test_type_metadata_verifier.nim"
require_file "tests/integration/test_cli_gir.nim"
require_file "tests/test_strict_nil_policy.nim"
require_file "tests/integration/test_strict_nil_cli.nim"
require_file "testsuite/02-types/types/20_strict_nil_policy.gene"
require_executable_or_file "testsuite/run_tests.sh"
require_file "docs/gradual-typing.md"
require_file "docs/feature-status.md"
require_file "docs/type-system-mvp.md"
require_file "docs/how-types-work.md"
require_file "docs/README.md"
require_file "openspec/changes/add-gradual-typing-foundation/design.md"
require_file "openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md"
require_file "openspec/changes/add-gradual-typing-foundation/tasks.md"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/gene_m006_foundation_gate.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# Build phase. If this fails, do not continue to any CLI checks that could use an old bin/gene.
phase "Build: fresh gene binary"
run nimble build
[[ -x "bin/gene" ]] || fail "nimble build completed but bin/gene is not executable"

# Descriptor verifier phase: source compile and owner/path diagnostics.
phase "Descriptor verifier: source metadata diagnostics"
run nim c -r tests/test_type_metadata_verifier.nim

# GIR phase: source/GIR parity, corrupt GIR load rejection, direct .gir CLI rejection,
# and cached corrupted-GIR fallback behavior are all covered by this integration suite.
phase "GIR parity and corruption rejection"
run nim c -r tests/integration/test_cli_gir.nim

# Strict nil unit/CLI phase: direct runtime policy, eval/run surfaces, source fixture,
# and loaded-GIR strict nil behavior.
phase "Strict nil unit and CLI tests"
run nim c -r tests/test_strict_nil_policy.nim
run nim c -r tests/integration/test_strict_nil_cli.nim

# Explicit pipe phase: `pipe --strict-nil` must reject implicit nil for Int while
# default `pipe` mode must remain nil-compatible for the same expression.
phase "Strict nil pipe negative/default compatibility check"
pipe_expr='(fn f [x: Int] x) (f nil)'
strict_pipe_out="$workdir/pipe_strict_nil.out"
if printf 'ignored\n' | bin/gene pipe --strict-nil "$pipe_expr" >"$strict_pipe_out" 2>&1; then
  fail "gene pipe --strict-nil unexpectedly accepted nil for a typed Int argument"
fi
require_output_contains "$strict_pipe_out" "GENE_TYPE_MISMATCH"
require_output_contains "$strict_pipe_out" "strict nil mode"
require_output_contains "$strict_pipe_out" "Any, Nil, Option[T], or unions containing Nil"

default_pipe_out="$workdir/pipe_default_nil.out"
printf 'ignored\n' | bin/gene pipe "$pipe_expr" >"$default_pipe_out" 2>&1
require_output_absent "$default_pipe_out" "GENE_TYPE_MISMATCH"
require_output_absent "$default_pipe_out" "strict nil mode"

# Full testsuite phase: include all tracked numbered fixtures plus command suites,
# not just the strict-nil fixture.
phase "Full testsuite"
run ./testsuite/run_tests.sh

# OpenSpec phase. T03 owns final task-checkbox closure, so this gate validates and
# lists the active change without asserting the final 20/20 count here.
phase "OpenSpec validation and active-change visibility"
run openspec validate add-gradual-typing-foundation --strict
run openspec list

# Docs discoverability phase: every current docs entry point should lead readers
# to the foundation contract.
phase "Docs discoverability checks"
require_rg 'Gradual Typing|gradual-typing\.md' docs/README.md
require_rg 'Gradual Typing|gradual-typing\.md' docs/feature-status.md
require_rg 'Gradual Typing|gradual-typing\.md' docs/type-system-mvp.md
require_rg 'Gradual Typing|gradual-typing\.md' docs/how-types-work.md

# Descriptor metadata contract term checks: the docs/spec/tests must keep the
# stable marker, source/GIR phase wording, owner/path context, and summary-parity terms discoverable.
phase "Descriptor metadata term checks"
require_rg 'GENE_TYPE_METADATA_INVALID' docs/gradual-typing.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md tests/test_type_metadata_verifier.nim tests/integration/test_cli_gir.nim
require_rg 'source compile|GIR load|source/GIR' docs/gradual-typing.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md tests/integration/test_cli_gir.nim
require_rg 'owner/path|invalid TypeId|descriptor-table length|source path' docs/gradual-typing.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md tests/test_type_metadata_verifier.nim tests/integration/test_cli_gir.nim
require_rg 'descriptor metadata summary|descriptor_metadata_summary|source and loaded descriptor metadata summaries' docs/gradual-typing.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md tests/integration/test_cli_gir.nim

# Strict nil wording checks: keep Option[T] and the stable allowed-target wording in
# docs/specs/tests and in the explicit pipe diagnostic asserted above.
phase "Strict nil allowed-target wording checks"
require_rg 'strict nil|--strict-nil' docs/gradual-typing.md docs/type-system-mvp.md docs/feature-status.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md tests/test_strict_nil_policy.nim tests/integration/test_strict_nil_cli.nim testsuite/02-types/types/20_strict_nil_policy.gene
require_rg 'Option\[T\]|Option\[T\], or unions containing Nil|Any, Nil, Option\[T\], or unions containing Nil' docs/gradual-typing.md docs/type-system-mvp.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md tests/test_strict_nil_policy.nim tests/integration/test_strict_nil_cli.nim

# Deferred/out-of-scope wording checks: the foundation must not claim later tracks
# such as blame, broad guard unification, native facts, generics, or wrappers/proxies.
phase "Deferred/out-of-scope wording checks"
require_rg 'Deferred|deferred|out of scope|out-of-scope|Non-Goals|non-core' docs/gradual-typing.md docs/feature-status.md docs/type-system-mvp.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md
require_rg 'structured blame|runtime guard|flow typing|native typed|generic classes|bounds|monomorphization|deep collection|wrappers|proxies|static-only' docs/gradual-typing.md docs/feature-status.md docs/type-system-mvp.md openspec/changes/add-gradual-typing-foundation/design.md openspec/changes/add-gradual-typing-foundation/specs/gradual-typing/spec.md

printf '\nM006 foundation gate passed.\n'
