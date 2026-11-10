param(
    [int]$Port = 8080,
    [int]$DefaultPerPage = 24,
    [int]$CacheMinutes = 5
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'

$script:cache = @{}
$script:index = @{}   # post id -> bare mp4 url

# ---------------------------------------------------------------- upstream

function Invoke-Upstream {
    param([string]$Url)

    return Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60 -Headers @{
        'User-Agent' = $ua
        'Accept'     = 'application/json'
    }
}

function Get-HeaderValue {
    param($Response, [string]$Name)

    $v = $Response.Headers[$Name]
    if ($null -eq $v) { return $null }
    if ($v -is [array]) { $v = $v[0] }
    return [string]$v
}

function Get-CacheItem {
    param([string]$Key)

    if (-not $script:cache.ContainsKey($Key)) { return $null }
    $entry = $script:cache[$Key]
    if (((Get-Date) - $entry.at).TotalMinutes -ge $CacheMinutes) {
        $script:cache.Remove($Key)
        return $null
    }
    return $entry.data
}

function Set-CacheItem {
    param([string]$Key, $Data)

    $script:cache[$Key] = @{ at = (Get-Date); data = $Data }
}

function Get-PosterUrls {
    param($Post)

    $result = [pscustomobject]@{ thumb = $null; full = $null }
    try {
        $fm = @($Post._embedded.'wp:featuredmedia') | Select-Object -First 1
        if (-not $fm) { return $result }

        $sizes = $fm.media_details.sizes
        if ($sizes) {
            foreach ($name in @('videoclub_post_thumb', 'post-thumbnail', 'large', 'medium', 'full')) {
                $prop = $sizes.PSObject.Properties[$name]
                if ($prop -and $prop.Value.source_url) { $result.thumb = [string]$prop.Value.source_url; break }
            }
        }
        if ($fm.source_url) {
            $result.full = [string]$fm.source_url
            if (-not $result.thumb) { $result.thumb = [string]$fm.source_url }
        }
    }
    catch { }
    return $result
}

function Get-Mp4Url {
    param([string]$Html)

    if ([string]::IsNullOrEmpty($Html)) { return $null }
    $m = [regex]::Match($Html, '<source[^>]+src="([^"]+)"')
    if (-not $m.Success) { return $null }
    # WordPress appends ?_=N; the file host 302s that to the homepage. Keep the bare path.
    return ($m.Groups[1].Value -split '\?')[0]
}

function Get-CategoriesData {
    param([switch]$Force)

    if (-not $Force) {
        $hit = Get-CacheItem 'categories'
        if ($hit) { return $hit }
    }

    $resp = Invoke-Upstream 'https://darkero.com/wp-json/wp/v2/categories?per_page=100&_fields=id,name,slug,count,parent'
    # PS 5.1 emits a JSON array as one object; assign first, then re-wrap.
    $parsed = $resp.Content | ConvertFrom-Json
    $raw    = @($parsed)

    $cats = @(
        $raw |
            Where-Object { [int]$_.count -gt 0 } |
            Sort-Object { [int]$_.count } -Descending |
            ForEach-Object {
                [pscustomobject]@{
                    id      = [int]$_.id
                    name    = [string]$_.name
                    slug    = [string]$_.slug
                    count   = [int]$_.count
                    hasKids = $false
                }
            }
    )

    $statsResp = Invoke-Upstream 'https://darkero.com/wp-json/wp/v2/posts?per_page=1&_fields=id'
    $total     = 0
    [void][int]::TryParse((Get-HeaderValue $statsResp 'X-WP-Total'), [ref]$total)

    $data = [pscustomobject]@{
        totalVideos = $total
        categories  = $cats
    }
    Set-CacheItem 'categories' $data
    return $data
}

function Get-VideosData {
    param(
        [int]$Category = 0,
        [int]$Page = 1,
        [int]$PerPage = $DefaultPerPage,
        [string]$Search = '',
        [switch]$Force
    )

    if ($Page -lt 1) { $Page = 1 }
    if ($PerPage -lt 1) { $PerPage = $DefaultPerPage }
    if ($PerPage -gt 48) { $PerPage = 48 }

    $key = 'v|{0}|{1}|{2}|{3}' -f $Category, $Page, $PerPage, $Search.ToLowerInvariant()
    if (-not $Force) {
        $hit = Get-CacheItem $key
        if ($hit) { return $hit }
    }

    $url = 'https://darkero.com/wp-json/wp/v2/posts?per_page={0}&page={1}&orderby=date&order=desc' -f $PerPage, $Page
    $url += '&_embed=wp:featuredmedia&_fields=id,slug,date,link,title,content,categories,featured_media,_links,_embedded'
    if ($Category -gt 0) { $url += "&categories=$Category" }
    if ($Search) { $url += '&search=' + [Uri]::EscapeDataString($Search) }

    $total      = 0
    $totalPages = 0
    $items      = @()
    $errorText  = $null

    try {
        $resp  = Invoke-Upstream $url
        $parsed = $resp.Content | ConvertFrom-Json
        $posts  = @($parsed)

        $t = 0; if ([int]::TryParse((Get-HeaderValue $resp 'X-WP-Total'), [ref]$t)) { $total = $t }
        $p = 0; if ([int]::TryParse((Get-HeaderValue $resp 'X-WP-TotalPages'), [ref]$p)) { $totalPages = $p }

        $items = @(
            foreach ($post in $posts) {
                $mp4 = Get-Mp4Url ([string]$post.content.rendered)
                if (-not $mp4) { continue }

                $script:index[[string]$post.id] = $mp4
                $posters = Get-PosterUrls $post

                [pscustomobject]@{
                    id         = [int]$post.id
                    slug       = [string]$post.slug
                    title      = [Net.WebUtility]::HtmlDecode([string]$post.title.rendered)
                    date       = [string]$post.date
                    page       = [string]$post.link
                    mp4        = $mp4
                    poster     = $posters.thumb
                    posterFull = $posters.full
                    categories = @($post.categories | ForEach-Object { [int]$_ })
                    download   = "/dl/$($post.id)"
                }
            }
        )
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 400) {
            # WordPress rejects page > totalPages; treat as an empty tail page.
            $prev = Get-CacheItem ('v|{0}|1|{1}|{2}' -f $Category, $PerPage, $Search.ToLowerInvariant())
            if ($prev) { $total = $prev.total; $totalPages = $prev.totalPages }
        }
        else {
            $errorText = $_.Exception.Message
        }
    }

    $data = [pscustomobject]@{
        page       = $Page
        perPage    = $PerPage
        total      = $total
        totalPages = $totalPages
        category   = $Category
        search     = $Search
        error      = $errorText
        items      = @($items)
    }
    if (-not $errorText) { Set-CacheItem $key $data }
    return $data
}

