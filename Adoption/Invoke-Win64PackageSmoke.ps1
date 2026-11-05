#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EngineRoot,
    [Parameter(Mandatory)] [string] $InfrastructureRoot,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [string] $PythonExecutable = 'python',
    [string] $ClangRoot,
    [ValidateRange(1, 8)] [int] $MaxParallelActions = 2,
    [switch] $VerifySignedUpdate,
    [switch] $VerifyNativeAssetUpdate
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$report = [ordered]@{
    schemaVersion = 1
    status = 'running'
    phase = 'input'
    editorBuildId = $null
    infrastructureRevision = $null
    buildExitCode = $null
    uatExitCode = $null
    gameExitCode = $null
    worldReady = $false
    signedUpdateReport = $null
    outputDirectory = $null
    error = $null
}

function Get-LocalPath([string] $Path) {
    $provider = $null
    $drive = $null
    $result = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Choose a local filesystem path.' }
    return $result
}

function Build-Package([string] $Archive, [string] $Suffix, [int] $Release) {
    $cookOptions = @()
    if ($Release) {
        $report.phase = "author-asset-$Release"
        $env:UE_ADOPTION_FIXTURE_RELEASE = [string] $Release
        Set-Content -LiteralPath (Join-Path $sampleRoot 'Source/SampleGame/AdoptionFixtureVersion.h') `
            -Value "#define UE_ADOPTION_FIXTURE_RELEASE $Release" -Encoding ascii
        $assetLog = Join-Path $output "author-asset-$Release.log"
        & $editor $project -run=PythonScript "-script=$assetScript" -EnablePlugins=PythonScriptPlugin `
            -Unattended -NullRHI -NoSound -NoSplash -stdout -FullStdOutLogOutput *> $assetLog
        if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath $assetLog -SimpleMatch -Quiet `
                -Pattern "UE_ADOPTION_COOKED_ASSET_WRITTEN release=$Release asset=")) {
            throw "DataTable authoring failed. See author-asset-$Release.log."
        }
        if ($Release -gt 100) { $cookOptions += '-iterativecooking' }
    }

    $report.phase = "cook-and-package$Suffix"
    & $uat BuildCookRun "-project=$project" -noP4 -platform=Win64 -clientconfig=Development -build -skipbuildeditor `
        -cook "-map=$map" @cookOptions -stage -pak -package -archive "-archivedirectory=$Archive" -unattended -utf8output `
        ("-ubtargs=" + ($ubtOptions -join ' ')) *> (Join-Path $output "package$Suffix.log")
    $report.uatExitCode = $LASTEXITCODE
    if ($report.uatExitCode -ne 0) { throw "BuildCookRun failed. See package$Suffix.log." }
    return (Join-Path $Archive 'Windows')
}

$previousLlvm = $env:LLVM_PATH
$previousFixtureRelease = $env:UE_ADOPTION_FIXTURE_RELEASE
try {
    if (-not $IsWindows) { throw 'The package smoke needs a Windows host and a Win64 Installed Build.' }
    $engine = Get-LocalPath $EngineRoot
    $infrastructure = Get-LocalPath $InfrastructureRoot
    $output = Get-LocalPath $OutputDirectory
    if (Test-Path -LiteralPath $output) { throw 'Choose a new smoke output directory.' }
    if ($output -notmatch '^[ -~]+$') { throw 'Choose a short ASCII path for the package smoke.' }
    $runner = Join-Path $PSHOME 'pwsh.exe'
    $readinessArgs = @('-EngineRoot', $engine, '-CheckCpp', '-Json')
    $ubtOptions = @('-NoUBA', "-MaxParallelActions=$MaxParallelActions", '-NoDebugInfo', '-NoLinkerDebugInfo')
    if ($ClangRoot) {
        $env:LLVM_PATH = Get-LocalPath $ClangRoot
        $readinessArgs += @('-ClangRoot', $env:LLVM_PATH)
        $ubtOptions += '-Compiler=Clang'
    }
    $report.phase = 'engine'
    $engineCheck = & $runner -NoProfile -File (Join-Path $PSScriptRoot '../Tools/Test-ProMaxReadiness.ps1') @readinessArgs
    if ($LASTEXITCODE -ne 0) { throw 'Engine or compiler preflight failed. Run Test-ProMaxReadiness.ps1 -CheckCpp for details.' }
    $report.editorBuildId = ($engineCheck | ConvertFrom-Json).editorBuildId
    $build = Join-Path $engine 'Engine/Build/BatchFiles/Build.bat'
    $uat = Join-Path $engine 'Engine/Build/BatchFiles/RunUAT.bat'
    $editor = Join-Path $engine 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe'
    $map = '/Engine/Maps/Entry'
    foreach ($file in @($build, $uat, (Join-Path $engine 'Engine/Content/Maps/Entry.umap'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing Win64 package input $file" }
    }

    $report.phase = 'scaffold'
    $report.outputDirectory = (New-Item -Path $output -ItemType Directory).FullName
    $sampleRoot = Join-Path $output 'SampleGame'
    $adoption = & $runner -NoProfile -File (Join-Path $PSScriptRoot 'Start-UEAdoption.ps1') -EngineRoot $engine `
        -LocalDemo -InfrastructureRoot $infrastructure -ProjectOutput $sampleRoot `
        -PythonExecutable $PythonExecutable
    $adoptionExit = $LASTEXITCODE
    $local = $adoption | ConvertFrom-Json
    if ($adoptionExit -ne 0 -or $local.status -ne 'local-demo-passed') { throw "Scaffold or offline demo failed. $($local.error)" }
    $report.infrastructureRevision = $local.infrastructureRevision
    $project = $local.generatedProject
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Win64Smoke/SampleGame.cpp') -Destination (Join-Path $sampleRoot 'Source/SampleGame/SampleGame.cpp')
    if ($VerifyNativeAssetUpdate) {
        if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) { throw 'Native and asset verification requires UnrealEditor-Cmd.exe.' }
        $assetScript = Join-Path $output 'Write-AdoptionCookedAsset.py'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Win64Smoke/Write-AdoptionCookedAsset.py') -Destination $assetScript
    }
    $moduleRules = Join-Path $sampleRoot 'Source/SampleGame/SampleGame.Build.cs'
    $dependencies = '        PublicDependencyModuleNames.AddRange(new[] { "Core", "CoreUObject", "Engine" });'
    $rules = Get-Content -LiteralPath $moduleRules -Raw
    if (-not $rules.Contains($dependencies)) { throw 'Unexpected SampleGame module rules in the pinned scaffold.' }
    Set-Content -LiteralPath $moduleRules -NoNewline -Value ($rules.Replace($dependencies,
        "$dependencies`n        PrivateDependencyModuleNames.Add(`"Json`");"))
    $config = Join-Path $sampleRoot 'Config'
    [IO.Directory]::CreateDirectory($config) | Out-Null
    Set-Content -LiteralPath (Join-Path $config 'DefaultEngine.ini') -Value @"
[/Script/EngineSettings.GameMapsSettings]
GameDefaultMap=$($map).Entry
"@
    Set-Content -LiteralPath (Join-Path $config 'DefaultGame.ini') -Value @'
[/Script/UnrealEd.ProjectPackagingSettings]
UsePakFile=True
bUseIoStore=False
bUseZenStore=False
bGenerateChunks=False
'@
    if ($VerifyNativeAssetUpdate) {
        Add-Content -LiteralPath (Join-Path $config 'DefaultGame.ini') -Value '+DirectoriesToAlwaysCook=(Path="/Game/Release")'
    }

    $report.phase = 'editor-build'
    & $build SampleGameEditor Win64 Development "-Project=$project" @ubtOptions -NoHotReload *> (Join-Path $output 'editor-build.log')
    $report.buildExitCode = $LASTEXITCODE
    if ($report.buildExitCode -ne 0) { throw 'Editor module build failed. See editor-build.log.' }
    $modules = Get-Content -LiteralPath (Join-Path $sampleRoot 'Binaries/Win64/UnrealEditor.modules') -Raw | ConvertFrom-Json
    if ($modules.BuildId -cne $report.editorBuildId) { throw 'Editor and project module Build IDs differ.' }

    $baseRelease = 0
    if ($VerifyNativeAssetUpdate) { $baseRelease = 100 }
    $payload = Build-Package (Join-Path $output 'Archive') '' $baseRelease
    $game = Join-Path $payload 'SampleGame/Binaries/Win64/SampleGame.exe'
    $paks = @(Get-ChildItem -LiteralPath (Join-Path $payload 'SampleGame/Content/Paks') -File -Filter '*.pak')
    if (-not (Test-Path -LiteralPath $game -PathType Leaf) -or $paks.Count -eq 0) {
        throw 'Expected the archived Win64 game and at least one PAK.'
    }

    $report.phase = 'packaged-launch'
    $log = Join-Path $output 'packaged-game.log'
    $start = [Diagnostics.ProcessStartInfo]::new($game)
    $start.WorkingDirectory = $payload
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($arg in @('-AdoptionSmoke', '-NullRHI', '-Unattended', '-NoSound', "-abslog=$log")) {
        $start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(120000)) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            throw 'Packaged game did not exit within 120 seconds. See packaged-game.log.'
        }
        $report.gameExitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($report.gameExitCode -ne 0) { throw 'Packaged game exited with a failure. See packaged-game.log.' }
    $contents = Get-Content -LiteralPath $log -Raw
    if ($contents -notmatch '(?m)^.*LogTemp: Display: UE_ADOPTION_SMOKE_WORLD_READY /Engine/Maps/Entry\s*$' -or
        $contents -notmatch 'LogExit: Exiting\.') {
        throw 'Expected a ready game world and normal exit marker in packaged-game.log.'
    }
    $report.worldReady = $true
    $report.status = 'win64-package-smoke-passed'
    if ($VerifySignedUpdate -or $VerifyNativeAssetUpdate) {
        $variantArgs = @()
        if ($VerifyNativeAssetUpdate) {
            foreach ($release in @(101, 102)) {
                $candidate = Build-Package (Join-Path $output "Archive-$release") "-$release" $release
                $variantArgs += @('--candidate-archive', "$release=$candidate")
            }
        }
        $report.phase = 'signed-update'
        $python = (Get-Command -Name $PythonExecutable -CommandType Application | Select-Object -First 1).Source
        $updateOutput = Join-Path $output 'SignedUpdate'
        $updateLog = Join-Path $output 'signed-update.log'
        & $python -X utf8 -B (Join-Path $PSScriptRoot 'Win64Smoke/verify_update.py') `
            --archive $payload --infrastructure $infrastructure --output $updateOutput @variantArgs *> $updateLog
        if ($LASTEXITCODE -ne 0) { throw 'Signed update verification failed. See signed-update.log.' }
        $report.signedUpdateReport = Join-Path $updateOutput 'report.json'
        $signed = Get-Content -LiteralPath $report.signedUpdateReport -Raw | ConvertFrom-Json
        if ($signed.status -cne 'win64-signed-update-passed' -or
            ($VerifyNativeAssetUpdate -and $signed.sameExeAndPaksAcrossReleases -ne $false)) {
            throw 'Signed update verification did not report success.'
        }
        $report.status = 'win64-signed-update-passed'
    }
    $report.phase = 'complete'
} catch {
    $report.status = 'blocked'
    $report.error = $_.Exception.Message
} finally {
    $env:LLVM_PATH = $previousLlvm
    $env:UE_ADOPTION_FIXTURE_RELEASE = $previousFixtureRelease
}

$report | ConvertTo-Json -Depth 5
if ($report.status -eq 'blocked') { exit 1 }
exit 0
