## Why
Gene needs a repeatable way to improve LLM skills that are supposed to produce correct, idiomatic Gene code. Right now, skill edits are mostly prompt tweaks judged by intuition, which makes regressions easy to introduce and hard to prove. Because Gene syntax is specialized and small syntax mistakes usually make code unusable, skill revisions need to be measured in fresh sessions against the real repository and real verification commands.

## What Changes
- Add a versioned Gene authoring skill/reference bundle that points models to the canonical Gene syntax and project-specific hazards.
- Add a benchmark corpus of short Gene coding requirements with explicit `dev` and `holdout` splits plus task-specific verification profiles.
- Add a fresh-session evaluation runner that executes each task with only the requirement, selected skill version, and task-approved repository context.
- Add bounded repair rounds driven by structured verifier feedback so we can measure pass-after-repair separately from pass@1.
- Add deterministic verification using Gene CLI commands and task-specific project tests before any subjective judging.
- Add blind pairwise comparison and versioned result storage so new skill revisions can be compared against a baseline without label leakage.
- Define promotion reporting that prioritizes deterministic holdout performance over LLM judge preference.

## Impact
- New `gene-authoring-skill-eval` capability for measuring Gene-focused LLM authoring quality.
- Affected areas: versioned skill artifacts, benchmark task definitions, evaluation runner, result summaries, and documentation.
- Establishes measurable pass/fail data for skill revisions instead of ad hoc prompt tuning.
- No changes to Gene runtime or language semantics; scope is tooling and evaluation workflow only.
