<#
.SYNOPSIS
  Preloads verified Decode K/V heads to PL-DDR through the APU JTAG target.

.DESCRIPTION
  The runner only accepts the manifest emitted by
  prepare_llama3_jtag_kv_preload.py.  Before XSDB is started it verifies every
  segment size, SHA-256 digest, head index, and physical address.  XSDB writes
  and reads each head through the APU physical-memory map; after XSDB returns,
  this host process performs bytewise and SHA-256 equality checks on every
  persistent binary readback.  -DryRun performs all local manifest and source
  validation but never resolves XSDB, connects JTAG, or opens a serial port.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$XsdbPath = "D:\Vivado\Vivado\2024.2\bin\xsdb.bat",

    [string]$OutputDirectory = "",

    [switch]$DryRun,

    [ValidatePattern("^[A-Z]$")]
    [string]$DriveLetter = "V"
)

$ErrorActionPreference = "Stop"

$Schema = "gqav7_llama3_jtag_kv_preload_v1"
$KvHeads = 8
$HeadDim = 128
$BytesPerTokenPerHead = $HeadDim * 2
$KBase = [Convert]::ToUInt64("B4000000", 16)
$VBase = [Convert]::ToUInt64("B5000000", 16)
$HeadStride = [Convert]::ToUInt64("00200000", 16)

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-SafeLeafPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Leaf
    )

    if ($Leaf -notmatch "^[A-Za-z0-9._-]+$") {
        throw "Unsafe JTAG preload segment file name: $Leaf"
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $Parent $Leaf))
    $expectedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $actualParent = [IO.Path]::GetDirectoryName($candidate).TrimEnd('\')
    if (-not [string]::Equals(
            $actualParent, $expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "JTAG preload segment must remain beside its manifest: $Leaf"
    }
    return $candidate
}

function Convert-AddressText {
    param([Parameter(Mandatory = $true)][string]$Address)

    if ($Address -notmatch "^0x[0-9A-Fa-f]{8,16}$") {
        throw "Invalid physical address text: $Address"
    }
    return [Convert]::ToUInt64($Address.Substring(2), 16)
}

function Test-BinaryEqual {
    param(
        [Parameter(Mandatory = $true)][string]$LeftPath,
        [Parameter(Mandatory = $true)][string]$RightPath
    )

    $leftInfo = [IO.FileInfo]::new($LeftPath)
    $rightInfo = [IO.FileInfo]::new($RightPath)
    if ($leftInfo.Length -ne $rightInfo.Length) {
        return $false
    }
    $left = [IO.File]::OpenRead($LeftPath)
    $right = [IO.File]::OpenRead($RightPath)
    try {
        $leftBuffer = [byte[]]::new(1024 * 1024)
        $rightBuffer = [byte[]]::new(1024 * 1024)
        while ($true) {
            $leftRead = $left.Read($leftBuffer, 0, $leftBuffer.Length)
            $rightRead = $right.Read($rightBuffer, 0, $rightBuffer.Length)
            if ($leftRead -ne $rightRead) {
                return $false
            }
            if ($leftRead -eq 0) {
                return $true
            }
            for ($index = 0; $index -lt $leftRead; $index++) {
                if ($leftBuffer[$index] -ne $rightBuffer[$index]) {
                    return $false
                }
            }
        }
    }
    finally {
        $left.Dispose()
        $right.Dispose()
    }
}

function Assert-WithinProjectRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = $ProjectRoot.TrimEnd($separator) + $separator
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "JTAG preload path must remain inside the project root: $resolved"
    }
    return $resolved
}

$manifestPathResolved = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifestDirectory = Split-Path -Parent $manifestPathResolved
$manifest = Get-Content -LiteralPath $manifestPathResolved -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schema -ne $Schema) {
    throw "Unsupported JTAG preload manifest schema: $($manifest.schema)"
}
if ($manifest.mode -ne "decode") {
    throw "JTAG K/V preload only supports Decode manifests"
}
$context = [int]$manifest.context
if ($context -lt 1 -or $context -gt 8192) {
    throw "Unsupported Decode context in JTAG preload manifest: $context"
}
if ([int]$manifest.kv_heads -ne $KvHeads -or [int]$manifest.head_dim -ne $HeadDim) {
    throw "JTAG preload geometry must be 8 KV heads with head dimension 128"
}
if ([int]$manifest.batch -ne 1) {
    throw "JTAG preload currently supports batch=1 only"
}
if ($null -eq $manifest.segments -or @($manifest.segments).Count -ne 16) {
    throw "JTAG preload manifest must contain exactly 16 K/V head segments"
}

