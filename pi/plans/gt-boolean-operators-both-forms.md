# GT – Boolean Operators (RPN) – Support Symbolic Forms

## Rationale
- The original design used the word tokens `gt`, `lt`, `gte`, `lte`, `eq`, `neq` because they are unambiguous when typed after the `rpn` command and avoid any shell‑level redirection issues (e.g., `>` can be interpreted by the shell if the user does not quote the expression).
- Users coming from other RPN calculators or from infix languages naturally expect the symbolic forms (`>`, `<`, `>=`, `<=`, `==`, `!=`).  Providing both forms improves discoverability and ergonomics without breaking existing scripts that already use the word forms.
- Adding symbolic aliases is straightforward: the `OperatorRegistry` already maps token strings to handler functions.  We can register the symbols as synonyms for the same implementation used by the word tokens.

---
## Example REPL syntax (both word and symbol forms)
```text
# Word forms
> rpn 5 3 gt        # → true
> rpn 7 7 eq        # → true
> rpn a 5 3 gt =    # store true in variable "a"

# Symbolic forms (quoted to avoid shell redirection if needed)
> rpn 5 3 >          # → true
> rpn 7 7 ==         # → true
> rpn a 5 3 > =      # store true in variable "a"
```
Both `gt` and `>` (as well as the other operators) evaluate to the same result.

---
## Plan:
1. Extend `OperatorRegistry` to register symbolic aliases: map `>` to the same handler as `gt`, `<` to `lt`, `>=` to `gte`, `<=` to `lte`, `==` to `eq`, and `!=` to `neq`.
2. Implement the six Boolean operator handlers (`gt`, `lt`, `gte`, `lte`, `eq`, `neq`) if not already present, using the existing `Number` comparison methods.
3. Ensure the RPN parser treats both word and symbol tokens as standard operators (no changes to tokenization needed).
4. Add unit tests covering both forms for each operator, checking numeric and mixed‑type comparisons.
5. Update documentation (`README.md` and godoc comments) to list both the word and symbolic tokens with usage examples.
6. Update the CI pipeline to run the new tests and bump the project version (e.g., `v0.2.1`).

---
*This plan is stored at* `/home/paul/.pi/plans/gt-boolean-operators-both-forms.md` *and serves as the reference for any upcoming tasks.*