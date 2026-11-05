#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Project,
    [Parameter(Mandatory)] [ValidateSet('Win64', 'Android')] [string] $Platform,
    [string] $InfrastructureRoot,
    [string] $ReadinessSource
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()
$report = [ordered]@{
    schemaVersion = 1
    scope = 'SampleGame producer inputs (static inspection)'
    referenceRevision = '2d0654e54b78aeed17161747c6deedb9dce3d0b1'
    project = $null
    platform = $Platform
    luaVersion = $null
    runtimeValidated = $false
}

function Add-Check([string] $Name, [string] $Status, [string] $Detail) {
    $checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Read-TextFile([string] $Path, [int] $MaximumBytes) {
    $file = Get-Item -LiteralPath $Path
    if ($file -isnot [IO.FileInfo] -or $file.Length -lt 1 -or $file.Length -gt $MaximumBytes) {
        throw "Expected a regular, nonempty input no larger than $MaximumBytes bytes: $Path"
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($file.FullName))
}

function Test-FileInput([string] $Name, [string] $Path, [string] $Hint) {
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($file -is [IO.FileInfo] -and $file.Length -gt 0) {
        Add-Check $Name 'present' $Path
    } else {
        Add-Check $Name 'blocked' "Missing or empty $Path. $Hint"
    }
}

function Test-AndroidTrust([string] $Root) {
    try {
        $producer = Read-TextFile (Join-Path $Root 'Tools/Release/ReleaseSets/android_pipeline.py') (256KB)
        $pins = [regex]::Matches($producer, '(?m)^CERTIFICATE_SHA256[ \t]*=[ \t]*(["''])([a-f0-9]{64})\1[ \t]*\r?$')
        if ($pins.Count -ne 1 -or $pins[0].Groups[2].Value -ceq ('0' * 64)) {
            throw 'Configure one non-placeholder CERTIFICATE_SHA256 in the selected Android producer.'
        }
        $certPath = Join-Path $Root 'Tools/Release/NativeAndroid/release-certificate.der'
        $file = Get-Item -LiteralPath $certPath
        if ($file -isnot [IO.FileInfo] -or $file.Length -lt 1 -or $file.Length -gt 16KB) {
            throw 'Expected a public DER certificate up to 16 KiB at Tools/Release/NativeAndroid/release-certificate.der.'
        }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $actual = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        } finally {
            $algorithm.Dispose()
        }
        if ($actual -cne $pins[0].Groups[2].Value) {
            throw 'The public Android certificate digest differs from CERTIFICATE_SHA256.'
        }
        if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($bytes) -ne 'Cert') {
            throw 'Expected a public X.509 certificate in DER format.'
        }
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
        try {
            $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
            try {
                if (-not $rsa -or $rsa.KeySize -lt 2048 -or
                    [BitConverter]::ToString($cert.RawData) -cne [BitConverter]::ToString($bytes)) {
                    throw 'Expected a DER certificate with an RSA public key of at least 2048 bits.'
                }
            } finally {
                if ($rsa) { $rsa.Dispose() }
            }
        } finally {
            $cert.Dispose()
        }
        Add-Check 'androidCertificate' 'present' 'Public DER certificate matches the producer pin. Verify the actual APK signer during packaging.'
    } catch {
        Add-Check 'androidCertificate' 'blocked' $_.Exception.Message
    }
}

