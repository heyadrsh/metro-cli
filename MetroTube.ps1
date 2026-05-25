<#
.SYNOPSIS
    MetroTube - Terminal YouTube Music Player for Windows
.DESCRIPTION
    A full-featured YouTube Music client that runs entirely in PowerShell.
    Uses the InnerTube API (same as the Metrolist Android app).
    Zero external dependencies - just run it.
.PARAMETER Search
    Initial search query to run on startup
.PARAMETER PlayFavorites
    Start playing from favorites
.PARAMETER Resume
    Resume last session (queue and position)
.EXAMPLE
    .\MetroTube.ps1
    .\MetroTube.ps1 -Search "bohemian rhapsody"
    .\MetroTube.ps1 -PlayFavorites
    .\MetroTube.ps1 -Resume
#>

param(
    [string]$Search,
    [switch]$PlayFavorites,
    [switch]$Resume,
    [switch]$Test
)

#region ==================== PROXY FIX ====================
# Auto-configure proxy to use Windows credentials (fixes 407 errors behind corporate proxies)
try {
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
} catch { }
#endregion

#region ==================== CONFIGURATION ====================

$script:Config = @{
    AppName = "MetroTube"
    Version = "1.0.8"
    BaseUrl = "https://music.youtube.com/youtubei/v1"
    StoragePath = "$env:APPDATA\MetroTube"
    LogPath = "$env:APPDATA\MetroTube\metrotube.log"
    CachePath = "$env:APPDATA\MetroTube\cache"

    # WEB_REMIX client for search (returns YouTube Music format)
    WebClient = @{
        clientName = "WEB_REMIX"
        clientVersion = "1.20240101.01.00"
        clientId = "67"
        gl = "US"
        hl = "en"
    }

    # Multiple player clients for fallback (like Metrolist does)
    PlayerClients = @(
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
        },
        @{
            name = "TVHTML5_EMBEDDED"
            clientName = "TVHTML5_SIMPLY_EMBEDDED_PLAYER"
            clientVersion = "2.0"
            clientId = "85"
            gl = "US"
            hl = "en"
            isEmbedded = $true
            userAgent = "Mozilla/5.0 (PlayStation; PlayStation 4/12.02) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15"
        }
    )

    WebUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    # Windows Media Player is most reliable with M4A/AAC. Keep WebM/Opus as fallback.
    ItagPriority = @(140, 139, 251, 250, 249)
    DownloadChunkSize = 1048576

    RefreshInterval = 1000
}

$script:State = @{
    CurrentSong = $null
    Queue = New-Object System.Collections.ArrayList
    QueueIndex = 0
    IsPlaying = $false
    Volume = 80
    RepeatMode = "off"
    ShuffleMode = $false
    ShuffleOrder = @()
    CurrentView = "player"
    SearchResults = @()
    SearchQuery = ""
    LastSearchQuery = ""
    IsSearching = $false
    StatusMessage = ""
    Player = $null
    PlayerBackend = ""
    LastPosition = 0
    VisitorData = $null
}

$script:Settings = @{
    volume = 80
    audioQuality = "high"
    repeatMode = "off"
    shuffleEnabled = $false
    colorEnabled = $true
    autoRecommendations = $true
}

$script:Favorites = @{ songs = New-Object System.Collections.ArrayList }
$script:History = @{ songs = New-Object System.Collections.ArrayList }
$script:Playlists = @{ playlists = New-Object System.Collections.ArrayList }

#endregion

#region ==================== UTILITIES ====================

function Write-Color {
    param(
        [string]$Text,
        [ConsoleColor]$Color = "White",
        [switch]$NoNewline
    )

    if ($script:Settings.colorEnabled) {
        if ($NoNewline) {
            Write-Host $Text -ForegroundColor $Color -NoNewline
        } else {
            Write-Host $Text -ForegroundColor $Color
        }
    } else {
        if ($NoNewline) {
            Write-Host $Text -NoNewline
        } else {
            Write-Host $Text
        }
    }
}

function Ensure-StorageDirectory {
    try {
        if (-not (Test-Path $script:Config.StoragePath)) {
            New-Item -ItemType Directory -Path $script:Config.StoragePath -Force | Out-Null
        }
        if (-not (Test-Path $script:Config.CachePath)) {
            New-Item -ItemType Directory -Path $script:Config.CachePath -Force | Out-Null
        }
    } catch {
        # If storage cannot be created, keep the app usable and surface the real error elsewhere.
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [object]$ErrorRecord = $null
    )

    try {
        Ensure-StorageDirectory
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $entry = "$timestamp [$Level] $Message"

        if ($ErrorRecord) {
            $entry += [Environment]::NewLine + ($ErrorRecord | Out-String)
            if ($ErrorRecord.ScriptStackTrace) {
                $entry += [Environment]::NewLine + "Script stack:" + [Environment]::NewLine + $ErrorRecord.ScriptStackTrace
            }
        }

        Add-Content -Path $script:Config.LogPath -Value $entry -Encoding UTF8
    } catch {
        # Logging must never be the thing that crashes playback.
    }
}

function Format-Duration {
    param([int]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $minutes = [math]::Floor($Seconds / 60)
    $secs = $Seconds % 60
    return "{0}:{1:D2}" -f $minutes, $secs
}

function Truncate-String {
    param(
        [string]$Text,
        [int]$MaxLength
    )

    if ([string]::IsNullOrEmpty($Text) -or $MaxLength -le 0) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }
    if ($MaxLength -le 3) { return $Text.Substring(0, [Math]::Min($Text.Length, $MaxLength)) }
    return $Text.Substring(0, $MaxLength - 3) + "..."
}

function Get-ProgressBar {
    param(
        [double]$Current,
        [double]$Total,
        [int]$Width = 40
    )

    if ($Total -le 0) { $Total = 1 }
    $percent = [math]::Min(1, [math]::Max(0, $Current / $Total))
    $filled = [math]::Floor($Width * $percent)
    $empty = $Width - $filled

    $bar = ("=" * $filled)
    if ($filled -lt $Width) {
        $bar += "O"
        $empty--
    }
    $bar += ("-" * [math]::Max(0, $empty))

    return $bar
}

function Get-VolumeBar {
    param([int]$Volume)

    $blocks = [math]::Floor($Volume / 10)
    $filled = [char]0x2588 * $blocks
    $empty = [char]0x2591 * (10 - $blocks)
    return $filled + $empty
}

#endregion

#region ==================== STORAGE ====================

function Initialize-Storage {
    Ensure-StorageDirectory
    Write-Log "MetroTube v$($script:Config.Version) starting"
}

function Get-StoragePath {
    param([string]$FileName)
    return Join-Path $script:Config.StoragePath $FileName
}

function Get-CachePath {
    param(
        [string]$VideoId,
        [int]$Itag,
        [string]$MimeType
    )

    $extension = if ($MimeType -match "audio/webm") { "webm" } else { "m4a" }
    $safeId = $VideoId -replace "[^a-zA-Z0-9_-]", "_"
    return Join-Path $script:Config.CachePath "$safeId-$Itag.$extension"
}

function Save-JsonFile {
    param(
        [string]$FileName,
        [object]$Data
    )

    try {
        Ensure-StorageDirectory
        $path = Get-StoragePath $FileName
        $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    } catch {
        Write-Log "Failed to save $FileName" "ERROR" $_
    }
}

function Load-JsonFile {
    param(
        [string]$FileName,
        [object]$Default
    )

    $path = Get-StoragePath $FileName
    if (Test-Path $path) {
        try {
            return Get-Content -Path $path -Raw | ConvertFrom-Json
        } catch {
            return $Default
        }
    }
    return $Default
}

function Save-Settings {
    Save-JsonFile "config.json" $script:Settings
}

function Load-Settings {
    $loaded = Load-JsonFile "config.json" $script:Settings
    if ($loaded) {
        foreach ($key in $loaded.PSObject.Properties.Name) {
            $script:Settings[$key] = $loaded.$key
        }
    }
    $script:State.Volume = $script:Settings.volume
    $script:State.RepeatMode = $script:Settings.repeatMode
    $script:State.ShuffleMode = $script:Settings.shuffleEnabled
}

