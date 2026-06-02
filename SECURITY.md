# Security Hardening — mzigRead

This document tracks the security posture of mzigRead, a native Zig parser for ThermoFisher RAW files.

## Threat Model

mzigRead parses binary files from external sources (mass spectrometry data). The primary threats are:

- **Malformed files** causing out-of-bounds reads, crashes, or infinite loops
- **Oversized files** causing memory exhaustion (DoS)
- **Non-RAW files** being opened accidentally or maliciously

## Input Validation

| Check | Status | Location |
|-------|--------|----------|
| File size limit (64 GB) | ✅ | `app_state.zig:328` |
| Minimum file size (8 bytes) | ✅ | `app_state.zig:332` |
| OLE2 / Finnigan magic validation | ✅ | `app_state.zig:351` |
| Scan count limit (10M) | ✅ | `app_state.zig:440` |
| Packet bounds check before unsafe decode | ✅ | `advanced_packet.zig:422` |
| Peak count limit (50M) | ✅ | `advanced_packet.zig:400` |
| Segment count limit (4096) | ✅ | `advanced_packet.zig:348` |
| String length limit (1M chars) | ✅ | `raw_file.zig:93` |

## Memory Safety

| Check | Status | Notes |
|-------|--------|-------|
| Bounds-checked mmap reads | ✅ | All `read*Mm` helpers verify `offset + size > mm.len` |
| No allocator in hot decode path | ✅ | `page_allocator` fallback replaced with 1 KB stack buffer |
| Arena allocator for bulk iteration | ✅ | `loadScanArena` uses bump allocation |
| Reusable buffers for zero-alloc bulk | ✅ | `loadScanBulk` reuses grow-only buffers |

## Secrets & Dependencies

| Check | Status |
|-------|--------|
| No secrets in repository | ✅ Audited — no API keys, tokens, or passwords in source |
| `.env` in `.gitignore` | ✅ |
| No network dependencies | ✅ Single binary, no external services |

## CI Quality Gates

| Check | Status | File |
|-------|--------|------|
| Format check (`zig fmt`) | ✅ | `.github/workflows/ci.yml` |
| Unit tests | ✅ | `zig build test` |
| Full test suite (leak detection) | ✅ | `zig build test-all` |
| Benchmark regression gate | ✅ | `ci/check_regression.py` |

## Rollback

All security checks are hardcoded constants at the entry points. If a legitimate file is rejected, the constant can be tuned:

- `MAX_FILE_SIZE` in `app_state.zig`
- `MAX_SCAN_COUNT` in `app_state.zig`
- `max_stack_segments` in `advanced_packet.zig`

## Audit Date

2026-05-26
