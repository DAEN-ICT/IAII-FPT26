param(
    [Parameter(Mandatory = $true)]
    [string]$DecodeBinaryPath,
    [Parameter(Mandatory = $true)]
    [string]$PrefillBinaryPath,
    [string]$ComPort = "COM3",
    [string]$DecodeContexts = "1,2,3,4,7,8,15,16,17,31,32,33,64,128,256,512,1024,2048,4096,8192",
    [string]$PrefillCases = "1:1,16:16,32:32,64:64,128:128,256:256,512:512,1024:1024,2048:2048,4096:4096,8192:8192",
    [ValidateRange(1, 100)]
    [int]$Repeat = 1,
    [ValidateRange(1, 1000000000)]
    [long]$ClockHz = 235000000,
    [ValidateRange(1, 1000000000)]
    [long]$DmaClockHz = 300000000,
    [ValidateRange(30, 3600)]
    [int]$CaseTimeoutSeconds = 1800,
    [switch]$ExistingLogin,
    [switch]$ContinueOnCaseFailure,
    [string]$BoardPassword = "",
    [string]$LogPath = "fpgatten_board_suite_serial.log"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($BoardPassword)) {
    if (-not [string]::IsNullOrWhiteSpace($env:FPGATTEN_BOARD_PASSWORD)) {
        $BoardPassword = $env:FPGATTEN_BOARD_PASSWORD
    }
    else {
        $enteredPassword = Read-Host "Board sudo password" -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($enteredPassword)
        try {
            $BoardPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}
if ($BoardPassword.Length -lt 12) {
    throw "BoardPassword must contain at least 12 characters"
}
$decodeBinary = (Resolve-Path $DecodeBinaryPath).Path
$prefillBinary = (Resolve-Path $PrefillBinaryPath).Path
$log = [IO.Path]::GetFullPath($LogPath)
$serial = [IO.Ports.SerialPort]::new($ComPort, 115200, "None", 8, "One")
$serial.NewLine = [char]10
$serial.ReadTimeout = 200
$serial.WriteTimeout = 5000
$serial.DtrEnable = $true
$serial.RtsEnable = $false
$password = $BoardPassword

Set-Content -LiteralPath $log -Value (
    "FPGAtten board suite serial log; core_hz=$ClockHz dma_hz=$DmaClockHz")

function Receive-Until {
    param(
        [string]$Marker,
        [int]$TimeoutSeconds
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

function Upload-Binary {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )
    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    $localHash = (Get-FileHash -Algorithm SHA256 $LocalPath).Hash.ToLowerInvariant()
    $serial.WriteLine("stty -echo; : > $RemotePath")
    Start-Sleep -Milliseconds 300
    for ($offset = 0; $offset -lt $bytes.Length; $offset += 700) {
        $length = [Math]::Min(700, $bytes.Length - $offset)
        $builder = [Text.StringBuilder]::new(4 * $length)
        for ($index = 0; $index -lt $length; $index++) {
            [void]$builder.AppendFormat("\x{0:x2}", $bytes[$offset + $index])
        }
        $serial.WriteLine("printf '%b' '$builder' >> $RemotePath")
        Start-Sleep -Milliseconds 250
        [void]$serial.ReadExisting()
    }
    $serial.WriteLine(
        "chmod 755 $RemotePath; stty echo; " +
        "echo UPLOAD_READY=`$(sha256sum $RemotePath | cut -d' ' -f1)")
    $uploadResult = Receive-Until -Marker "UPLOAD_READY=" -TimeoutSeconds 30
    if (-not $uploadResult.ToLowerInvariant().Contains($localHash)) {
        throw "Uploaded binary SHA-256 does not match $localHash"
    }
}

function Invoke-SudoCommand {
    param(
        [string]$Command,
        [string]$PromptMarker,
        [string]$ResultMarker,
        [int]$TimeoutSeconds,
        [switch]$AllowNonzero
    )
    $serial.WriteLine("stty -echo")
    Start-Sleep -Milliseconds 300
    [void]$serial.ReadExisting()
    $serial.WriteLine(
        "sudo -k -S -p $PromptMarker $Command; echo $ResultMarker`$?")
    [void](Receive-Until -Marker $PromptMarker -TimeoutSeconds 15)
    $serial.WriteLine($password)
    $result = Receive-Until -Marker $ResultMarker -TimeoutSeconds $TimeoutSeconds
    $serial.WriteLine("stty echo")
    if (-not $result.Contains($ResultMarker + "0")) {
        if ($AllowNonzero) {
            return $false
        }
        throw "Board command returned nonzero status: $Command"
    }
    return $true
}

$parsedDecodeContexts = @()
foreach ($entry in $DecodeContexts.Split(",")) {
    if ($entry -notmatch "^[1-9][0-9]{0,3}$") {
        throw "Illegal decode context '$entry'"
    }
    $context = [int]$entry
    if ($context -gt 8192) {
        throw "Illegal decode context '$entry'; maximum is 8192"
    }
    $parsedDecodeContexts += $context
}

$parsedCases = @()
foreach ($entry in $PrefillCases.Split(",")) {
    if ($entry -notmatch "^([1-9][0-9]{0,3}):([1-9][0-9]{0,3})$") {
        throw "Illegal prefill case '$entry'; use CONTEXT:QUERY"
    }
    $context = [int]$Matches[1]
    $queries = [int]$Matches[2]
    if ($context -gt 8192 -or $queries -gt $context) {
        throw "Illegal prefill case '$entry'; require QUERY <= CONTEXT <= 8192"
    }
    $parsedCases += [PSCustomObject]@{ Context = $context; Queries = $queries }
}

try {
    $caseFailures = @()
    $serial.Open()

    if ($ExistingLogin) {
        $serial.WriteLine("")
        [void](Receive-Until -Marker ":~$" -TimeoutSeconds 15)
    }
    else {
        # The companion boot listener leaves the terminal at the first-login
        # password prompt.  Every cold boot applies the same stable password.
        $serial.WriteLine($password)
        [void](Receive-Until -Marker "Retype new password:" -TimeoutSeconds 15)
        $serial.WriteLine($password)
        [void](Receive-Until -Marker ":~$" -TimeoutSeconds 30)
    }

    Upload-Binary -LocalPath $decodeBinary -RemotePath "/tmp/gqav7-uio-benchmark"
    $serial.WriteLine(
        "/tmp/gqav7-uio-benchmark --model-self-test; echo MODEL_RC=`$?")
    [void](Receive-Until -Marker "MODEL_RC=0" -TimeoutSeconds 30)

    Upload-Binary -LocalPath $prefillBinary -RemotePath "/tmp/gqav7-custom-experiment"
    $serial.WriteLine(
        "/tmp/gqav7-custom-experiment --help; echo HELP_RC=`$?")
    $helpResult = Receive-Until -Marker "HELP_RC=" -TimeoutSeconds 30
    if (-not $helpResult.Contains("--prefill") -or
        -not $helpResult.Contains("HELP_RC=0")) {
        throw "Uploaded prefill program does not expose the expected CLI"
    }

    if ($ContinueOnCaseFailure) {
        foreach ($context in $parsedDecodeContexts) {
            $decodeMarker = "GQAV7_DECODE_RC_$context="
            $decodePassed = Invoke-SudoCommand `
                -Command (
                    "/tmp/gqav7-uio-benchmark --repeat $Repeat " +
                    "--clock-hz $ClockHz --dma-clock-hz $DmaClockHz " +
                    "--contexts $context /dev/uio4 /dev/uio5") `
                -PromptMarker "GQAV7_DECODE_SUDO_PROMPT_$context" `
                -ResultMarker $decodeMarker `
                -TimeoutSeconds $CaseTimeoutSeconds `
                -AllowNonzero
            if (-not $decodePassed) {
                $caseFailures += "decode:$context"
                Add-Content -LiteralPath $log -Value (
                    "`nGQAV7_CASE_FAILURE=decode:$context")
            }
        }
    }
    else {
        $decodeMarker = "GQAV7_DECODE_RC="
        [void](Invoke-SudoCommand `
            -Command (
                "/tmp/gqav7-uio-benchmark --repeat $Repeat " +
                "--clock-hz $ClockHz --dma-clock-hz $DmaClockHz " +
                "--contexts $DecodeContexts " +
                "/dev/uio4 /dev/uio5") `
            -PromptMarker "GQAV7_DECODE_SUDO_PROMPT" `
            -ResultMarker $decodeMarker `
            -TimeoutSeconds $CaseTimeoutSeconds)
    }

    foreach ($case in $parsedCases) {
        $marker = "GQAV7_PREFILL_RC_" +
            $case.Context + "_" + $case.Queries + "="
        $prefillPassed = Invoke-SudoCommand `
            -Command (
                "/tmp/gqav7-custom-experiment --clock-hz $ClockHz --prefill " +
                "/dev/uio4 /dev/uio5 " + $case.Context + " " +
                $case.Queries) `
            -PromptMarker (
                "GQAV7_PREFILL_SUDO_PROMPT_" +
                $case.Context + "_" + $case.Queries) `
            -ResultMarker $marker `
            -TimeoutSeconds $CaseTimeoutSeconds `
            -AllowNonzero:$ContinueOnCaseFailure
        if (-not $prefillPassed) {
            $caseFailures += (
                "prefill:" + $case.Context + ":" + $case.Queries)
            Add-Content -LiteralPath $log -Value (
                "`nGQAV7_CASE_FAILURE=prefill:" +
                $case.Context + ":" + $case.Queries)
        }
    }

    if ($caseFailures.Count -ne 0) {
        throw (
            "FPGAtten board suite completed all requested cases with " +
            "$($caseFailures.Count) failure(s): " +
            ($caseFailures -join ","))
    }
    Write-Host "PASS: FPGAtten board suite completed; log=$log"
}
finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $password = $null
}
