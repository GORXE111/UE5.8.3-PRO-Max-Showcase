#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UpdatesUri,
    [Parameter(Mandatory)] [long] $ReleaseId,
    [Parameter(Mandatory)] [string] $ManifestPath,
    [Parameter(Mandatory)] [string] $SignaturePath,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$report = [ordered]@{
    schemaVersion = 1
    status = 'checking'
    phase = 'input'
    verificationScope = 'Feed byte equality against the prepared metadata and cache headers'
    signatureCryptographicallyVerified = $false
    packageFilesVerified = $false
    updatesUri = $null
    channel = $null
    releaseId = $ReleaseId
    manifestSha256 = $null
    signatureSha256 = $null
    responses = [ordered]@{}
    error = $null
}
$client = $null
$deadline = $null

function Read-ExpectedFile([string] $Path, [int] $Limit) {
    $provider = $null
    $drive = $null
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem' -or $fullPath.StartsWith('\\') -or
        [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath)).DriveType -eq 'Network') {
        throw 'Supply a metadata file on a local filesystem.'
    }
    $file = Get-Item -LiteralPath $fullPath -Force
    if ($file -isnot [IO.FileInfo] -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Expected a regular prepared metadata file.'
    }
    $stream = [IO.File]::OpenRead($fullPath)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt $Limit) {
            throw "Prepared metadata must be between 1 and $Limit bytes."
        }
        $bytes = [byte[]]::new([int] $stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw 'Prepared metadata changed while reading.' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw 'Prepared metadata changed while reading.' }
        return ,$bytes
    } finally {
        $stream.Dispose()
    }
}

function Get-Sha256([byte[]] $Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Test-ExpectedManifest([byte[]] $Bytes, [string] $Channel) {
    # The publisher supplied these exact bytes. Parse identity without re-encoding signed JSON.
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Expected a release manifest JSON object.'
        }
        $properties = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $root.EnumerateObject()) {
            if (-not $properties.Add($property.Name)) {
                throw 'Prepared manifest repeats a top-level field.'
            }
        }
        $id = 0L
        $element = $root.GetProperty('releaseId')
        if ($element.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
            -not $element.TryGetInt64([ref] $id) -or $id -ne $ReleaseId) {
            throw "Prepared manifest releaseId differs from expected release $ReleaseId."
        }
        if ($root.GetProperty('kind').GetString() -cne 'samplegame-release-set' -or
            $root.GetProperty('channel').GetString() -cne $Channel) {
            throw 'Prepared manifest kind or channel differs from the update endpoint.'
        }
    } finally {
        $document.Dispose()
    }
}

function Test-MetadataResponse([uri] $Uri, [byte[]] $Expected, [bool] $Versioned) {
    $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
        $deadline.Token).GetAwaiter().GetResult()
    try {
        if ([int] $response.StatusCode -ne 200) {
            throw "Expected HTTP 200, received $([int] $response.StatusCode). Redirects are disabled."
        }
        $headers = $response.Content.Headers
        if ($headers.ContentLength -ne $Expected.Length -or $headers.ContentRange) {
            throw "Expected the entire $($Expected.Length)-byte metadata file."
        }
        foreach ($encoding in $headers.ContentEncoding) {
            if ($encoding -ne 'identity') { throw "Expected identity encoding, received '$encoding'." }
        }
        $cache = $response.Headers.CacheControl
        $immutable = $cache -and [bool] ($cache.Extensions | Where-Object Name -eq 'immutable')
        if ($Versioned) {
            if (-not $immutable -or $cache.NoCache -or $cache.NoStore -or $cache.Private -or
                -not $cache.MaxAge -or $cache.MaxAge.TotalSeconds -le 0) {
                throw 'Expected immutable versioned caching with a positive max-age and no private or bypass directives.'
            }
        } elseif (-not $cache.NoStore -or $immutable) {
            throw 'Expected no-store caching for current release metadata.'
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $bytes = [byte[]]::new($Expected.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.ReadAsync($bytes, $offset, $bytes.Length - $offset,
                $deadline.Token).GetAwaiter().GetResult()
            if ($read -eq 0) { throw 'Response ended before the metadata file was complete.' }
            $offset += $read
        }
        $extra = [byte[]]::new(1)
        if ($stream.ReadAsync($extra, 0, 1, $deadline.Token).GetAwaiter().GetResult() -ne 0 -or
            -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($Expected, $bytes)) {
            throw 'Public metadata bytes differ from the prepared file.'
        }
        return [ordered]@{ statusCode = 200; size = $bytes.Length; cacheControl = [string] $cache }
    } finally {
        $response.Dispose()
    }
}

try {
    $uri = $null
    if (-not [uri]::TryCreate($UpdatesUri, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -cnotmatch '^/samplegame/([a-z][a-z0-9_-]{0,31})/updates/?\z') {
        throw 'Provide an HTTPS channel URI ending in /samplegame/<channel>/updates/ without credentials, a query or a fragment.'
    }
    $report.channel = $Matches[1]
    if ($ReleaseId -lt 1 -or $ReleaseId -gt 999999999 -or $TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 600) {
        throw 'ReleaseId must be 1 through 999999999 and TimeoutSeconds must be 1 through 600.'
    }
    $base = [uri] ($uri.AbsoluteUri.TrimEnd('/') + '/')
    $report.updatesUri = $base.AbsoluteUri
    $manifest = Read-ExpectedFile $ManifestPath 1MB
    $signature = Read-ExpectedFile $SignaturePath 4096
    Test-ExpectedManifest $manifest $report.channel
    $report.manifestSha256 = Get-Sha256 $manifest
    $report.signatureSha256 = Get-Sha256 $signature

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $handler.UseProxy = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $client.DefaultRequestHeaders.AcceptEncoding.ParseAdd('identity')
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('UE-Adoption-Probe/1.0')
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))

    $report.phase = 'currentManifest'
    $report.responses.currentManifest = Test-MetadataResponse ([uri]::new($base, 'manifest.json')) $manifest $false
    $report.phase = 'currentSignature'
    $report.responses.currentSignature = Test-MetadataResponse ([uri]::new($base, 'manifest.json.sig')) $signature $false
    $report.phase = 'versionedManifest'
    $report.responses.versionedManifest = Test-MetadataResponse ([uri]::new($base, "versions/$ReleaseId/manifest.json")) $manifest $true
    $report.phase = 'versionedSignature'
    $report.responses.versionedSignature = Test-MetadataResponse ([uri]::new($base, "versions/$ReleaseId/manifest.json.sig")) $signature $true
    $report.phase = 'complete'
    $report.status = 'verified'
} catch {
    $report.status = 'blocked'
    $report.error = if ($deadline -and $deadline.IsCancellationRequested) {
        'The feed probe exceeded the time limit.'
    } else {
        $_.Exception.Message
    }
} finally {
    if ($client) { $client.Dispose() }
    if ($deadline) { $deadline.Dispose() }
}

$report | ConvertTo-Json -Depth 5
if ($report.status -eq 'blocked') { exit 1 }
exit 0
