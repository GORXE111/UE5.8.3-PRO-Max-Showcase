#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Inspect')]
param(
    [Parameter(Mandatory)] [string] $EngineRoot,
    [Parameter(Mandatory, ParameterSetName = 'Demo')] [switch] $LocalDemo,
    [Parameter(Mandatory, ParameterSetName = 'Demo')] [string] $InfrastructureRoot,
    [Parameter(Mandatory, ParameterSetName = 'Demo')] [string] $ProjectOutput,
    [Parameter(ParameterSetName = 'Demo')] [string] $PythonExecutable = 'python'
)

$ErrorActionPreference = 'Stop'
$expectedRevision = '2d0654e54b78aeed17161747c6deedb9dce3d0b1'
$report = [ordered]@{
    schemaVersion = 1
    status = 'checking'
    engine = $null
    infrastructureRevision = $null
    demo = $null
    generatedProject = $null
    nextAction = $null
    error = $null
}

function Get-LocalPath([string] $Path) {
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') {
        throw 'Choose a local filesystem path.'
    }
    return $resolved
}

try {
    if (-not $IsWindows) {
        throw 'This onboarding entry supports Windows UE checkouts and installations.'
    }
    $root = Get-LocalPath $EngineRoot
    $versionPath = Join-Path $root 'Engine/Build/Build.version'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw 'EngineRoot must point to a UE 5.8.3 root containing Engine/Build/Build.version.'
    }
    $version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json -AsHashtable
    $versionLabel = "$($version.MajorVersion).$($version.MinorVersion).$($version.PatchVersion)"
    if ($versionLabel -cne '5.8.3') {
        throw "The current adoption recipe targets UE 5.8.3. Found $versionLabel."
    }
    $runner = Join-Path $PSHOME 'pwsh.exe'
    $editor = Join-Path $root 'Engine/Binaries/Win64/UnrealEditor.exe'
    if (Test-Path -LiteralPath (Join-Path $root 'Engine/Build/InstalledBuild.txt') -PathType Leaf) {
        $readiness = Join-Path $PSScriptRoot '../Tools/Test-ProMaxReadiness.ps1'
        $raw = & $runner -NoProfile -File $readiness -EngineRoot $root -Json
        $readinessExit = $LASTEXITCODE
        $report.engine = [ordered]@{
            kind = 'installed'
            version = $versionLabel
            readiness = ($raw | Out-String | ConvertFrom-Json -AsHashtable)
        }
        if ($readinessExit -ne 0) {
            throw 'Installed engine file inspection failed. See engine.readiness.checks.'
        }
        $report.nextAction = 'Validate the C++ toolchain and compile a blank project with this editor.'
    } else {
        foreach ($relative in @('Setup.bat', 'GenerateProjectFiles.bat', 'Engine/Build/BatchFiles/Build.bat')) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) {
                throw "Expected a complete Epic source checkout. Missing $relative."
            }
        }
        $editorPresent = Test-Path -LiteralPath $editor -PathType Leaf
        $report.engine = [ordered]@{ kind = 'source'; version = $versionLabel; editorFilePresent = $editorPresent }
        $report.nextAction = if ($editorPresent) {
            'Verify the source build identity and run a clean editor/project build.'
        } else {
            'Follow the Epic source setup and Development Editor Win64 build steps in the adoption guide.'
        }
    }

    if ($LocalDemo) {
        $infrastructure = Get-LocalPath $InfrastructureRoot
        $output = Get-LocalPath $ProjectOutput
        if (Test-Path -LiteralPath $output) {
            throw 'Choose a project output path that does not exist yet.'
        }
        if (-not (Test-Path -LiteralPath $infrastructure -PathType Container)) {
            throw 'Clone the pinned infrastructure repository first. See the adoption guide.'
        }
        $revision = & git -C $infrastructure rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or $revision -cne $expectedRevision) {
            throw "Check out the reviewed infrastructure revision $expectedRevision before running the demo."
        }
        $changes = & git -C $infrastructure status --porcelain --untracked-files=all --ignored -- Tools/Scaffold Tools/Release/ReleaseSets
        if ($LASTEXITCODE -ne 0 -or $changes) {
            throw 'Use a clean infrastructure checkout. Changes or local files were found in the demo inputs.'
        }
        $report.infrastructureRevision = $revision
        $python = (Get-Command -Name $PythonExecutable -CommandType Application | Select-Object -First 1).Source
        $demoPath = Join-Path $infrastructure 'Tools/Release/ReleaseSets/demo_transaction.py'
        $demoJson = & $python -B $demoPath
        if ($LASTEXITCODE -ne 0) {
            throw 'The offline transaction demo failed. Check Python 3.11+, cryptography and the process output.'
        }
        $report.demo = $demoJson | Out-String | ConvertFrom-Json -AsHashtable
        if ($report.demo.status -cne 'passed' -or -not $report.demo.fixturePayloads -or $report.demo.networkUsed) {
            throw 'The demo result did not identify a successful offline fixture run.'
        }
        $scaffold = Join-Path $infrastructure 'Tools/Scaffold/New-UEProject.ps1'
        & $runner -NoProfile -File $scaffold -ProjectName SampleGame -OutputDirectory $output | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Project scaffolding failed. Check the destination path and disk permissions.'
        }
        $project = Join-Path $output 'SampleGame.uproject'
        if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
            throw 'The scaffold did not produce SampleGame.uproject.'
        }
        $report.generatedProject = $project
        $report.status = 'local-demo-passed'
    } else {
        $report.status = 'engine-files-inspected'
    }
} catch {
    $report.status = 'blocked'
    $report.error = $_.Exception.Message
}

$report | ConvertTo-Json -Depth 12
if ($report.status -eq 'blocked') { exit 1 }
exit 0
