## MODIFIED Requirements

### Requirement: Quote Macro Prefix
The reader SHALL treat backtick (`) as the quote macro for the next form, equivalent to `(quote <form>)`.

#### Scenario: Quote symbol
- **WHEN** the input is `` `a ``
- **THEN** the parsed value is equivalent to `(quote a)`

#### Scenario: Quote gene
- **WHEN** the input is `` `(if true 1 0) ``
- **THEN** the parsed value is equivalent to `(quote (if true 1 0))`

### Requirement: Colon Tokens
The reader SHALL treat `:` as a normal constituent character for symbols; leading-colon tokens are symbols with the leading `:` preserved.

#### Scenario: Leading colon symbol
- **WHEN** the input is `:a`
- **THEN** the parsed value is a symbol named `:a`

#### Scenario: No quote expansion for colon
- **WHEN** the input is `:(+ 1 2)`
- **THEN** the reader SHALL NOT treat `:` as a quote macro

## REMOVED Requirements

### Requirement: Colon Quote Prefix
The reader no longer treats `:` as a quote macro prefix.

#### Scenario: Deprecated colon quote
- **WHEN** the input is `:a`
- **THEN** it is parsed as a symbol named `:a`, not as `(quote a)`
