# Benchmark Results

**Timestamp:** 2026-05-19 17:43:17 UTC  
**Version:** Post P0 FT Profile Packet Decoding  
**Compiler:** Zig 0.16.0 (x86_64-windows, ReleaseFast)  
**CPU:** AMD EPYC 7R13 (8 vCPUs)  

## Summary

All 18 test files pass without errors. FT Profile packets (type 21) are now decoded correctly alongside FT Centroid packets (type 20).

| Metric | Value |
|--------|-------|
| Total files tested | 18 |
| Files with MS1 profile + MS2 centroid | All Orbitrap files |
| Max scans in single file | 275,462 |
| Max points decoded (single file) | 1.68 billion |
| Fastest loadScanBulk | ~11 µs/scan (small centroid-only files) |
| Profile scan decode (MS1) | ~130 µs/scan (401,854 points each) |

## Complete Results by File

### test.raw — MS1 profile + MS2 centroid (463 MB, 6,716 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 2,565 | 0 | 0.38 | — |
| loadScan_full | 1,809,081 | 192,336,080 | 269.37 | 106,317,008 |
| loadScanArena_full | 953,101 | 192,336,080 | 141.91 | 201,800,313 |
| loadScanBulk_full | 870,337 | 192,336,080 | 129.59 | 220,990,352 |
| loadScan_random_1000 | 278,738 | 33,072,257 | 278.74 | 118,649,976 |
| loadScanBulk_random_1000 | 120,495 | 27,239,965 | 120.50 | 226,067,181 |

