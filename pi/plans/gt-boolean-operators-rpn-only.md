# GT – Boolean Operators (RPN Only) Implementation Plan

## Overview
The **gt** project currently evaluates arithmetic and percentage expressions via a REPL that supports RPN (postfix) syntax.  To make the language more expressive we will add a full set of Boolean comparison operators, but **only** in the existing RPN form.  No infix parsing will be introduced.

## Goals
- Provide the six common comparison operators as postfix tokens:
  - `gt`  → `>`  (greater than)
  - `lt`  → `<`  (less than)
  - `gte` → `>=` (greater‑than‑or‑equal)
  - `lte` → `<=` (less‑than‑or‑equal)
  - `eq`  → `==` (equal)
  - `neq` → `!=` (not equal)
- Extend the RPN stack to store boolean values alongside numbers.
- Ensure the new operators work with all numeric types supported by the existing calculator (int, float, unsigned) and handle edge cases (NaN, Inf, division‑by‑zero). 
- Add thorough unit tests and update documentation.
- Integrate the changes into the CI pipeline and bump the project version.

## Plan:
1. Extend the REPL value system to support a boolean type for RPN stack values.
2. Implement the postfix operator `gt` (greater‑than) as an RPN operator.
3. Implement the postfix operator `lt` (less‑than) as an RPN operator.
4. Implement the postfix operator `gte` (greater‑than‑or‑equal) as an RPN operator.
5. Implement the postfix operator `lte` (less‑than‑or‑equal) as an RPN operator.
6. Implement the postfix operator `eq` (equal) as an RPN operator.
7. Implement the postfix operator `neq` (not‑equal) as an RPN operator.
8. Register all new operators in the RPN operator registry.
9. Update the existing `RPNHandler` to recognize and dispatch the new operator symbols.
10. Add unit tests for each new operator covering numeric types, mixed‑type comparisons, and edge cases (NaN, Inf, zero divisor).
11. Update godoc comments for each operator and extend `README.md` with a table of Boolean operators and RPN usage examples.
12. Modify the CI pipeline to run the new tests, bump the module version to the next minor (e.g., `v0.2.0`), and add a changelog entry documenting the new Boolean operators.
