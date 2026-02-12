## ADDED Requirements

### Requirement: Tiered Native Execution Policy
The runtime SHALL expose explicit native execution tiers (`never`, `guarded`, `fully-typed`) that control when native compilation is attempted.

#### Scenario: Never tier disables native execution
- **WHEN** native tier is set to `never`
- **THEN** typed functions execute without native compilation

#### Scenario: Guarded tier deoptimizes on guard miss
- **WHEN** native tier is set to `guarded` and runtime args miss native guards
- **THEN** execution deoptimizes to bytecode/VM dispatch for that call

#### Scenario: Fully-typed tier enforces typed signature boundary
- **WHEN** native tier is set to `fully-typed` for a function without required typed boundary metadata
- **THEN** native compilation is skipped and execution remains on VM path

### Requirement: CLI Tier Configuration
The CLI SHALL allow setting native compilation tier explicitly.

#### Scenario: Legacy flag compatibility
- **WHEN** users pass `--native-code`
- **THEN** runtime uses `guarded` native tier semantics
