## ADDED Requirements

### Requirement: Manifest Parser Supports Hash Parse-Macro Forms
In parse-macro-enabled manifest contexts, the parser SHALL accept `#`-prefixed symbols in both call-head and argument positions, preserving them as symbols for parse-macro evaluation.

#### Scenario: Parse macro call with macro variable argument
- **WHEN** the input contains `(#Var #a 1)`
- **THEN** the parsed form head is symbol `#Var`
- **AND** the first argument is symbol `#a`

#### Scenario: Parse nested macro calls
- **WHEN** the input contains `(#If (#Eq #a 2) A B)`
- **THEN** the parser preserves nested `#`-prefixed call heads (`#If`, `#Eq`) and symbol arguments for the evaluator

### Requirement: Manifest Parse-Macro Evaluator Executes Supported Macros
Manifest parsing mode SHALL evaluate supported `#`-prefixed parse macros in expression order with a shared macro-variable environment.

#### Scenario: Variable assignment and conditional selection
- **GIVEN** expressions `(#Var #a 1)` followed by `(#If (#Eq #a 2) A B)`
- **WHEN** the manifest evaluator executes them sequentially
- **THEN** the second expression evaluates to `B`

#### Scenario: Incrementing a macro variable
- **GIVEN** expressions `(#Var #i 0)` followed by `(#Inc #i)` then `(#Inc #i)`
- **WHEN** the manifest evaluator executes them sequentially
- **THEN** the `#Inc` results are `1` then `2`
- **AND** `#i` is bound to `2` after the second increment

### Requirement: Built-In Parse Macros Include Environment Lookup
The manifest evaluator SHALL provide built-ins `#Var`, `#If`, `#Eq`, `#Env`, and `#Inc`.

#### Scenario: Direct environment lookup by symbol
- **GIVEN** environment variable `HOME` is defined
- **WHEN** expression `(#Env HOME)` is evaluated
- **THEN** the result is the current value of `HOME`

#### Scenario: Environment lookup through macro variable indirection
- **GIVEN** expressions `(#Var #name HOME)` and `(#Env #name)`
- **WHEN** evaluated in order
- **THEN** `(#Env #name)` resolves using environment key `HOME`

### Requirement: Package Manifest Loading Uses Parse-Macro Mode
The `package.gene` loading path SHALL evaluate manifest expressions using manifest parse-macro mode before manifest data is consumed by dependency/package tooling.

#### Scenario: Environment-dependent package metadata value
- **GIVEN** a `package.gene` value field defined as `(#If (#Eq (#Env CI) "true") "ci" "local")`
- **WHEN** `CI=true` in the process environment
- **THEN** the resolved manifest value is `"ci"`

#### Scenario: Existing static manifest remains valid
- **GIVEN** a `package.gene` with no `#`-prefixed macro forms
- **WHEN** it is loaded
- **THEN** the resolved manifest data is equivalent to current static behavior

### Requirement: Manifest Parse-Macro Mode Is Safe and Deterministic
Manifest parse-macro mode SHALL reject unsupported macro calls and SHALL NOT execute arbitrary runtime functions while evaluating manifest data.

#### Scenario: Unknown parse macro is rejected
- **WHEN** expression `(#Unknown 1 2)` is encountered in manifest mode
- **THEN** loading fails with an error identifying unknown parse macro `#Unknown`
- **AND** the error includes source location

#### Scenario: Runtime call forms are not executed
- **WHEN** a non-parse-macro call form appears in manifest mode
- **THEN** the evaluator does not execute it as runtime code
- **AND** manifest loading either treats it as data or rejects it according to manifest schema validation rules
