# GT – Boolean‑to‑Number Coercion (RPN) Implementation Plan

## Overview
The GT REPL will support arithmetic operations that involve booleans by automatically converting `true` → `1` and `false` → `0`.  This allows expressions such as `5 3 == 1 +` to evaluate correctly without explicit conversion steps.

---

## Examples
The following REPL interactions illustrate how booleans are automatically coerced to numbers (`true` → 1, `false` → 0) and can participate in arithmetic operations.

```
> 5 3 == 1 +      # → 2
> 5 3 > 10 +      # → 11
> 0 false +       # → 0
> true 2 *        # → 2
> 9 3 > 4 5 < +   # → 2
```

In each case the boolean result is shown as `true`/`false` when printed, but when used as an operand it behaves as the corresponding numeric value.

## Plan
1. Extend the internal stack/value type to store a variant that can be either a `float64` or a `bool`.
2. Add a helper `toNumber(v Value) float64` that returns `1` for `true`, `0` for `false`, or the numeric value otherwise.
3. Update each arithmetic operator implementation (`Add`, `Subtract`, `Multiply`, `Divide`, `Modulo`, `Power`) to call `toNumber` on both operands before performing the calculation.
4. Implement Boolean operators (`gt`, `lt`, `gte`, `lte`, `eq`, `neq`) to push a boolean `Value` onto the stack.
5. Modify `Show` to display boolean values as `true`/`false` while still allowing them to be used in arithmetic via the coercion helper.
6. Write unit tests covering mixed boolean‑numeric expressions, e.g. `5 3 == 1 +` → `2`, `0 false +` → `0`, `true 2 *` → `2`.
7. Update `README.md` and godoc comments to document the automatic coercion rule and provide usage examples.
8. Add the new test suite to CI, ensure it runs on every build, and bump the project version (e.g., to `v0.2.2`).

---
*This plan is stored at* `/home/paul/.pi/plans/gt-boolean-numeric-coercion.md` *and serves as the reference for any upcoming tasks.*