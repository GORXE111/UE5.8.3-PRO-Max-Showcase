#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EngineRoot,
    [string] $Project,
    [string[]] $PluginRoot,
    [switch] $CheckCpp,
    [string] $ClangRoot,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check($Name, $Status, $Detail) {
    $checks.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
}

function Resolve-LocalPath([string] $Path) {
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') {
        throw 'Choose a local file-system path.'
    }
    return $resolved
}

function Read-JsonObject([string] $Path) {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($document -isnot [System.Collections.IDictionary]) {
        throw 'Expected a JSON object.'
    }
    return $document
}

function Read-EditorBuildId([string] $Path) {
    $value = (Read-JsonObject $Path)['BuildId']
    if ($value -isnot [string] -or $value -cnotmatch '^[A-Za-z0-9._-]{1,128}$') {
        throw 'Missing or invalid BuildId in the editor module receipt.'
    }
    return $value
}

function Add-PathCheck([string] $Name, [string] $Path) {
    if ($Path -match '[^\u0020-\u007e]') {
        Add-Check $Name 'warning' 'This path contains non-ASCII characters. Use a short ASCII path if UBT, UAT or Android tools fail to resolve it.'
    } elseif ($Path.Length -ge 240) {
        Add-Check $Name 'warning' 'This path approaches legacy Windows path limits before deeper build paths are added.'
    }
}

function Add-DriveSpace([string] $Name, [string] $Path) {
    try {
        $driveInfo = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
        $freeGiB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1)
        Add-Check $Name 'info' "$freeGiB GiB free on this volume. Include build outputs and caches in your disk estimate."
    } catch {
        Add-Check $Name 'warning' 'Free space could not be measured for this path.'
    }
}

function Test-EditorModuleReceipt([string] $Name, [string] $Receipt, [string] $EditorId, [bool] $HasCode) {
    if (-not (Test-Path -LiteralPath $Receipt -PathType Leaf)) {
        if ($HasCode) {
            Add-Check $Name 'warning' 'Code modules have no Win64 editor receipt. Build them for the selected editor.'
        }
        return
    }
    try {
        $moduleId = Read-EditorBuildId $Receipt
        if ($EditorId -and $moduleId -cne $EditorId) {
            throw "Module BuildId $moduleId differs from editor BuildId $EditorId. Rebuild these modules for the selected engine."
        }
        if ($EditorId) {
            Add-Check $Name 'pass' 'Editor module BuildId matches.'
        }
    } catch {
        Add-Check $Name 'fail' $_.Exception.Message
    }
}

function Find-MsvcVersions {
    $vswhere = if (${env:ProgramFiles(x86)}) {
        Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    }
    $locations = @()
    if ($vswhere -and (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        $installations = @(& $vswhere -products '*' -property installationPath)
        if ($LASTEXITCODE -eq 0) {
            $locations += $installations | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'VC/Tools/MSVC' }
        }
    }
    if ($env:VCToolsInstallDir) {
        $locations += [IO.Path]::GetDirectoryName([IO.Path]::TrimEndingDirectorySeparator($env:VCToolsInstallDir))
    }
    foreach ($location in ($locations | Sort-Object -Unique)) {
        if (-not $location -or -not (Test-Path -LiteralPath $location -PathType Container)) { continue }
        foreach ($toolset in (Get-ChildItem -LiteralPath $location -Directory)) {
            if ($toolset.Name -as [version] -and
                (Test-Path -LiteralPath (Join-Path $toolset.FullName 'bin/Hostx64/x64/cl.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $toolset.FullName 'lib/x64/libcmt.lib') -PathType Leaf)) {
                [version] $toolset.Name
            }
        }
    }
}

function Find-WindowsSdkVersions {
    $roots = @($env:WindowsSdkDir)
    if (${env:ProgramFiles(x86)}) {
        $roots += Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
    }
    foreach ($key in @('HKLM:/SOFTWARE/Microsoft/Windows Kits/Installed Roots',
                       'HKLM:/SOFTWARE/WOW6432Node/Microsoft/Windows Kits/Installed Roots')) {
        $roots += Get-ItemPropertyValue -LiteralPath $key -Name KitsRoot10 -ErrorAction SilentlyContinue
    }
    foreach ($root in ($roots | Where-Object { $_ } | Sort-Object -Unique)) {
        $include = Join-Path $root 'Include'
        if (-not (Test-Path -LiteralPath $include -PathType Container)) { continue }
        foreach ($version in (Get-ChildItem -LiteralPath $include -Directory)) {
            if (($version.Name -as [version]) -and
                (Test-Path -LiteralPath (Join-Path $version.FullName 'um/Windows.h') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $root "Lib/$($version.Name)/um/x64/kernel32.lib") -PathType Leaf)) {
                [version] $version.Name
            }
        }
    }
}

$root = $null
$projectPath = $null
$pluginPaths = [System.Collections.Generic.List[string]]::new()
$engineVersion = $null
$editorBuildId = $null
$package = $null
try {
    $root = Resolve-LocalPath $EngineRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'The supplied engine directory does not exist.'
    }
    Add-Check 'engineRoot' 'pass' 'Found the selected engine directory.'
    Add-PathCheck 'enginePath' $root
    Add-DriveSpace 'engineDisk' $root
} catch {
    $root = $null
    Add-Check 'engineRoot' 'fail' $_.Exception.Message
}