function Save-Favorites {
    Save-JsonFile "favorites.json" $script:Favorites
}

function Load-Favorites {
    $loaded = Load-JsonFile "favorites.json" @{ songs = @() }
    if ($loaded -and $loaded.songs) {
        $script:Favorites.songs = [System.Collections.ArrayList]@($loaded.songs)
    }
}

function Save-History {
    Save-JsonFile "history.json" $script:History
}

function Load-History {
    $loaded = Load-JsonFile "history.json" @{ songs = @() }
    if ($loaded -and $loaded.songs) {
        $script:History.songs = [System.Collections.ArrayList]@($loaded.songs)
    }
}

function Save-QueueState {
    $position = 0
    try {
        if ($script:State.Player) {
            $position = Get-PlayerPositionInternal
        }
    } catch {
        Write-Log "Could not read playback position while saving queue" "WARN" $_
    }

    $queueState = @{
        queue = $script:State.Queue
        index = $script:State.QueueIndex
        position = $position
        repeatMode = $script:State.RepeatMode
        shuffleMode = $script:State.ShuffleMode
        volume = $script:State.Volume
    }
    Save-JsonFile "queue.json" $queueState
}

function Load-QueueState {
    $loaded = Load-JsonFile "queue.json" $null
    if ($loaded) {
        if ($loaded.queue) {
            $script:State.Queue = [System.Collections.ArrayList]@($loaded.queue)
        }
        if ($null -ne $loaded.index) {
            $script:State.QueueIndex = $loaded.index
        }
        if ($null -ne $loaded.position) {
            $script:State.LastPosition = $loaded.position
        }
    }
}

function Add-ToHistory {
    param([object]$Song)

    $entry = @{
        id = $Song.id
        title = $Song.title
        artist = $Song.artist
        album = $Song.album
        duration = $Song.duration
        thumbnail = $Song.thumbnail
        playedAt = (Get-Date).ToString("o")
    }

    $existing = $script:History.songs | Where-Object { $_.id -eq $Song.id } | Select-Object -First 1
    if ($existing) {
        $script:History.songs.Remove($existing)
    }

    $script:History.songs.Insert(0, $entry)

    if ($script:History.songs.Count -gt 100) {
        $script:History.songs = [System.Collections.ArrayList]@($script:History.songs[0..99])
    }

    Save-History
}

function Toggle-Favorite {
    $song = $script:State.CurrentSong
    if (-not $song) { return $false }

    $existing = $script:Favorites.songs | Where-Object { $_.id -eq $song.id } | Select-Object -First 1

    if ($existing) {
        $script:Favorites.songs.Remove($existing) | Out-Null
        $script:State.StatusMessage = "Removed from favorites"
        Save-Favorites
        return $false
    } else {
        $entry = @{
            id = $song.id
            title = $song.title
            artist = $song.artist
            album = $song.album
            duration = $song.duration
            thumbnail = $song.thumbnail
            addedAt = (Get-Date).ToString("o")
        }
        $script:Favorites.songs.Insert(0, $entry) | Out-Null
        $script:State.StatusMessage = "Added to favorites"
        Save-Favorites
        return $true
    }
}

function Is-Favorite {
    param([string]$SongId)
    return ($script:Favorites.songs | Where-Object { $_.id -eq $SongId } | Measure-Object).Count -gt 0
}

#endregion

#region ==================== API FUNCTIONS ====================

function Build-WebContext {
    $ctx = @{
        client = @{
            clientName = $script:Config.WebClient.clientName
            clientVersion = $script:Config.WebClient.clientVersion
            gl = $script:Config.WebClient.gl
            hl = $script:Config.WebClient.hl
        }
        user = @{ lockedSafetyMode = $false }
        request = @{ useSsl = $true; internalExperimentFlags = @() }
    }

    if ($script:State.VisitorData) {
        $ctx.client.visitorData = $script:State.VisitorData
    }

    return $ctx
}

function Build-PlayerContext {
    # Use first client from PlayerClients array for simple requests
    $client = $script:Config.PlayerClients[0]
    $ctx = @{
        client = @{
            clientName = $client.clientName
            clientVersion = $client.clientVersion
            gl = $client.gl
            hl = $client.hl
        }
        user = @{ lockedSafetyMode = $false }
        request = @{ useSsl = $true; internalExperimentFlags = @() }
    }
    if ($client.deviceMake) { $ctx.client.deviceMake = $client.deviceMake }
    if ($client.deviceModel) { $ctx.client.deviceModel = $client.deviceModel }
    if ($client.osName) { $ctx.client.osName = $client.osName }
    if ($client.osVersion) { $ctx.client.osVersion = $client.osVersion }
    if ($client.androidSdkVersion) { $ctx.client.androidSdkVersion = $client.androidSdkVersion }
    return $ctx
}

function Add-OptionalClientProperties {
    param(
        [hashtable]$ClientContext,
        [hashtable]$Client,
        [string]$VideoId = $null
    )

    if ($Client.deviceMake) { $ClientContext.client.deviceMake = $Client.deviceMake }
    if ($Client.deviceModel) { $ClientContext.client.deviceModel = $Client.deviceModel }
    if ($Client.osName) { $ClientContext.client.osName = $Client.osName }
    if ($Client.osVersion) { $ClientContext.client.osVersion = $Client.osVersion }
    if ($Client.androidSdkVersion) { $ClientContext.client.androidSdkVersion = $Client.androidSdkVersion }

    if ($Client.isEmbedded -and $VideoId) {
        $ClientContext.thirdParty = @{
            embedUrl = "https://www.youtube.com/watch?v=$VideoId"
        }
    }
}

function New-YouTubeHeaders {
    param(
        [hashtable]$Client,
        [string]$VisitorData = $null
    )

    $headers = @{
        "Accept" = "application/json"
        "Accept-Language" = "en-US,en;q=0.9"
        "X-Goog-Api-Format-Version" = "1"
        "X-YouTube-Client-Name" = $Client.clientId
        "X-YouTube-Client-Version" = $Client.clientVersion
        "X-Origin" = "https://music.youtube.com"
        "Origin" = "https://music.youtube.com"
        "Referer" = "https://music.youtube.com/"
    }

    if ($VisitorData) {
        $headers["X-Goog-Visitor-Id"] = $VisitorData
    }

    return $headers
}

function Invoke-WebRequest-YTMusic {
    param(
        [string]$Endpoint,
        [hashtable]$Body
    )

    $url = "$($script:Config.BaseUrl)/$Endpoint"

    $fullBody = @{ context = (Build-WebContext) } + $Body
    $jsonBody = $fullBody | ConvertTo-Json -Depth 10 -Compress

    $headers = New-YouTubeHeaders $script:Config.WebClient $script:State.VisitorData

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonBody -ContentType "application/json" -UserAgent $script:Config.WebUserAgent -ErrorAction Stop
        if ($response.responseContext.visitorData -and -not $script:State.VisitorData) {
            $script:State.VisitorData = $response.responseContext.visitorData
            Write-Log "Captured visitorData from $Endpoint response"
        }
        return $response
    } catch {
        $script:State.StatusMessage = "API Error: $($_.Exception.Message)"
        Write-Log "WEB_REMIX $Endpoint request failed" "ERROR" $_
        return $null
    }
}

function Invoke-PlayerRequest {
    param(
        [string]$Endpoint,
        [hashtable]$Body
    )

    $url = "$($script:Config.BaseUrl)/$Endpoint"

    $fullBody = @{ context = (Build-PlayerContext) } + $Body
    $jsonBody = $fullBody | ConvertTo-Json -Depth 10 -Compress

    # Use first client's user agent
    $userAgent = $script:Config.PlayerClients[0].userAgent

    $headers = New-YouTubeHeaders $script:Config.PlayerClients[0] $script:State.VisitorData

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonBody -ContentType "application/json" -UserAgent $userAgent -ErrorAction Stop
        return $response
    } catch {
        $script:State.StatusMessage = "API Error: $($_.Exception.Message)"
        Write-Log "Player $Endpoint request failed" "ERROR" $_
        return $null
    }
}

