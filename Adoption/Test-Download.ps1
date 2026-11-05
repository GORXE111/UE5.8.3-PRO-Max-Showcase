#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Url,
    [Parameter(Mandatory)] [long] $ExpectedSize,
    [Parameter(Mandatory)] [string] $ExpectedSha256,
    [switch] $RequireImmutable,
    [int] $TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()
$report = [ordered]@{
    schemaVersion = 1
    status = 'checking'
    phase = 'input'
    url = $null
    expectedSize = $ExpectedSize
    expectedSha256 = $null
    requireImmutable = [bool] $RequireImmutable
    head = $null
    range = $null
    full = $null
    error = $null
    elapsedMilliseconds = $null
}
$client = $null
$deadline = $null

function Send-ArtifactRequest([Net.Http.HttpMethod] $Method, [uri] $Uri, [long] $RangeEnd = -1) {
    $request = [Net.Http.HttpRequestMessage]::new($Method, $Uri)
    try {
        if ($RangeEnd -ge 0) {
            $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new(0, $RangeEnd)
        }
        return $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $deadline.Token).GetAwaiter().GetResult()
    } finally {
        $request.Dispose()
    }
}

function Get-VerifiedHeaders([Net.Http.HttpResponseMessage] $Response, [int] $Status, [long] $Length) {
    $code = [int] $Response.StatusCode
    if ($code -ne $Status) {
        throw "Expected HTTP $Status, received $code. Redirects are disabled."
    }
    $headers = $Response.Content.Headers
    if ($null -eq $headers.ContentLength -or $headers.ContentLength -ne $Length) {
        throw "Expected Content-Length $Length, received '$($headers.ContentLength)'."
    }
    foreach ($encoding in $headers.ContentEncoding) {
        if ($encoding -ne 'identity') {
            throw "Expected identity encoding, received '$encoding'."
        }
    }
    $cache = $Response.Headers.CacheControl
    $immutable = $false
    if ($cache) {
        $immutable = -not ($cache.NoCache -or $cache.NoStore) -and
            [bool] ($cache.Extensions | Where-Object Name -eq 'immutable')
    }
    if ($RequireImmutable -and -not $immutable) {
        throw 'Expected Cache-Control immutable without no-cache or no-store.'
    }
    return [ordered]@{
        statusCode = $code
        contentLength = $headers.ContentLength
        cacheControl = [string] $cache
        immutable = $immutable
    }
}

function Read-ExactBytes([IO.Stream] $Stream, [byte[]] $Buffer) {
    $offset = 0
    while ($offset -lt $Buffer.Length) {
        $read = $Stream.ReadAsync($Buffer, $offset, $Buffer.Length - $offset,
            $deadline.Token).GetAwaiter().GetResult()
        if ($read -eq 0) {
            throw 'Response body ended before the expected prefix was received.'
        }
        $offset += $read
    }
}

try {
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -ne 'https' -or
        -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Provide an absolute HTTPS artifact URL without credentials, query or fragment.'
    }
    if ($ExpectedSize -lt 1 -or $ExpectedSha256 -cnotmatch '^[0-9A-Fa-f]{64}\z') {
        throw 'Provide a positive expected size and a 64-digit SHA-256 from the release plan.'
    }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 86400) {
        throw 'TimeoutSeconds must be between 1 and 86400.'
    }
    $report.url = $uri.AbsoluteUri
    $report.expectedSha256 = $ExpectedSha256.ToLowerInvariant()

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

    $report.phase = 'head'
    $response = Send-ArtifactRequest ([Net.Http.HttpMethod]::Head) $uri
    try {
        $report.head = Get-VerifiedHeaders $response 200 $ExpectedSize
        if ($response.Content.Headers.ContentRange) {
            throw 'Unexpected Content-Range on HEAD.'
        }
    } finally {
        $response.Dispose()
    }

    $report.phase = 'range'
    $prefixSize = [int] [Math]::Min($ExpectedSize, 65536L)
    $prefixEnd = $prefixSize - 1
    $rangePrefix = [byte[]]::new($prefixSize)
    $response = Send-ArtifactRequest ([Net.Http.HttpMethod]::Get) $uri $prefixEnd
    try {
        $report.range = Get-VerifiedHeaders $response 206 $prefixSize
        $range = $response.Content.Headers.ContentRange
        if (-not $range -or $range.Unit -ne 'bytes' -or -not $range.HasRange -or -not $range.HasLength -or
            $range.From -ne 0 -or $range.To -ne $prefixEnd -or $range.Length -ne $ExpectedSize) {
            throw "Expected Content-Range bytes 0-$prefixEnd/$ExpectedSize."
        }
        $report.range.contentRange = [string] $range
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        Read-ExactBytes $stream $rangePrefix
        $extra = [byte[]]::new(1)
        if ($stream.ReadAsync($extra, 0, 1, $deadline.Token).GetAwaiter().GetResult() -ne 0) {
            throw 'Range response body contains more than the requested prefix.'
        }
    } finally {
        $response.Dispose()
    }

    $report.phase = 'full'
    $response = Send-ArtifactRequest ([Net.Http.HttpMethod]::Get) $uri
    try {
        $report.full = Get-VerifiedHeaders $response 200 $ExpectedSize
        if ($response.Content.Headers.ContentRange) {
            throw 'Unexpected Content-Range on full GET.'
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fullPrefix = [byte[]]::new($prefixSize)
        Read-ExactBytes $stream $fullPrefix
        if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($rangePrefix, $fullPrefix)) {
            throw 'Range bytes differ from the prefix of the full GET.'
        }
        $report.range.prefixMatchesFullGet = $true

        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $hash.AppendData($fullPrefix)
            $count = [long] $prefixSize
            $buffer = [byte[]]::new(262144)
            while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length,
                        $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
                if ($read -gt $ExpectedSize - $count) {
                    throw 'Full GET exceeded the expected artifact size.'
                }
                $count += $read
                $hash.AppendData($buffer, 0, $read)
            }
            $report.full.bytesRead = $count
            $report.full.sha256 = [BitConverter]::ToString($hash.GetHashAndReset()).Replace('-', '').ToLowerInvariant()
        } finally {
            $hash.Dispose()
        }
        if ($count -ne $ExpectedSize -or $report.full.sha256 -cne $report.expectedSha256) {
            throw 'Full GET size or SHA-256 differs from the release plan.'
        }
    } finally {
        $response.Dispose()
    }
    $report.phase = 'complete'
    $report.status = 'verified'
} catch {
    $report.status = 'blocked'
    $report.error = if ($deadline -and $deadline.IsCancellationRequested) {
        'The HTTPS probe exceeded the time limit.'
    } else {
        $_.Exception.Message
    }
} finally {
    if ($client) { $client.Dispose() }
    if ($deadline) { $deadline.Dispose() }
    $clock.Stop()
    $report.elapsedMilliseconds = $clock.ElapsedMilliseconds
}

$report | ConvertTo-Json -Depth 5
if ($report.status -eq 'blocked') { exit 1 }
exit 0
