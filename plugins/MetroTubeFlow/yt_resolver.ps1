param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("search", "stream", "related")]
    [string]$Mode,
    [string]$Query,
    [string]$VideoId,
    [int]$Limit = 10
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
} catch { }

$BaseUrl = "https://music.youtube.com/youtubei/v1"
$WebUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

$WebClient = @{
    clientName = "WEB_REMIX"
    clientVersion = "1.20240101.01.00"
    clientId = "67"
    gl = "US"
    hl = "en"
}

$PlayerClients = @(
    @{
        name = "ANDROID_VR_1_43"
        clientName = "ANDROID_VR"
        clientVersion = "1.43.32"
        clientId = "28"
        deviceMake = "Oculus"
        deviceModel = "Quest 3"
        osName = "Android"
        osVersion = "12"
        androidSdkVersion = "32"
        gl = "US"
        hl = "en"
        userAgent = "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)"
    },
    @{
        name = "ANDROID_VR_1_61"
        clientName = "ANDROID_VR"
        clientVersion = "1.61.48"
        clientId = "28"
        deviceMake = "Oculus"
        deviceModel = "Quest 3"
        osName = "Android"
        osVersion = "12"
        androidSdkVersion = "32"
        gl = "US"
        hl = "en"
        userAgent = "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)"
    },
    @{
        name = "IOS"
        clientName = "IOS"
        clientVersion = "21.03.1"
        clientId = "5"
        deviceMake = "Apple"
        deviceModel = "iPhone16,2"
        osName = "iOS"
        osVersion = "18.2.22C152"
        gl = "US"
        hl = "en"
        userAgent = "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)"
    },
    @{
        name = "IPADOS"
        clientName = "IOS"
        clientVersion = "21.03.3"
        clientId = "5"
        deviceMake = "Apple"
        deviceModel = "iPad7,6"
        osName = "iPadOS"
        osVersion = "17.7.10.21H450"
        gl = "US"
        hl = "en"
        userAgent = "com.google.ios.youtube/21.03.3 (iPad7,6; U; CPU iPadOS 17_7_10 like Mac OS X; en-US)"
    }
)

$ItagPriority = @(140, 139, 251, 250, 249)

function Write-JsonAndExit {
    param($Value)
    $Value | ConvertTo-Json -Depth 30 -Compress
    exit 0
}

function Fail {
    param([string]$Message)
    Write-JsonAndExit @{ ok = $false; error = $Message }
}

function New-Headers {
    param($Client, [string]$VisitorData)

    $headers = @{
        "Accept" = "application/json"
        "Accept-Language" = "en-US,en;q=0.9"
        "Origin" = "https://music.youtube.com"
        "Referer" = "https://music.youtube.com/"
        "X-Goog-Api-Format-Version" = "1"
        "X-Origin" = "https://music.youtube.com"
        "X-Youtube-Client-Name" = $Client.clientId
        "X-Youtube-Client-Version" = $Client.clientVersion
    }
    if ($VisitorData) {
        $headers["X-Goog-Visitor-Id"] = $VisitorData
    }
    return $headers
}

function Add-ClientProperties {
    param($Context, $Client, [string]$VideoId)

    foreach ($key in @("deviceMake", "deviceModel", "osName", "osVersion", "androidSdkVersion")) {
        if ($Client.ContainsKey($key)) {
            $Context.client[$key] = $Client[$key]
        }
    }

    if ($Client.ContainsKey("isEmbedded") -and $Client.isEmbedded) {
        $Context.thirdParty = @{ embedUrl = "https://www.youtube.com/watch?v=$VideoId" }
    }
}

function Invoke-YT {
    param(
        [string]$Endpoint,
        [hashtable]$Context,
        [hashtable]$Body,
        [hashtable]$Headers,
        [string]$UserAgent
    )

    $url = "$BaseUrl/$Endpoint"
    $fullBody = @{ context = $Context } + $Body
    $jsonBody = $fullBody | ConvertTo-Json -Depth 30 -Compress
    return Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -Body $jsonBody -ContentType "application/json" -UserAgent $UserAgent
}

function Get-TextFromRuns {
    param($Runs)
    if (-not $Runs) { return "" }
    return (($Runs | ForEach-Object { $_.text }) -join "").Trim()
}

function Convert-Duration {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $parts = $Text -split ":"
    try {
        if ($parts.Count -eq 2) { return ([int]$parts[0] * 60 + [int]$parts[1]) }
        if ($parts.Count -eq 3) { return ([int]$parts[0] * 3600 + [int]$parts[1] * 60 + [int]$parts[2]) }
    } catch { }
    return 0
}