if ($root) {
    $requiredFiles = [ordered]@{
        installedMarker = 'Engine/Build/InstalledBuild.txt'
        editor = 'Engine/Binaries/Win64/UnrealEditor.exe'
    }
    foreach ($file in $requiredFiles.GetEnumerator()) {
        if (Test-Path -LiteralPath (Join-Path $root $file.Value) -PathType Leaf) {
            Add-Check $file.Key 'pass' "Found $($file.Value)."
        } else {
            Add-Check $file.Key 'fail' "Missing $($file.Value). Point to the root of a complete Win64 Installed Build."
        }
    }
    try {
        $version = Read-JsonObject (Join-Path $root 'Engine/Build/Build.version')
        foreach ($key in @('MajorVersion', 'MinorVersion', 'PatchVersion', 'Changelist')) {
            if ($version[$key] -isnot [long] -and $version[$key] -isnot [int]) {
                throw "Missing or invalid $key in Build.version."
            }
        }
        $engineVersion = "$($version.MajorVersion).$($version.MinorVersion).$($version.PatchVersion)"
        if ($engineVersion -cne '5.8.3') {
            throw "Expected Unreal Engine 5.8.3, found $engineVersion. Select a matching build."
        }
        Add-Check 'engineVersion' 'pass' "Unreal Engine $engineVersion, changelist $($version.Changelist)."
    } catch {
        Add-Check 'engineVersion' 'fail' $_.Exception.Message
    }
    try {
        $editorBuildId = Read-EditorBuildId (Join-Path $root 'Engine/Binaries/Win64/UnrealEditor.modules')
        Add-Check 'editorBuildId' 'pass' "Editor module BuildId is $editorBuildId. Match this exact value when using precompiled plugin binaries."
    } catch {
        Add-Check 'editorBuildId' 'fail' $_.Exception.Message
    }
    $packagePath = Join-Path $root 'PRO_MAX_PACKAGE.json'
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        try {
            $package = Read-JsonObject $packagePath
            if ($package.buildId -isnot [string] -or $package.buildId -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
                $package.acceptanceStatus -isnot [string] -or $package.acceptanceStatus -cnotmatch '^[a-z_ /-]{1,80}$') {
                throw 'Invalid package label or acceptance state.'
            }
            Add-Check 'packageIdentity' 'pass' "Package label: $($package.buildId). Recorded acceptance: $($package.acceptanceStatus)."
        } catch {
            $package = $null
            Add-Check 'packageIdentity' 'warning' 'The optional PRO_MAX_PACKAGE.json could not be read. Package provenance needs manual verification.'
        }
    }
}

if ($Project) {
    try {
        $projectPath = Resolve-LocalPath $Project
        if ([IO.Path]::GetExtension($projectPath) -ne '.uproject' -or
            -not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
            throw 'Choose an existing .uproject file.'
        }
        $descriptor = Read-JsonObject $projectPath
        if (($descriptor.FileVersion -isnot [long] -and $descriptor.FileVersion -isnot [int]) -or $descriptor.FileVersion -lt 1) {
            throw 'Missing or invalid FileVersion in the project descriptor.'
        }
        Add-Check 'project' 'pass' 'Project descriptor parsed.'
        Add-PathCheck 'projectPath' $projectPath
        Add-DriveSpace 'projectDisk' $projectPath
        if ($descriptor.EngineAssociation) {
            Add-Check 'engineAssociation' 'warning' 'The project specifies an engine association. Open it with the selected editor explicitly if the association resolves to another engine.'
        }
        $projectRoot = [IO.Path]::GetDirectoryName($projectPath)
        $projectReceipt = Join-Path $projectRoot 'Binaries/Win64/UnrealEditor.modules'
        Test-EditorModuleReceipt 'projectBuildId' $projectReceipt $editorBuildId ([bool] $descriptor.Modules)
    } catch {
        Add-Check 'project' 'fail' $_.Exception.Message
    }
}

