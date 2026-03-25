# GT – Boolean Operators (RPN‑Only) – Example Syntax

## Overview
This plan adds a full set of Boolean comparison operators to the **gt** REPL, **exclusively** in RPN (postfix) form.  The operators will be registered in the RPN handler, the RPN value system will be extended to hold booleans, and the change will be documented with usage examples.

---
## Example REPL syntax
```text
> rpn 5 3 gt        # → true   (5 > 3)
> rpn 3 5 lt        # → true   (3 < 5)
> rpn 4 4 gte       # → true   (4 >= 4)
> rpn 2 2 lte       # → true   (2 <= 2)
> rpn 7 7 eq        # → true   (7 == 7)
> rpn 5 7 neq       # → true   (5 != 7)
> rpn 10 0 gt       # → false  (10 > 0 is false) 

# Variable assignment with a Boolean result
> rpn a 5 3 gt =    # stores true in variable "a"
> rpn a              # → true
```
The operators `gt`, `lt`, `gte`, `lte`, `eq`, and `neq` are the only new tokens; all other REPL functionality remains unchanged.

---
## Plan
1. Extend the internal RPN value type to represent booleans alongside numbers.
2. Implement the six postfix Boolean operators (`gt`, `lt`, `gte`, `lte`, `eq`, `neq`) and register them in the RPN operator registry.
3. Add unit tests and update documentation (godoc and README) with the example syntax above.

---
*This plan is stored at* `/home/paul/.pi/plans/gt-boolean-operators-rpn-only-example.md` *and serves as the reference for any future tasks.*