function Test-API {
    Write-Host "Testing YouTube Music API..." -ForegroundColor Cyan
    Write-Host ""

    # Test Search API
    Write-Host "1. Testing Search API (WEB_REMIX client)..." -ForegroundColor Yellow
    $searchBody = @{ query = "never gonna give you up" }
    $searchResponse = Invoke-WebRequest-YTMusic "search" $searchBody

    if ($searchResponse) {
        $tabs = $searchResponse.contents.tabbedSearchResultsRenderer.tabs
        if ($tabs) {
            Write-Host "   [OK] Search API works!" -ForegroundColor Green
            $contents = $tabs[0].tabRenderer.content.sectionListRenderer.contents
            $songCount = 0
            foreach ($section in $contents) {
                if ($section.musicShelfRenderer) {
                    $songCount += $section.musicShelfRenderer.contents.Count
                }
            }
            Write-Host "   Found approximately $songCount results" -ForegroundColor Gray
        } else {
            Write-Host "   [FAIL] Unexpected response format" -ForegroundColor Red
        }
    } else {
        Write-Host "   [FAIL] Search API failed" -ForegroundColor Red
    }

    Write-Host ""

    # Test Player API using the same fallback chain as real playback.
    Write-Host "2. Testing Player API fallback chain..." -ForegroundColor Yellow
    Write-Host "   Video: Rick Astley - Never Gonna Give You Up" -ForegroundColor Gray
    $stream = Get-StreamUrl "dQw4w9WgXcQ"

    if ($stream) {
        Write-Host "   [OK] Player fallback works!" -ForegroundColor Green
        Write-Host "   $($script:State.StatusMessage)" -ForegroundColor Gray
        Write-Host "   Selected stream: itag=$($stream.itag), bitrate=$($stream.bitrate)bps, mime=$($stream.mimeType)" -ForegroundColor Gray

        Write-Host ""
        Write-Host "3. Testing range download/cache..." -ForegroundColor Yellow
        $testSong = @{
            id = "dQw4w9WgXcQ"
            title = "Never Gonna Give You Up"
            artist = "Rick Astley"
        }
        try {
            $cacheFile = Save-StreamToCache $testSong $stream $false
            $cacheSize = (Get-Item $cacheFile).Length
            Write-Host "   [OK] Cached audio file: $cacheFile" -ForegroundColor Green
            Write-Host "   Size: $cacheSize bytes" -ForegroundColor Gray
        } catch {
            Write-Host "   [FAIL] Cache download failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "   See log: $($script:Config.LogPath)" -ForegroundColor Gray
        }
    } else {
        Write-Host "   [FAIL] Player fallback failed" -ForegroundColor Red
        Write-Host "   See log: $($script:Config.LogPath)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "API Test Complete!" -ForegroundColor Cyan
    Write-Host ""
}

function Search-Songs {
    param(
        [string]$Query,
        [string]$Filter = $null
    )

    $body = @{
        query = $Query
    }

    if ($Filter -eq "songs") {
        $body.params = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    }

    $response = Invoke-WebRequest-YTMusic "search" $body

    if (-not $response) { return @() }

    $results = New-Object System.Collections.ArrayList

    try {
        $contents = $response.contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents
    } catch {
        Write-Log "Search response format was not recognized" "ERROR" $_
        return @()
    }

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

            $title = ""
            $artist = ""
            $album = ""
            $duration = 0
            $thumbnail = ""

            if ($renderer.flexColumns -and $renderer.flexColumns.Count -gt 0) {
                $titleRuns = $renderer.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs
                if ($titleRuns) {
                    $title = ($titleRuns | ForEach-Object { $_.text }) -join ""
                }
            }

            if ($renderer.flexColumns -and $renderer.flexColumns.Count -gt 1) {
                $secondaryRuns = $renderer.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs
                if ($secondaryRuns) {
                    $parts = @()
                    foreach ($run in $secondaryRuns) {
                        if ($run.text -and $run.text -ne " " -and $run.text -ne " • ") {
                            $parts += $run.text
                        }
                    }
                    if ($parts.Count -gt 0) { $artist = $parts[0] }
                    if ($parts.Count -gt 1) { $album = $parts[1] }

                    if ($parts.Count -gt 0) {
                        $lastPart = $parts[-1]
                        if ($lastPart -match "^\d+:\d+") {
                            $timeParts = $lastPart -split ":"
                            if ($timeParts.Count -eq 2) {
                                $duration = [int]$timeParts[0] * 60 + [int]$timeParts[1]
                            } elseif ($timeParts.Count -eq 3) {
                                $duration = [int]$timeParts[0] * 3600 + [int]$timeParts[1] * 60 + [int]$timeParts[2]
                            }
                        }
                    }
                }
            }

            if ($renderer.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails) {
                $thumbnail = $renderer.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url
            }

            $song = @{
                id = $videoId
                title = $title
                artist = $artist
                album = $album
                duration = $duration
                thumbnail = $thumbnail
                type = "song"
            }

            $results.Add($song) | Out-Null

            if ($results.Count -ge 20) { break }
        }

        if ($results.Count -ge 20) { break }
    }

    return $results
}

function Get-SearchSuggestions {
    param([string]$Query)

    $body = @{ input = $Query }
    $response = Invoke-WebRequest-YTMusic "music/get_search_suggestions" $body

    if (-not $response) { return @() }

    $suggestions = New-Object System.Collections.ArrayList

    $contents = $response.contents
    if ($contents) {
        foreach ($section in $contents) {
            $sectionRenderer = $section.searchSuggestionsSectionRenderer
            if (-not $sectionRenderer) { continue }

            foreach ($item in $sectionRenderer.contents) {
                if ($item.searchSuggestionRenderer) {
                    $text = ($item.searchSuggestionRenderer.suggestion.runs | ForEach-Object { $_.text }) -join ""
                    $suggestions.Add($text) | Out-Null
                }
            }
        }
    }

    return $suggestions
}

function Get-StreamUrl {
    param([string]$VideoId)

    Write-Log "Resolving stream for videoId=$VideoId"

    # Try each player client in order (fallback like Metrolist)
    foreach ($client in $script:Config.PlayerClients) {
        $clientContext = @{
            client = @{
                clientName = $client.clientName
                clientVersion = $client.clientVersion
                gl = $client.gl
                hl = $client.hl
            }
            user = @{ lockedSafetyMode = $false }
            request = @{ useSsl = $true; internalExperimentFlags = @() }
        }

        Add-OptionalClientProperties $clientContext $client $VideoId

        # Add visitorData if we have it
        if ($script:State.VisitorData) {
            $clientContext.client.visitorData = $script:State.VisitorData
        }

        $body = @{
            context = $clientContext
            videoId = $VideoId
            contentCheckOk = $true
            racyCheckOk = $true
        }

        $jsonBody = $body | ConvertTo-Json -Depth 10 -Compress
        $url = "$($script:Config.BaseUrl)/player"

        $headers = New-YouTubeHeaders $client $script:State.VisitorData

        try {
            Write-Log "Trying player client $($client.name)"
            $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonBody -ContentType "application/json" -UserAgent $client.userAgent -ErrorAction Stop

            # Store visitorData from response for future requests
            if ($response.responseContext.visitorData -and -not $script:State.VisitorData) {
                $script:State.VisitorData = $response.responseContext.visitorData
                Write-Log "Captured visitorData from player response"
            }

            if ($response.playabilityStatus.status -eq "OK") {
                $formats = $response.streamingData.adaptiveFormats
                if ($formats) {
                    $audioFormats = $formats | Where-Object {
                        $_.mimeType -match "^audio/" -and $_.url
                    }

                    foreach ($itag in $script:Config.ItagPriority) {
                        $format = $audioFormats | Where-Object { $_.itag -eq $itag } | Select-Object -First 1
                        if ($format -and $format.url) {
                            $script:State.StatusMessage = "Playing via $($client.name)"
                            Write-Log "Selected stream via $($client.name): itag=$($format.itag), bitrate=$($format.bitrate), mime=$($format.mimeType)"
                            return @{
                                url = $format.url
                                itag = $format.itag
                                bitrate = $format.bitrate
                                mimeType = $format.mimeType
                                contentLength = $format.contentLength
                                userAgent = $client.userAgent
                                clientName = $client.name
                            }
                        }
                    }

                    $bestFormat = $audioFormats | Sort-Object -Property bitrate -Descending | Select-Object -First 1
                    if ($bestFormat -and $bestFormat.url) {
                        $script:State.StatusMessage = "Playing via $($client.name)"
                        Write-Log "Selected fallback stream via $($client.name): itag=$($bestFormat.itag), bitrate=$($bestFormat.bitrate), mime=$($bestFormat.mimeType)"
                        return @{
                            url = $bestFormat.url
                            itag = $bestFormat.itag
                            bitrate = $bestFormat.bitrate
                            mimeType = $bestFormat.mimeType
                            contentLength = $bestFormat.contentLength
                            userAgent = $client.userAgent
                            clientName = $client.name
                        }
                    }
                }
                Write-Log "Client $($client.name) returned OK but no direct audio URL" "WARN"
            } else {
                $status = $response.playabilityStatus.status
                $reason = $response.playabilityStatus.reason
                Write-Log "Client $($client.name) failed playability: status=$status reason=$reason" "WARN"
            }
        } catch {
            Write-Log "Client $($client.name) player request threw" "WARN" $_
        }
    }

    $script:State.StatusMessage = "Error: All player clients failed"
    Write-Log "All player clients failed for videoId=$VideoId" "ERROR"
    return $null
}