function Resolve-VideoUrl {
    param([int]$Id)

    $cached = $script:index[[string]$Id]
    if ($cached) { return $cached }

    $resp = Invoke-Upstream ("https://darkero.com/wp-json/wp/v2/posts/{0}?_fields=id,content" -f $Id)
    $post = $resp.Content | ConvertFrom-Json
    $mp4  = Get-Mp4Url ([string]$post.content.rendered)
    if ($mp4) { $script:index[[string]$Id] = $mp4 }
    return $mp4
}

# ---------------------------------------------------------------- http

function Send-Response {
    param(
        $Stream,
        [int]$Status = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [byte[]]$Body = @(),
        [hashtable]$Headers = @{},
        [switch]$HeadOnly
    )

    $reasons = @{
        200 = 'OK'; 204 = 'No Content'; 301 = 'Moved Permanently'; 302 = 'Found'
        304 = 'Not Modified'; 400 = 'Bad Request'; 404 = 'Not Found'; 405 = 'Method Not Allowed'
        419 = 'Authentication Timeout'; 429 = 'Too Many Requests'
        500 = 'Internal Server Error'; 502 = 'Bad Gateway'; 503 = 'Service Unavailable'
    }
    $reason = if ($reasons.ContainsKey($Status)) { $reasons[$Status] } else { 'OK' }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status $reason`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $($Body.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("Access-Control-Allow-Origin: *`r`n")
    [void]$sb.Append("X-Content-Type-Options: nosniff`r`n")
    [void]$sb.Append("Connection: close`r`n")
    foreach ($k in $Headers.Keys) { [void]$sb.Append("$k`: $($Headers[$k])`r`n") }
    [void]$sb.Append("`r`n")

    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($head, 0, $head.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, $Data, [int]$Status = 200, [hashtable]$Headers = @{}, [switch]$HeadOnly)

    $json = ConvertTo-Json -InputObject $Data -Depth 8 -Compress
    Send-Response -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -Headers $Headers -HeadOnly:$HeadOnly
}

