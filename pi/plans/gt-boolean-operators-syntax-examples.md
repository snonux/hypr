# GT – Boolean Operators (RPN) – Syntax Examples

## Overview
We are extending the **gt** REPL with a full set of Boolean comparison operators, usable **only** in RPN (postfix) form.  The operators will be available in two token styles:
- **Word form** – `gt`, `lt`, `gte`, `lte`, `eq`, `neq`
- **Symbolic form** – `>`, `<`, `>=`, `<=`, `==`, `!=`

Both forms map to the same underlying implementation, allowing users to pick the style they prefer while keeping backward compatibility.

---
## Example REPL syntax
```text
# Word forms
> rpn 5 3 gt        # → true   (5 > 3)
> rpn 7 7 eq        # → true   (7 == 7)
> rpn a 10 2 lt =    # store true in variable "a"
> rpn a               # → true

# Symbolic forms (quote the expression if your shell would interpret the symbols)
> rpn 5 3 >          # → true
> rpn 7 7 ==         # → true
> rpn a 10 2 < =      # store true in variable "a"
> rpn a               # → true

# Mixed usage across the same session
> rpn 8 4 gte        # → true
> rpn 8 4 >=         # → true
> rpn 8 4 neq        # → false
> rpn 8 4 !=         # → false
```
All operators push a **boolean** (`true`/`false`) onto the stack, which can be stored in variables or inspected with `show`.

---
## Goals
1. Provide the six Boolean operators in both word and symbolic token forms.
2. Extend the RPN value system to store booleans alongside numbers.
3. Ensure existing REPL behavior (stack, variables, commands) stays unchanged.
4. Document the syntax with clear examples (as shown above).
5. Add comprehensive unit tests and CI verification.

---
## Plan
1. Implement the Boolean operator handlers (`gt`, `lt`, `gte`, `lte`, `eq`, `neq`) using the `Number.Compare` method and push a boolean onto the stack.
2. Register symbolic aliases (`>`, `<`, `>=`, `<=`, `==`, `!=`) in the `OperatorRegistry` as synonyms for the word forms.
3. Extend the `Stack` (or introduce a new stack type) to hold a `Value` that can represent either a `float64` or a `bool`.
4. Update `Show` to display booleans as `true`/`false` while preserving numeric formatting.
5. Write unit tests for each operator, covering numeric, mixed‑type, and edge cases (NaN, Inf, zero).
6. Add documentation to `README.md` and godoc comments, including the example syntax block above.
7. Update the CI pipeline to run the new tests, bump the module version (e.g., `v0.2.1`), and generate a changelog entry.

---
*This plan is stored at* `/home/paul/.pi/plans/gt-boolean-operators-syntax-examples.md` *and serves as the reference for any upcoming tasks.*