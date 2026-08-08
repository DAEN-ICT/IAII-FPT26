<#
.SYNOPSIS
  Replays one real Llama3-8B GQA Q/K/V payload on the FPGA board.

.DESCRIPTION
  This runner keeps the timing boundary inside gqav7-llama3-replay: local
  payload validation, serial transport, PL-DDR loading, and Golden comparison
  occur outside the reported accelerator tokens/s measurement.  It verifies
  the four payload SHA-256 values locally from replay_manifest.json, uploads
  the binary and payloads over the existing serial printf transport, then runs
  sha256sum -c on the board before invoking the UIO program.

  No password is embedded in this script.  For a non-dry run, provide a
  SecureString -BoardPassword, set FPGATTEN_BOARD_PASSWORD for the current
  process, or enter it when prompted.  The password is never written to the
  local serial log.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ReplayBinaryPath,

    [Parameter(Mandatory = $true)]
    [string]$PayloadDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateSet("decode", "prefill")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 8192)]
    [int]$Context,

    [ValidateRange(1, 100)]
    [int]$Repeats = 3,

    [ValidateRange(1, 1000000000)]
    [long]$ClockHz = 235000000,

    [ValidateRange(1, 3600000)]
    [int]$DeviceTimeoutMs = 300000,

    [ValidateRange(30, 7200)]
    [int]$CaseTimeoutSeconds = 1800,

    [string]$ComPort = "COM3",

    [switch]$ExistingLogin,

    # K/V are supplied through the separately verified JTAG PL-DDR preload
    # path.  Q and Golden remain serial-uploaded and board-hash-verified.
    [switch]$PreloadedKv,

    [switch]$DryRun,

    [ValidateSet("none", "gzip")]
    [string]$TransportCompression = "gzip",

    [System.Security.SecureString]$BoardPassword,

    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$preloadedKvNumber = if ($PreloadedKv) { 1 } else { 0 }

function Get-PlainTextSecureString {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Value)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-BoardPassword {
    if ($null -ne $BoardPassword -and $BoardPassword.Length -gt 0) {
        return Get-PlainTextSecureString -Value $BoardPassword
    }
    if (-not [string]::IsNullOrWhiteSpace($env:FPGATTEN_BOARD_PASSWORD)) {
        $fromEnvironment = ConvertTo-SecureString `
            -String $env:FPGATTEN_BOARD_PASSWORD -AsPlainText -Force
        return Get-PlainTextSecureString -Value $fromEnvironment
    }
    $entered = Read-Host "PetaLinux sudo password" -AsSecureString
    return Get-PlainTextSecureString -Value $entered
}

function Get-ManifestPayloadEntry {
    param(
        [Parameter(Mandatory = $true)]$ManifestPayloads,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $ManifestPayloads.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "Replay manifest is missing payload entry '$Name'"
    }
    return $property.Value
}

function Assert-SafeLeafName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -notmatch "^[A-Za-z0-9._-]+$") {
        throw "Unsafe replay payload file name: $Name"
    }
}

function Receive-Until {
    param(
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $buffer = [Text.StringBuilder]::new()
    while ([DateTime]::UtcNow -lt $deadline) {
        $received = $serial.ReadExisting()
        if ($received.Length -ne 0) {
            [void]$buffer.Append($received)
            Write-Host -NoNewline $received
            Add-Content -LiteralPath $log -Value $received -NoNewline
            if ($buffer.ToString().Contains($Marker)) {
                return $buffer.ToString()
            }
            if ($buffer.Length -gt 1048576) {
                [void]$buffer.Remove(0, $buffer.Length - 524288)
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Serial timeout waiting for marker: $Marker"
}

function Upload-File {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [switch]$Executable
    )

    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $LocalPath).Hash.ToLowerInvariant()
    $marker = "GQAV7_REPLAY_UPLOAD_" + [Guid]::NewGuid().ToString("N") + "="

    $serial.WriteLine("stty -echo; : > $RemotePath")
    Start-Sleep -Milliseconds 300
    for ($offset = 0; $offset -lt $bytes.Length; $offset += 700) {
        $length = [Math]::Min(700, $bytes.Length - $offset)
        $escaped = [Text.StringBuilder]::new(4 * $length)
        for ($index = 0; $index -lt $length; $index++) {
            [void]$escaped.AppendFormat("\x{0:x2}", $bytes[$offset + $index])
        }
        $serial.WriteLine("printf '%b' '$escaped' >> $RemotePath")
        Start-Sleep -Milliseconds 250
        [void]$serial.ReadExisting()
    }

    $chmod = if ($Executable) { "chmod 755 $RemotePath; " } else { "" }
    $serial.WriteLine(
        "${chmod}stty echo; echo ${marker}`$(sha256sum $RemotePath | cut -d' ' -f1)")
    $uploadResult = Receive-Until -Marker $marker -TimeoutSeconds 60
    if (-not $uploadResult.ToLowerInvariant().Contains($localHash)) {
        throw "Uploaded file SHA-256 does not match local file: $LocalPath"
    }
}

function New-GzipTransportFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $input = [IO.File]::OpenRead($SourcePath)
    try {
        $output = [IO.File]::Create($DestinationPath)
        try {
            $gzip = [IO.Compression.GzipStream]::new(
                $output, [IO.Compression.CompressionLevel]::Optimal, $false)
            try {
                $input.CopyTo($gzip)
            }
            finally {
                $gzip.Dispose()
            }
        }
        finally {
            $output.Dispose()
        }
    }
    finally {
        $input.Dispose()
    }
    return (Resolve-Path -LiteralPath $DestinationPath).Path
}

