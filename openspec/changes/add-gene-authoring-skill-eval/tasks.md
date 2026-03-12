## 1. Skill and Corpus Definition
- [ ] 1.1 Define the versioned Gene authoring skill/reference bundle and keep `examples/full.gene` as its canonical syntax oracle.
- [ ] 1.2 Define the benchmark task manifest schema, including requirement text, split, allowed repository context, expected artifacts, verification profile, and repair-round limit.
- [ ] 1.3 Seed an initial corpus of short Gene authoring tasks spanning expressions, control flow, collections, functions, classes, async usage, and module-oriented work.
- [ ] 1.4 Separate tasks into `dev` and `holdout` splits and document how each split is used during skill iteration.

## 2. Fresh-Session Runner
- [ ] 2.1 Implement a runner that starts a new LLM session for each task/version trial with no prior conversation state.
- [ ] 2.2 Feed only the requirement, selected skill bundle, and task-approved repository context into each trial.
- [ ] 2.3 Capture generated code, supporting files, verifier logs, and repair-round transcripts as per-task artifacts.
- [ ] 2.4 Support a bounded number of repair rounds driven by compact structured verifier feedback.

## 3. Deterministic Verification
- [ ] 3.1 Implement reusable verification profiles for common Gene authoring tasks.
- [ ] 3.2 Add standard Gene verification stages using `bin/gene parse` and `bin/gene fmt --check`.
- [ ] 3.3 Add execution and task-specific verification using configured commands such as `bin/gene run`, `bin/gene eval`, `nimble test`, and `./testsuite/run_tests.sh`.
- [ ] 3.4 Classify failures as syntax, format, runtime, test, timeout, or missing-artifact and record them in run summaries.

## 4. Comparison and Reporting
- [ ] 4.1 Store per-run results keyed by skill version, model/provider, task id, split, and timestamp.
- [ ] 4.2 Compute comparison metrics including pass@1, pass-after-repair, syntax failure rate, average repair rounds, and task coverage.
- [ ] 4.3 Add blind pairwise judging for candidate outputs that both pass deterministic verification.
- [ ] 4.4 Define a promotion report that refuses to mark a candidate as better overall when holdout deterministic metrics regress against baseline.

## 5. Documentation and Validation
- [ ] 5.1 Document how to add tasks, add a new skill version, and run the comparison loop.
- [ ] 5.2 Add a smoke benchmark run that exercises at least one end-to-end task.
- [ ] 5.3 Run `openspec validate add-gene-authoring-skill-eval --strict` and resolve all issues.
