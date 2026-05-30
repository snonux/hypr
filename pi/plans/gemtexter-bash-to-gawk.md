# Plan: Convert gemtexter from GNU Bash to GNU Awk

## Overview

Assess feasibility of porting gemtexter from GNU Bash to GNU Awk (gawk), considering the extensive use of bash-specific features.

## Current State Analysis

The gemtexter project (~1000 LOC) consists of:
- **Main script** (`gemtexter`) - CLI entry point, sourcing, argument parsing
- **10 library files** in `lib/` - source'd by main script
- **Key features**: namespaced functions, associative arrays, process substitution, background jobs, eval for templates, parallel generation

## Feasibility Assessment: **MEDIUM-HIGH COMPLEXITY**

### Awk-Can-Do ✅
- All text processing (Gemtext → HTML/MD)
- File I/O and regex matching
- Associative arrays
- Functions and control flow
- Subprocess via `system()` / `| getline`

### Awk-Cannot-Do ⚠️
- **No process substitution** (`<(...)`) - critical for `while read < <(find ...)`
- **No background jobs** (`&`, `wait -n`) - parallelization requires rewrite
- **No source/require** - all code must be single file
- **No eval equivalent** - template blocks need redesign
- **No namespaced functions** - `module::func` becomes `module_func`
- **No `local` keyword** - variable scoping via function parameters
- **Different string manipulation** - bash `${var/pat/repl}` ≠ gawk

## Task Plan

1. **Audit all bash-specific constructs** - categorize what can/cannot map to gawk
2. **Design gawk architecture** - single-file vs multi-file approach, how to handle "sourcing"
3. **Prototype core conversion** - pick one library (e.g., `html.source.sh`) as proof of concept
4. **Handle process substitution rewrites** - rewrite `while read < <(find ...)` patterns
5. **Redesign template system** - replace bash `eval` blocks with gawk-compatible approach
6. **Migrate parallel generation** - convert `&`/`wait` to sequential or `xargs -P`
7. **Migrate remaining libraries** - one by one, keeping tests passing
8. **Integration testing** - verify all `--generate`, `--test`, `--publish` modes work

## Effort Estimate

- **Phase 1 (Feasibility)**: 1-2 tasks
- **Phase 2 (Core Migration)**: 3-5 tasks  
- **Phase 3 (Testing/Polish)**: 2-3 tasks

**Total**: ~10 tasks, significant rewrite effort. Awk is excellent at text processing but shell scripting is fundamentally different.
