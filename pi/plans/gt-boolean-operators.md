# GT – Boolean Operators Implementation Plan

## Overview
The **gt** project currently provides the `>` (greater‑than) operator for numeric comparisons.  To make the language richer and more expressive, we want to add a full suite of boolean comparison operators (e.g. `<`, `>=`, `<=`, `==`, `!=`).  These operators will be usable both from the REPL and in RPN scripts, and will follow the same design patterns as the existing `gt` implementation.

## Goals
1. **Feature completeness** – support the most common boolean operators:
   - `>`  (greater than) – already present
   - `<`  (less than)
   - `>=` (greater‑than‑or‑equal)
   - `<=` (less‑than‑or‑equal)
   - `==` (equal)
   - `!=` (not equal)
2. **Unified operator model** – introduce an interface/registry so that new operators can be added with minimal friction.
3. **REPL integration** – allow infix notation for all operators, with helpful auto‑completion and syntax highlighting.
4. **RPN integration** – provide postfix forms (e.g. `gt`, `lt`, `gte`, `lte`, `eq`, `neq`).
5. **Documentation** – update godoc, README, and example snippets for each operator.
6. **Testing & quality** – comprehensive unit tests, property‑based tests for edge cases (different numeric types, nil handling, overflow), and benchmarks.
7. **CI/Release** – ensure the CI pipeline verifies the new operators and bump the module version appropriately.

## Plan
1. **Design a generic Operator interface** and a registry that maps symbols (`>`, `<`, `>=`, …) and RPN names (`gt`, `lt`, …) to concrete implementations.
2. **Implement operator structs** (`LessThan`, `GreaterThanOrEqual`, `LessThanOrEqual`, `Equal`, `NotEqual`) that satisfy the interface, reusing existing comparison logic where possible.
3. **Update the REPL parser** to recognise the new symbols, perform tokenisation, and dispatch to the registry.
4. **Extend the RPN parser** to support the new postfix operator tokens and map them to the same implementations.
5. **Add unit tests** for each operator covering:
   - Various numeric types (int, float, unsigned).
   - Mixed‑type comparisons.
   - Edge cases (NaN, overflow, nil values).
   - Error handling for unsupported types.
6. **Write benchmarks** comparing the performance of the existing `gt` operator with the new implementations.
7. **Document the operators** in Godoc comments, update `README.md` with a comparison table, and add usage examples for REPL and RPN.
8. **Integrate with CI** – add linting, run the new test suite, and verify that the binary builds correctly.
9. **Version bump** – plan a minor version bump (e.g., `v0.2.0`) and prepare a changelog entry summarising the new boolean operators.

---
*This plan is stored at* `/home/paul/.pi/plans/gt-boolean-operators.md` *and serves as the reference for upcoming task creation.*