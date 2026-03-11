## Why

GeneClaw now has filesystem-backed persistence, but its storage contract is
still described mostly in terms of a single workspace tree. The tier strategy
in `example-projects/geneclaw/tmp/diff_data_diff_strategy.md` is a clearer
model: different data classes should use different persistence semantics based
on access pattern, mutation frequency, and sensitivity.

This proposal converts that strategy into OpenSpec so future app storage work
can be reviewed against a normative model instead of an informal design note.
GeneClaw is the first app expected to adopt the model, not the only one.

## What Changes

- Add an app-level data-storage capability spec that defines the following
  tiers: Config, Hot State, Keyed Records, Archive, Append-Only Log, Secrets,
  and Ephemeral.
- Define these as reusable storage capabilities in Gene rather than a single
  mandatory directory schema for every app.
- Require apps to choose which storage capabilities they use and how they map
  those capabilities into their own home directory structure.
- Require derived indexes for keyed collections instead of separately persisted
  registries that can drift from the record files.
- Keep text `.gene` persistence as the default durable format for v1 tiered
  storage; binary storage remains a future optimization only if profiling
  justifies it.
- Separate mutable keyed records such as sessions, jobs, runs, and documents
  from append-only logging concerns such as audit and event logs.
- Treat GeneClaw as the first concrete adopter of the generic storage-tier
  model.

## Impact

- Affected specs:
  - `app-data-storage`
- Affected code:
  - Future follow-on changes for GeneClaw would primarily touch
    `example-projects/geneclaw/src/home_store.gene`,
    `example-projects/geneclaw/src/config.gene`,
    `example-projects/geneclaw/src/workspace_state.gene`,
    `example-projects/geneclaw/src/db.gene`,
    `example-projects/geneclaw/src/scheduler.gene`,
    and related docs/tests.
- Breaking behavior:
  - A follow-on implementation for a given app would replace any current
    workspace-centric storage layout with an app-chosen directory structure
    built from the shared storage capabilities.
  - Persisted registries that duplicate keyed-record directories would no
    longer be part of the supported storage model.
