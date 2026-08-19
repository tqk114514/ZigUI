# ci/check.ps1 -- CI check script (rule.md section 8.2, Windows runner)
# Steps: zig fmt --check -> zig build test -> zig build examples -> ReleaseFast build ->
#        import matrix check (mechanizes L1 and section-3 matrix).
param(
    [switch]$SkipRelease
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Assert-Exit0([string]$label) {
    if ($LASTEXITCODE -ne 0) {
        Write-Error "[FAIL] $label"
    }
    Write-Host "[OK] $label"
}

Write-Host "=== 1/5 zig fmt --check ==="
zig fmt --check build.zig ui.zig theme.zig platform core
Assert-Exit0 "zig fmt --check"

Write-Host "=== 2/5 zig build test ==="
zig build test
Assert-Exit0 "zig build test"

Write-Host "=== 3/5 zig build (examples) ==="
zig build
Assert-Exit0 "zig build examples"

if (-not $SkipRelease) {
    Write-Host "=== 4/5 ReleaseFast build ==="
    zig build -Doptimize=ReleaseFast --summary all
    Assert-Exit0 "zig build ReleaseFast"
}

Write-Host "=== 5/5 import matrix check ==="
# L1 + section-3 matrix:
#   Rule A1: @import("win32") only allowed in platform/ and render/;
#   Rule A2: @import("platform/...") only allowed in platform/, render/ and the root ui.zig;
#   Rule B: core/, widgets/ and theme.zig must not contain any `extern "..."` system decl.
$allowed_win32_top = @('platform', 'render')
$allowed_platform_top = @('platform', 'render')
$violations = @()

Get-ChildItem -Path . -Recurse -Include *.zig |
    Where-Object { $_.FullName -notmatch 'zig-out|\.zig-cache|zig-pkg' } |
    ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        $top = ($rel -split '/')[0]
        $content = Get-Content $_.FullName -Raw

        # Rule A1: the win32 package is only reachable through platform/render.
        if ($content -match '@import\s*\("win32"') {
            if ($top -notin $allowed_win32_top) {
                $violations += "win32 import in disallowed dir: $rel"
            }
        }

        # Rule A2: platform internals re-exported only from the root ui.zig.
        if (($rel -ne 'ui.zig') -and ($content -match '@import\s*\("platform/')) {
            if ($top -notin $allowed_platform_top) {
                $violations += "platform import in disallowed dir: $rel"
            }
        }

        # Rule B: core/, widgets/, theme.zig must not contain extern system decls.
        if (($top -in @('core', 'widgets')) -or $rel -eq 'theme.zig') {
            if ($content -match 'extern\s+"[^"]+"') {
                $violations += "extern system declaration in $rel"
            }
        }
    }

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Host "[FAIL] $_" }
    throw "import matrix violations detected ($($violations.Count))"
}
Write-Host "[OK] import matrix check"

Write-Host "=== CI all passed ==="