function Get-ContentLengthFromUrl {
    param([string]$Url)

    try {
        if ($Url -match "(?:\?|&)clen=(\d+)") {
            return [int64]$matches[1]
        }
    } catch {
        Write-Log "Could not parse clen from stream URL" "WARN" $_
    }

    return 0
}

function Copy-HttpRangeToFile {
    param(
        [string]$Url,
        [string]$Path,
        [int64]$Start,
        [int64]$End,
        [string]$UserAgent
    )

    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
    $request.Method = "GET"
    $request.UserAgent = $UserAgent
    $request.AddRange([int]$Start, [int]$End)
    $request.Headers["Accept-Language"] = "en-US,en;q=0.9"
    $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000

    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 206 -and $statusCode -ne 200) {
            throw "Unexpected HTTP status $statusCode while downloading range $Start-$End"
        }

        $inputStream = $response.GetResponseStream()
        $outputStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Close() }
    }
}

function Save-StreamToCache {
    param(
        [object]$Song,
        [hashtable]$Stream,
        [bool]$ShowProgress = $true
    )

    Ensure-StorageDirectory
    $cachePath = Get-CachePath $Song.id $Stream.itag $Stream.mimeType

    $expectedLength = 0
    if ($Stream.contentLength) {
        try { $expectedLength = [int64]$Stream.contentLength } catch { $expectedLength = 0 }
    }
    if ($expectedLength -le 0) {
        $expectedLength = Get-ContentLengthFromUrl $Stream.url
    }

    if ((Test-Path $cachePath) -and $expectedLength -gt 0) {
        $existingLength = (Get-Item $cachePath).Length
        if ($existingLength -eq $expectedLength) {
            Write-Log "Using cached audio file: $cachePath"
            return $cachePath
        }
    }

    if (Test-Path $cachePath) {
        Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
    }

    if ($expectedLength -le 0) {
        throw "Could not determine stream content length"
    }

    $script:State.StatusMessage = "Downloading audio..."
    if ($ShowProgress) {
        try { Render-UI } catch { Write-Log "Render failed while downloading audio" "WARN" $_ }
    }

    Write-Log "Downloading stream to cache: path=$cachePath, bytes=$expectedLength, chunkSize=$($script:Config.DownloadChunkSize)"

    $start = [int64]0
    while ($start -lt $expectedLength) {
        $end = [Math]::Min($start + [int64]$script:Config.DownloadChunkSize - 1, $expectedLength - 1)
        Copy-HttpRangeToFile $Stream.url $cachePath $start $end $Stream.userAgent
        $start = $end + 1

        $percent = [Math]::Floor(($start / $expectedLength) * 100)
        $script:State.StatusMessage = "Downloading audio... $percent%"
        if ($ShowProgress) {
            try { Render-UI } catch { }
        }
    }

    $actualLength = (Get-Item $cachePath).Length
    if ($actualLength -ne $expectedLength) {
        throw "Cached file size mismatch. Expected $expectedLength bytes, got $actualLength bytes"
    }

    Write-Log "Cached audio file complete: $cachePath"
    return $cachePath
}

function Get-Recommendations {
    param([string]$VideoId)

    $body = @{
        videoId = $VideoId
        isAudioOnly = $true
    }

    $response = Invoke-WebRequest-YTMusic "next" $body

    if (-not $response) { return @() }

    $recommendations = New-Object System.Collections.ArrayList

    $tabs = $response.contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs
    if (-not $tabs) { return @() }

    $queueTab = $tabs[0]
    $contents = $queueTab.tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer.contents

    if (-not $contents) { return @() }

    $skipFirst = $true
    foreach ($item in $contents) {
        $renderer = $item.playlistPanelVideoRenderer
        if (-not $renderer) { continue }

        if ($skipFirst) {
            $skipFirst = $false
            continue
        }

        $id = $renderer.videoId
        if (-not $id) { continue }

        $title = ""
        if ($renderer.title.runs) {
            $title = ($renderer.title.runs | ForEach-Object { $_.text }) -join ""
        }

        $artist = ""
        if ($renderer.shortBylineText.runs) {
            $artist = ($renderer.shortBylineText.runs | ForEach-Object { $_.text }) -join ""
        }

        $album = ""
        if ($renderer.longBylineText.runs) {
            $runs = $renderer.longBylineText.runs
            for ($i = 0; $i -lt $runs.Count; $i++) {
                if ($runs[$i].navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType -eq "MUSIC_PAGE_TYPE_ALBUM") {
                    $album = $runs[$i].text
                    break
                }
            }
        }

        $duration = 0
        if ($renderer.lengthText.runs) {
            $timeStr = $renderer.lengthText.runs[0].text
            $timeParts = $timeStr -split ":"
            if ($timeParts.Count -eq 2) {
                $duration = [int]$timeParts[0] * 60 + [int]$timeParts[1]
            } elseif ($timeParts.Count -eq 3) {
                $duration = [int]$timeParts[0] * 3600 + [int]$timeParts[1] * 60 + [int]$timeParts[2]
            }
        }

        $thumbnail = ""
        if ($renderer.thumbnail.thumbnails) {
            $thumbnail = $renderer.thumbnail.thumbnails[-1].url
        }

        $song = @{
            id = $id
            title = $title
            artist = $artist
            album = $album
            duration = $duration
            thumbnail = $thumbnail
            type = "song"
        }

        $recommendations.Add($song) | Out-Null

        if ($recommendations.Count -ge 25) { break }
    }

    return $recommendations
}

#endregion

#region ==================== AUDIO ENGINE ====================

function Initialize-Player {
    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        $script:State.Player = New-Object System.Windows.Media.MediaPlayer
        $script:State.PlayerBackend = "WPF"
        Set-PlayerVolumeInternal $script:State.Volume
        Write-Log "WPF MediaPlayer initialized"
        return $true
    } catch {
        Write-Log "WPF MediaPlayer initialization failed; trying Windows Media Player COM" "WARN" $_
    }

    try {
        $script:State.Player = New-Object -ComObject WMPlayer.OCX
        $script:State.PlayerBackend = "WMP"
        Set-PlayerVolumeInternal $script:State.Volume
        Write-Log "Windows Media Player COM initialized"
        return $true
    } catch {
        $script:State.StatusMessage = "Failed to initialize audio player"
        Write-Log "All audio player backends failed" "ERROR" $_
        return $false
    }
}

function Set-PlayerVolumeInternal {
    param([int]$Volume)

    if (-not $script:State.Player) { return }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            $script:State.Player.Volume = [Math]::Max(0, [Math]::Min(1, $Volume / 100))
        } else {
            $script:State.Player.settings.volume = $Volume
        }
    } catch {
        Write-Log "Failed to set player volume" "WARN" $_
    }
}

