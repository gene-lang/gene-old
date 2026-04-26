# AOP implementation audit

This document is a current-state audit of Gene's aspect-oriented programming
(AOP) implementation. It is written for a maintainer who needs to classify AOP
behavior before the S02 proof pass and the S03 keep/remove/defer
recommendation.

The job of this page is not to promote AOP or preserve old proposal text. It
separates behavior into five buckets:

- **Implemented:** present in the Nim VM or stdlib registration path.
- **Verified:** implemented and backed by tracked executable fixtures.
- **Unverified:** visible in code but not yet covered by the S01 fixture map.
- **Unsupported:** not registered as current public behavior.
- **Stale:** design-era wording that contradicts the current runtime.

## Status and source of truth

**Status:** AOP is an implemented, narrow runtime surface that remains under
audit. It is not being promoted to the stable language boundary by this
document. The strategic recommendation is still pending: keep/remove/defer is
an S03 decision after S02 proof work.

**Source of truth:** runtime code and tracked fixtures outrank this historical
proposal text. Use these sources when resolving conflicts:

| Evidence source | What it establishes |
| --- | --- |
| `src/gene/stdlib/aspects.nim` | Live public registration for `(aspect ...)`, `Aspect.apply`, `Aspect.apply-fn`, `Aspect.enable-interception`, and `Aspect.disable-interception`. This module is the registration authority even though older helper code still exists elsewhere in stdlib. |
| `src/gene/types/type_defs.nim` | `Aspect`, `Interception`, `AopAfterAdvice`, `AopContext`, `VkAspect`, `VkInterception`, and the VM `aop_contexts` stack. |
| `src/gene/types/reference_types.nim` | Reference union arms that store `aspect` for `VkAspect` and `interception` for `VkInterception`. |
| `src/gene/compiler/operators.nim` | `(aspect ...)` is excluded from the regular fast-call path so it can remain macro-dispatched. |
| `src/gene/vm/dispatch.nim` and `src/gene/vm/exec.nim` | Invocation and dispatch behavior for `VkInterception`, including method calls, function calls, around advice, chaining, and inactive interceptions. |
| Tracked testsuite fixtures | Executable proof for the behaviors named in the verification table below. |
| `docs/feature-status.md` | AOP is outside the documented stable language boundary and should not be framed as a release guarantee. |

## Current public surface

### Aspect definition

AOP definitions use the native macro form:

```gene
(aspect Audit [method_name]
  (before method_name [x]
    (println "before" x)
  )
  (around method_name [x wrapped]
    (wrapped x)
  )
  (after method_name [x result]
    (println "after" result)
  )
)
```

The second argument is an array of aspect parameter names. Advice targets must
name one of those parameters. Application maps each parameter to a concrete
method or function name.

Supported advice forms are:

| Advice form | Current behavior |
| --- | --- |
| `before` | Runs before the wrapped callable. Multiple entries for the same parameter are stored in declaration order. |
| `before_filter` | Runs before normal `before` advice. A falsey result skips the wrapped callable and returns `nil`. |
| `invariant` | Runs before and after the wrapped callable when the call reaches the normal execution path. |
| `around` | Wraps the original callable. Only one `around` advice is allowed per aspect parameter. The wrapped callable is passed as the final argument. |
| `after` | Runs after a non-escaped call. If `^^replace_result` is present, the advice return value replaces the wrapped call result. |

Advice bodies can be inline function bodies, or they can be symbols that resolve
to `VkFunction` or `VkNativeFn` callables in the caller/runtime namespaces.

### Class method application: `.apply`

`(A .apply C "m1" "m2")` applies an aspect to class methods. The receiver must
be a `VkAspect`, the second argument must be a `VkClass`, and the remaining
string or symbol arguments must match the aspect parameter count.

Current semantics:

- class method application mutates `class.methods[method].callable` in place;
- each mapped method is replaced with a `VkInterception` wrapper;
- the method's previous callable is stored as the interception's `original`, so
  applying another aspect creates nested wrappers rather than a single global
  aspect list;
- the return value is an array of the created `VkInterception` values, which can
  later be passed to the per-interception toggle APIs.

### Function application: `.apply-fn`

`(A .apply-fn inc "f")` returns a `VkInterception` wrapper around a standalone
function, native function, or existing interception. The receiver must be a
`VkAspect`; the function argument must be `VkFunction`, `VkNativeFn`, or
`VkInterception`; and the parameter name must be one of the aspect's declared
parameters.

This means function-level AOP is implemented through explicit wrapper values:

```gene
(fn inc [x] (x + 1))
(var wrapped (A .apply-fn inc "f"))
(wrapped 4)
```