try {
    $descriptor = Get-Item -LiteralPath $Project
    if ($descriptor -isnot [IO.FileInfo] -or $descriptor.Extension -ine '.uproject') {
        throw 'Choose an existing .uproject descriptor.'
    }
    $report.project = $descriptor.FullName
    $projectRoot = $descriptor.Directory
    if (-not $projectRoot.Parent -or -not $projectRoot.Parent.Parent) {
        throw 'Place the project directory two levels inside the source checkout.'
    }
    $repository = $projectRoot.Parent.Parent.FullName
    $definition = Read-TextFile $descriptor.FullName (256KB) | ConvertFrom-Json -AsHashtable
    if ($definition -isnot [System.Collections.IDictionary] -or
        ($definition.FileVersion -isnot [long] -and $definition.FileVersion -isnot [int]) -or
        $definition.FileVersion -ne 3) {
        throw 'Expected an Unreal project descriptor with FileVersion 3.'
    }
    if ($descriptor.Name -ine 'SampleGame.uproject') {
        Add-Check 'projectIdentity' 'blocked' 'The reference producers expect SampleGame. Adapt producer, launcher, cooked paths and signing identity together for a different project.'
    } else {
        Add-Check 'projectIdentity' 'present' 'SampleGame.uproject parsed.'
    }

    Test-FileInput 'buildAdapter' (Join-Path $repository 'Tools/Build-Project.ps1') 'Supply the project-owned Build adapter.'
    Test-FileInput 'cookAdapter' (Join-Path $repository 'Tools/Package-Project.ps1') 'Supply the project-owned Cook and package adapter.'
    Test-FileInput 'nativeHashAdapter' (Join-Path $repository 'Tools/Release/Read-NativeSourceHash.ps1') 'Supply the project-owned native identity adapter.'

    try {
        $lua = Read-TextFile (Join-Path $projectRoot 'Content/Lua/game/release_status.lua') (64KB)
        $lines = @($lua -split '\r?\n' | Where-Object { $_ -cmatch '^\s*local\s+version\b' })
        $pattern = '^\s*local\s+version\s*=\s*(["''])((?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?)\1\s*$'
        if ($lines.Count -ne 1 -or $lines[0] -cnotmatch $pattern -or $Matches[2].Length -gt 96) {
            throw 'Declare one literal local version in Content/Lua/game/release_status.lua, such as 1.0.7+dev.1.'
        }
        $report.luaVersion = $Matches[2]
        Add-Check 'luaIdentity' 'present' 'Found a release identity in the expected source file.'
    } catch {
        Add-Check 'luaIdentity' 'blocked' $_.Exception.Message
    }

    if ($Platform -eq 'Android') {
        $plugin = 'SampleGameNativeUpdate'
        $entry = @($definition.Plugins | Where-Object { $_.Name -ceq $plugin })
        if ($entry.Count -ne 1 -or $entry[0].Enabled -isnot [bool] -or -not $entry[0].Enabled -or
            ($entry[0].PlatformAllowList -and 'Android' -notin $entry[0].PlatformAllowList) -or
            ('Android' -in $entry[0].PlatformDenyList) -or
            ($entry[0].SupportedTargetPlatforms -and 'Android' -notin $entry[0].SupportedTargetPlatforms) -or
            ($entry[0].TargetAllowList -and 'Game' -notin $entry[0].TargetAllowList) -or
            ('Game' -in $entry[0].TargetDenyList)) {
            Add-Check 'androidBootstrap' 'blocked' 'Enable the SampleGameNativeUpdate plugin for the Android game target in the .uproject.'
        } else {
            $pluginRoot = Join-Path $projectRoot "Plugins/$plugin"
            Test-FileInput 'androidBootstrap' (Join-Path $pluginRoot "$plugin.uplugin") 'Install the matching reference plugin source.'
            Test-FileInput 'androidUpl' (Join-Path $pluginRoot "Source/$plugin/Android/${plugin}_UPL.xml") 'Supply the reference Android packaging bridge.'
            Test-FileInput 'androidModuleRules' (Join-Path $pluginRoot "Source/$plugin/$plugin.Build.cs") 'Add the AndroidPlugin receipt property to the module rules.'
            Test-FileInput 'androidReleasePlayer' (Join-Path $pluginRoot "Source/$plugin/Android/Java/com/example/samplegame/update/ReleasePlayer.java") 'Install the matching Android release bootstrap.'
        }
        if ($InfrastructureRoot) {
            Test-AndroidTrust $InfrastructureRoot
        } else {
            Add-Check 'androidCertificate' 'blocked' 'Pass the configured producer checkout with -InfrastructureRoot to inspect its public Android signer pin.'
        }
    }

    $healthContract = if ($Platform -eq 'Android') { 'JNI acknowledge after real readiness' } else { 'atomic health.json after real readiness' }
    if ($ReadinessSource) {
        try {
            $adapterPath = if ([IO.Path]::IsPathFullyQualified($ReadinessSource)) {
                $ReadinessSource
            } else {
                Join-Path $projectRoot $ReadinessSource
            }
            $adapter = Read-TextFile $adapterPath (1MB)
            $marker = if ($Platform -eq 'Android') { '\backnowledge\b' } else { '\b(?:health\.json|ackPath)\b' }
            if ($adapter -cmatch '\bSampleGameReleaseTicket\b' -and $adapter -cmatch $marker) {
                Add-Check 'gameReadiness' 'review' "Found source clues for $healthContract. Verify the call path and run a real packaged boot and rollback."
            } else {
                Add-Check 'gameReadiness' 'review' "The selected source lacks the expected ticket and health markers. Follow the call path for $healthContract."
            }
        } catch {
            Add-Check 'gameReadiness' 'blocked' $_.Exception.Message
        }
    } else {
        Add-Check 'gameReadiness' 'review' "Inspect the game adapter for $healthContract. Pass -ReadinessSource to check one source file for reference markers."
    }
} catch {
    Add-Check 'projectDescriptor' 'blocked' $_.Exception.Message
}

$blocked = @($checks | Where-Object status -eq 'blocked').Count -gt 0
$report.status = if ($blocked) { 'blocked' } else { 'static-inputs-present' }
$report.checks = $checks.ToArray()
$report | ConvertTo-Json -Depth 5
if ($blocked) { exit 1 }
exit 0