function Get-QueryMap {
    param([string]$QueryString)

    $map = @{}
    if ([string]::IsNullOrEmpty($QueryString)) { return $map }
    foreach ($pair in $QueryString.Split('&')) {
        if (-not $pair) { continue }
        $i = $pair.IndexOf('=')
        if ($i -lt 0) {
            $map[[Uri]::UnescapeDataString($pair)] = ''
        }
        else {
            $k = [Uri]::UnescapeDataString($pair.Substring(0, $i))
            $v = [Uri]::UnescapeDataString($pair.Substring($i + 1).Replace('+', ' '))
            $map[$k] = $v
        }
    }
    return $map
}

function Get-IntQuery {
    param($Map, [string]$Key, [int]$Default = 0)

    if (-not $Map.ContainsKey($Key)) { return $Default }
    $n = 0
    if ([int]::TryParse([string]$Map[$Key], [ref]$n)) { return $n }
    return $Default
}

# ---------------------------------------------------------------- server

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "DarkEro API demo on http://localhost:$Port/"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 4096, $true)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { $client.Close(); continue }
            while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') { }

            $parts   = $requestLine.Split(' ')
            $method  = $parts[0]
            $target  = $parts[1]
            $rawPath = ($target -split '\?')[0]
            $query   = if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' }
            $path    = [Uri]::UnescapeDataString($rawPath)
            $q       = Get-QueryMap $query
            $isHead  = $method -eq 'HEAD'

            if ($method -ne 'GET' -and $method -ne 'HEAD') {
                Send-Response -Stream $stream -Status 405 -Body ([Text.Encoding]::UTF8.GetBytes('GET/HEAD only')) -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/' -or $path -eq '/index.html') {
                $file = Join-Path $root 'index.html'
                $body = [IO.File]::ReadAllBytes($file)
                Send-Response -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body $body -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/api/bootstrap') {
                $force  = $q.ContainsKey('refresh') -and $q['refresh'] -eq '1'
                $cats   = Get-CategoriesData -Force:$force
                $videos = Get-VideosData -Page 1 -PerPage $DefaultPerPage -Force:$force
                Send-Json $stream ([pscustomobject]@{
                    totalVideos = $cats.totalVideos
                    categories  = @($cats.categories)
                    videos      = $videos
                }) -Headers @{ 'X-Source' = 'darkero.com/wp-json/wp/v2/posts' } -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/api/categories') {
                $force = $q.ContainsKey('refresh') -and $q['refresh'] -eq '1'
                Send-Json $stream (Get-CategoriesData -Force:$force) -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/api/videos') {
                $videos = Get-VideosData `
                    -Category (Get-IntQuery $q 'category' 0) `
                    -Page     (Get-IntQuery $q 'page' 1) `
                    -PerPage  (Get-IntQuery $q 'per_page' $DefaultPerPage) `
                    -Search   ([string]$q['search']) `
                    -Force:($q.ContainsKey('refresh') -and $q['refresh'] -eq '1')
                Send-Json $stream $videos -Headers @{ 'X-Source' = 'darkero.com/wp-json/wp/v2/posts' } -HeadOnly:$isHead
                continue
            }

            if ($path -match '^/dl/(\d+)$') {
                $id  = [int]$Matches[1]
                $mp4 = $null
                try { $mp4 = Resolve-VideoUrl $id } catch { }
                if (-not $mp4) {
                    Send-Response -Stream $stream -Status 404 -ContentType 'application/json; charset=utf-8' `
                        -Body ([Text.Encoding]::UTF8.GetBytes('{"error":"unknown video id"}')) -HeadOnly:$isHead
                    continue
                }
                Send-Response -Stream $stream -Status 302 -ContentType 'text/plain; charset=utf-8' `
                    -Body ([byte[]]@()) -Headers @{ 'Location' = $mp4 } -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/health') {
                Send-Response -Stream $stream -Status 200 -ContentType 'application/json; charset=utf-8' `
                    -Body ([Text.Encoding]::UTF8.GetBytes('{"ok":true}')) -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/favicon.ico') {
                Send-Response -Stream $stream -Status 204 -ContentType 'image/x-icon' -Body ([byte[]]@()) -HeadOnly:$isHead
                continue
            }

            Send-Response -Stream $stream -Status 404 -Body ([Text.Encoding]::UTF8.GetBytes('not found')) -HeadOnly:$isHead
        }
        catch {
            try {
                Send-Response -Stream $stream -Status 500 -Body ([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
            }
            catch { }
        }
        finally {
            if ($stream) { try { $stream.Dispose() } catch { } }
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