function Invoke-SudoCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$PromptMarker,
        [Parameter(Mandatory = $true)][string]$ResultMarker,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Password
    )

    # Hide command echo while the password is supplied.  Receive-Until writes
    # only board output to the log; the password itself is not logged.
    $serial.WriteLine("stty -echo")
    Start-Sleep -Milliseconds 300
    [void]$serial.ReadExisting()
    $serial.WriteLine(
        "sudo -k -S -p $PromptMarker $Command; rc=`$?; stty echo; echo $ResultMarker`$rc")
    [void](Receive-Until -Marker $PromptMarker -TimeoutSeconds 20)
    $serial.WriteLine($Password)
    # Match the full success token.  Matching only the prefix can return
    # between the `=` and the status digit on a serial chunk boundary.
    $result = Receive-Until -Marker ($ResultMarker + "0") -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Contains($ResultMarker + "0")) {
        throw "Board command returned nonzero status: $Command"
    }
    return $result
}

$binary = (Resolve-Path -LiteralPath $ReplayBinaryPath).Path
$payloadDirectoryResolved = (Resolve-Path -LiteralPath $PayloadDirectory).Path
$manifestPath = Join-Path $payloadDirectoryResolved "replay_manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Replay manifest does not exist: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schema -ne "gqav7_llama3_fpga_replay_payload_v1") {
    throw "Unsupported replay manifest schema: $($manifest.schema)"
}
if ($manifest.mode -ne $Mode) {
    throw "Replay manifest mode '$($manifest.mode)' does not match requested mode '$Mode'"
}
if ([int]$manifest.context -ne $Context) {
    throw "Replay manifest context '$($manifest.context)' does not match requested context '$Context'"
}
if ($null -eq $manifest.layer -or [int]$manifest.layer -lt 0) {
    throw "Replay manifest layer must be a non-negative integer"
}

$expectedPayloadFiles = [ordered]@{
    q             = "q_bf16_le.bin"
    k             = "k_bf16_le.bin"
    v             = "v_bf16_le.bin"
    golden_output = "o_fp32_golden_le.bin"
}
$payloadRecords = @()
foreach ($name in $expectedPayloadFiles.Keys) {
    $entry = Get-ManifestPayloadEntry -ManifestPayloads $manifest.payloads -Name $name
    $expectedFile = $expectedPayloadFiles[$name]
    if ($entry.file -ne $expectedFile) {
        throw "Replay manifest payload '$name' must use '$expectedFile', got '$($entry.file)'"
    }
    Assert-SafeLeafName -Name $expectedFile
    $localPath = Join-Path $payloadDirectoryResolved $expectedFile
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        throw "Replay payload file does not exist: $localPath"
    }
    $actualBytes = [IO.FileInfo]::new($localPath).Length
    if ($actualBytes -ne [int64]$entry.bytes) {
        throw "Replay payload byte count mismatch for ${expectedFile}: expected $($entry.bytes), got $actualBytes"
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash.ToLowerInvariant()
    $expectedHash = ([string]$entry.sha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch for ${expectedFile}: expected $expectedHash, got $actualHash"
    }
    $payloadRecords += [PSCustomObject]@{
        Name       = $name
        FileName   = $expectedFile
        LocalPath  = $localPath
        Bytes      = $actualBytes
        Sha256     = $actualHash
    }
}
$boardPayloadRecords = @(
    $payloadRecords | Where-Object {
        -not $PreloadedKv -or ($_.Name -ne "k" -and $_.Name -ne "v")
    }
)