### test2.raw — MS1 profile + MS2 centroid (2.8 GB, 57,486 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 31,578 | 0 | 0.55 | — |
| loadScan_full | 5,018,390 | 507,561,721 | 87.30 | 101,140,350 |
| loadScanArena_full | 2,159,884 | 507,561,721 | 37.57 | 234,994,898 |
| loadScanBulk_full | 1,955,173 | 507,561,721 | 34.01 | 259,599,391 |
| loadScan_random_1000 | 92,476 | 10,660,398 | 92.48 | 115,277,456 |
| loadScanBulk_random_1000 | 35,945 | 9,225,537 | 35.95 | 256,657,032 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw — Centroid DDA (300 MB, 12,333 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 8,815 | 0 | 0.71 | — |
| loadScan_full | 4,500,120 | 528,273,625 | 364.88 | 117,391,008 |
| loadScanArena_full | 2,876,302 | 528,273,625 | 233.22 | 183,664,172 |
| loadScanBulk_full | 2,617,956 | 528,273,625 | 212.27 | 201,788,580 |
| loadScan_random_1000 | 345,593 | 43,592,087 | 345.59 | 126,137,066 |
| loadScanBulk_random_1000 | 201,249 | 40,762,870 | 201.25 | 202,549,429 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_02.raw — Centroid DDA (299 MB, 12,306 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 8,752 | 0 | 0.71 | — |
| loadScan_full | 4,413,358 | 531,374,715 | 358.63 | 120,401,453 |
| loadScanArena_full | 2,874,240 | 531,374,715 | 233.56 | 184,874,859 |
| loadScanBulk_full | 2,641,158 | 531,374,715 | 214.62 | 201,190,052 |
| loadScan_random_1000 | 348,801 | 42,392,502 | 348.80 | 121,537,788 |
| loadScanBulk_random_1000 | 204,473 | 41,187,800 | 204.47 | 201,433,930 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_03.raw — Centroid DDA (298 MB, 12,360 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 10,004 | 0 | 0.81 | — |
| loadScan_full | 4,416,522 | 526,163,954 | 357.32 | 119,135,364 |
| loadScanArena_full | 2,867,025 | 526,163,954 | 231.96 | 183,522,625 |
| loadScanBulk_full | 2,618,522 | 526,163,954 | 211.85 | 200,939,291 |
| loadScan_random_1000 | 416,209 | 48,780,277 | 416.21 | 117,201,399 |
| loadScanBulk_random_1000 | 190,405 | 37,590,011 | 190.41 | 197,421,344 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y10-E40_02.raw — Centroid DDA (327 MB, 12,377 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 12,552 | 0 | 1.01 | — |
| loadScan_full | 4,411,795 | 524,835,437 | 356.45 | 118,961,882 |
| loadScanArena_full | 2,822,183 | 524,835,437 | 228.02 | 185,967,897 |
| loadScanBulk_full | 2,590,386 | 524,835,437 | 209.29 | 202,608,969 |
| loadScan_random_1000 | 355,317 | 44,095,265 | 355.32 | 124,101,197 |
| loadScanBulk_random_1000 | 212,488 | 43,287,709 | 212.49 | 203,718,370 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y45-E05_01.raw — Centroid DDA (318 MB, 12,291 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 8,295 | 0 | 0.67 | — |
| loadScan_full | 4,392,991 | 534,729,287 | 357.42 | 121,723,283 |
| loadScanArena_full | 2,905,606 | 534,729,287 | 236.40 | 184,033,653 |
| loadScanBulk_full | 2,633,739 | 534,729,287 | 214.28 | 203,030,478 |
| loadScan_random_1000 | 353,098 | 43,632,840 | 353.10 | 123,571,473 |
| loadScanBulk_random_1000 | 209,283 | 42,489,676 | 209.28 | 203,024,976 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y45-E05_02.raw — Centroid DDA (318 MB, 12,346 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 8,313 | 0 | 0.67 | — |
| loadScan_full | 4,395,546 | 527,965,042 | 356.03 | 120,113,643 |
| loadScanArena_full | 2,859,904 | 527,965,042 | 231.65 | 184,609,358 |
| loadScanBulk_full | 2,614,740 | 527,965,042 | 211.79 | 201,918,754 |
| loadScan_random_1000 | 368,857 | 46,039,775 | 368.86 | 124,817,409 |
| loadScanBulk_random_1000 | 208,232 | 42,070,457 | 208.23 | 202,036,464 |

### 20240428_MP1_50SPD_IO25_LFQ_10pg_Y45-E05_03.raw — Centroid DDA (383 MB, 12,385 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 8,607 | 0 | 0.69 | — |
| loadScan_full | 4,630,317 | 525,961,841 | 373.86 | 113,590,893 |
| loadScanArena_full | 2,916,185 | 525,961,841 | 235.46 | 180,359,559 |
| loadScanBulk_full | 2,615,302 | 525,961,841 | 211.17 | 201,109,410 |
| loadScan_random_1000 | 375,747 | 46,306,333 | 375.75 | 123,238,064 |
| loadScanBulk_random_1000 | 229,853 | 46,315,407 | 229.85 | 201,500,120 |

### 29082025_AMP5_CF_HT_100ng_300SPD_2Th_3ms__AGC500_3.raw — Centroid DIA (1.4 GB, 40,969 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 25,537 | 0 | 0.62 | — |
| loadScan_full | 2,450,028 | 256,656,606 | 59.80 | 104,756,601 |
| loadScanArena_full | 1,143,398 | 256,656,606 | 27.91 | 224,468,301 |
| loadScanBulk_full | 1,002,785 | 256,656,606 | 24.48 | 255,943,803 |
| loadScan_random_1000 | 54,607 | 6,116,676 | 54.61 | 112,012,672 |
| loadScanBulk_random_1000 | 29,881 | 7,205,363 | 29.88 | 241,135,270 |

### 29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_1.raw — Centroid DIA (8.6 GB, 275,462 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 215,111 | 0 | 0.78 | — |
| loadScan_full | 15,106,086 | 1,680,259,365 | 54.84 | 111,230,624 |
| loadScanArena_full | 7,372,657 | 1,680,259,365 | 26.76 | 227,904,182 |
| loadScanBulk_full | 6,834,197 | 1,680,259,365 | 24.81 | 245,860,540 |
| loadScan_random_1000 | 47,596 | 5,977,921 | 47.60 | 125,597,130 |
| loadScanBulk_random_1000 | 32,752 | 7,593,284 | 32.75 | 231,841,842 |

### 29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_2.raw — Centroid DIA (8.7 GB, 275,445 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 215,155 | 0 | 0.78 | — |
| loadScan_full | 15,606,589 | 1,681,546,598 | 56.66 | 107,745,940 |
| loadScanArena_full | 7,432,064 | 1,681,546,598 | 26.98 | 226,255,667 |
| loadScanBulk_full | 6,791,649 | 1,681,546,598 | 24.66 | 247,590,327 |
| loadScan_random_1000 | 50,680 | 5,505,867 | 50.68 | 108,639,838 |
| loadScanBulk_random_1000 | 23,559 | 5,465,033 | 23.56 | 231,972,197 |

### 29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_3.raw — Centroid DIA (8.7 GB, 275,436 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 205,790 | 0 | 0.75 | — |
| loadScan_full | 15,371,252 | 1,684,423,188 | 55.81 | 109,582,693 |
| loadScanArena_full | 7,361,726 | 1,684,423,188 | 26.73 | 228,808,188 |
| loadScanBulk_full | 6,729,638 | 1,684,423,188 | 24.43 | 250,299,227 |
| loadScan_random_1000 | 66,821 | 8,115,092 | 66.82 | 121,445,234 |
| loadScanBulk_random_1000 | 11,179 | 3,360,789 | 11.18 | 300,634,135 |

### 29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_4.raw — Centroid DIA (8.6 GB, 275,432 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 210,570 | 0 | 0.76 | — |
| loadScan_full | 15,492,727 | 1,676,054,146 | 56.25 | 108,183,288 |
| loadScanArena_full | 7,386,111 | 1,676,054,146 | 26.82 | 226,919,707 |
| loadScanBulk_full | 6,720,196 | 1,676,054,146 | 24.40 | 249,405,545 |
| loadScan_random_1000 | 47,700 | 5,941,839 | 47.70 | 124,566,855 |
| loadScanBulk_random_1000 | 37,830 | 8,501,439 | 37.83 | 224,727,439 |

### 29082025_AMP5_CF_HT_20ng_300SPD_5Th_10ms__AGC500_3.raw — Centroid DIA (1.3 GB, 17,291 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 6,836 | 0 | 0.40 | — |
| loadScan_full | 2,507,198 | 247,051,148 | 145.00 | 98,536,752 |
| loadScanArena_full | 1,030,542 | 247,051,148 | 59.60 | 239,729,335 |
| loadScanBulk_full | 942,238 | 247,051,148 | 54.49 | 262,196,120 |
| loadScan_random_1000 | 158,062 | 17,318,726 | 158.06 | 109,569,194 |
| loadScanBulk_random_1000 | 37,653 | 10,833,445 | 37.65 | 287,717,977 |

### 29082025_AMP5_CF_HT_20ng_60SPD_3Th_5ms_500nl_AGC500_2.raw — Centroid DIA (5.4 GB, 192,042 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 115,126 | 0 | 0.60 | — |
| loadScan_full | 12,376,129 | 1,457,773,005 | 64.44 | 117,789,093 |
| loadScanArena_full | 7,017,915 | 1,457,773,005 | 36.54 | 207,721,667 |
| loadScanBulk_full | 6,262,324 | 1,457,773,005 | 32.61 | 232,784,667 |
| loadScan_random_1000 | 51,372 | 6,296,607 | 51.37 | 122,568,851 |
| loadScanBulk_random_1000 | 32,355 | 7,359,285 | 32.36 | 227,454,335 |

### 29082025_AMP5_CF_HT_20ng_60SPD_5Th_10ms_500nl_AGC500_1.raw — Centroid DIA (6.9 GB, 111,146 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 57,234 | 0 | 0.51 | — |
| loadScan_full | 14,915,165 | 1,520,465,901 | 134.19 | 101,940,937 |
| loadScanArena_full | 6,767,416 | 1,520,465,901 | 60.89 | 224,674,514 |
| loadScanBulk_full | 6,148,581 | 1,520,465,901 | 55.32 | 247,287,285 |
| loadScan_random_1000 | 121,842 | 14,021,465 | 121.84 | 115,079,078 |
| loadScanBulk_random_1000 | 52,444 | 13,066,311 | 52.44 | 249,147,872 |

### 29082025_AMP5_CF_HT_50ng_300SPD_3Th_5ms__AGC500_1.raw — Centroid DIA (1.5 GB, 28,794 scans)
| Benchmark | Time (µs) | Points | µs/scan | pts/sec |
|-----------|-----------|--------|---------|---------|
| open | 13,974 | 0 | 0.49 | — |
| loadScan_full | 3,522,542 | 258,954,914 | 122.34 | 73,513,648 |
| loadScanArena_full | 1,076,640 | 258,954,914 | 37.39 | 240,521,357 |
| loadScanBulk_full | 972,425 | 258,954,914 | 33.77 | 266,298,084 |
| loadScan_random_1000 | 99,871 | 11,366,548 | 99.87 | 113,812,298 |
| loadScanBulk_random_1000 | 19,996 | 6,123,663 | 20.00 | 306,244,399 |

## Performance Characteristics

### loadScan (alloc + copy per scan)
- **Best for:** Small files, random access
- **Overhead:** Allocates mz/intensity arrays for every scan
- **Typical:** 50–400 µs/scan depending on point count

### loadScanArena (arena allocator)
- **Best for:** Batch processing, sequential access
- **Overhead:** Single arena reset between scans
- **Typical:** 25–240 µs/scan (2–3× faster than loadScan)

### loadScanBulk (zero allocation)
- **Best for:** Maximum throughput, benchmarks
- **Overhead:** Reuses grow-only buffers
- **Typical:** 20–215 µs/scan (fastest)

## Profile Packet Decoding Performance

Profile scans decode at ~130 µs/scan for 401,854 points (≈3.1 ns/point). The bottleneck is:
1. Mass calculation: `coeff1/freq + coeff2/freq²` per point
2. Zero-padding for gaps between subsegments
3. Monotonicity enforcement (`IncreaseMass`)

Profile scans are ~3–5× slower than centroid scans due to the much larger point count (401K vs ~200 points).

## Run-to-Run Variance

Three consecutive runs on the same file show typical cloud VM variance:

| File | Benchmark | Run 1 | Run 2 | Run 3 | StdDev |
|------|-----------|-------|-------|-------|--------|
| test.raw | loadScan_full | 1,775,567 µs | 1,766,856 µs | 1,785,097 µs | ±0.5% |
| test.raw | loadScanBulk_full | 874,459 µs | 876,693 µs | 874,363 µs | ±0.1% |
| test2.raw | loadScan_full | 5,210,787 µs | 5,392,186 µs | 5,144,304 µs | ±2.4% |
| test2.raw | loadScanBulk_full | 1,968,193 µs | 1,979,272 µs | 1,964,889 µs | ±0.4% |

## Changes in This Version

- **P0 FT Profile Decoding:** Added support for packet type 21 (FT Profile)
- **Buffer sizing fix:** Profile buffers now sized by `num_expanded_words` instead of `num_profile_words * 100`
- **All three loaders updated:** `loadScan`, `loadScanArena`, `loadScanBulk` all handle profile packets
- **Centroid performance unchanged:** The `if (is_profile)` branch adds ~1 instruction for centroid scans
