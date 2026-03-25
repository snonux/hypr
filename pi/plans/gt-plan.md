# Project gt – Gap Analysis and Improvement Plan

## Overall Picture & Goals

- Provide a reliable, well‑documented command‑line percentage calculator with RPN and rational number support.
- Deliver a smooth developer experience: clear contribution guidelines, automated CI/CD, and proper versioning.
- Ensure the codebase follows Go best practices, has comprehensive tests, and ships a stable binary.

Plan:

1. **Fix CI build step** – Update GitHub Actions workflow to build the correct binary path (`./cmd/gt` instead of `./cmd/perc`).
2. **Update `go.mod` Go version** – Change the `go` directive to a supported version (e.g. `go 1.22`) to match the CI Go version.
3. **Add `CONTRIBUTING.md`** – Provide guidelines for building, testing, using `mage`, and submitting pull requests.
4. **Expand README** – Include concrete examples for rational‑mode (`rat on/off/toggle`) and hyper‑operators (`[+]`, `[*]`, etc.).
5. **Add badges to README** – CI status, test coverage, and Go Report Card badges.
6. **Add end‑to‑end CLI tests** – Test the built binary for commands like `gt version`, `gt 20% of 150`, and `gt help`.
7. **Add REPL command tests** – Cover built‑in commands (`help`, `clear`, `quit`, `rat`) and variable management (`vars`, `clear`, `name d`).
8. **Add `.goreleaser.yml`** – Set up automated release builds and GitHub releases.
9. **Implement version bump workflow** – Use the `increment-version-and-push` skill to bump the version, tag, and push.
10. **Document variable management** – Add a dedicated README section describing `vars`, `clear`, and variable deletion commands.
11. **Update Magefile** – Add shortcuts for build, test, lint, and release.
12. **Add missing Go documentation** – Ensure all exported functions in the REPL package (`NewREPL`, `RunREPL`, `executor`, `defaultExecutor`, `defaultCompleter`, `defaultGetCommandDescription`) have godoc comments.
13. **Add go vet step to CI workflow** – Include a `go vet ./...` step in the GitHub Actions CI configuration to catch static analysis issues.
14. **Add godoc comments for exported TTYChecker methods (IsTTY, EnsureTTY)**.
15. **Add godoc comments for exported SignalHandler methods (Start, Stop)**.
16. **Add SPDX license headers to all .go source files**.
17. **Wrap errors with %w where appropriate for better error chaining**.
18. **Design a nice logo for the gt project (e.g., stylized 'gt' with calculator motif)**.

