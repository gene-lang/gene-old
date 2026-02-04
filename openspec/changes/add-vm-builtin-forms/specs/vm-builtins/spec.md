## ADDED Requirements

### Requirement: $vm and $vmstmt special form recognition
The compiler SHALL treat a Gene form whose type is the symbol `$vm` or `$vmstmt` as a VM builtin form and SHALL NOT resolve those symbols through normal scope lookup.

#### Scenario: Recognize $vm form
- **WHEN** the compiler encounters `($vm duration)`
- **THEN** it compiles the form as a VM builtin rather than a normal function call

#### Scenario: Recognize $vmstmt form
- **WHEN** the compiler encounters `($vmstmt duration_start)`
- **THEN** it compiles the form as a VM builtin rather than a normal function call

### Requirement: Whitelisted VM builtins
The compiler SHALL whitelist VM builtin names. Only `duration_start` is valid for `$vmstmt`, and only `duration` is valid for `$vm`.

#### Scenario: Reject unknown $vm builtin
- **WHEN** code contains `($vm does_not_exist)`
- **THEN** the compiler reports an unknown VM builtin error

#### Scenario: Reject unknown $vmstmt builtin
- **WHEN** code contains `($vmstmt does_not_exist)`
- **THEN** the compiler reports an unknown VM builtin error

### Requirement: Statement-only duration start
The compiler SHALL compile `($vmstmt duration_start)` into a dedicated VM instruction that has **no stack result** and updates the VM duration timer in microseconds. Using `$vmstmt` in a value position MUST be a compile-time error.

#### Scenario: Duration start as statement
- **WHEN** a top-level form is `($vmstmt duration_start)`
- **THEN** the compiler emits a single `IkVmDurationStart` instruction and does not emit an `IkPop` for that form

#### Scenario: Duration start used as expression
- **WHEN** code contains `(println ($vmstmt duration_start))`
- **THEN** the compiler reports an error indicating that the builtin is statement-only

### Requirement: Duration value builtin
The compiler SHALL compile `($vm duration)` into a dedicated VM instruction that pushes the duration in microseconds onto the stack.

#### Scenario: Duration used as expression
- **WHEN** code contains `(println ($vm duration))`
- **THEN** the compiler emits `IkVmDuration` and the printed value is the current duration in microseconds
