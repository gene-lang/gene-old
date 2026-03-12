## Context
Gene needs a practical way to improve authoring skills for LLMs without relying on subjective prompt review. A skill revision that sounds better can still produce invalid Gene syntax, skip repository conventions, or overfit a few examples. The evaluation loop therefore needs three layers: a versioned skill bundle, deterministic execution against the repo, and a blind judge that only looks at already-working outputs.

## Goals / Non-Goals
- Goals:
  - Measure whether a skill revision helps a fresh session produce valid, working Gene code.
  - Keep deterministic verification primary and LLM judging secondary.
  - Preserve a stable `holdout` split so skill editing does not collapse into benchmark overfitting.
  - Record enough structured output to compare revisions over time.
- Non-Goals:
  - Build a general-purpose prompt-evaluation platform for every language or model.
  - Replace existing Nim or Gene test suites.
  - Automatically accept a skill revision based only on LLM judge preference.
  - Standardize on a single model provider in this proposal.

## Technical Architecture

### Repository Artifacts
The capability should live in repository-controlled artifacts so results are reproducible and reviewable:

- `evals/gene_authoring/skills/<version>/` for versioned skill snapshots used by the runner
- `evals/gene_authoring/tasks/<task-id>.toml` for benchmark task definitions
- `evals/gene_authoring/profiles/` for reusable verification profiles
- `evals/gene_authoring/runs/<timestamp>/...` for artifacts and summaries

These paths are indicative; implementation may adjust exact names while keeping the same separation of concerns.

### Task Manifest
Each task definition should include:

- short natural-language requirement
- split (`dev` or `holdout`)
- allowed repository context or reference files
- expected artifact paths
- verification profile
- repair-round limit

This keeps task authoring small while letting the runner remain generic.

### Execution Loop
Each task/version trial starts in a new LLM session. The runner provides only:

- the short requirement
- the selected versioned skill bundle
- task-approved repository context

The skill bundle should direct the model to treat `examples/full.gene` as the canonical syntax oracle and to follow the repository's Gene-specific hazards and verification workflow.

If deterministic verification fails and repair rounds remain, the runner returns a compact structured failure back to the same trial session. No state carries across tasks, runs, or skill versions.

### Deterministic Verification
Deterministic checks should happen before any LLM judging. Verification profiles allow different task types without hard-coding one command sequence for every benchmark:

- `gene-file`: artifact existence, `bin/gene parse`, `bin/gene fmt --check`, `bin/gene run`
- `gene-snippet`: `bin/gene eval` or equivalent snippet execution
- `runtime-change`: project tests such as `nimble test` or `./testsuite/run_tests.sh`

Each step should emit structured result data: command, stage, exit status, duration, and a normalized failure class.

### Judge Layer
The blind judge operates only on candidates that pass deterministic verification. It receives:

- the task requirement
- anonymized candidate artifacts (`Candidate A`, `Candidate B`)
- a small rubric focused on idiomatic Gene syntax, unnecessary complexity, invented constructs, and adherence to repository conventions

This prevents the judge from rewarding plausible-looking but broken Gene code.

### Result Model and Promotion
Per-run summaries should track at least:

- skill version
- model/provider
- task id and split
- pass@1
- pass-after-repair
- failure class
- repair count

Comparison reports should present `dev` and `holdout` metrics separately. A candidate must not be marked better overall if its deterministic holdout performance regresses, even if the blind judge prefers its passing outputs.

## Risks / Mitigations
- Overfitting to benchmark tasks:
  - Mitigate with separate `dev` and `holdout` splits and versioned task definitions.
- Judge bias:
  - Mitigate with blind pairwise comparison and by restricting judge input to deterministically passing outputs.
- Context bloat:
  - Mitigate by keeping the skill bundle lean and pointing to repo references such as `examples/full.gene` instead of duplicating large examples in the skill itself.
- Provider variability:
  - Mitigate by recording model/provider metadata with each run and comparing like-for-like baselines.
