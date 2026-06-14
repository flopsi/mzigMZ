# Cross-repo build validation for mzigRead → msViewer
# Verifies that msViewer builds against the current mzigRead working tree.
# Must pass before merging any PR that touches ScanIndexEntry, DecodeResult,
# ZoomState, or any published-module source file.
#
# Usage: .\scripts\verify-msviewer-build.ps1

param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$msViewerPath = "D:/000projects/msViewer"

if (-not (Test-Path "$msViewerPath/build.zig")) {
    Write-Error "msViewer not found at $msViewerPath"
    exit 2
}

Push-Location $msViewerPath
try {
    $result = zig build 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "=== CROSS-REPO BUILD FAILED ===" -ForegroundColor Red
        Write-Host "msViewer failed to build against the current mzigRead working tree." -ForegroundColor Red
        Write-Host "A published-module API may have changed (ScanIndexEntry, DecodeResult, ZoomState)." -ForegroundColor Red
        Write-Host ""
        Write-Host "Build output:" -ForegroundColor DarkGray
        Write-Host $result
        exit 1
    }
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "=== CROSS-REPO BUILD PASSED ===" -ForegroundColor Green
        Write-Host "msViewer builds successfully against current mzigRead working tree." -ForegroundColor Green
    }
    exit 0
} finally {
    Pop-Location
}
