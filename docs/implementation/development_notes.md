# Questions for Claude Code Session

## Implementation Questions

### 1. Variable Declaration Without Value Issue

**Problem**: The test `(var a) (a = 2) a` fails with "index 255 not in 0 .. 19 [IndexDefect]"

**Analysis**: 
- Compiler generates correct instructions: `IkVarValue nil 0` 
- VM implementation added for `IkVarValue` but something is wrong with value conversion
- The error occurs during `IkVarResolve` execution when trying to access `inst.arg0.int`

**Question**: Is there an issue with how `Value(0)` is converted to `int`? The `Value` type is `distinct int64`, but the conversion from `Value` to `int` might be problematic.
A: this can be something related to scope variable resolving issue, not related to value conversion.

### 2. Range Implementation

**Problem**: Range functions `(range 0 100)` and `(0 .. 100)` cause segmentation faults

**Analysis**:
- Added `IkCreateRange` instruction and `new_range_value` function
- VM implementation added but runtime crashes
- May be related to memory management or reference counting

**Question**: Should ranges be implemented as reference types or value types? The current implementation uses `new_ref(VkRange)` but this might not be correct for the VM architecture.
A: Value's size is 8 bytes. Range doesn't fit in 8 bytes.

### 3. Language Feature Scope

**Priority Order** (from test analysis):
1. ✅ `self` keyword fixed  
2. ✅ `(nil || 1)` truthy operator fixed
3. ❌ Variable declaration without value `(var a)`
4. ❌ Compound assignment operators `+=`, `-=`
5. ❌ Namespace operations `$ns/a` 
6. ❌ Property access `/` for arrays and objects
7. ❌ Control flow: `elif`, `then`, `not`, `continue`, `while`
8. ❌ Special operations: `void`, `$with`, `$tap`, `eval`, `$parse`
9. ❌ Array/gene spread operator `...`
10. ❌ Gene expressions with properties ``(`test ^a a b)``

**Question**: What's the priority order for implementing these features? Should we focus on completing the basic variable system first, or move to other features?
A: 3 6 7 4 8 5 9 10

### 4. Test Coverage Strategy

**Current Status**: 
- 20+ basic tests passing
- 15+ advanced tests failing  
- Range tests temporarily disabled due to segfaults

**Question**: Should we implement features incrementally (get basic ones working first) or tackle the most blocking issues first?
A: Incrementally but get all tests in one test_x file before moving to next one.

## Next Steps Needed

1. **Fix `(var a)` issue**: Debug the Value to int conversion problem
2. **Implement compound assignment**: Add `+=`, `-=` operators to compiler and VM
3. **Add namespace support**: Implement `$ns` resolution and `/` property access
4. **Complete control flow**: Add `elif`, `then`, `not`, `continue`, `while` constructs
5. **Add special operations**: Implement `void`, `$with`, `$tap`, `eval`, `$parse`

## Architecture Questions

**VM vs Interpreter Trade-offs**: The current VM implementation requires more complex instruction handling compared to the tree-walking interpreter in gene-new. Should we simplify some features to match the VM architecture better?
A: let's try to enhance the VM unless it's too hard or incompatible with the VM architecture.

**Memory Management**: Some features like ranges and complex objects may need careful memory management in the VM. Should we implement a more robust reference counting system?
A: let's keep the current reference counting system for now.
