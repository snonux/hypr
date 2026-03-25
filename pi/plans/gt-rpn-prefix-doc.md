# GT – RPN Prefix Optional – Documentation & Tests Plan

## Background
The REPL currently supports evaluating RPN expressions in three ways:
1. Explicit `rpn` (or `calc`) prefix – `rpn 3 4 +`
2. Implicit RPN when the input contains spaces – `3 4 +`
3. Incremental operator handling – entering a single operator after previous tokens.

Because of the second case, users can omit the `rpn` prefix entirely and still get RPN evaluation. This behavior is not clearly documented, which can lead to confusion.

## Goal
Make it explicit in the user‑facing documentation that the `rpn` prefix is optional and that any space‑separated expression is treated as RPN. Add unit tests to guard against regression.

## Plan
1. **Update README.md** – add a section titled *"RPN usage (prefix optional)"* with clear examples showing both prefixed and unprefixed forms.
2. **Update godoc for `RPNHandler`** – clarify in the handler comment that it treats space‑separated inputs as RPN when no built‑in command matches.
3. **Add unit tests** in `internal/repl/handlers_test.go` (or a new test file) that verify expressions like `"3 4 +"` and `"rpn 3 4 +"` produce the same result.
4. **Ensure CI runs the new tests** – modify any test scripts if needed to include the new test file.
5. **Add a changelog entry** indicating the documentation update and added tests (e.g., `v0.2.2 – clarified RPN prefix optional`).

---
*Plan file stored at* `/home/paul/.pi/plans/gt-rpn-prefix-doc.md` *for reference.*