The original function binding is not changed by `.apply-fn`; callers must use
the returned wrapper if they want interception.

### Per-interception toggles

`(A .disable-interception interception)` and
`(A .enable-interception interception)` toggle the `active` flag on a specific
`VkInterception`. The interception must belong to the aspect receiver. When an
interception is inactive, dispatch calls the stored original callable directly.

These APIs are per wrapper. They are not a global aspect-level toggle.

## Runtime data model

AOP is represented with two public runtime value kinds and several supporting
objects.

| Runtime object | Role |
| --- | --- |
| `Aspect` | Stores the aspect name, parameter names, advice tables, single `around` advice table, `before_filter` table, and internal enabled flag. |
| `AopAfterAdvice` | Stores an after-advice callable plus `replace_result` and `user_arg_count`, which decide whether the current result is appended and whether the advice result replaces it. |
| `Interception` | Stores `original`, `aspect`, `param_name`, and `active`. This is the wrapper that dispatch recognizes. |
| `AopContext` | Captures wrapped callable state during intercepted execution: wrapped value, instance, positional args, keyword pairs, around-call state, caller frame, handler depth, and escape state. |
| `VkAspect` | The `ValueKind` used for aspect definitions. `Reference` stores the `aspect` payload for this arm. |
| `VkInterception` | The `ValueKind` used for applied wrappers. `Reference` stores the `interception` payload for this arm. |

The compiler deliberately keeps `(aspect ...)` out of the regular symbol-call
fast path. That lets the runtime treat it as a native macro that receives the
unevaluated advice definitions and registers the resulting `VkAspect` in the
caller namespace.

## Dispatch flow and execution order

VM call paths recognize `VkInterception` as callable for both standalone wrapper
values and class method callables. Standalone function wrappers enter dispatch
with no receiver. Class method wrappers enter dispatch with the method receiver,
and bound-method dispatch re-enters the same interception path if the bound
callable is a `VkInterception`.

`run_intercepted_method` is the central execution path:

1. If the interception is inactive, it immediately calls `call_interception_original`
   on the stored original callable and skips the disabled wrapper's advice. In a
   nested chain, any outer active wrapper still runs.
2. It validates that the wrapper points at a `VkAspect`, reads the mapped aspect
   parameter name, and prepares a wrapped callable. Method interceptions receive
   a bound method wrapper so around advice can call the original method with the
   same receiver.
3. It pushes an `AopContext` with the original callable, receiver, positional
   arguments, keyword pairs, caller frame, current exception-handler depth, and
   an `exception_escaped` flag.
4. If the aspect is enabled, each `before_filter` for the parameter runs first.
   A falsey filter result returns `nil` and prevents normal `before`, invariant,
   around/original, and after execution for that call.
5. Remaining pre-call advice runs in table order: FIFO `before` advice, then FIFO
   pre-call invariants.
6. If an `around` advice exists, the VM marks the context as in-around and calls
   the single stored around advice with the original positional arguments plus the
   wrapped callable as the final argument. Otherwise it calls
   `call_interception_original` directly. Registration stores only one around
   advice per aspect parameter; duplicate-around rejection still needs a negative
   S02 fixture before it should be called verified.
7. `call_interception_original` dispatches through the original kind. It executes
   standalone `VkFunction` values directly, executes methods with the receiver
   when one exists, calls `VkNativeFn` values with receiver/keyword shims as
   needed, and recursively invokes `run_intercepted_method` when the original is
   another `VkInterception`. That recursion is the chaining model: nested wrapper
   values, not one flattened global advice list.
8. Exception dispatch marks the active `AopContext` when a thrown value escapes
   past the handler depth captured at interception entry. When that escape flag
   is set, post-call invariants and after advice are skipped.
9. If no escape was marked, FIFO invariants run again after the original/around
   call, followed by FIFO after advice.
10. After-advice result handling is intentionally conservative. Inline advice
    with a declared argument count less than or equal to the intercepted
    positional argument count receives only the original positional arguments;
    symbol/callable advice with unknown arity, or inline advice declaring more
    arguments than the intercepted call supplied, also receives the current
    result appended. Only after advice marked `^^replace_result` replaces the
    wrapped call result with the advice return value.

Macro-like wrapped method calls have a special `call_bound_method` path: when an
around advice calls the wrapped bound method for the same receiver and original
callable, the VM can preserve the caller frame captured in `AopContext`. This is
code-present behavior; the S01 fixture set does not yet prove the macro-like
caller-context boundary.

## Verification map

The following claims may be treated as verified only after the focused AOP
fixtures pass. Each verified claim names the tracked fixture that proves it.
Runtime behavior outside this table is implemented or code-present evidence, not
S01-verified behavior yet.

