# Byte-identical passthrough for .raw writer

**Context:** The .raw writer must produce files that Thermo tooling (Xcalibur, FreeStyle, Spectronaut) can open. The reader only decodes a subset of the .raw binary structure (scan table, packet data, key metadata fields); large regions are skipped (sequence row body, auto-sampler config, raw info preamble, unknown trailer sections).

**Decision:** For the pure-passthrough writer (round 1, no modification): copy every byte region verbatim from the source mmap *except* the scan table and packet data, which are re-encoded from decoded state. Unknown regions are preserved byte-for-byte.

**Why:** Re-encoding every region would require understanding every byte of the .raw format — including legacy padding and unused controller entries that no tool reads but all tools expect. Copying unknown regions verbatim guarantees byte-level compatibility with picky consumers. The scan table is the only region the reader fully parses; re-encoding it proves the scan index writer works. Packet encoding follows in a separate commit.

**Considered alternatives:**

- **Re-encode everything:** Would require full binary-format understanding for every struct, including legacy versions. High risk of subtle incompatibility bugs. Deferred to a future "slim writer."
- **Copy everything verbatim:** Trivially correct but proves nothing — no encode logic is tested. The scan index writer never gets validated.

**Consequences:** The passthrough file is the same size as the original. Unknown regions are opaque — if a downstream tool depends on a byte we skipped, the file will still work because we preserved it. The tradeoff is that the "slim writer" (only necessary data) requires later work to understand and re-encode the skipped regions.
