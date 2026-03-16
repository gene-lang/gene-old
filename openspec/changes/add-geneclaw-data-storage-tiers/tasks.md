## 1. Specification

- [x] 1.1 Add the `app-data-storage` capability spec covering the storage
      tiers, tier semantics, and app-selectable directory layout.
- [x] 1.2 Capture the architectural decisions behind text `.gene` persistence,
      derived indexes, keyed records, and append-only logs in the design doc.
- [x] 1.3 Make GeneClaw explicit as the first adopter of the generic storage
      tier model.
- [x] 1.4 Document that Gene provides the storage functionality while each app
      chooses which pieces to use and how to organize its directories.

## 2. Follow-On Planning

- [x] 2.1 Plan a follow-on implementation change for GeneClaw to adopt the
      generic storage-tier model.
- [x] 2.2 Document that the first GeneClaw rollout may reset old workspace
      data instead of migrating it.
- [x] 2.3 Plan logging, archival, and retention behavior once mutable record
      tiers are stable.

## 3. Validation

- [x] 3.1 Run `openspec validate add-geneclaw-data-storage-tiers --strict`.
