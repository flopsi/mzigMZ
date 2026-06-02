---
name: zig-quality
description: Use when editing, reviewing, or validating a Zig 0.16 project. Integrated with Domain Truth for mass spectrometry binary parsing.
allowed-tools: Read, Grep, Bash(zig fmt:*), Bash(zig ast-check:*)
user-invocable: false
---

# zig-quality — primary repo-local Zig & Domain Quality skill

This skill enforces Zig 0.16.0 standards and the project-specific **Truth-Driven** binary parsing mandates.

## The Five-Tier Quality Gate

1.  **Zig 0.16 Idioms**: (Per-turn) Check against `references/0.16-idioms.md`. NO drift.
2.  **Allocator Discipline**: (Per-turn) check against `references/allocator-discipline.md`. No hidden allocators.
3.  **Domain Truth (New)**: (Per-turn) Every numeric offset must be derived from the `thermo/decompiled` DLLs and reside in `src/spec/`.
4.  **Verification**: (Per-commit) Every field extracted must match the `.NET` JSON ground truth in `thermo/json`.
5.  **Release Hygiene**: (Per-release) Full `release-checklist.md` pass.

## Domain Truth Guardrails (The "No-Magic" Rule)

When reviewing code in this specific project, the agent MUST:

1.  **Audit All Numerics**: Any integer literal in a reader function (e.g., `data[0x42]`) is a **Critical Quality Failure**. Demand the offset be moved to `src/spec/` and referenced by name.
2.  **Verify the Chain**: Ensure the path is `Mmap` $\rightarrow$ `McdfResolver` $\rightarrow$ `Spec` $\rightarrow$ `Value`.
3.  **Cross-Reference Truth**: If a field is added, the agent must verify its type and size against the corresponding `.cs` file in `thermo/decompiled`.

## References (load on demand)

### `references/0.16-idioms.md`
Load when editing any `.zig` file. Enforces "Juicy Main" and `std.Io` injection.

### `references/0.16-grounded-facts.md`
The tie-breaker for 0.16 API names.

### `references/allocator-discipline.md`
Enforces explicit allocator propagation and unmanaged container patterns.

### `references/error-set-discipline.md`
Enforces named error sets and exhaustive switches on public APIs.

### `references/io-injection.md`
Enforces the `std.Io` capability pattern for all blocking/nondeterministic work.

### `references/testing-patterns.md`
Guidelines for `std.testing.allocator` and ground-truth comparison tests.

### `references/release-checklist.md`
Final hygiene for tagged releases.

## Assets (load on demand)

### `assets/migration-table.md`
0.14/0.15 $\rightarrow$ 0.16 mapping.

### `assets/gate-map.md`
Visual of the quality gate topology.