function Open-PlayerUrlInternal {
    param([string]$Url)

    if ($script:State.PlayerBackend -eq "WPF") {
        $sourceUri = if (Test-Path $Url) {
            New-Object System.Uri((Resolve-Path $Url).ProviderPath)
        } else {
            New-Object System.Uri($Url)
        }
        $script:State.Player.Open($sourceUri)
        $script:State.Player.Play()
    } else {
        $script:State.Player.URL = if (Test-Path $Url) { (Resolve-Path $Url).ProviderPath } else { $Url }
        $script:State.Player.controls.play()
    }
}

function Play-PlayerInternal {
    if (-not $script:State.Player) { return }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            $script:State.Player.Play()
        } else {
            $script:State.Player.controls.play()
        }
    } catch {
        Write-Log "Failed to resume player" "WARN" $_
    }
}

function Pause-PlayerInternal {
    if (-not $script:State.Player) { return }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            $script:State.Player.Pause()
        } else {
            $script:State.Player.controls.pause()
        }
    } catch {
        Write-Log "Failed to pause player" "WARN" $_
    }
}

function Stop-PlayerInternal {
    if (-not $script:State.Player) { return }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            $script:State.Player.Stop()
        } else {
            $script:State.Player.controls.stop()
        }
    } catch {
        Write-Log "Failed to stop player backend" "WARN" $_
    }
}

function Get-PlayerPositionInternal {
    if (-not $script:State.Player) { return 0 }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            return [int]$script:State.Player.Position.TotalSeconds
        }

        return $script:State.Player.controls.currentPosition
    } catch {
        Write-Log "Failed to read player position" "WARN" $_
        return 0
    }
}

function Set-PlayerPositionInternal {
    param([double]$Seconds)

    if (-not $script:State.Player) { return }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            $script:State.Player.Position = [TimeSpan]::FromSeconds($Seconds)
        } else {
            $script:State.Player.controls.currentPosition = $Seconds
        }
    } catch {
        Write-Log "Failed to set player position" "WARN" $_
    }
}

function Get-PlayerDurationInternal {
    if (-not $script:State.Player) { return 0 }

    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            if ($script:State.Player.NaturalDuration.HasTimeSpan) {
                return [int]$script:State.Player.NaturalDuration.TimeSpan.TotalSeconds
            }
            return 0
        }

        if ($script:State.Player.currentMedia) {
            return $script:State.Player.currentMedia.duration
        }

        return 0
    } catch {
        Write-Log "Failed to read player duration" "WARN" $_
        return 0
    }
}

function Start-Playback {
    param([object]$Song)

    if (-not $Song) { return $false }

    $script:State.StatusMessage = "Loading: $($Song.title)..."
    Write-Log "Starting playback: title=$($Song.title), artist=$($Song.artist), id=$($Song.id)"
    try { Render-UI } catch { Write-Log "Render failed while starting playback" "WARN" $_ }

    $stream = Get-StreamUrl $Song.id
    if (-not $stream) {
        Write-Log "No stream returned for $($Song.id)" "ERROR"
        return $false
    }

    if (-not $script:State.Player) {
        if (-not (Initialize-Player)) {
            return $false
        }
    }

    try {
        $playbackSource = Save-StreamToCache $Song $stream
    } catch {
        $script:State.StatusMessage = "Download error: $($_.Exception.Message)"
        Write-Log "Failed to download stream before playback" "ERROR" $_
        return $false
    }

    try {
        try {
            Stop-PlayerInternal
        } catch {
            Write-Log "Could not stop previous media before playback" "WARN" $_
        }

        Open-PlayerUrlInternal $playbackSource
        $script:State.CurrentSong = $Song
        $script:State.IsPlaying = $true
        $script:State.StatusMessage = "Now playing"

        Add-ToHistory $Song
        Write-Log "Playback handed to $($script:State.PlayerBackend): source=$playbackSource, itag=$($stream.itag), mime=$($stream.mimeType)"

        Start-Sleep -Milliseconds 250
        try {
            $playState = Get-PlaybackState
            Write-Log "$($script:State.PlayerBackend) state after play(): $playState"

            if ($script:State.PlayerBackend -eq "WMP" -and $script:State.Player.error -and $script:State.Player.error.errorCount -gt 0) {
                $wmpError = $script:State.Player.error.item(0).errorDescription
                $script:State.StatusMessage = "Player error: $wmpError"
                Write-Log "Windows Media Player reported error: $wmpError" "ERROR"
                return $false
            }
        } catch {
            Write-Log "Could not inspect Windows Media Player state after play" "WARN" $_
        }

        return $true
    } catch {
        $script:State.StatusMessage = "Playback error: $($_.Exception.Message)"
        Write-Log "Playback failed after stream resolution" "ERROR" $_
        return $false
    }
}

function Stop-Playback {
    if ($script:State.Player) {
        try {
            Stop-PlayerInternal
        } catch {
            Write-Log "Failed to stop playback" "WARN" $_
        }
    }
    $script:State.IsPlaying = $false
}

function Toggle-PlayPause {
    if (-not $script:State.CurrentSong) { return }

    if ($script:State.IsPlaying) {
        Pause-PlayerInternal
        $script:State.IsPlaying = $false
        $script:State.StatusMessage = "Paused"
    } else {
        Play-PlayerInternal
        $script:State.IsPlaying = $true
        $script:State.StatusMessage = "Playing"
    }
}

function Seek-Position {
    param([int]$Seconds)

    if (-not $script:State.Player) { return }
    if (-not $script:State.CurrentSong) { return }

    $current = Get-PlayerPositionInternal
    $duration = $script:State.CurrentSong.duration
    if ($duration -le 0) {
        $duration = Get-PlayerDurationInternal
    }

    $newPos = $current + $Seconds
    $newPos = [math]::Max(0, [math]::Min($newPos, $duration - 1))

    Set-PlayerPositionInternal $newPos
}

function Set-Volume {
    param([int]$Delta)

    $script:State.Volume = [math]::Max(0, [math]::Min(100, $script:State.Volume + $Delta))

    if ($script:State.Player) {
        Set-PlayerVolumeInternal $script:State.Volume
    }

    $script:Settings.volume = $script:State.Volume
    $script:State.StatusMessage = "Volume: $($script:State.Volume)%"
}

function Get-PlaybackPosition {
    if (-not $script:State.Player) { return 0 }
    try {
        return Get-PlayerPositionInternal
    } catch {
        return 0
    }
}

function Get-PlaybackState {
    if (-not $script:State.Player) { return "stopped" }
    try {
        if ($script:State.PlayerBackend -eq "WPF") {
            if (-not $script:State.CurrentSong) { return "stopped" }
            if ($script:State.IsPlaying) { return "playing" }
            return "paused"
        }

        $state = $script:State.Player.playState
        switch ($state) {
            1 { return "stopped" }
            2 { return "paused" }
            3 { return "playing" }
            6 { return "buffering" }
            10 { return "ended" }
            default { return "unknown" }
        }
    } catch {
        return "unknown"
    }
}

function Check-PlaybackEnd {
    if ($script:State.PlayerBackend -eq "WPF" -and $script:State.IsPlaying -and $script:State.CurrentSong) {
        $duration = $script:State.CurrentSong.duration
        if ($duration -le 0) { $duration = Get-PlayerDurationInternal }
        $position = Get-PlaybackPosition
        if ($duration -gt 0 -and $position -ge ($duration - 1)) {
            Handle-SongEnd
            return
        }
    }

    $state = Get-PlaybackState

    if ($state -eq "ended" -or ($state -eq "stopped" -and $script:State.IsPlaying)) {
        Handle-SongEnd
    }
}

function Handle-SongEnd {
    $script:State.IsPlaying = $false

    switch ($script:State.RepeatMode) {
        "one" {
            if ($script:State.CurrentSong) {
                Start-Playback $script:State.CurrentSong
            }
        }
        "all" {
            Skip-Next
        }
        default {
            if ($script:State.QueueIndex -lt ($script:State.Queue.Count - 1)) {
                Skip-Next
            } elseif ($script:Settings.autoRecommendations -and $script:State.CurrentSong) {
                Load-Recommendations
                if ($script:State.Queue.Count -gt $script:State.QueueIndex + 1) {
                    Skip-Next
                }
            }
        }
    }
}

