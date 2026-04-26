# AOP implementation audit

This page is a current-state audit of Gene's aspect-oriented programming
(AOP) implementation. It is written for the maintainer who will make the S03
keep/remove/defer recommendation after the S02 proof pass.

The post-read action is narrow: decide which AOP behaviors are executable facts,
which behaviors are current unsupported boundaries, and which inputs remain for
S03. This page does not choose keep, remove, or defer.

## Status and source of truth

**Status:** AOP is an implemented runtime surface under audit. This document does
not promote AOP to a core language guarantee. The strategic recommendation is
pending S03: keep/remove/defer remains open after S02.

**Source of truth:** runtime behavior and tracked testsuite fixtures outrank old
proposal text. When this document conflicts with executable behavior, update the
document or add a fixture before treating the behavior as a public claim.

| Evidence source | What it establishes |
| --- | --- |
| Aspect stdlib registration | Live public registration for `(aspect ...)`, `Aspect.apply`, `Aspect.apply-fn`, `Aspect.enable-interception`, and `Aspect.disable-interception`. |
| Runtime type model | `Aspect`, `Interception`, `AopAfterAdvice`, `AopContext`, `VkAspect`, and `VkInterception` are the value and context objects used by dispatch. |
| Compiler dispatch rules | `(aspect ...)` stays out of the regular fast-call path so the native macro receives unevaluated advice definitions. |
| VM dispatch | `VkInterception` is callable for standalone wrappers and class method wrappers, with around advice, disabled wrappers, chaining, and escape handling. |
| Tracked S02 fixtures | Executable proof for each behavior named in the verification map below. |
| Feature-status documentation | AOP is outside the documented guaranteed feature boundary unless a later decision changes that status. |

## Current public surface

### Aspect definitions

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
to existing Gene or native callables in the caller/runtime namespaces.

### Class method application

`(A .apply C "m1" "m2")` applies an aspect to class methods. The receiver must
be an aspect, the second argument must be a class, and the remaining string or
symbol arguments must match the aspect parameter count.

Current semantics:

- class method application mutates the selected class method callables in place;
- each mapped method is replaced with an interception wrapper;
- the method's previous callable is stored as the wrapper's original callable,
  so applying another aspect creates nested wrappers;
- the return value is an array of the created wrapper values, which can later be
  passed to the per-interception toggle APIs.

### Standalone function application

`(A .apply-fn inc "f")` returns an interception wrapper around a standalone
function, native function, or existing interception. The receiver must be an
aspect; the function argument must be a function, native function, or existing
interception; and the parameter name must be one of the aspect's declared
parameters.

Function-level AOP is therefore explicit wrapper behavior:

```gene
(fn inc [x] (x + 1))
(var wrapped (A .apply-fn inc "f"))
(wrapped 4)
```

The original function binding is not changed by `.apply-fn`; callers must use
the returned wrapper if they want interception.

### Per-interception toggles

`(A .disable-interception interception)` and
`(A .enable-interception interception)` toggle the active flag on a specific
interception wrapper. The interception must belong to the aspect receiver. When
an interception is inactive, dispatch calls the stored original callable
directly.

These APIs are per wrapper. They are not whole-aspect toggles.

## Dispatch flow

Interception dispatch handles both standalone wrapper values and class method
callables.

1. If the interception is inactive, dispatch immediately calls the stored
   original callable and skips that wrapper's advice. Outer active wrappers in a
   nested chain still run.
2. If active, dispatch prepares an AOP context containing the original callable,
   receiver when present, positional arguments, keyword pairs, caller frame,
   handler depth, and escape state.
3. `before_filter` advice runs first. A falsey filter result returns `nil` and
   prevents normal `before`, invariant, around/original, and after execution for
   that call.
4. FIFO `before` advice runs, followed by FIFO pre-call invariants.
5. A single `around` advice can call the wrapped callable; without around advice,
   dispatch calls the stored original callable directly.
6. If the call escapes past the captured handler depth, post-call invariants and
   after advice are skipped.
7. Otherwise, FIFO post-call invariants run, then FIFO `after` advice runs.
   `^^replace_result` after advice can replace the final result.

## Verified S02 proof map

Each row below is backed by a tracked testsuite fixture in the focused S02 proof
command.

