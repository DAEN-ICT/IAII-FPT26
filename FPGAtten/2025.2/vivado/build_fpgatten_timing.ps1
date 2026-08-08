param(
    [string]$ProjectRoot = "",
    [ValidateSet(235)]
    [int]$CoreMHz = 235,
    [ValidateRange(1, 16)]
    [int]$Jobs = 4,
    [string]$VivadoBat = "",
    [ValidatePattern("^[A-Z]$")]
    [string]$DriveLetter = "X",
    [ValidatePattern("^[A-Za-z0-9_]+$")]
    [string]$Revision = "release_2025_2",
    # Keep generated Vivado .Xil and OOC checkpoint paths below Windows' 260
    # character limit.  The user-facing revision stays descriptive; only the
    # disposable project-work directory is shortened.
    [ValidatePattern("^[A-Za-z0-9_]*$")]
    [string]$ProjectDirectoryLeaf = "",
    # Optionally map an already-created project directory directly to a
    # second drive letter.  Generated OOC paths then begin at e.g. Y:\\ rather
    # than X:\\FPGAtten\\vivado\\project\\<long-name>, avoiding the Windows
    # MAX_PATH limit without moving sources or delivery outputs.
    [ValidatePattern("^[A-Z]?$")]
    [string]$ProjectDriveLetter = "",
    # An explicit project-file view is useful when a short compatibility path
    # tree preserves legacy ../../board and ../../../rtl references.
    [string]$ProjectFileOverride = "",
    # Reuse only a locally completed accelerator OOC checkpoint.  Top
    # synthesis, implementation and bitstream generation still run fresh.
    [switch]$ReuseAccelerator,
    [switch]$HeadlessRunner,
    [switch]$DisablePostRoutePhysOpt
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}
else {
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
}
if ([string]::IsNullOrWhiteSpace($VivadoBat)) {
    $vivadoCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:XILINX_VIVADO)) {
        $vivadoCandidates += (Join-Path $env:XILINX_VIVADO "bin\vivado.bat")
    }
    $vivadoCandidates += @(
        "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat",
        "D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat",
        "C:\Xilinx\Vivado\2025.2\bin\vivado.bat",
        "D:\Xilinx\Vivado\2025.2\bin\vivado.bat"
    )
    $VivadoBat = $vivadoCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($VivadoBat) -or
    -not (Test-Path -LiteralPath $VivadoBat -PathType Leaf)) {
    throw "Vivado 2025.2 launcher is missing; pass -VivadoBat explicitly"
}
$vivadoVersionLine = (& $VivadoBat -version 2>&1 |
    Select-Object -First 1).ToString()
if ($vivadoVersionLine -notmatch '^vivado v2025\.2\b') {
    throw "Vivado 2025.2 is required, got: $vivadoVersionLine"
}

# Map only the parent workspace to keep generated Vivado paths short.  The
# project leaf is derived rather than hard-coded, so this script can never
# redirect an FPGAtten build outside the selected project root.
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ".."))
$projectLeaf = Split-Path -Leaf $ProjectRoot
$substExe = Join-Path $env:SystemRoot "System32\subst.exe"
$drive = "${DriveLetter}:"
$mapping = (& $substExe) |
    Where-Object { $_ -match ("^{0}:\\" -f $DriveLetter) }
if ($mapping) {
    if ($mapping -notmatch [regex]::Escape($workspaceRoot)) {
        throw "$drive is already mapped elsewhere: $mapping"
    }
}
else {
    & $substExe $drive $workspaceRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $drive to $workspaceRoot"
    }
}

$driveProjectRoot = "${drive}\${projectLeaf}"
if (-not (Test-Path -LiteralPath $driveProjectRoot -PathType Container)) {
    throw "Mapped FPGAtten project root is inaccessible: $driveProjectRoot"
}
# Launch from the mapped project drive so generated OOC paths stay below the
# Windows path-length limit on the remote Vivado 2025.2 build host.
Set-Location -LiteralPath $driveProjectRoot
$projectName = if ([string]::IsNullOrWhiteSpace($ProjectDirectoryLeaf)) {
    "FPGAtten_2025_2_z19p_core${CoreMHz}_dma300_$Revision"
}
else {
    $ProjectDirectoryLeaf
}
$outputName = "FPGAtten_2025_2_${CoreMHz}MHz_core_300MHz_$Revision"
$logStem = "fpgatten_core${CoreMHz}_$Revision"
$projectDirectory = Join-Path $driveProjectRoot (
    "vivado\project\$projectName")