$layer = [int]$manifest.layer
$caseName = "{0}_context_{1}_layer_{2:D2}" -f $Mode, $Context, $layer
$remoteDirectory = "/tmp/gqav7-llama3/$caseName"
$remoteBinary = "$remoteDirectory/gqav7-llama3-replay"
$binaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash.ToLowerInvariant()

Write-Host "LOCAL_PAYLOAD_SHA256_OK=$($payloadRecords.Count)"
Write-Host "LOCAL_REPLAY_BINARY_SHA256=$binaryHash"
Write-Host "REMOTE_CASE=$remoteDirectory"
Write-Host "PRELOADED_KV=$preloadedKvNumber"
if ($DryRun) {
    Write-Host "DRY_RUN=1"
    return
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $defaultLogDirectory = Join-Path $PSScriptRoot "..\..\results\Board\llama3_replay"
    $LogPath = Join-Path $defaultLogDirectory ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $caseName, (Get-Date))
}
$log = [IO.Path]::GetFullPath($LogPath)
$logDirectory = Split-Path -Parent $log
if (-not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}
Set-Content -LiteralPath $log -Encoding UTF8 -Value @(
    "FPGAtten real Llama3 replay serial log",
    "mode=$Mode context=$Context layer=$layer repeats=$Repeats core_clock_hz=$ClockHz",
    "timing_boundary=single-layer_device-resident_attention-only; local loading and Golden comparison excluded",
    "remote_directory=$remoteDirectory",
    "replay_binary_sha256=$binaryHash",
    "transport_compression=$TransportCompression",
    "preloaded_kv=$preloadedKvNumber"
)

$transportDirectory = Join-Path $logDirectory ("{0}.transport" -f $caseName)
if (-not (Test-Path -LiteralPath $transportDirectory)) {
    New-Item -ItemType Directory -Path $transportDirectory -Force | Out-Null
}

$checksumFile = Join-Path $logDirectory ("{0}.SHA256SUMS" -f $caseName)
$checksumLines = @("$binaryHash  gqav7-llama3-replay")
foreach ($record in $boardPayloadRecords) {
    $checksumLines += "$($record.Sha256)  $($record.FileName)"
}
[IO.File]::WriteAllText(
    $checksumFile,
    (($checksumLines -join "`n") + "`n"),
    [Text.UTF8Encoding]::new($false))

$rawTransferRecords = @(
    [PSCustomObject]@{
        LocalPath = $binary
        RemotePath = $remoteBinary
        Executable = $true
        Label = "replay_binary"
    }
)
foreach ($record in $boardPayloadRecords) {
    $rawTransferRecords += [PSCustomObject]@{
        LocalPath = $record.LocalPath
        RemotePath = "$remoteDirectory/$($record.FileName)"
        Executable = $false
        Label = $record.Name
    }
}
$rawTransferRecords += [PSCustomObject]@{
    LocalPath = $checksumFile
    RemotePath = "$remoteDirectory/SHA256SUMS"
    Executable = $false
    Label = "checksums"
}