$headBytes = [int64]$context * $BytesPerTokenPerHead
$validatedSegments = @()
$seen = @{}
foreach ($segment in $manifest.segments) {
    $kind = [string]$segment.kind
    if ($kind -notin @("k", "v")) {
        throw "JTAG preload segment kind must be k or v, got '$kind'"
    }
    $head = [int]$segment.head
    if ($head -lt 0 -or $head -ge $KvHeads) {
        throw "Invalid JTAG preload head index: $head"
    }
    $identity = "${kind}:${head}"
    if ($seen.ContainsKey($identity)) {
        throw "Duplicate JTAG preload segment: $identity"
    }
    $seen[$identity] = $true
    $expectedFile = "{0}_head_{1:D2}_bf16_le.bin" -f $kind, $head
    if ([string]$segment.file -ne $expectedFile) {
        throw "Unexpected JTAG preload segment file for ${identity}: $($segment.file)"
    }
    $source = Get-SafeLeafPath -Parent $manifestDirectory -Leaf $expectedFile
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "JTAG preload segment does not exist: $source"
    }
    $actualBytes = [IO.FileInfo]::new($source).Length
    if ($actualBytes -ne $headBytes -or [int64]$segment.bytes -ne $headBytes) {
        throw "JTAG preload segment byte count mismatch for ${identity}: expected $headBytes"
    }
    $actualHash = Get-Sha256 -Path $source
    $expectedHash = ([string]$segment.sha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch for JTAG preload segment ${identity}: expected $expectedHash, got $actualHash"
    }
    $base = if ($kind -eq "k") { $KBase } else { $VBase }
    $expectedAddress = $base + [uint64]$head * $HeadStride
    $addressText = "0x{0:X8}" -f $expectedAddress
    if ([string]$segment.physical_address -ne $addressText -or
        (Convert-AddressText -Address ([string]$segment.physical_address)) -ne $expectedAddress) {
        throw "Physical address mismatch for ${identity}: expected $addressText"
    }
    if ($headBytes % 4 -ne 0 -or [int64]$segment.words -ne ($headBytes / 4)) {
        throw "JTAG preload word count mismatch for ${identity}"
    }
    $validatedSegments += [PSCustomObject]@{
        Kind = $kind
        Head = $head
        SourcePath = $source
        Bytes = $actualBytes
        Sha256 = $actualHash
        Address = $addressText
        Words = [int64]($headBytes / 4)
    }
}
foreach ($kind in @("k", "v")) {
    foreach ($head in 0..($KvHeads - 1)) {
        if (-not $seen.ContainsKey("${kind}:${head}")) {
            throw "Missing JTAG preload segment: ${kind}:${head}"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $manifestDirectory ("jtag_kv_preload_run_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$runManifest = Join-Path $output "jtag_kv_preload_manifest.json"
Copy-Item -LiteralPath $manifestPathResolved -Destination $runManifest -Force

$localValidation = [PSCustomObject]@{
    Schema = "gqav7_jtag_kv_preload_local_validation_v1"
    Mode = "decode"
    Context = $context
    Layer = [int]$manifest.layer
    ManifestSha256 = Get-Sha256 -Path $manifestPathResolved
    LocalSha256SegmentsVerified = $validatedSegments.Count
    Segments = $validatedSegments
}
[IO.File]::WriteAllText(
    (Join-Path $output "local_validation.json"),
    ($localValidation | ConvertTo-Json -Depth 6) + "`n",
    [Text.UTF8Encoding]::new($false))
Write-Host "GQAV7_JTAG_KV_LOCAL_SHA256_OK=$($validatedSegments.Count)"
Write-Host "GQAV7_JTAG_KV_CONTEXT=$context LAYER=$($manifest.layer)"
if ($DryRun) {
    Write-Host "GQAV7_JTAG_KV_PRELOAD_DRY_RUN=1"
    return
}

$xsdb = (Resolve-Path -LiteralPath $XsdbPath).Path
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$tcl = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "fpgatten_jtag_kv_preload.tcl")).Path
Assert-WithinProjectRoot -Path $tcl -ProjectRoot $projectRoot | Out-Null
Assert-WithinProjectRoot -Path $output -ProjectRoot $projectRoot | Out-Null
foreach ($record in $validatedSegments) {
    Assert-WithinProjectRoot -Path $record.SourcePath -ProjectRoot $projectRoot | Out-Null
}

$subst = Join-Path $env:SystemRoot "System32\subst.exe"
$drive = "${DriveLetter}:"
$driveRoot = "${drive}\"
$mapping = (& $subst) | Where-Object { $_ -match ("^{0}:\\:" -f $DriveLetter) }
$createdMapping = $false
if ($mapping) {
    if ($mapping -notmatch [Regex]::Escape($projectRoot)) {
        throw "$drive is already mapped elsewhere: $mapping"
    }
}
else {
    & $subst $drive $projectRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $drive to $projectRoot"
    }
    $createdMapping = $true
}

function Convert-ToDrivePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = $projectRoot.TrimEnd($separator) + $separator
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside mapped JTAG project root: $full"
    }
    return (Join-Path $driveRoot $full.Substring($prefix.Length)) -replace '\\', '/'
}

