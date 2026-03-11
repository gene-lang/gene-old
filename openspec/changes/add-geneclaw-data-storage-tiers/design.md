## Context

GeneClaw's current filesystem persistence is functional, but it is still
framed around a unified workspace tree. The strategy note in
`example-projects/geneclaw/tmp/diff_data_diff_strategy.md` argues for a more
explicit storage taxonomy:

- Config stays human-authored and low-churn.
- Small runtime state stays eagerly loaded.
- Large independent collections use keyed per-record files.
- Logs are append-only and operationally distinct from mutable records.
- Secrets and ephemeral state follow their own safety rules.

This change captures that taxonomy as a spec-level contract for app storage
work in general, with GeneClaw as the first adopter.

## Goals / Non-Goals

- Goals:
  - Define the storage tiers Gene SHALL make available to apps.
  - Define how apps choose which capabilities they adopt and how they arrange
    their own home-directory layout.
  - Make the boundary between mutable records and append-only logs explicit.
  - Require derived indexes instead of separately persisted registries for
    keyed collections.
  - Keep the current text `.gene` serializer as the default persisted format
    unless profiling demonstrates that it is inadequate.
- Non-Goals:
  - Implement the tiered layout in this change.
  - Introduce a binary persistence format.
  - Define automatic migration tooling from the current layout.
  - Fully specify archival compaction or retention algorithms.

## Decisions

- Decision: app storage SHALL be organized by storage tier, not by a single
  one-size-fits-all persistence strategy.
  - Rationale: the access pattern for config, hot state, sessions, logs, and
    secrets is materially different.

- Decision: Gene SHALL provide reusable storage capabilities, but apps SHALL
  choose their own home-directory layout.
  - Rationale: different apps may need different subsets of the model and
    different grouping of keyed records, assets, and scratch space.
  - Adoption note:
    - GeneClaw would instantiate its home root as `GENECLAW_HOME`.
    - A valid GeneClaw layout could be:
      ```text
      config/
      state/
      sessions/<session-id>/uploaded
      sessions/<session-id>/generated
      scheduler/jobs/
      scheduler/runs/
      assets/uploaded/
      assets/generated/
      logs/
      archive/
      tmp/
      ```

- Decision: v1 tiered storage SHALL continue to use text `.gene` persistence
  for config, hot state, and keyed records.
  - Rationale: GeneClaw already has working text Gene serialization, and the
    strategy explicitly treats binary storage as a profiling-driven
    optimization rather than a prerequisite.

- Decision: mutable durable collections SHALL use keyed records with point
  reads and point writes.
  - Example adopters:
    - sessions
    - scheduler jobs
    - run records
    - document records
  - Rationale: these entities mutate independently and should not force
    shared-blob rewrites.

- Decision: append-only operational logs SHALL be separate from keyed records.
  - Applies to:
    - tool audit trail
    - request/response logs
    - event logs
    - error logs
  - Rationale: log workloads are append-heavy and do not need point mutation.

- Decision: indexes for keyed collections SHALL be derived at startup rather
  than persisted as separate registries.
  - Examples:
    - session list
    - document catalog
    - job list
  - Rationale: duplicated registries create drift and restart bugs unless
    they are perfectly write-through.

- Decision: secrets are a cross-cutting concern, not a normal storage tier.
  - Guardrails:
    - expanded secret values are never written to disk
    - placeholders remain the durable authored form
    - public config and logs must redact secret values
  - Rationale: persistence safety must hold across all other tiers.

- Decision: archived data SHALL be excluded from startup load and only loaded
  on explicit access.
  - Rationale: cold data should not affect restart cost for active workloads.

- Decision: apps MAY introduce app-specific durable asset trees and scratch
  directories alongside the shared storage capabilities.
  - Examples:
    - uploaded assets
    - generated assets
    - temporary working files
  - Rationale: asset payloads and tmp space are operationally useful but do
    not fit cleanly into the same contract as config, keyed records, or logs.

- Decision: no migration compatibility is required for the first adopter.
  - GeneClaw adoption rule:
    - old workspace data may be discarded
    - the app may start from a clean home directory rather than migrate prior
      state
  - Rationale: the approved direction is to start fresh instead of carrying
    migration complexity into the first implementation.

## Alternatives Considered

- Keep the single workspace-tree model as the only storage abstraction:
  - Rejected because it blurs the distinction between hot state, keyed
    records, and append-only logs.

- Introduce binary persistence immediately:
  - Rejected because it adds migration and tooling complexity before there is
    evidence that text Gene serialization is the bottleneck.

- Persist active registries for sessions/jobs/documents:
  - Rejected because duplicated indexes are a common source of drift unless
    they are rebuilt or strictly write-through.

## Risks / Trade-offs

- More freedom in per-app layout choices:
  - Mitigation: keep the capability contract in Gene explicit even when the
    directory mapping is chosen by the app.

- Directory scans at startup for derived indexes:
  - Mitigation: for current GeneClaw scale this should be cheap; if it stops
    being cheap, introduce a rebuildable cache rather than an authoritative
    registry.

- Fresh-start adoption loses prior app state:
  - Mitigation: make reset expectations explicit for the adopting app and do
    not imply migration support where none exists.

## Migration Plan

1. Ratify the tiered storage model in OpenSpec.
2. Create follow-on implementation proposals for adopting apps, starting with
   GeneClaw.
3. Allow first-adopter implementations to reset durable state instead of
   migrating old data.
4. Implement archive and append-only log optimizations after the mutable record
   tiers are stable.

## Open Questions

- Whether tool audit should live in `.log` text files or append-only `.gene`
  files for the first implementation.
  A: append only .gene file
- Whether document indexes should remain purely derived or gain a rebuildable
  cache file when collection sizes grow.
  A: derived in v1
- What operational threshold should trigger archival of cold sessions or runs.
  A: when last modification time is >X days (X defaults to 10)