foreach ($plugin in $PluginRoot) {
    try {
        $pluginPath = Resolve-LocalPath $plugin
        if (-not (Test-Path -LiteralPath $pluginPath -PathType Container)) {
            throw 'The supplied plugin directory does not exist.'
        }
        $descriptors = @(Get-ChildItem -LiteralPath $pluginPath -Filter '*.uplugin' -File)
        if ($descriptors.Count -ne 1) {
            throw 'Choose a plugin directory containing exactly one .uplugin file.'
        }
        $descriptor = Read-JsonObject $descriptors[0].FullName
        if (($descriptor.FileVersion -isnot [long] -and $descriptor.FileVersion -isnot [int]) -or
            $descriptor.FileVersion -lt 1) {
            throw 'Missing or invalid FileVersion in the plugin descriptor.'
        }
        $pluginPaths.Add($pluginPath)
        Add-Check "plugin/$($descriptors[0].BaseName)" 'pass' 'Plugin descriptor parsed.'
        $receipt = Join-Path $pluginPath 'Binaries/Win64/UnrealEditor.modules'
        Test-EditorModuleReceipt "pluginBuildId/$($descriptors[0].BaseName)" $receipt $editorBuildId ([bool] $descriptor.Modules)
    } catch {
        Add-Check 'plugin' 'fail' $_.Exception.Message
    }
}

if ($CheckCpp -and $root) {
    $core = Join-Path $root 'Engine/Intermediate/Build/Win64/x64/UnrealEditor/Development/Core/UnrealEditor-Core.lib'
    if (Test-Path -LiteralPath $core -PathType Leaf) {
        Add-Check 'editorImportLibrary' 'pass' 'Found UnrealEditor-Core.lib for the Win64 editor target.'
        Add-PathCheck 'editorImportLibraryPath' $core
    } else {
        Add-Check 'editorImportLibrary' 'fail' 'The expected UnrealEditor-Core.lib is absent. Check the Installed Build includes Win64 editor import libraries.'
    }
    if (-not $IsWindows) {
        Add-Check 'win64Toolchain' 'fail' 'Win64 compiler discovery is supported on Windows.'
    } else {
        $msvc = @(Find-MsvcVersions | Sort-Object -Unique)
        if ($msvc.Count -eq 0) {
            Add-Check 'msvc' 'fail' 'No Visual Studio x64 compiler and libraries were found. Install the C++ workload for the selected UE distribution.'
        } elseif ($editorBuildId -eq '55116800' -and $version.Changelist -eq 58210709 -and
                  -not @($msvc | Where-Object { $_.Major -eq 14 -and $_.Minor -eq 44 })) {
            Add-Check 'msvc' 'fail' "Found $($msvc -join ', '). The inspected stock 5.8.3 build uses MSVC 14.44; install a matching toolset and verify with UBT."
        } else {
            Add-Check 'msvc' 'pass' "Found x64 MSVC toolsets $($msvc -join ', '). UBT selects the compatible toolset."
        }
        $sdk = @(Find-WindowsSdkVersions | Sort-Object -Unique)
        if ($sdk.Count) {
            Add-Check 'windowsSdk' 'pass' "Found Windows SDK x64 headers and libraries $($sdk -join ', ')."
        } else {
            Add-Check 'windowsSdk' 'fail' 'No Windows 10/11 SDK with x64 headers and libraries was found.'
        }
        if ($package -and $package.product -eq 'UE 5.8.3 PRO Max') {
            $clang = $null
            try {
                $llvm = if ($ClangRoot) { Resolve-LocalPath $ClangRoot } else { $env:LLVM_PATH }
                if ($llvm) {
                    $clang = Join-Path $llvm 'bin/clang-cl.exe'
                } else {
                    $clang = (Get-Command clang-cl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                }
                if (-not $clang -or -not (Test-Path -LiteralPath $clang -PathType Leaf)) {
                    throw 'clang-cl.exe was not found. Set LLVM_PATH or pass -ClangRoot for the verified custom toolchain.'
                }
                $clangVersion = (Get-Item -LiteralPath $clang).VersionInfo.ProductVersion
                if ($clangVersion -eq '20.1.8') {
                    Add-Check 'clang' 'pass' 'Found Clang 20.1.8, the tested custom-build compiler.'
                } else {
                    Add-Check 'clang' 'warning' "Found Clang version '$clangVersion'. The recorded custom-build compiler is 20.1.8."
                }
            } catch {
                Add-Check 'clang' 'fail' $_.Exception.Message
            }
        }
    }
}

$blocked = @($checks | Where-Object status -eq 'fail').Count -gt 0
$report = [pscustomobject]@{
    schemaVersion = 1
    status = if ($blocked) { 'blocked' } else { 'ready-for-next-check' }
    engineRoot = $root
    engineVersion = $engineVersion
    editorBuildId = $editorBuildId
    project = $projectPath
    pluginRoots = $pluginPaths.ToArray()
    checks = $checks.ToArray()
}
if ($Json) {
    $report | ConvertTo-Json -Depth 5
} else {
    foreach ($check in $checks) {
        Write-Output ('[{0}] {1} - {2}' -f $check.status.ToUpperInvariant(), $check.name, $check.detail)
    }
    Write-Output "Result $($report.status). This was a local file and toolchain inspection."
}
if ($blocked) { exit 1 }
exit 0