#endregion

#region ==================== QUEUE SYSTEM ====================

function Add-ToQueue {
    param(
        [object]$Song,
        [switch]$PlayNow,
        [switch]$PlayNext
    )

    if ($PlayNext -and $script:State.Queue.Count -gt 0) {
        $insertIndex = $script:State.QueueIndex + 1
        $script:State.Queue.Insert($insertIndex, $Song)
        $script:State.StatusMessage = "Added to play next: $($Song.title)"
    } else {
        $script:State.Queue.Add($Song) | Out-Null
        $script:State.StatusMessage = "Added to queue: $($Song.title)"
    }

    if ($PlayNow -or $script:State.Queue.Count -eq 1) {
        $script:State.QueueIndex = $script:State.Queue.Count - 1
        if ($PlayNow) {
            $script:State.QueueIndex = $script:State.Queue.IndexOf($Song)
        }
        Start-Playback $Song
    }

    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
    }
}

function Remove-FromQueue {
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $script:State.Queue.Count) { return }

    $script:State.Queue.RemoveAt($Index)

    if ($Index -lt $script:State.QueueIndex) {
        $script:State.QueueIndex--
    } elseif ($Index -eq $script:State.QueueIndex) {
        if ($script:State.QueueIndex -ge $script:State.Queue.Count) {
            $script:State.QueueIndex = [math]::Max(0, $script:State.Queue.Count - 1)
        }
        if ($script:State.Queue.Count -gt 0) {
            Start-Playback $script:State.Queue[$script:State.QueueIndex]
        } else {
            Stop-Playback
            $script:State.CurrentSong = $null
        }
    }

    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
    }
}

function Clear-Queue {
    Stop-Playback
    $script:State.Queue.Clear()
    $script:State.QueueIndex = 0
    $script:State.CurrentSong = $null
    $script:State.StatusMessage = "Queue cleared"
}

function Skip-Next {
    if ($script:State.Queue.Count -eq 0) { return }

    $nextIndex = $script:State.QueueIndex + 1

    if ($script:State.ShuffleMode -and $script:State.ShuffleOrder.Count -gt 0) {
        $currentShufflePos = $script:State.ShuffleOrder.IndexOf($script:State.QueueIndex)
        if ($currentShufflePos -lt $script:State.ShuffleOrder.Count - 1) {
            $nextIndex = $script:State.ShuffleOrder[$currentShufflePos + 1]
        } elseif ($script:State.RepeatMode -eq "all") {
            $nextIndex = $script:State.ShuffleOrder[0]
        } else {
            return
        }
    } else {
        if ($nextIndex -ge $script:State.Queue.Count) {
            if ($script:State.RepeatMode -eq "all") {
                $nextIndex = 0
            } elseif ($script:Settings.autoRecommendations -and $script:State.CurrentSong) {
                Load-Recommendations
                $nextIndex = $script:State.QueueIndex + 1
                if ($nextIndex -ge $script:State.Queue.Count) { return }
            } else {
                return
            }
        }
    }

    $script:State.QueueIndex = $nextIndex
    Start-Playback $script:State.Queue[$nextIndex]
}

function Skip-Previous {
    if ($script:State.Queue.Count -eq 0) { return }

    $position = Get-PlaybackPosition
    if ($position -gt 3) {
        Set-PlayerPositionInternal 0
        return
    }

    $prevIndex = $script:State.QueueIndex - 1

    if ($script:State.ShuffleMode -and $script:State.ShuffleOrder.Count -gt 0) {
        $currentShufflePos = $script:State.ShuffleOrder.IndexOf($script:State.QueueIndex)
        if ($currentShufflePos -gt 0) {
            $prevIndex = $script:State.ShuffleOrder[$currentShufflePos - 1]
        } elseif ($script:State.RepeatMode -eq "all") {
            $prevIndex = $script:State.ShuffleOrder[-1]
        } else {
            Set-PlayerPositionInternal 0
            return
        }
    } else {
        if ($prevIndex -lt 0) {
            if ($script:State.RepeatMode -eq "all") {
                $prevIndex = $script:State.Queue.Count - 1
            } else {
                Set-PlayerPositionInternal 0
                return
            }
        }
    }

    $script:State.QueueIndex = $prevIndex
    Start-Playback $script:State.Queue[$prevIndex]
}

function Toggle-Repeat {
    switch ($script:State.RepeatMode) {
        "off" {
            $script:State.RepeatMode = "all"
            $script:State.StatusMessage = "Repeat: All"
        }
        "all" {
            $script:State.RepeatMode = "one"
            $script:State.StatusMessage = "Repeat: One"
        }
        "one" {
            $script:State.RepeatMode = "off"
            $script:State.StatusMessage = "Repeat: Off"
        }
    }
    $script:Settings.repeatMode = $script:State.RepeatMode
}

function Toggle-Shuffle {
    $script:State.ShuffleMode = -not $script:State.ShuffleMode
    $script:Settings.shuffleEnabled = $script:State.ShuffleMode

    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
        $script:State.StatusMessage = "Shuffle: On"
    } else {
        $script:State.ShuffleOrder = @()
        $script:State.StatusMessage = "Shuffle: Off"
    }
}

function Update-ShuffleOrder {
    if ($script:State.Queue.Count -eq 0) {
        $script:State.ShuffleOrder = @()
        return
    }

    $indices = 0..($script:State.Queue.Count - 1) | Where-Object { $_ -ne $script:State.QueueIndex }
    $shuffled = $indices | Sort-Object { Get-Random }
    $script:State.ShuffleOrder = @($script:State.QueueIndex) + $shuffled
}

function Load-Recommendations {
    if (-not $script:State.CurrentSong) { return }

    $script:State.StatusMessage = "Loading recommendations..."
    Render-UI

    $recs = Get-Recommendations $script:State.CurrentSong.id

    $existingIds = $script:State.Queue | ForEach-Object { $_.id }
    $newRecs = $recs | Where-Object { $_.id -notin $existingIds }

    foreach ($rec in $newRecs) {
        $script:State.Queue.Add($rec) | Out-Null
    }

    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
    }

    $script:State.StatusMessage = "Added $($newRecs.Count) recommendations"
}

function Play-SearchResult {
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $script:State.SearchResults.Count) { return }

    $song = $script:State.SearchResults[$Index]

    Clear-Queue

    foreach ($result in $script:State.SearchResults) {
        $script:State.Queue.Add($result) | Out-Null
    }

    $script:State.QueueIndex = $Index
    $script:State.CurrentView = "player"

    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
    }

    if (-not (Start-Playback $song)) {
        Write-Log "Play-SearchResult failed for index=$Index videoId=$($song.id)" "ERROR"
    }
}

#endregion

#region ==================== TUI RENDERING ====================

function Clear-Screen {
    try {
        [Console]::Clear()
        [Console]::SetCursorPosition(0, 0)
    } catch {
        Write-Log "Console clear failed" "WARN" $_
    }
}

function Hide-Cursor {
    try { [Console]::CursorVisible = $false } catch { }
}

function Show-Cursor {
    try { [Console]::CursorVisible = $true } catch { }
}

function Render-UI {
    try {
        $width = [Math]::Max(40, [Math]::Min([Console]::WindowWidth, 80))
        [Console]::SetCursorPosition(0, 0)
    } catch {
        Write-Log "Console cursor reset failed" "WARN" $_
        return
    }

    switch ($script:State.CurrentView) {
        "player" { Render-PlayerView $width }
        "search" { Render-SearchView $width }
        "queue" { Render-QueueView $width }
        "help" { Render-HelpView $width }
    }
}

function Render-Header {
    param([int]$Width)

    $title = " METROTUBE v$($script:Config.Version) "
    $help = "[?] Help "
    $padding = $Width - $title.Length - $help.Length - 4

    Write-Color ("+" + ("=" * ($Width - 2)) + "+") Cyan
    Write-Color -NoNewline "|" Cyan
    Write-Color -NoNewline $title Yellow
    Write-Color -NoNewline (" " * [Math]::Max(0, $padding)) White
    Write-Color -NoNewline $help DarkGray
    Write-Color "|" Cyan
    Write-Color ("+" + ("-" * ($Width - 2)) + "+") Cyan
}

