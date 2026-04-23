<#
.SYNOPSIS
    Vendors upstream Zig and builds libzig on Windows.

.DESCRIPTION
    Clones upstream Zig into deps\zig, applies patches\zig-expose-lib.patch,
    and builds the libzig static library so zigbox's build.zig can link it in.

    Supported Tag values:
      - supported      -> project-pinned tested version (default)
      - latest-stable  -> latest stable release from ziglang.org/download/index.json
      - master         -> latest master snapshot from ziglang.org/download/index.json
      - 0.14.0         -> explicit release tag

    Bootstrap Zig selection:
      -Zig zig         -> use zig from PATH (must match resolved version exactly)
      -Zig C:\...\zig.exe
      -Zig auto        -> download a matching bootstrap Zig into deps\toolchains\bootstrap

    The auto bootstrap mode is experimental and uses official ziglang.org
    download metadata.

.PARAMETER Tag
    Version selector or explicit upstream release tag. Default: supported.

.PARAMETER Repo
    Upstream repository URL. Default: https://github.com/ziglang/zig

.PARAMETER Optimize
    Zig optimize mode for libzig. Debug | ReleaseSafe | ReleaseFast |
    ReleaseSmall. Default: ReleaseFast.

.PARAMETER Target
    Target triple for the upstream Zig build. Default: native.

.PARAMETER Zig
    Path to zig.exe, "zig" from PATH, or "auto". Default: "zig".

.PARAMETER EnableLlvm
    Build libzig with LLVM extensions enabled.

.PARAMETER ConfigH
    Optional path to Zig's generated config.h for LLVM/Clang/LLD integration.

.PARAMETER SearchPrefix
    Extra linker/search prefixes forwarded to zig build via --search-prefix.

.PARAMETER IndexUrl
    Official Zig download index. Default: https://ziglang.org/download/index.json

.EXAMPLE
    .\scripts\setup-zig-source.ps1

.EXAMPLE
    .\scripts\setup-zig-source.ps1 -Tag 0.14.0 -Zig auto

.EXAMPLE
    .\scripts\setup-zig-source.ps1 -Tag latest-stable -Zig auto

.EXAMPLE
    .\scripts\setup-zig-source.ps1 -Tag master -Zig auto

.EXAMPLE
    .\scripts\setup-zig-source.ps1 -Target x86_64-windows-msvc -EnableLlvm -ConfigH C:\llvm\zig\config.h -SearchPrefix C:\llvm
#>

[CmdletBinding()]
param(
    [string]$Tag = "supported",
    [string]$Repo = "https://github.com/ziglang/zig",
    [ValidateSet("Debug","ReleaseSafe","ReleaseFast","ReleaseSmall")]
    [string]$Optimize = "ReleaseFast",
    [string]$Target = "native",
    [string]$Zig = "zig",
    [switch]$EnableLlvm,
    [string]$ConfigH,
    [string[]]$SearchPrefix = @(),
    [string]$IndexUrl = "https://ziglang.org/download/index.json"
)

$ErrorActionPreference = "Stop"

$SupportedTags = @(
    "0.14.0"
)
$DefaultSupportedTag = $SupportedTags[0]

function Write-Info ($msg) {
    Write-Host "[setup-zig] $msg" -ForegroundColor Cyan
}

function Write-Fatal ($msg) {
    Write-Host "[setup-zig] $msg" -ForegroundColor Red
    exit 1
}

function Get-ZigIndex([string]$Url) {
    Write-Info "fetching Zig download index"
    return Invoke-RestMethod $Url
}

function Get-LatestStableTag($Index) {
    $stableTags = $Index.PSObject.Properties.Name |
        Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_ } -Descending

    if (-not $stableTags) {
        Write-Fatal "no stable release tags found in $IndexUrl"
    }

    return $stableTags[0]
}