| Verified behavior claim | Tracked fixture proof | What the fixture demonstrates |
| --- | --- | --- |
| Class method interception runs FIFO `before` advice, preserves `self`, executes the original method, runs FIFO `after` advice, and lets `^^replace_result` replace the final result. | `2_aop_aspects.gene` | Two `before` entries print before the method, receiver state is available, an after advice sees the current result and replaces it, and a later after advice runs without replacing it. |
| `before_filter` falsey results short-circuit an intercepted method and return `nil` without running later advice or the original method. | `2_aop_aspects.gene`; `4_aop_invariants.gene` | Filtered calls return `nil`; the invariant fixture shows no later before/invariant/around/after output for the filtered call. |
| Around advice receives a wrapped callable and can delegate to the original method or function. | `2_aop_aspects.gene`; `4_aop_invariants.gene`; `6_aop_functions.gene` | Method and function fixtures print around output before original callable output, proving delegation through the wrapped callable. |
| Invariants run before and after a non-escaped call, in declaration order. | `4_aop_invariants.gene` | Two invariants print in order before around/original execution and again afterward. |
| If the original call escapes with an error to the caller, post-call invariants and after advice are skipped. | `4_aop_invariants.gene` | The throwing method prints pre-call advice and original output, then the catch marker, with no post-call invariant or after output. |
| Applying multiple aspects to the same method creates nested wrappers rather than one shared advice list. | `6_aop_chaining.gene` | The second-applied aspect runs outside the first-applied aspect; disabling the inner wrapper leaves the outer wrapper active. |
| Per-interception disable bypasses that wrapper and calls its stored original directly. | `6_aop_chaining.gene`; `10_aop_interception_controls.gene`; `11_aop_function_boundaries.gene` | Disabling one captured wrapper removes only that wrapper's advice. Re-enabling restores it. Wrong-owner and non-interception toggle inputs are catchable errors. |
| `.apply-fn` returns an explicit standalone function wrapper with before, around, and after advice. | `6_aop_functions.gene`; `11_aop_function_boundaries.gene` | Wrapped standalone functions run advice around the original callable. The original function binding remains callable without interception. |
| Callable advice symbols resolve to existing Gene or native callables and receive receiver/argument/result values according to advice kind. | `5_aop_callable_advices.gene` | Gene advice functions and native `println` advice both run through the class method interception path. |
| Malformed class and function application inputs fail through catchable errors. | `10_aop_interception_controls.gene`; `11_aop_function_boundaries.gene` | Missing method mappings, duplicate around advice, bad advice targets, invalid `^^replace_result`, missing `.apply-fn` arguments, non-callable function inputs, and unknown function parameters are rejected. |
| Intercepted class methods can receive keyword arguments. | `10_aop_interception_controls.gene` | The advice reads receiver state and the wrapped method receives keyword arguments correctly. |
| Advice-thrown errors stop the wrapped method and later advice while allowing the caller to catch and continue. | `10_aop_interception_controls.gene` | A throwing `before` advice prevents method and after-advice execution, is caught by the caller, and execution continues. |
| Standalone `.apply-fn` wrappers reject keyword-argument calls. | `11_aop_function_boundaries.gene` | Calling a wrapped standalone function with keywords is caught as the current boundary rather than treated as supported behavior. |
| `.apply-fn` can wrap an existing interception value, producing explicit nested function wrappers. | `11_aop_function_boundaries.gene` | Inner and outer wrapper advice run in nested order around the original standalone function. |
| Inline advice lexical capture is patched for the narrow S02 case. | `12_aop_callable_capture.gene` | Symbol advice and inline advice defined inside a factory both capture lexical locals after the S02 scope-tracker patch. |
| Macro-style standalone functions still work directly, but `.apply-fn` wrappers do not preserve quoted-argument behavior. | `13_aop_macro_boundary.gene` | A direct `fn!` call receives the symbol argument. The wrapped call receives an evaluated value, and an undefined symbol argument is caught before wrapper advice/original execution. |

## Patched behavior in S02

The S02 runtime patch is intentionally narrow: inline advice functions generated
by the aspect macro inherit the caller scope tracker before matcher locals are
added. That lets inline advice bodies resolve lexical locals from the scope where
the aspect was defined.

The patch does not change wrapper dispatch, keyword behavior, macro-style call
evaluation, class method application, or stale design-era APIs. The executable
proof for the patch is `12_aop_callable_capture.gene`.

## Unsupported, stale, and boundary surfaces

The following items are not current supported public AOP behavior. They are kept
here only so maintainers can recognize stale proposal language and avoid copying
it into examples.

- `fn_aspect` is stale; current definitions use `(aspect ...)`.
- `.apply_in_place` is stale; class method application mutates method callables
  in place, while `.apply-fn` returns an explicit wrapper for standalone
  functions.
- Constructor/destructor/exception join-point wording from the old proposal is
  unsupported. Design-era names such as `before_init`, `after_init`,
  `destruction`, and `after exception` are not registered advice forms.
- Global aspect `(A .disable)` and `(A .enable)` examples are stale; current
  public toggles are per-interception APIs.
- Regex/selector method matching is unsupported by the registered class method
  application path, which expects concrete method names as strings or symbols.
- Async advice isolation, unapply/reset, priority controls, and broad ordering
  policy beyond the current advice tables and wrapper nesting remain unproven.
- The old note saying "No function-level AOP" or "only instance methods" is
  stale; `.apply-fn` implements explicit standalone function wrappers.
- Standalone `.apply-fn` keyword calls are unsupported even though intercepted
  class methods can receive keyword arguments.
- `.apply-fn` wrapping of `fn!` macro-style functions is a current boundary, not
  a future promise. Direct `fn!` calls can receive quoted arguments. The wrapper
  path is not macro-transparent: defined arguments are evaluated before the
  wrapper runs, and undefined quoted-symbol arguments fail before advice/original
  execution.
- Macro-like class methods and macro-like constructors are rejected elsewhere in
  the language and should not be inferred as an AOP capability.
- Any core-guarantee claim is unsupported until a later decision explicitly
  changes the feature-status boundary.

## S03 recommendation inputs

S03 should make the keep/remove/defer recommendation from these facts:

- AOP has real executable coverage for class method wrappers, standalone
  function wrappers, interception toggles, chaining, callable advice, inline
  lexical capture, and controlled error boundaries.
- The S02 code patch was narrow and targeted inline advice lexical capture only.
- The current surface still has sharp boundaries: standalone keyword calls are
  rejected, macro-style wrapper calls do not preserve quoted arguments, and old
  proposal APIs remain stale.
- The feature is not yet framed as a guaranteed public boundary. Promotion,
  removal, or deferral should be an explicit S03 decision rather than an implied
  result of this audit.
