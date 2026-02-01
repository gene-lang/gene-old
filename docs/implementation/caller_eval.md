# $caller_eval Design Document

## Overview

`$caller_eval` is a special form used within macros that allows evaluation of expressions in the caller's context rather than the macro's context. This is essential for hygiene-breaking macros that need to access or modify variables in the calling scope.

## Current Understanding

### Example Usage
```gene
(macro m []
  ($caller_eval `a)
)
(fn f []
  (var a 1)
  (m)  # Should return 1
)
```

### Key Requirements
1. Must capture the caller's execution context (frame, scope, namespace)
2. Must be able to evaluate arbitrary expressions in that context
3. Must return the result back to the macro for further processing
4. Must handle nested macro calls correctly

## Design Questions

### 1. Context Capture
**Question**: When should we capture the caller's context?
- Option A: Capture at macro call site (in IkGeneStartDefault)
- Option B: Capture when entering macro body (in IkGeneEnd)
- Option C: Only capture when $caller_eval is actually used
Answer: A

**Considerations**:
- Memory overhead of always capturing context
- Performance impact
- Complexity of implementation

### 2. Context Storage
**Question**: Where should we store the caller's context?
- Option A: Add caller_context field to Frame
- Option B: Add caller_context field to Macro
- Option C: Use a stack of contexts in VirtualMachine
- Option D: Pass context as implicit argument to macro
Answer: D

**Considerations**:
- Need to handle nested macro calls
- Must survive across instruction boundaries
- Should be accessible from within macro execution

### 3. Execution Model
**Question**: How should $caller_eval execute the expression?
- Option A: Compile expression and execute in saved context
- Option B: Interpret expression directly in saved context
- Option C: Generate special instructions that switch contexts
Answer: A

**Considerations**:
- Compilation overhead vs interpretation overhead
- Complexity of context switching
- Stack management during context switch

### 4. Scope Resolution
**Question**: How should variable lookup work in $caller_eval?
- Should it see only caller's local variables?
- Should it see caller's namespace members?
- What about nested scopes in the caller?
- How to handle 'self' reference?
A: should work the same as normal execution with new scope created as needed

### 5. Return Path
**Question**: How should results flow back to the macro?
- Option A: Push result on macro's stack
- Option B: Store in temporary location
- Option C: Use special return instruction
Answer: like how function returns result to caller

### 6. Error Handling
**Question**: How should errors in $caller_eval be handled?
- Should exceptions propagate to caller or macro?
- How to report location of errors?
- What about stack traces?
Answer: similar to how function calls work

## Proposed Design

### Phase 1: Basic Implementation
1. Add `caller_frame` field to Frame type
2. Capture caller's frame when entering macro (in IkGeneEnd for FkMacro)
3. Add IkCallerEval instruction
4. Implement basic variable lookup in caller's scope

### Phase 2: Full Implementation
1. Handle namespace resolution
2. Support arbitrary expressions (not just variable lookup)
3. Handle nested macro calls
4. Implement proper error handling

## Implementation Challenges

### 1. Circular Dependencies
- compiler.nim needs to recognize $caller_eval
- vm.nim needs to handle IkCallerEval
- types.nim needs frame modifications

### 2. State Management
- Must carefully save/restore execution state
- Stack pointer management is critical
- Program counter must be handled correctly

### 3. Testing
- Need tests for nested macros
- Need tests for error cases
- Need tests for different scope scenarios

## Questions for Design Decision

1. **Scope of Implementation**: Should we implement full expression evaluation or start with just variable lookup?
Answer: full expression evaluation

2. **Performance vs Simplicity**: Should we optimize for the common case (simple variable lookup) or implement general expression evaluation from the start?
Answer: implement general expression evaluation from the start

3. **API Compatibility**: Should $caller_eval work exactly like the reference implementation, or can we make improvements?
Answer: should be compatible with the new design

4. **Security Concerns**: Should there be any restrictions on what $caller_eval can access?
Answer: no restrictions

5. **Debugging Support**: How can we make debugging of $caller_eval expressions easier?
Answer: defer this to later

## Next Steps

1. Decide on answers to key design questions
2. Implement basic prototype with variable lookup only
3. Test with existing test cases
4. Extend to full expression evaluation
5. Handle edge cases and error conditions

## Alternative Approaches

### A. Template-based Approach
Instead of runtime evaluation, expand $caller_eval at compile time:
- Pro: Better performance
- Con: Less flexible, can't handle dynamic expressions

### B. Continuation-based Approach
Treat $caller_eval as a continuation that captures the entire call stack:
- Pro: Very powerful and general
- Con: Complex to implement, may have performance overhead

### C. Two-phase Compilation
Compile macros in two phases - first collect $caller_eval expressions, then compile with context:
- Pro: Can optimize better
- Con: Requires significant compiler changes
