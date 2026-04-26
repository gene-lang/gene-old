#!/usr/bin/env python3
"""Public-surface assertions for the explicit interception migration.

The goal is not to ban legacy AOP syntax from the repository.  Legacy fixtures
and the migration/history document must keep it so compatibility remains tested
and explainable.  The goal is to prevent public drift where current docs,
examples, or OpenSpec accidentally teach broad AOP syntax as the preferred
Experimental surface again.

This script intentionally reads only bounded, source-controlled public trees:
``docs/``, ``examples/``, the active ``openspec/changes/add-class-aspects``
change, and ``testsuite/`` source/assertion files.  It never scans ignored local
planning artifacts such as ``.gsd/``, build output, ``bin/``, or caches.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
THIS_SCRIPT = Path(__file__).resolve()

SCAN_ROOTS = [
    REPO_ROOT / "docs",
    REPO_ROOT / "examples",
    REPO_ROOT / "openspec/changes/add-class-aspects",
    REPO_ROOT / "testsuite",
]

TEXT_SUFFIXES = {".gene", ".md", ".py", ".sh"}
EXCLUDED_DIRS = {
    ".git",
    ".gsd",
    ".nimblecache",
    "bin",
    "build",
    "node_modules",
    "__pycache__",
}

CURRENT_REFERENCE_FILES = [
    "docs/interception.md",
    "docs/feature-status.md",
    "docs/README.md",
    "docs/architecture.md",
    "testsuite/README.md",
    "examples/interception.gene",
    "examples/README.md",
    "examples/run_examples.sh",
    "openspec/changes/add-class-aspects/proposal.md",
    "openspec/changes/add-class-aspects/design.md",
    "openspec/changes/add-class-aspects/tasks.md",
    "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
]

PRIMARY_CURRENT_FILES = {
    "docs/interception.md",
    "docs/feature-status.md",
    "examples/interception.gene",
    "examples/README.md",
    "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
}

MIGRATION_HISTORY_FILES = {
    "docs/proposals/future/aop.md",
}

# Legacy executable fixtures remain part of the public regression surface.  They
# are explicitly exempt because their job is to prove old `(aspect ...)`, `.apply`,
# and `.apply-fn` compatibility while docs/specs teach explicit interception.
LEGACY_FIXTURE_GLOBS = [
    "testsuite/05-functions/functions/*_aop_*.gene",
    "testsuite/07-oop/oop/*_aop_*.gene",
]
LEGACY_FIXTURE_FILES = {
    "testsuite/07-oop/oop/13_interceptor_diagnostics.gene",
}

# Implementation-level invariant script may mention internal proc names such as
# `apply_aspect_to_class`; those are not user-facing API recommendations.
IMPLEMENTATION_ASSERTION_FILES = {
    "testsuite/experimental/interception_toggle_source_assertions.py",
}

REQUIRED_APPEARANCES = {
    "(interceptor": [
        "docs/interception.md",
        "examples/interception.gene",
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
    ],
    "(fn-interceptor": [
        "docs/interception.md",
        "examples/interception.gene",
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
    ],
    "/.enable": [
        "docs/interception.md",
        "examples/interception.gene",
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
    ],
    "/.disable": [
        "docs/interception.md",
        "examples/interception.gene",
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
    ],
    "GENE.INTERCEPT": [
        "docs/interception.md",
        "docs/feature-status.md",
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
    ],
    "temporary compatibility": [
        "docs/interception.md",
        "docs/feature-status.md",
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md",
    ],
    "Experimental": [
        "docs/interception.md",
        "docs/feature-status.md",
        "examples/interception.gene",
        "examples/README.md",
    ],
}

STALE_EXACT_PHRASES = [
    "fn_aspect",
    ".apply_in_place",
    "No function-level AOP",
    "only instance methods",
    "hard migration diagnostics are deferred",
    "Function aspects",
]

LEGACY_API_PHRASES = [
    "(aspect",
    ".apply",
    ".apply-fn",
]

ALLOWED_STALE_CONTEXT_WORDS = [
    "compatibility",
    "temporary",
    "migration",
    "history",
    "historical",
    "legacy",
    "old",
    "stale",
    "unsupported",
    "deferred",
    "not the preferred",
    "not preferred",
    "do not present",
    "not teach",
    "not taught",
    "rather than the preferred",
    "not the current spelling",
    "existing code",
    "current boundary",
    "rather than treated as supported",
    "remove legacy",
    "compatibility/history",
]

PREFERRED_LEGACY_SIGNALS = [
    "prefer ",
    "preferred",
    "current api",
    "current spelling",
    "current surface",
    "teach first",
    "start here",
    "use `.apply",
    "use (aspect",
]

LEGACY_NEGATIONS = [
    "not the preferred",
    "not preferred",
    "do not present",
    "not teach",
    "not taught",
    "rather than the preferred",
    "not the current spelling",
    "only as temporary",
    "compatibility rather than",
    "compatibility/history",
    "remain compatibility",
    "remains compatibility",
    "temporary compatibility",
    "migration history",
    "history context",
    "remove legacy",
]


@dataclass(frozen=True)
class PublicFile:
    rel: str
    path: Path
    text: str
    lines: list[str]


FAILURES: list[str] = []
PASSES: list[str] = []


def rel_path(path: Path) -> str:
    return path.resolve().relative_to(REPO_ROOT).as_posix()


def read_public_file(rel: str) -> PublicFile:
    path = REPO_ROOT / rel
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        FAILURES.append(f"missing required public file: {rel}")
        text = ""
    return PublicFile(rel=rel, path=path, text=text, lines=text.splitlines())


def iter_public_text_files() -> list[PublicFile]:
    files: list[PublicFile] = []
    for root in SCAN_ROOTS:
        if not root.exists():
            FAILURES.append(f"missing scan root: {rel_path(root)}")
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            if path.resolve() == THIS_SCRIPT:
                continue
            rel = rel_path(path)
            if path.suffix not in TEXT_SUFFIXES:
                continue
            if any(part in EXCLUDED_DIRS for part in path.relative_to(REPO_ROOT).parts):
                FAILURES.append(f"scan attempted to enter excluded path: {rel}")
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                FAILURES.append(f"non-utf8 public text candidate: {rel}")
                continue
            files.append(PublicFile(rel=rel, path=path, text=text, lines=text.splitlines()))
    return files


def check(condition: bool, message: str) -> None:
    if condition:
        PASSES.append(message)
    else:
        FAILURES.append(message)


def context_for(lines: list[str], line_index: int, radius: int = 2) -> str:
    start = max(0, line_index - radius)
    end = min(len(lines), line_index + radius + 1)
    return "\n".join(lines[start:end]).lower()


def is_legacy_fixture(rel: str) -> bool:
    path = Path(rel)
    if rel in LEGACY_FIXTURE_FILES:
        return True
    return any(path.match(glob) for glob in LEGACY_FIXTURE_GLOBS)


def is_context_allowed(context: str) -> bool:
    return any(word in context for word in ALLOWED_STALE_CONTEXT_WORDS)


def is_preferred_legacy_context(context: str) -> bool:
    if not any(signal in context for signal in PREFERRED_LEGACY_SIGNALS):
        return False
    return not any(negation in context for negation in LEGACY_NEGATIONS)


def stale_phrase_allowed(rel: str, phrase: str, context: str) -> bool:
    if is_legacy_fixture(rel):
        return True
    if rel in IMPLEMENTATION_ASSERTION_FILES:
        return True
    # Migration/history docs may name stale terms, but still need local wording
    # that marks them as stale, compatibility, unsupported, or historical.
    if rel in MIGRATION_HISTORY_FILES:
        return is_context_allowed(context)
    return is_context_allowed(context)


def check_required_terms(files_by_rel: dict[str, PublicFile]) -> None:
    for phrase, rels in REQUIRED_APPEARANCES.items():
        for rel in rels:
            public_file = files_by_rel.get(rel) or read_public_file(rel)
            check(
                phrase in public_file.text,
                f"{rel}: required current term `{phrase}` must appear",
            )

    example = files_by_rel.get("examples/interception.gene") or read_public_file("examples/interception.gene")
    for forbidden in LEGACY_API_PHRASES:
        check(
            forbidden not in example.text,
            f"examples/interception.gene: runnable public example must not contain legacy `{forbidden}`",
        )

    runner = files_by_rel.get("examples/run_examples.sh") or read_public_file("examples/run_examples.sh")
    check(
        "examples/interception.gene" in runner.text,
        "examples/run_examples.sh: curated runner must include the explicit interception example",
    )


def check_stale_phrases(public_files: list[PublicFile]) -> None:
    for public_file in public_files:
        for line_no, line in enumerate(public_file.lines, start=1):
            context = context_for(public_file.lines, line_no - 1)

            for phrase in STALE_EXACT_PHRASES:
                if phrase in line:
                    allowed = stale_phrase_allowed(public_file.rel, phrase, context)
                    check(
                        allowed,
                        f"{public_file.rel}:{line_no}: stale phrase `{phrase}` outside migration/compatibility allowlist",
                    )

            for phrase in LEGACY_API_PHRASES:
                if phrase in line:
                    allowed = stale_phrase_allowed(public_file.rel, phrase, context)
                    check(
                        allowed,
                        f"{public_file.rel}:{line_no}: legacy API `{phrase}` outside migration/compatibility allowlist",
                    )
                    check(
                        not is_preferred_legacy_context(context),
                        f"{public_file.rel}:{line_no}: legacy API `{phrase}` appears in preferred/current guidance context",
                    )


def check_primary_surface_presence(files_by_rel: dict[str, PublicFile]) -> None:
    for rel in sorted(PRIMARY_CURRENT_FILES):
        public_file = files_by_rel.get(rel) or read_public_file(rel)
        check(
            "interception" in public_file.text.lower(),
            f"{rel}: primary current surface should mention interception",
        )

    feature_status = files_by_rel.get("docs/feature-status.md") or read_public_file("docs/feature-status.md")
    check(
        "Explicit runtime interception (AOP compatibility)" in feature_status.text,
        "docs/feature-status.md: feature matrix must name explicit runtime interception with AOP compatibility",
    )

    spec = files_by_rel.get("openspec/changes/add-class-aspects/specs/explicit-interception/spec.md") or read_public_file(
        "openspec/changes/add-class-aspects/specs/explicit-interception/spec.md"
    )
    check(
        "### Requirement: Keep legacy AOP compatibility migration-only" in spec.text,
        "openspec explicit-interception spec: legacy compatibility must be migration-only",
    )


def check_negative_guards() -> None:
    """Synthetic guards prove the allowlist would reject future bad drift."""
    current_doc = "docs/interception.md"
    bad_preferred = "Use `.apply-fn` as the preferred standalone function interception API."
    bad_context = bad_preferred.lower()
    check(
        not stale_phrase_allowed(current_doc, ".apply-fn", bad_context),
        "negative guard: current docs reject preferred `.apply-fn` wording",
    )
    check(
        is_preferred_legacy_context(bad_context),
        "negative guard: preferred legacy wording is recognized",
    )

    bad_stale = "No function-level AOP is a current limitation."
    check(
        not stale_phrase_allowed(current_doc, "No function-level AOP", bad_stale.lower()),
        "negative guard: current docs reject stale `No function-level AOP` wording",
    )

    allowed_history = "The old `fn_aspect` name is stale migration history, not current guidance."
    check(
        stale_phrase_allowed("docs/proposals/future/aop.md", "fn_aspect", allowed_history.lower()),
        "negative guard: migration history may name stale `fn_aspect` with stale/history context",
    )


def main() -> int:
    files_by_rel = {rel: read_public_file(rel) for rel in CURRENT_REFERENCE_FILES}
    public_files = iter_public_text_files()

    # Deterministic bounded-read invariant: every scanned path must stay under the
    # allowed source roots and outside ignored or generated directories.
    allowed_prefixes = tuple(f"{rel_path(root)}/" for root in SCAN_ROOTS)
    for public_file in public_files:
        check(
            public_file.rel.startswith(allowed_prefixes),
            f"{public_file.rel}: scanned file must stay under allowed public roots",
        )
        check(
            not any(part in EXCLUDED_DIRS for part in Path(public_file.rel).parts),
            f"{public_file.rel}: scanned file must not be in ignored/generated directories",
        )

    check_required_terms(files_by_rel)
    check_primary_surface_presence(files_by_rel)
    check_stale_phrases(public_files)
    check_negative_guards()

    if FAILURES:
        print("interception public-surface assertions FAILED")
        for failure in FAILURES:
            print(f"FAIL: {failure}")
        return 1

    print(f"interception public-surface assertions passed ({len(PASSES)} checks across {len(public_files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