function Resolve-RequestedTag {
    param(
        [string]$RequestedTag,
        $Index
    )

    switch ($RequestedTag) {
        "supported" {
            return [pscustomobject]@{
                RequestedTag = $RequestedTag
                ResolvedRef = $DefaultSupportedTag
                BootstrapVersion = $DefaultSupportedTag
                Experimental = $false
                Description = "project-supported release"
            }
        }
        "latest-stable" {
            if (-not $Index) {
                Write-Fatal "latest-stable requires download metadata"
            }
            $latest = Get-LatestStableTag $Index
            return [pscustomobject]@{
                RequestedTag = $RequestedTag
                ResolvedRef = $latest
                BootstrapVersion = $latest
                Experimental = $false
                Description = "latest stable release"
            }
        }
        "master" {
            if (-not $Index) {
                Write-Fatal "master requires download metadata"
            }
            return [pscustomobject]@{
                RequestedTag = $RequestedTag
                ResolvedRef = "master"
                BootstrapVersion = $Index.master.version
                Experimental = $true
                Description = "latest master snapshot"
            }
        }
        default {
            $isSemver = $RequestedTag -match '^\d+\.\d+\.\d+$'
            return [pscustomobject]@{
                RequestedTag = $RequestedTag
                ResolvedRef = $RequestedTag
                BootstrapVersion = if ($isSemver) { $RequestedTag } else { $null }
                Experimental = $false
                Description = if ($isSemver) { "explicit release tag" } else { "custom upstream ref" }
            }
        }
    }
}

function Get-WindowsPlatformKeys {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($arch.ToUpperInvariant()) {
        "ARM64" { return @("aarch64-windows") }
        "X86"   { return @("x86-windows") }
        default { return @("x86_64-windows") }
    }
}

