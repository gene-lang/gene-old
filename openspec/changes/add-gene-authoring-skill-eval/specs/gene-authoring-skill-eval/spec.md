## ADDED Requirements

### Requirement: Versioned Gene Authoring Skill Bundle
The system SHALL maintain a versioned Gene authoring skill bundle for evaluation runs so fresh LLM sessions can receive the same Gene-specific instructions and references every time.

#### Scenario: Select a specific skill version for a run
- **WHEN** a developer starts an evaluation run with a named skill version
- **THEN** the runner loads that exact versioned skill bundle for every task in the run

#### Scenario: Skill bundle points to canonical Gene syntax
- **WHEN** the skill bundle is used for a Gene authoring task
- **THEN** it directs the model to use `examples/full.gene` as the canonical syntax reference and to follow the Gene-specific verification workflow

### Requirement: Fresh-Session Benchmark Execution
The system SHALL execute each task/version trial in an isolated fresh LLM session with no state shared across tasks or skill versions.

#### Scenario: Consecutive tasks do not share conversation state
- **WHEN** two benchmark tasks run for the same skill version
- **THEN** the second task starts without conversation history, generated artifacts, or repair feedback from the first task

#### Scenario: Repair feedback stays within the current trial
- **WHEN** deterministic verification fails and the task still has repair rounds remaining
- **THEN** only structured failure feedback for that task is returned to the current trial session

### Requirement: Benchmark Corpus with Explicit Splits
The system SHALL define a benchmark corpus of short Gene authoring tasks with explicit split and verification metadata.

#### Scenario: Task manifests include required evaluation metadata
- **WHEN** a new benchmark task is added
- **THEN** it includes the requirement text, split, allowed repository context, expected artifacts, verification profile, and repair-round limit

#### Scenario: Comparison report separates dev and holdout results
- **WHEN** an evaluation run finishes
- **THEN** the summary reports metrics for `dev` and `holdout` tasks separately

### Requirement: Deterministic Verification Before Judging
The system SHALL apply a deterministic verification profile to each task before any subjective pairwise judging occurs.

#### Scenario: File-based Gene task uses standard Gene checks
- **WHEN** a task uses the `gene-file` verification profile
- **THEN** the verifier checks required artifacts and runs `bin/gene parse`, `bin/gene fmt --check`, and `bin/gene run` in the configured order

#### Scenario: Project-changing task runs configured repository tests
- **WHEN** a task uses a verification profile that includes project tests
- **THEN** the verifier runs the configured commands such as `nimble test` or `./testsuite/run_tests.sh` and records their results

#### Scenario: Failed candidates are classified and excluded from judging
- **WHEN** any deterministic verification step fails
- **THEN** the run summary records the failing stage, command, exit status, and failure classification, and that candidate is not eligible for blind pairwise judging unless it later passes after repair

### Requirement: Blind Pairwise Review of Passing Outputs
The system SHALL support blind pairwise comparison of passing candidate outputs so skill versions can be compared on idiomatic Gene quality without label leakage.

#### Scenario: Judge receives anonymized passing candidates
- **WHEN** two skill versions both produce deterministically passing outputs for the same task
- **THEN** the judge receives anonymized `Candidate A` and `Candidate B` artifacts plus the task requirement, without skill-version labels

#### Scenario: Deterministic winner skips unnecessary judge comparison
- **WHEN** only one candidate produces a deterministically passing output for a task
- **THEN** the comparison report records the deterministic winner and skips pairwise judge preference for that task

### Requirement: Versioned Result Reporting and Promotion Gate
The system SHALL persist versioned evaluation results and block “better than baseline” conclusions when deterministic holdout metrics regress.

#### Scenario: Run summary stores comparable version metadata
- **WHEN** an evaluation run completes
- **THEN** the stored summary includes skill version, model/provider, task id, split, pass@1, pass-after-repair, repair count, and failure classification

#### Scenario: Holdout regression blocks promotion
- **WHEN** a candidate skill version has worse deterministic holdout performance than the baseline
- **THEN** the comparison report does not mark the candidate as better overall even if blind judge preference favors it
