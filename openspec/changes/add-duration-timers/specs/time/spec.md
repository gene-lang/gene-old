## ADDED Requirements

### Requirement: Microsecond time access
The system SHALL expose `time/now_us` as a native function that returns the current epoch time in microseconds.

#### Scenario: Read microsecond time
- **WHEN** a program evaluates `(time/now_us)`
- **THEN** it returns an integer representing epoch microseconds

### Requirement: Duration special variables
The system SHALL provide `$duration_start` and `$duration` as special timing variables backed by VM state.

#### Scenario: Start duration
- **WHEN** a program evaluates `$duration_start`
- **THEN** it stores the current epoch microsecond timestamp in VM state and returns that timestamp

#### Scenario: Read duration
- **WHEN** a program evaluates `$duration` after `$duration_start`
- **THEN** it returns the elapsed microseconds since `$duration_start`

#### Scenario: Duration without start
- **WHEN** a program evaluates `$duration` before `$duration_start`
- **THEN** it raises a Gene exception indicating the start time is not set