function Render-PlayerView {
    param([int]$Width)

    Clear-Screen
    Render-Header $Width

    Write-Host ""

    if ($script:State.CurrentSong) {
        $song = $script:State.CurrentSong
        $position = Get-PlaybackPosition
        $duration = $song.duration
        if ($duration -le 0) {
            $duration = Get-PlayerDurationInternal
        }

        $isFav = Is-Favorite $song.id
        $favIcon = if ($isFav) { "[FAV]" } else { "     " }

        $titleLine = "  $(Truncate-String $song.title ($Width - 10))"
        $artistLine = "  $(Truncate-String $song.artist ($Width - 10))"
        $albumLine = "  $(Truncate-String $song.album ($Width - 10))"

        Write-Color "  NOW PLAYING $favIcon" Cyan
        Write-Host ""
        Write-Color $titleLine White
        Write-Color $artistLine Green
        Write-Color $albumLine DarkGray
        Write-Host ""

        $posStr = Format-Duration ([int]$position)
        $durStr = Format-Duration ([int]$duration)
        $barWidth = [Math]::Max(10, $Width - $posStr.Length - $durStr.Length - 8)
        $progressBar = Get-ProgressBar $position $duration $barWidth

        Write-Color -NoNewline "  $posStr " DarkGray
        Write-Color -NoNewline $progressBar White
        Write-Color " $durStr" DarkGray

        Write-Host ""

        $playIcon = if ($script:State.IsPlaying) { "||" } else { ">>" }
        $repeatIcon = switch ($script:State.RepeatMode) {
            "one" { "[R1]" }
            "all" { "[RA]" }
            default { "[R-]" }
        }
        $shuffleIcon = if ($script:State.ShuffleMode) { "[S+]" } else { "[S-]" }

        $controls = "  |<<  $playIcon  >>|  $repeatIcon  $shuffleIcon"
        Write-Color $controls Yellow

        Write-Host ""

        $volBar = Get-VolumeBar $script:State.Volume
        Write-Color "  Volume: $volBar $($script:State.Volume)%" DarkGray

    } else {
        Write-Host ""
        Write-Color "  No song playing" DarkGray
        Write-Color "  Press [S] to search for music" DarkGray
        Write-Host ""
    }

    Write-Host ""
    Write-Color ("+" + ("-" * ($Width - 2)) + "+") Cyan

    Write-Color "  QUEUE ($($script:State.Queue.Count) songs)" Cyan
    Write-Host ""

    $startIdx = [Math]::Max(0, $script:State.QueueIndex - 1)
    $endIdx = [Math]::Min($script:State.Queue.Count - 1, $startIdx + 4)

    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $qSong = $script:State.Queue[$i]
        $prefix = if ($i -eq $script:State.QueueIndex) { " >> " } else { "    " }
        $num = ($i + 1).ToString().PadLeft(2)
        $title = Truncate-String $qSong.title ($Width - 30)
        $artist = Truncate-String $qSong.artist 15
        $dur = Format-Duration $qSong.duration

        $line = "$prefix$num. $title"
        $color = if ($i -eq $script:State.QueueIndex) { "Cyan" } else { "White" }
        Write-Color -NoNewline $line $color
        Write-Color " - $artist" Green -NoNewline
        Write-Color " [$dur]" DarkGray
    }

    if ($script:State.Queue.Count -eq 0) {
        Write-Color "    Queue is empty" DarkGray
    }

    Write-Host ""
    Write-Color ("+" + ("-" * ($Width - 2)) + "+") Cyan

    if ($script:State.StatusMessage) {
        Write-Color "  $($script:State.StatusMessage)" Magenta
    }

    Write-Host ""
    Write-Color "  [Space] Play/Pause  [N] Next  [P] Prev  [S] Search  [Q] Queue  [Esc] Exit" DarkGray
}

function Render-SearchView {
    param([int]$Width)

    Clear-Screen
    Render-Header $Width

    Write-Host ""
    Write-Color "  SEARCH" Cyan
    Write-Host ""
    Write-Color -NoNewline "  > " Yellow
    Write-Color $script:State.SearchQuery White
    Write-Host ""

    if ($script:State.SearchResults.Count -gt 0) {
        Write-Color "  Results:" DarkGray
        Write-Host ""

        for ($i = 0; $i -lt [Math]::Min(10, $script:State.SearchResults.Count); $i++) {
            $song = $script:State.SearchResults[$i]
            $num = ($i + 1).ToString()
            if ($i -eq 9) { $num = "0" }

            $title = Truncate-String $song.title ($Width - 30)
            $artist = Truncate-String $song.artist 20
            $dur = Format-Duration $song.duration

            Write-Color -NoNewline "  [$num] " Yellow
            Write-Color -NoNewline $title White
            Write-Color -NoNewline " - " DarkGray
            Write-Color -NoNewline $artist Green
            Write-Color " $dur" DarkGray
        }
    } elseif ($script:State.SearchQuery -and -not $script:State.IsSearching) {
        Write-Color "  No results found" DarkGray
    }

    Write-Host ""
    Write-Color ("+" + ("-" * ($Width - 2)) + "+") Cyan

    if ($script:State.StatusMessage) {
        Write-Color "  $($script:State.StatusMessage)" Magenta
    }

    Write-Host ""
    Write-Color "  [1-0] Play  [Enter] Search / Play first result  [Esc] Back" DarkGray
}

function Render-QueueView {
    param([int]$Width)

    Clear-Screen
    Render-Header $Width

    Write-Host ""
    Write-Color "  QUEUE ($($script:State.Queue.Count) songs)" Cyan
    Write-Host ""

    if ($script:State.Queue.Count -eq 0) {
        Write-Color "  Queue is empty. Search for songs to add." DarkGray
    } else {
        $displayCount = [Math]::Min(15, $script:State.Queue.Count)

        for ($i = 0; $i -lt $displayCount; $i++) {
            $song = $script:State.Queue[$i]
            $prefix = if ($i -eq $script:State.QueueIndex) { " >> " } else { "    " }
            $num = ($i + 1).ToString().PadLeft(2)
            $title = Truncate-String $song.title ($Width - 35)
            $artist = Truncate-String $song.artist 15
            $dur = Format-Duration $song.duration

            $color = if ($i -eq $script:State.QueueIndex) { "Cyan" } else { "White" }

            Write-Color -NoNewline "$prefix$num. " $color
            Write-Color -NoNewline $title $color
            Write-Color -NoNewline " - " DarkGray
            Write-Color -NoNewline $artist Green
            Write-Color " [$dur]" DarkGray
        }

        if ($script:State.Queue.Count -gt $displayCount) {
            Write-Host ""
            Write-Color "  ... and $($script:State.Queue.Count - $displayCount) more" DarkGray
        }
    }

    Write-Host ""
    Write-Color ("+" + ("-" * ($Width - 2)) + "+") Cyan

    $repeatIcon = switch ($script:State.RepeatMode) {
        "one" { "Repeat: One" }
        "all" { "Repeat: All" }
        default { "Repeat: Off" }
    }
    $shuffleIcon = if ($script:State.ShuffleMode) { "Shuffle: On" } else { "Shuffle: Off" }

    Write-Color "  $repeatIcon | $shuffleIcon" Magenta

    Write-Host ""
    Write-Color "  [C] Clear  [R] Repeat  [Z] Shuffle  [Esc] Back" DarkGray
}