| Verified behavior claim | Tracked fixture proof | What the fixture demonstrates |
| --- | --- | --- |
| Class method interception runs FIFO `before` advice, preserves `self`, executes the original method, runs FIFO `after` advice, and lets `^^replace_result` replace the final result. | `testsuite/07-oop/oop/2_aop_aspects.gene` | Two `before` entries print before the method, `/tag` resolves through the receiver, one after advice sees the current result and replaces it, and a later after advice runs without replacing it. |
| `before_filter` falsey results short-circuit an intercepted method and return `nil` without running later advice or the original method. | `testsuite/07-oop/oop/2_aop_aspects.gene`; `testsuite/07-oop/oop/4_aop_invariants.gene` | Negative `m2` calls print/filter to `result nil`; the invariant fixture shows no later before/invariant/around/after output for the filtered call. |
| Around advice receives a wrapped callable and can delegate to the original method or function. | `testsuite/07-oop/oop/2_aop_aspects.gene`; `testsuite/07-oop/oop/4_aop_invariants.gene`; `testsuite/05-functions/functions/6_aop_functions.gene` | Method and function fixtures print around output before the original callable output, proving delegation through the wrapped callable. |
| Invariants run before and after a non-escaped call, in declaration order. | `testsuite/07-oop/oop/4_aop_invariants.gene` | `inv1` then `inv2` print before around/original execution and again afterward for `m1`. |
| If the original call escapes with an error to the caller, post-call invariants and after advice are skipped. | `testsuite/07-oop/oop/4_aop_invariants.gene` | The throwing `m3` call prints before/invariant/around/original output and then `caught`, with no post-call invariant or after output. |
| Applying multiple aspects to the same method creates nested wrappers rather than one global advice list. | `testsuite/07-oop/oop/6_aop_chaining.gene` | The second-applied aspect runs its `before`, then the first wrapper runs, then the first `after`, then the second `after`; disabling the inner wrapper leaves the outer wrapper active. |
| Per-interception disable bypasses that wrapper and calls its stored original directly. | `testsuite/07-oop/oop/6_aop_chaining.gene` | Disabling the first aspect's captured interception removes A1 output from the second call while A2 output and the original method still run. |
| `.apply-fn` returns an explicit standalone function wrapper with before, around, and after advice. | `testsuite/05-functions/functions/6_aop_functions.gene` | The returned `wrapped` value prints before/around/original/after output around `inc`; the original binding is not mutated by this fixture. |
| Callable advice symbols resolve to existing Gene or native callables and receive receiver/argument/result values according to advice kind. | `testsuite/07-oop/oop/5_aop_callable_advices.gene` | `before_fn`, `after_fn`, and native `println` advice all run; native after advice receives receiver, original argument, and result. |

This page should only label additional behavior as verified when a later tracked
fixture proves it.

## Unsupported and stale design-era surfaces

The following items are not current supported public AOP behavior. They are kept
here only so maintainers can recognize stale proposal language and avoid copying
it into examples.

- `fn_aspect` is stale; current definitions use `(aspect ...)`.
- `.apply_in_place` is stale; class `.apply` mutates method callables in place,
  while `.apply-fn` returns an explicit wrapper for standalone functions.
- Constructor/destructor/exception join-point wording from the old proposal is
  unsupported; the registered advice forms are `before`, `before_filter`,
  `invariant`, `around`, and `after`.
- Global aspect `(A .disable)` and `(A .enable)` examples are stale; current
  public toggles are per-interception APIs.
- Regex/selector method matching is unsupported by the registered `.apply`
  implementation, which expects concrete method names as strings or symbols.
- Async advice isolation, unapply/reset, priority controls, and broad ordering
  policy beyond the current tables and wrapper nesting remain unproven.
- The old note saying "No function-level AOP" or "only instance methods" is
  stale; `.apply-fn` implements explicit standalone function wrappers.
- Any stable-core status claim is unsupported until a later decision explicitly
  changes the feature-status boundary.

## S02 proof candidates

S02 should decide whether the following code-present or suspected behaviors are
verified, unsupported, or in need of a narrow patch:

- `.enable-interception` positive and negative paths;
- malformed `.apply` and `.apply-fn` inputs, including wrong receiver, missing
  class/function, unknown parameter, and mismatched method count;
- keyword-argument boundaries for intercepted methods and standalone functions;
- chaining `.apply-fn` around an existing `VkInterception`;
- macro-like around advice caller-context behavior;
- advice-thrown error behavior and whether post-call advice is skipped; and
- callable advice lexical capture.

Until that proof exists, keep/remove/defer remains open.