function Search-Songs {
    param([string]$SearchQuery, [int]$MaxItems)

    if (-not $SearchQuery) { Fail "Search query is empty." }

    $context = @{
        client = $WebClient
        user = @{ lockedSafetyMode = $false }
        request = @{ useSsl = $true; internalExperimentFlags = @() }
    }
    $headers = New-Headers $WebClient $null
    $body = @{
        query = $SearchQuery
        params = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    }
    $response = Invoke-YT "search" $context $body $headers $WebUserAgent
    $items = New-Object System.Collections.ArrayList

    $contents = $response.contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents
    foreach ($section in $contents) {
        $shelf = $section.musicShelfRenderer
        if (-not $shelf) { continue }

        foreach ($item in $shelf.contents) {
            $renderer = $item.musicResponsiveListItemRenderer
            if (-not $renderer) { continue }

            $videoId = $renderer.playlistItemData.videoId
            if (-not $videoId) {
                $videoId = $renderer.overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId
            }
            if (-not $videoId) { continue }

            $title = Get-TextFromRuns $renderer.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs
            $secondaryRuns = $renderer.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs
            $parts = @()
            foreach ($run in $secondaryRuns) {
                if ($run.text -and $run.text -ne " " -and $run.text -ne " • ") {
                    $parts += $run.text
                }
            }

            $artist = ""
            $album = ""
            $durationText = ""
            if ($parts.Count -gt 0) { $artist = $parts[0] }
            if ($parts.Count -gt 1) { $album = $parts[1] }
            if ($parts.Count -gt 0 -and $parts[-1] -match "^\d+:\d+") { $durationText = $parts[-1] }

            $thumbnail = ""
            if ($renderer.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails) {
                $thumbnail = $renderer.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url
            }

            [void]$items.Add(@{
                id = $videoId
                title = $title
                artist = $artist
                album = $album
                duration = Convert-Duration $durationText
                durationText = $durationText
                thumbnail = $thumbnail
            })

            if ($items.Count -ge $MaxItems) { break }
        }

        if ($items.Count -ge $MaxItems) { break }
    }

    Write-JsonAndExit @{ ok = $true; items = @($items) }
}

function Resolve-Stream {
    param([string]$Id)

    if (-not $Id) { Fail "Video id is empty." }

    foreach ($client in $PlayerClients) {
        $context = @{
            client = @{
                clientName = $client.clientName
                clientVersion = $client.clientVersion
                gl = $client.gl
                hl = $client.hl
            }
            user = @{ lockedSafetyMode = $false }
            request = @{ useSsl = $true; internalExperimentFlags = @() }
        }
        Add-ClientProperties $context $client $Id

        $headers = New-Headers $client $null
        $body = @{
            videoId = $Id
            contentCheckOk = $true
            racyCheckOk = $true
        }

        try {
            $response = Invoke-YT "player" $context $body $headers $client.userAgent
            if ($response.playabilityStatus.status -ne "OK") { continue }

            $audioFormats = @($response.streamingData.adaptiveFormats | Where-Object {
                $_.mimeType -match "^audio/" -and $_.url
            })

            foreach ($itag in $ItagPriority) {
                $format = $audioFormats | Where-Object { $_.itag -eq $itag } | Select-Object -First 1
                if ($format -and $format.url) {
                    Write-JsonAndExit @{
                        ok = $true
                        stream = @{
                            url = $format.url
                            itag = $format.itag
                            bitrate = $format.bitrate
                            mimeType = $format.mimeType
                            contentLength = $format.contentLength
                            clientName = $client.name
                        }
                    }
                }
            }

            $best = $audioFormats | Sort-Object -Property bitrate -Descending | Select-Object -First 1
            if ($best -and $best.url) {
                Write-JsonAndExit @{
                    ok = $true
                    stream = @{
                        url = $best.url
                        itag = $best.itag
                        bitrate = $best.bitrate
                        mimeType = $best.mimeType
                        contentLength = $best.contentLength
                        clientName = $client.name
                    }
                }
            }
        } catch {
            continue
        }
    }

    Fail "All player clients failed. YouTube may be asking for sign-in or bot verification."
}

function Get-Related {
    param([string]$Id, [int]$MaxItems)

    if (-not $Id) { Fail "Video id is empty." }

    $context = @{
        client = $WebClient
        user = @{ lockedSafetyMode = $false }
        request = @{ useSsl = $true; internalExperimentFlags = @() }
    }
    $headers = New-Headers $WebClient $null
    $body = @{
        videoId = $Id
        isAudioOnly = $true
        enablePersistentPlaylistPanel = $true
    }

    $response = Invoke-YT "next" $context $body $headers $WebUserAgent
    $items = New-Object System.Collections.ArrayList
    $panel = $response.contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs[0].tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer

    foreach ($entry in $panel.contents) {
        $renderer = $entry.playlistPanelVideoRenderer
        if (-not $renderer) { continue }
        $videoId = $renderer.videoId
        if (-not $videoId -or $videoId -eq $Id) { continue }

        $title = Get-TextFromRuns $renderer.title.runs
        $artist = Get-TextFromRuns $renderer.longBylineText.runs
        $durationText = $renderer.lengthText.runs[0].text
        $thumbnail = ""
        if ($renderer.thumbnail.thumbnails) {
            $thumbnail = $renderer.thumbnail.thumbnails[-1].url
        }

        [void]$items.Add(@{
            id = $videoId
            title = $title
            artist = $artist
            album = ""
            duration = Convert-Duration $durationText
            durationText = $durationText
            thumbnail = $thumbnail
        })

        if ($items.Count -ge $MaxItems) { break }
    }

    Write-JsonAndExit @{ ok = $true; items = @($items) }
}

try {
    if ($Mode -eq "search") { Search-Songs $Query $Limit }
    if ($Mode -eq "stream") { Resolve-Stream $VideoId }
    if ($Mode -eq "related") { Get-Related $VideoId $Limit }
} catch {
    Fail $_.Exception.Message
}