$transferRecords = @()
$transportIndex = 0
foreach ($record in $rawTransferRecords) {
    $transportIndex += 1
    $uploadedPath = $record.LocalPath
    $remoteUploadPath = $record.RemotePath
    $compressed = $false
    if ($TransportCompression -eq "gzip") {
        $candidate = Join-Path $transportDirectory (
            "{0:D2}_{1}.gz" -f $transportIndex, ([IO.Path]::GetFileName($record.LocalPath)))
        $candidatePath = New-GzipTransportFile `
            -SourcePath $record.LocalPath -DestinationPath $candidate
        if ([IO.FileInfo]::new($candidatePath).Length -lt [IO.FileInfo]::new($record.LocalPath).Length) {
            $uploadedPath = $candidatePath
            $remoteUploadPath = "$($record.RemotePath).gz"
            $compressed = $true
        }
    }
    $transferRecords += [PSCustomObject]@{
        LocalPath = $uploadedPath
        RemoteUploadPath = $remoteUploadPath
        RemoteRawPath = $record.RemotePath
        Executable = [bool]$record.Executable
        Label = $record.Label
        Compressed = $compressed
    }
}
$rawTransportBytes = ($rawTransferRecords | ForEach-Object {
    [IO.FileInfo]::new($_.LocalPath).Length
} | Measure-Object -Sum).Sum
$uploadedTransportBytes = ($transferRecords | ForEach-Object {
    [IO.FileInfo]::new($_.LocalPath).Length
} | Measure-Object -Sum).Sum
Add-Content -LiteralPath $log -Value (
    "transport_raw_bytes=$rawTransportBytes transport_uploaded_bytes=$uploadedTransportBytes")
Write-Host "TRANSPORT_GZIP_RAW_BYTES=$rawTransportBytes"
Write-Host "TRANSPORT_GZIP_UPLOADED_BYTES=$uploadedTransportBytes"

$serial = [IO.Ports.SerialPort]::new($ComPort, 115200, "None", 8, "One")
$serial.NewLine = [char]10
$serial.ReadTimeout = 200
$serial.WriteTimeout = 5000
$serial.DtrEnable = $true
$serial.RtsEnable = $false
$plainBoardPassword = $null

try {
    $plainBoardPassword = Get-BoardPassword
    $serial.Open()

    if ($ExistingLogin) {
        $serial.WriteLine("")
        # The previous replay leaves the shell in its payload directory, so
        # accept the generic regular-user prompt instead of assuming `~`.
        [void](Receive-Until -Marker '$ ' -TimeoutSeconds 20)
    }
    else {
        # First-login support remains opt-in.  The caller supplies the current
        # process password; it is not persisted in the runner or log.
        $serial.WriteLine($plainBoardPassword)
        [void](Receive-Until -Marker "Retype new password:" -TimeoutSeconds 20)
        $serial.WriteLine($plainBoardPassword)
        [void](Receive-Until -Marker '$ ' -TimeoutSeconds 30)
    }

    $serial.WriteLine("mkdir -p $remoteDirectory; echo GQAV7_REPLAY_MKDIR_RC=`$?")
    [void](Receive-Until -Marker "GQAV7_REPLAY_MKDIR_RC=0" -TimeoutSeconds 20)

    foreach ($transferRecord in $transferRecords) {
        Upload-File -LocalPath $transferRecord.LocalPath `
            -RemotePath $transferRecord.RemoteUploadPath `
            -Executable:$transferRecord.Executable
        if ($transferRecord.Compressed) {
            $decompressMarker = "GQAV7_REPLAY_DECOMPRESS_" +
                [Guid]::NewGuid().ToString("N") + "="
            $serial.WriteLine(
                "stty -echo; gzip -dc $($transferRecord.RemoteUploadPath) > " +
                "$($transferRecord.RemoteRawPath); rc=`$?; " +
                "stty echo; echo $decompressMarker`$rc")
            $decompressResult = Receive-Until -Marker ($decompressMarker + "0") -TimeoutSeconds 120
            if (-not $decompressResult.Contains($decompressMarker + "0")) {
                throw "Board gzip decompression failed for $($transferRecord.Label)"
            }
            if ($transferRecord.Executable) {
                $serial.WriteLine("chmod 755 $($transferRecord.RemoteRawPath)")
            }
        }
    }

    $boardHashMarker = "GQAV7_REPLAY_BOARD_SHA256_RC="
    $serial.WriteLine(
        "stty -echo; cd $remoteDirectory; sha256sum -c SHA256SUMS; rc=`$?; stty echo; echo $boardHashMarker`$rc")
    $boardHashResult = Receive-Until -Marker ($boardHashMarker + "0") -TimeoutSeconds 90
    if (-not $boardHashResult.Contains($boardHashMarker + "0")) {
        throw "Board sha256sum -c verification failed for $remoteDirectory"
    }
    foreach ($verifiedFile in @("gqav7-llama3-replay") + $boardPayloadRecords.FileName) {
        if ($boardHashResult -notmatch ([Regex]::Escape($verifiedFile) + ": OK")) {
            throw "Board sha256sum output did not confirm replay file: $verifiedFile"
        }
    }

    $preloadedKvOption = if ($PreloadedKv) { "--preloaded-kv " } else { "" }
    $runCommand = (
        "$remoteBinary --mode $Mode --context $Context --input-dir $remoteDirectory " +
        "$preloadedKvOption--clock-hz $ClockHz --repeats $Repeats " +
        "--timeout-ms $DeviceTimeoutMs /dev/uio4 /dev/uio5")
    $runResult = Invoke-SudoCommand `
        -Command $runCommand `
        -PromptMarker "GQAV7_REPLAY_SUDO_PROMPT" `
        -ResultMarker "GQAV7_REPLAY_RC=" `
        -TimeoutSeconds $CaseTimeoutSeconds `
        -Password $plainBoardPassword
    if (-not $runResult.Contains("GQAV7_LLAMA3_REPLAY_RESULT")) {
        throw "Replay program exited successfully but did not print GQAV7_LLAMA3_REPLAY_RESULT"
    }

    Write-Host "PASS: real Llama3 replay completed; log=$log"
}
finally {
    if ($null -ne $serial -and $serial.IsOpen) {
        $serial.Close()
    }
    $plainBoardPassword = $null
}