function Ensure-AutoBootstrap {
    param(
        $Index,
        [string]$BootstrapVersion,
        [string]$ToolchainsDir
    )

    if (-not $BootstrapVersion) {
        Write-Fatal "auto bootstrap needs a resolvable release version"
    }

    $entry = $Index.PSObject.Properties[$BootstrapVersion].Value
    if (-not $entry) {
        Write-Fatal "version '$BootstrapVersion' is not present in $IndexUrl, cannot use -Zig auto"
    }

    $platformKey = $null
    foreach ($candidate in Get-WindowsPlatformKeys) {
        if ($entry.PSObject.Properties[$candidate]) {
            $platformKey = $candidate
            break
        }
    }
    if (-not $platformKey) {
        Write-Fatal "no official bootstrap archive for this Windows host architecture"
    }

    $archive = $entry.PSObject.Properties[$platformKey].Value
    $cacheRoot = Join-Path $ToolchainsDir "bootstrap"
    $platformDir = Join-Path $cacheRoot $platformKey
    $extractDir = Join-Path $platformDir $BootstrapVersion
    $zigExe = Join-Path $extractDir "zig.exe"
    $zigLibDir = Join-Path $extractDir "lib"
    $archivePath = Join-Path $platformDir ([IO.Path]::GetFileName($archive.tarball))

    New-Item -ItemType Directory -Force -Path $platformDir | Out-Null

    if (Test-Path $zigExe) {
        $existingVersion = & $zigExe version
        if ($existingVersion -eq $BootstrapVersion -and (Test-Path $zigLibDir)) {
            Write-Info "reusing cached bootstrap zig: $zigExe"
            return $zigExe
        }
        Write-Info "cached bootstrap Zig is incomplete or wrong version; refreshing $extractDir"
        Remove-Item -Recurse -Force $extractDir
    }

    if (-not (Test-Path $archivePath)) {
        Write-Info "downloading bootstrap Zig $BootstrapVersion for $platformKey"
        Invoke-WebRequest -Uri $archive.tarball -OutFile $archivePath
    }

    $hash = (Get-FileHash -Algorithm SHA256 -Path $archivePath).Hash.ToLowerInvariant()
    if ($hash -ne $archive.shasum.ToLowerInvariant()) {
        Remove-Item -Force $archivePath
        Write-Fatal "checksum mismatch for $archivePath"
    }

    $tempExtract = Join-Path $platformDir ("extract-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempExtract | Out-Null
    try {
        Write-Info "extracting bootstrap Zig into cache"
        Expand-Archive -LiteralPath $archivePath -DestinationPath $tempExtract -Force
        $rootDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
        if (-not $rootDir) {
            Write-Fatal "bootstrap archive did not contain a root directory"
        }
        if (Test-Path $extractDir) {
            Remove-Item -Recurse -Force $extractDir
        }
        Move-Item -Path $rootDir.FullName -Destination $extractDir
    } finally {
        if (Test-Path $tempExtract) {
            Remove-Item -Recurse -Force $tempExtract
        }
    }

    if (-not (Test-Path $zigExe)) {
        Write-Fatal "bootstrap zig.exe was not found after extraction"
    }
    if (-not (Test-Path $zigLibDir)) {
        Write-Fatal "bootstrap Zig lib directory was not found after extraction"
    }

    Write-Info "cached bootstrap zig: $zigExe"
    return $zigExe
}

function Sync-UpstreamZig {
    param(
        [string]$RepoUrl,
        [string]$TargetDir,
        [string]$ResolvedRef,
        [bool]$IsMaster,
        [string]$PatchMarker
    )

    if (-not (Test-Path (Join-Path $TargetDir ".git"))) {
        if ($IsMaster) {
            Write-Info "cloning $RepoUrl @ master into deps\zig (experimental channel)"
        } else {
            Write-Info "cloning $RepoUrl @ $ResolvedRef into deps\zig"
        }
        git clone --depth 1 --branch $ResolvedRef $RepoUrl $TargetDir
        if ($LASTEXITCODE -ne 0) { Write-Fatal "git clone failed" }
        return
    }

    Push-Location $TargetDir
    try {
        if ($IsMaster) {
            Write-Info "updating deps\zig to latest origin/master"
            git fetch --depth 1 origin master
            if ($LASTEXITCODE -ne 0) { Write-Fatal "git fetch failed" }
            git checkout --force FETCH_HEAD
            if ($LASTEXITCODE -ne 0) { Write-Fatal "git checkout failed" }
            Remove-Item -Force -ErrorAction SilentlyContinue $PatchMarker
            return
        }

        $current = (git describe --tags --exact-match 2>$null)
        if ($current -ne $ResolvedRef) {
            Write-Info "updating deps\zig to $ResolvedRef (current: $current)"
            git fetch --depth 1 origin "refs/tags/$ResolvedRef:refs/tags/$ResolvedRef"
            if ($LASTEXITCODE -ne 0) { Write-Fatal "git fetch failed" }
            git checkout --force $ResolvedRef
            if ($LASTEXITCODE -ne 0) { Write-Fatal "git checkout failed" }
            Remove-Item -Force -ErrorAction SilentlyContinue $PatchMarker
        } else {
            Write-Info "deps\zig already at $ResolvedRef"
        }
    } finally {
        Pop-Location
    }
}

function Ensure-PublicMainArgs {
    param([string]$MainFile)

    $contents = Get-Content $MainFile -Raw
    if ($contents -match 'pub fn mainArgs\(gpa: Allocator, arena: Allocator, args: \[\]const \[\]const u8\) !void \{') {
        return
    }
    if ($contents -match 'fn mainArgs\(gpa: Allocator, arena: Allocator, args: \[\]const \[\]const u8\) !void \{') {
        Write-Info "upgrading deps\\zig\\src\\main.zig: exposing mainArgs as pub"
        $updated = $contents -replace 'fn mainArgs\(gpa: Allocator, arena: Allocator, args: \[\]const \[\]const u8\) !void \{', 'pub fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {'
        Set-Content -Path $MainFile -Value $updated -Encoding utf8NoBOM
        return
    }
    Write-Fatal "could not locate mainArgs signature in $MainFile"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fatal "git not found on PATH."
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DepsDir = Join-Path $RepoRoot "deps"
$ToolchainsDir = Join-Path $DepsDir "toolchains"
$ZigDir = Join-Path $DepsDir "zig"
$PatchFile = Join-Path $RepoRoot "patches\zig-expose-lib.patch"
$Marker = Join-Path $ZigDir ".zigbox-patched"

if (-not (Test-Path $PatchFile)) {
    Write-Fatal "missing $PatchFile"
}

New-Item -ItemType Directory -Force -Path $DepsDir | Out-Null

$needsIndex = ($Zig -eq "auto") -or ($Tag -in @("latest-stable", "master"))
$zigIndex = if ($needsIndex) { Get-ZigIndex $IndexUrl } else { $null }
$resolved = Resolve-RequestedTag -RequestedTag $Tag -Index $zigIndex

Write-Info "requested tag:       $Tag"
Write-Info "resolved ref:        $($resolved.ResolvedRef)"
if ($resolved.BootstrapVersion) {
    Write-Info "bootstrap version:   $($resolved.BootstrapVersion)"
}
if ($resolved.Experimental) {
    Write-Info "channel:             experimental"
}
Write-Info "optimize:            $Optimize"
Write-Info "target:              $Target"
Write-Info "enable llvm:         $($EnableLlvm.IsPresent)"

$zigPath = $Zig
if ($Zig -eq "auto") {
    $zigPath = Ensure-AutoBootstrap -Index $zigIndex -BootstrapVersion $resolved.BootstrapVersion -ToolchainsDir $ToolchainsDir
}

if (-not (Get-Command $zigPath -ErrorAction SilentlyContinue)) {
    Write-Fatal "zig not found on PATH (looked for '$zigPath'). Install from https://ziglang.org/download/ or set -Zig."
}

$zigVersion = & $zigPath version
Write-Info "bootstrap zig path:  $zigPath"
Write-Info "bootstrap zig ver:   $zigVersion"

if ($resolved.BootstrapVersion -and $zigVersion -ne $resolved.BootstrapVersion) {
    Write-Fatal @"
bootstrap Zig version mismatch:
  bootstrap zig: $zigVersion
  upstream ref:  $($resolved.ResolvedRef)
  expected:      $($resolved.BootstrapVersion)

Use the exact same Zig version to build upstream Zig as a library,
or pass -Zig auto to let the script fetch the matching toolchain.
"@
}

if ($ConfigH) {
    $ConfigH = (Resolve-Path $ConfigH).Path
    Write-Info "config.h:            $ConfigH"
}
if ($SearchPrefix.Count -gt 0) {
    Write-Info ("search prefixes:     " + ($SearchPrefix -join ", "))
}
if ($EnableLlvm -and -not $ConfigH -and $SearchPrefix.Count -eq 0) {
    Write-Info "LLVM mode without -ConfigH/-SearchPrefix relies on globally discoverable LLVM, Clang, and LLD libraries"
}

Sync-UpstreamZig -RepoUrl $Repo -TargetDir $ZigDir -ResolvedRef $resolved.ResolvedRef -IsMaster:$($resolved.ResolvedRef -eq "master") -PatchMarker $Marker

if (Test-Path $Marker) {
    Write-Info "patch already applied (marker present)"
} else {
    Write-Info "applying patches\zig-expose-lib.patch"
    Push-Location $ZigDir
    try {
        git apply --check $PatchFile 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Fatal @"
patch does not apply cleanly - upstream build.zig likely moved the anchor.
Try:    cd deps\zig; git apply --reject ..\..\patches\zig-expose-lib.patch
Then:   inspect the .rej file and port the small additive block manually.
"@
        }
        git apply $PatchFile
        if ($LASTEXITCODE -ne 0) { Write-Fatal "git apply failed" }
        (Get-Date -Format "o") | Out-File -FilePath $Marker -Encoding ascii
    } finally {
        Pop-Location
    }
}

Ensure-PublicMainArgs -MainFile (Join-Path $ZigDir "src\\main.zig")

Write-Info "building libzig (optimize=$Optimize)"
Push-Location $ZigDir
try {
    $buildArgs = @("build", "libzig", "-Doptimize=$Optimize")
    if ($Target -ne "native") {
        $buildArgs += "-Dtarget=$Target"
    }
    if ($EnableLlvm) {
        $buildArgs += "-Denable-llvm"
    }
    if ($ConfigH) {
        $buildArgs += "-Dconfig_h=$ConfigH"
    }
    foreach ($prefix in $SearchPrefix) {
        $buildArgs += "--search-prefix"
        $buildArgs += $prefix
    }
    & $zigPath @buildArgs
    if ($LASTEXITCODE -ne 0) { Write-Fatal "zig build libzig failed" }
} finally {
    Pop-Location
}

$libzig = Get-ChildItem -Path (Join-Path $ZigDir "zig-out") -Recurse `
            -Include "libzig.a","zig.lib","libzig.lib" -File `
          | Select-Object -First 1

if (-not $libzig) {
    Write-Fatal "libzig static library was not produced - check the build output above"
}

$sizeMb = [math]::Round($libzig.Length / 1MB, 1)
Write-Info ('success: {0} ({1} MB)' -f $libzig.FullName, $sizeMb)
$runArgs = @('build', 'smoke', ('-Dlibzig={0}' -f $libzig.FullName))
if ($Target -ne 'native') {
    $runArgs += ('-Dtarget={0}' -f $Target)
}
if ($EnableLlvm) {
    $runArgs += '-Dembedded-zig-have-llvm=true'
}
foreach ($prefix in $SearchPrefix) {
    $runArgs += '--search-prefix'
    $runArgs += $prefix
}
$runCmd = '& ' + $zigPath + ' ' + ($runArgs -join ' ')
Write-Info ('now run: {0}   (from {1})' -f $runCmd, $RepoRoot)