$runId = [Guid]::NewGuid().ToString("N")
$readbacks = Join-Path $output "readbacks"
$segmentsFile = Join-Path $output "jtag_kv_segments.tsv"
$log = Join-Path $output "jtag_kv_preload.log"
New-Item -ItemType Directory -Path $readbacks -Force | Out-Null
$rows = @()
foreach ($record in ($validatedSegments | Sort-Object Kind, Head)) {
    $readback = Join-Path $readbacks ("{0}_head_{1:D2}_readback.bin" -f $record.Kind, $record.Head)
    $record | Add-Member -NotePropertyName ReadbackPath -NotePropertyValue $readback
    $rowValues = @(
        (Convert-ToDrivePath -Path $record.SourcePath),
        (Convert-ToDrivePath -Path $readback),
        $record.Address,
        $record.Words,
        $record.Kind,
        $record.Head
    )
    $rows += ($rowValues -join "`t")
}
[IO.File]::WriteAllLines($segmentsFile, $rows, [Text.UTF8Encoding]::new($false))

$env:GQAV7_JTAG_KV_SEGMENTS_FILE = Convert-ToDrivePath -Path $segmentsFile
$env:GQAV7_JTAG_KV_RUN_ID = $runId
try {
    Push-Location $driveRoot
    try {
        & $xsdb (Convert-ToDrivePath -Path $tcl) 2>&1 | Tee-Object -FilePath $log
        $xsdbExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($xsdbExit -ne 0) {
        throw "XSDB JTAG K/V preload failed with exit code $xsdbExit; log=$log"
    }
    $logText = Get-Content -LiteralPath $log -Raw
    if ($logText -notmatch "GQAV7_JTAG_KV_PRELOAD_TCL_PASS") {
        throw "XSDB exited without the K/V preload PASS marker; log=$log"
    }

    $verification = @()
    foreach ($record in ($validatedSegments | Sort-Object Kind, Head)) {
        $readbackHash = ""
        $bytewiseEqual = $false
        $readbackExists = Test-Path -LiteralPath $record.ReadbackPath -PathType Leaf
        if ($readbackExists) {
            $bytewiseEqual = Test-BinaryEqual -LeftPath $record.SourcePath -RightPath $record.ReadbackPath
            $readbackHash = Get-Sha256 -Path $record.ReadbackPath
        }
        $passed = $readbackExists -and $bytewiseEqual -and ($readbackHash -eq $record.Sha256)
        $verification += [PSCustomObject]@{
            Kind = $record.Kind
            Head = $record.Head
            Address = $record.Address
            Bytes = $record.Bytes
            SourceSha256 = $record.Sha256
            ReadbackPath = $record.ReadbackPath
            ReadbackSha256 = $readbackHash
            BytewiseEqual = $bytewiseEqual
            Passed = $passed
        }
    }
    $allPassed = @($verification | Where-Object { -not $_.Passed }).Count -eq 0
    $verificationDocument = [PSCustomObject]@{
        Schema = "gqav7_jtag_kv_preload_readback_verification_v1"
        RunId = $runId
        Context = $context
        Layer = [int]$manifest.layer
        Passed = $allPassed
        Records = $verification
    }
    [IO.File]::WriteAllText(
        (Join-Path $output "readback_verification.json"),
        ($verificationDocument | ConvertTo-Json -Depth 6) + "`n",
        [Text.UTF8Encoding]::new($false))
    if (-not $allPassed) {
        throw "One or more JTAG K/V readbacks failed host-side bytewise/SHA-256 verification"
    }
    Write-Host "GQAV7_JTAG_KV_PRELOAD_PASS=1 SEGMENTS=$($verification.Count) LOG=$log"
}
finally {
    Remove-Item Env:\GQAV7_JTAG_KV_SEGMENTS_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\GQAV7_JTAG_KV_RUN_ID -ErrorAction SilentlyContinue
    if ($createdMapping) {
        & $subst $drive /d | Out-Null
    }
}
