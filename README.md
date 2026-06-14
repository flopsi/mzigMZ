# mzigRead

A Zig-based command-line toolkit for reading Thermo Fisher `.raw` mass-spectrometry files and exporting them to open formats.

> **Alpha status.** The CLI is functional for single-file conversion, batch conversion, and introspection of `.raw` files, but some features are still being refined.

## Requirements

- [Zig 0.16](https://ziglang.org/download/)
- Windows (the current build targets Win32 APIs and the native Thermo file layout)
- Real Thermo `.raw` files for commands that read data

## Build

```powershell
zig build mzig
```

The executable is written to `zig-out/bin/mzig.exe`. You can run it either via the build step:

```powershell
zig build mzig -- help
```

or directly:

```powershell
.\zig-out\bin\mzig.exe help
```

Run the full test suite with:

```powershell
zig build test
```

CLI integration tests (require a real `.raw` file):

```powershell
zig build test-cli -- C:\path\to\file.raw
```

## CLI usage

```text
mzig <command> [args]
```

### Global conventions

- `--format json|csv` controls output serialization for `dump` commands (default: `json`).
- `--scan N` is 1-based for `dump scan` and `dump packet`.
- `--range A:B` supports open-ended ranges: `10:`, `:10`, `5:10`.

### `convert` — convert one `.raw` file to mzML

```powershell
mzig convert input.raw output.mzML
```

Produces a non-indexed mzML file with `f64` m/z and intensity values and no compression.

### `convert-batch` — convert a directory of `.raw` files

```powershell
mzig convert-batch D:\data\raw D:\data\mzml
mzig convert-batch D:\data\raw D:\data\mzml --skip-existing --fail-fast
```

- Currently filters files by the `.raw` extension.
- `--skip-existing` skips an output file if it already exists.
- `--fail-fast` stops on the first conversion error instead of continuing through the directory.
- `--pattern` is parsed but not yet applied; it is reserved for future filtering.

### `dump scan` — print one scan

```powershell
mzig dump scan input.raw --scan 42
mzig dump scan input.raw --scan 42 --format csv
```

### `dump scans` — print a range of scans

```powershell
mzig dump scans input.raw --range 1:10
mzig dump scans input.raw --range 100: --format csv
```

### `dump chromatogram` — print TIC or BPC

```powershell
mzig dump chromatogram input.raw --type tic
mzig dump chromatogram input.raw --type bpc --format csv
```

> XIC extraction (`--type xic --mz <value> --tol <ppm>`) is parsed but not yet implemented.

### `dump metadata` — file-level metadata

```powershell
mzig dump metadata input.raw
mzig dump metadata input.raw --format csv
```

### `dump calibration` — mass calibration data

```powershell
mzig dump calibration input.raw
mzig dump calibration input.raw --scan 1 --format csv
```

### `dump instrument` — instrument method / tune data

```powershell
mzig dump instrument input.raw
mzig dump instrument input.raw --format csv
```

### `dump packet` — raw packet for a scan

```powershell
mzig dump packet input.raw --scan 42
mzig dump packet input.raw --scan 42 --format csv
```

### `verify` — sanity-check a `.raw` file

```powershell
mzig verify input.raw
```

Opens the file and reports whether it can be read successfully.

## Output formats

| Format | Description |
|--------|-------------|
| `json` | Pretty-printed JSON (default) |
| `csv`  | Comma-separated values |

## Project layout

```text
src/
  cli/              # mzig CLI implementation
    args.zig        # command/flag parser
    commands/       # one module per subcommand
    output/         # JSON/CSV sinks
    main.zig        # CLI entry point
  core/             # shared types and helpers
  export/           # mzML/mzigML writers and .raw passthrough
  gui/              # Win32 GUI viewer scaffolding
  mzml/             # mzML serialization
  raw_core/         # Thermo .raw reader and packet decoder
  tools/            # ground-truth generation/verification utilities
  viewer/           # additional viewer targets
  viewer_zgui/      # imguinz2-based GPU viewer
  main.zig          # default viewer entry point
tests/              # integration tests and test plan
```

## Known limitations

- The CLI currently writes only mzML output; `mzigML` and `parquet` writers exist in the source tree but are not yet wired to commands.
- XIC chromatograms are parsed but not yet computed.
- `convert-batch --pattern` is reserved and ignored (all `.raw` files are processed).
- Some `dump scan` fields (e.g., precursor intensity) are placeholders while the underlying decoder fields are finalized.

## Repository

```text
D:\000projects\mzigRead
https://github.com/flopsi/mzigMZ
```

The `tests/ground_truth/` directory is excluded from git; regenerate it locally with:

```powershell
zig build generate-ground-truth -- C:\path\to\file.raw
```