function Render-HelpView {
    param([int]$Width)

    Clear-Screen
    Render-Header $Width

    Write-Host ""
    Write-Color "  KEYBOARD CONTROLS" Cyan
    Write-Host ""

    $controls = @(
        @("Space", "Play / Pause"),
        @("N", "Next track"),
        @("P", "Previous track / Restart"),
        @("Right Arrow", "Seek forward 10s"),
        @("Left Arrow", "Seek backward 10s"),
        @("Up Arrow", "Volume up"),
        @("Down Arrow", "Volume down"),
        @("L", "Like / Unlike current song"),
        @("S", "Search"),
        @("Q", "Show queue"),
        @("R", "Toggle repeat (Off/All/One)"),
        @("Z", "Toggle shuffle"),
        @("F", "Show favorites"),
        @("H", "Show history"),
        @("?", "Show this help"),
        @("Esc", "Back / Exit")
    )

    foreach ($ctrl in $controls) {
        Write-Color -NoNewline ("  [{0}]" -f $ctrl[0]).PadRight(18) Yellow
        Write-Color $ctrl[1] White
    }

    Write-Host ""
    Write-Color ("+" + ("-" * ($Width - 2)) + "+") Cyan
    Write-Host ""
    Write-Color "  MetroTube v$($script:Config.Version) - Terminal YouTube Music Player" DarkGray
    Write-Color "  Uses InnerTube API (same as Metrolist Android app)" DarkGray
    Write-Host ""
    Write-Color "  [Esc] Back" DarkGray
}

#endregion

#region ==================== INPUT HANDLING ====================

function Read-KeyNonBlocking {
    try {
        if ([Console]::KeyAvailable) {
            return [Console]::ReadKey($true)
        }
    } catch {
        Write-Log "Console input read failed" "WARN" $_
    }
    return $null
}

function Handle-Input {
    $key = Read-KeyNonBlocking
    if (-not $key) { return }

    switch ($script:State.CurrentView) {
        "player" { return (Handle-PlayerInput $key) }
        "search" { return (Handle-SearchInput $key) }
        "queue" { return (Handle-QueueInput $key) }
        "help" { return (Handle-HelpInput $key) }
    }
}

function Handle-PlayerInput {
    param($key)

    switch ($key.Key) {
        "Spacebar" { Toggle-PlayPause }
        "N" { Skip-Next }
        "P" { Skip-Previous }
        "RightArrow" { Seek-Position 10 }
        "LeftArrow" { Seek-Position -10 }
        "UpArrow" { Set-Volume 5 }
        "DownArrow" { Set-Volume -5 }
        "L" { Toggle-Favorite }
        "S" {
            $script:State.CurrentView = "search"
            $script:State.SearchQuery = ""
            $script:State.SearchResults = @()
        }
        "Q" { $script:State.CurrentView = "queue" }
        "R" { Toggle-Repeat }
        "Z" { Toggle-Shuffle }
        "F" { Play-Favorites }
        "H" { Play-History }
        "OemQuestion" { $script:State.CurrentView = "help" }
        "Escape" {
            Save-QueueState
            Save-Settings
            return "exit"
        }
    }
}

function Handle-SearchInput {
    param($key)

    switch ($key.Key) {
        "Escape" {
            $script:State.CurrentView = "player"
        }
        "Enter" {
            if ($script:State.SearchResults.Count -gt 0 -and $script:State.SearchQuery -eq $script:State.LastSearchQuery) {
                Play-SearchResult 0
            } elseif ($script:State.SearchQuery.Length -gt 0) {
                $script:State.IsSearching = $true
                $script:State.StatusMessage = "Searching..."
                Render-UI
                $script:State.SearchResults = Search-Songs $script:State.SearchQuery "songs"
                $script:State.LastSearchQuery = $script:State.SearchQuery
                $script:State.IsSearching = $false
                $script:State.StatusMessage = "Found $($script:State.SearchResults.Count) results"
            }
        }
        "Backspace" {
            if ($script:State.SearchQuery.Length -gt 0) {
                $script:State.SearchQuery = $script:State.SearchQuery.Substring(0, $script:State.SearchQuery.Length - 1)
            }
        }
        "D1" { Play-SearchResult 0 }
        "D2" { Play-SearchResult 1 }
        "D3" { Play-SearchResult 2 }
        "D4" { Play-SearchResult 3 }
        "D5" { Play-SearchResult 4 }
        "D6" { Play-SearchResult 5 }
        "D7" { Play-SearchResult 6 }
        "D8" { Play-SearchResult 7 }
        "D9" { Play-SearchResult 8 }
        "D0" { Play-SearchResult 9 }
        default {
            $char = $key.KeyChar
            if ($char -and ([char]::IsLetterOrDigit($char) -or $char -eq ' ' -or $char -eq '-' -or $char -eq "'")) {
                $script:State.SearchQuery += $char
            }
        }
    }
}

function Handle-QueueInput {
    param($key)

    switch ($key.Key) {
        "Escape" { $script:State.CurrentView = "player" }
        "C" { Clear-Queue }
        "R" { Toggle-Repeat }
        "Z" { Toggle-Shuffle }
        "Spacebar" { Toggle-PlayPause }
        "N" { Skip-Next }
        "P" { Skip-Previous }
    }
}

function Handle-HelpInput {
    param($key)

    if ($key.Key -eq "Escape" -or $key.Key -eq "OemQuestion") {
        $script:State.CurrentView = "player"
    }
}

function Play-Favorites {
    if ($script:Favorites.songs.Count -eq 0) {
        $script:State.StatusMessage = "No favorites yet"
        return
    }

    Clear-Queue
    foreach ($song in $script:Favorites.songs) {
        $script:State.Queue.Add($song) | Out-Null
    }

    $script:State.QueueIndex = 0
    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
    }

    if (Start-Playback $script:State.Queue[0]) {
        $script:State.StatusMessage = "Playing favorites"
    }
}

function Play-History {
    if ($script:History.songs.Count -eq 0) {
        $script:State.StatusMessage = "No history yet"
        return
    }

    Clear-Queue
    foreach ($song in $script:History.songs) {
        $script:State.Queue.Add($song) | Out-Null
    }

    $script:State.QueueIndex = 0
    if ($script:State.ShuffleMode) {
        Update-ShuffleOrder
    }

    if (Start-Playback $script:State.Queue[0]) {
        $script:State.StatusMessage = "Playing history"
    }
}

#endregion

#region ==================== MAIN ====================

function Main {
    # Handle test mode first
    if ($Test) {
        Test-API
        return
    }

    Initialize-Storage
    Load-Settings
    Load-Favorites
    Load-History

    if (-not (Initialize-Player)) {
        Write-Color "Failed to initialize audio player. Exiting." Red
        return
    }

    Hide-Cursor
    Clear-Screen

    if ($Resume) {
        Load-QueueState
        if ($script:State.Queue.Count -gt 0 -and $script:State.QueueIndex -lt $script:State.Queue.Count) {
            $script:State.CurrentSong = $script:State.Queue[$script:State.QueueIndex]
            Start-Playback $script:State.CurrentSong
            if ($script:State.LastPosition -gt 0) {
                Start-Sleep -Milliseconds 500
                Set-PlayerPositionInternal $script:State.LastPosition
            }
        }
    }

    if ($PlayFavorites) {
        Play-Favorites
    }

    if ($Search) {
        $script:State.CurrentView = "search"
        $script:State.SearchQuery = $Search
        $script:State.SearchResults = Search-Songs $Search "songs"
        $script:State.LastSearchQuery = $Search
        if ($script:State.SearchResults.Count -gt 0) {
            Play-SearchResult 0
        }
    }

    $lastRender = [DateTime]::MinValue
    $running = $true

    while ($running) {
        $result = Handle-Input
        if ($result -eq "exit") {
            $running = $false
            continue
        }

        Check-PlaybackEnd

        $now = [DateTime]::Now
        if (($now - $lastRender).TotalMilliseconds -ge $script:Config.RefreshInterval) {
            Render-UI
            $lastRender = $now
        }

        Start-Sleep -Milliseconds 50
    }

    Stop-Playback
    Show-Cursor
    Clear-Screen
    Write-Color "Thanks for using MetroTube!" Cyan
}

try {
    Main
} catch {
    Show-Cursor
    try { Stop-Playback } catch { }
    Write-Log "Unhandled crash" "ERROR" $_

    Write-Host ""
    Write-Host "MetroTube crashed, but the error was saved for diagnosis." -ForegroundColor Red
    Write-Host "Log file: $($script:Config.LogPath)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ($_.Exception.Message) -ForegroundColor Red
    Write-Host ""

    try {
        Read-Host "Press Enter to close"
    } catch { }
} finally {
    Show-Cursor
}

#endregion