$projectFile = Join-Path $projectDirectory "FPGAtten_z19p.xpr"
if (-not [string]::IsNullOrWhiteSpace($ProjectDriveLetter)) {
    if ($ProjectDriveLetter -eq $DriveLetter) {
        throw "ProjectDriveLetter must differ from DriveLetter ($DriveLetter)"
    }
    $projectDrive = "${ProjectDriveLetter}:"
    $projectMapping = (& $substExe) |
        Where-Object { $_ -match ("^{0}:\\" -f $ProjectDriveLetter) }
    if ($projectMapping) {
        if ($projectMapping -notmatch [regex]::Escape($projectDirectory)) {
            throw "$projectDrive is already mapped elsewhere: $projectMapping"
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
            throw "Cannot map missing project directory: $projectDirectory"
        }
        & $substExe $projectDrive $projectDirectory | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to map project directory to $projectDrive"
        }
    }
    $projectFile = Join-Path $projectDrive "FPGAtten_z19p.xpr"
}
if (-not [string]::IsNullOrWhiteSpace($ProjectFileOverride)) {
    $projectFile = [IO.Path]::GetFullPath($ProjectFileOverride)
}
$outputDirectory = Join-Path $driveProjectRoot (
    "vivado\output\$outputName")
$createLog = Join-Path $driveProjectRoot "vivado\${logStem}_project_create.log"
$createJournal = Join-Path $driveProjectRoot "vivado\${logStem}_project_create.jou"
$vivadoLog = Join-Path $driveProjectRoot "vivado\${logStem}.log"
$vivadoJournal = Join-Path $driveProjectRoot "vivado\${logStem}.jou"
$createScript = Join-Path $driveProjectRoot (
    "vivado\board\scripts\create_z19p_project.tcl")
$buildScript = Join-Path $driveProjectRoot (
    "vivado\board\scripts\build_z19p_xsa.tcl")

if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    if (Test-Path -LiteralPath $projectDirectory) {
        throw (
            "Refusing to overwrite an incomplete FPGAtten project directory: " +
            $projectDirectory)
    }
    Write-Host "Creating fresh FPGAtten core-$CoreMHz MHz / DMA-300 MHz project ($Revision)"
    & $VivadoBat -mode batch -notrace -log $createLog -journal $createJournal `
        -source $createScript -tclargs $projectDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado project creation failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Vivado returned success but did not create FPGAtten project: $projectFile"
    }
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite FPGAtten output: $outputDirectory"
}

Remove-Item -LiteralPath "Env:\GQAV7_Z19P_REUSE_SYNTHESIS" `
    -ErrorAction SilentlyContinue
if ($ReuseAccelerator) {
    $env:GQAV7_Z19P_REUSE_ACCELERATOR = "YES"
}
else {
    Remove-Item -LiteralPath "Env:\GQAV7_Z19P_REUSE_ACCELERATOR" `
        -ErrorAction SilentlyContinue
}
$env:GQAV7_Z19P_PROJECT_FILE = $projectFile
$env:GQAV7_Z19P_OUTPUT_DIR = $outputDirectory
$env:GQAV7_CORE_FREQUENCY_MHZ = [string]$CoreMHz
$env:GQAV7_DMA_FREQUENCY_MHZ = "300"
$env:GQAV7_Z19P_ACCELERATOR_SYNTH_STRATEGY = "Flow_PerfOptimized_high"
$env:GQAV7_Z19P_IMPL_STRATEGY = "Performance_ExplorePostRoutePhysOpt"
if ($DisablePostRoutePhysOpt) {
    $env:GQAV7_Z19P_DISABLE_POST_ROUTE_PHYS_OPT = "YES"
}
else {
    Remove-Item -LiteralPath "Env:\GQAV7_Z19P_DISABLE_POST_ROUTE_PHYS_OPT" `
        -ErrorAction SilentlyContinue
}
if ($HeadlessRunner) {
    $env:GQAV7_Z19P_HEADLESS_RUNNER = "YES"
}
else {
    Remove-Item -LiteralPath "Env:\GQAV7_Z19P_HEADLESS_RUNNER" -ErrorAction SilentlyContinue
}
$env:GQAV7_HOST_PROJECT_ROOT = $ProjectRoot
$env:VIVADO_JOBS = [string]$Jobs
$desktopLicense = Join-Path $env:USERPROFILE "Desktop\license\License.lic"
$appDataLicense = Join-Path $env:APPDATA `
    "XilinxLicense\xilinx_ise_vivado.lic"
$licenseFile = @($desktopLicense, $appDataLicense) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not [string]::IsNullOrWhiteSpace($licenseFile)) {
    $env:XILINXD_LICENSE_FILE = $licenseFile
    $env:XILINX_LICENSE_FILE = $licenseFile
}

Write-Host "Vivado:  $vivadoVersionLine"
Write-Host "FPGAtten 2025.2 build revision=$Revision core=$CoreMHz MHz dma=300 MHz jobs=$Jobs headless=$HeadlessRunner disablePostRoutePhysOpt=$DisablePostRoutePhysOpt"
Write-Host "Project: $projectFile"
Write-Host "Output:  $outputDirectory"
& $VivadoBat -mode batch -notrace -log $vivadoLog -journal $vivadoJournal `
    -source $buildScript
if ($LASTEXITCODE -ne 0) {
    throw "FPGAtten Vivado implementation failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath (Join-Path $outputDirectory "reports\physical_metrics.kv") -PathType Leaf)) {
    throw "Vivado returned success but omitted FPGAtten implementation metrics"
}
Write-Host "PASS: FPGAtten core-$CoreMHz/DMA-300 build completed ($Revision)"
