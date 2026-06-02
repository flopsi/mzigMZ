# Karpathy-Inspired Behavioral Guidelines for Claude Code

> Behavioral guidelines to reduce common LLM coding mistakes.
> Merge with project-specific instructions as needed.
>
> **Tradeoff:** These guidelines bias toward caution over speed.
> For trivial tasks, use judgment.

## Core Principles

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them.
- If a simpler approach exists, say so.
- If something is unclear, stop. Name what's confusing.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" that wasn't requested.
- No error handling for impossible scenarios.
- If 200 lines could be 50, rewrite it.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

| Instead of... | Transform to... |
| --- | --- |
| "Add validation" | "Write tests for invalid inputs, then make them pass" |
| "Fix the bug" | "Write a test that reproduces it, then make it pass" |
| "Refactor X" | "Ensure tests pass before and after" |

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let Claude loop independently.
Weak criteria ("make it work") require constant clarification.

---

## Available Skills

Load skills via Claude Code slash commands:

| Skill | Purpose |
| --- | --- |
| `karpathy-guidelines` | Core 4 principles with self-check checklist |
| `karpathy-workflows` | Session compilation, MRE debugging, code review |
| `knowledge-compiler` | Persistent project memory across sessions |
| `git-workflow` | Checkpoint commits, conventional commits, format-on-save |
| `testing-strategy` | Test-first development with regression prevention |
| `architecture-guardian` | Over-engineering prevention, Rule of Three |

---

## Project-Specific Configuration

*Add your project-specific rules below this section.*

### Tech Stack

- Language: Zig
- Purpose: Memory-efficient reading and processing of large files (mzigRead)

### Build Commands

- `zig build` — Build the project
- `zig build test` — Run tests
- `zig build -Doptimize=ReleaseSafe` — Build for release with safety checks

### Coding Standards

- Follow standard Zig naming conventions (PascalCase for types, snake_case for functions/variables)
- Prefer explicit error handling using `try` and `catch`
- Use `std.mem.Allocator` for memory management and avoid global state
- Keep functions small and focused on a single task

### Safety Rules

- Avoid `undefined behavior` at all costs
- Use `std.debug.print` for logging during development, but ensure it's removed or gated in production
- Be mindful of memory leaks in long-running processes
