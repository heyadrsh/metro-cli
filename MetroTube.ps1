<#
.SYNOPSIS
    MetroTube - Terminal YouTube Music Player for Windows
.DESCRIPTION
    A full-featured YouTube Music client that runs entirely in PowerShell.
    Uses the InnerTube API (same as the Metrolist Android app).
    Zero external dependencies - just run it.
.PARAMETER Search
    Initial search query to run on startup
.PARAMETER Favorites
    Start playing from favorites
.PARAMETER Resume
    Resume last session (queue and position)
.EXAMPLE
    .\MetroTube.ps1
    .\MetroTube.ps1 -Search "bohemian rhapsody"
    .\MetroTube.ps1 -Favorites
    .\MetroTube.ps1 -Resume
#>

param(
    [string]$Search,
    [switch]$Favorites,
    [switch]$Resume,
    [switch]$Test
)

#region ==================== CONFIGURATION ====================

$script:Config = @{
    AppName = "MetroTube"
    Version = "1.0.1"
    BaseUrl = "https://music.youtube.com/youtubei/v1"
    StoragePath = "$env:APPDATA\MetroTube"

    # WEB_REMIX client for search (returns YouTube Music format)
    WebClient = @{
        clientName = "WEB_REMIX"
        clientVersion = "1.20240101.01.00"
        gl = "US"
        hl = "en"
    }

    # ANDROID_VR client for player (returns direct URLs without cipher)
    PlayerClient = @{
        clientName = "ANDROID_VR"
        clientVersion = "1.61.48"
        deviceMake = "Oculus"
        deviceModel = "Quest 3"
        osName = "Android"
        osVersion = "12"
        platform = "MOBILE"
        gl = "US"
        hl = "en"
    }

    WebUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    PlayerUserAgent = "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; Quest 3) gzip"

    ItagPriority = @(251, 140, 250, 249)

    RefreshInterval = 1000
}

$script:State = @{
    CurrentSong = $null
    Queue = [System.Collections.ArrayList]@()
    QueueIndex = 0
    IsPlaying = $false
    Volume = 80
    RepeatMode = "off"
    ShuffleMode = $false
    ShuffleOrder = @()
    CurrentView = "player"
    SearchResults = @()
    SearchQuery = ""
    IsSearching = $false
    StatusMessage = ""
    Player = $null
    LastPosition = 0
}

$script:Settings = @{
    volume = 80
    audioQuality = "high"
    repeatMode = "off"
    shuffleEnabled = $false
    colorEnabled = $true
    autoRecommendations = $true
}

$script:Favorites = @{ songs = [System.Collections.ArrayList]@() }
$script:History = @{ songs = [System.Collections.ArrayList]@() }
$script:Playlists = @{ playlists = [System.Collections.ArrayList]@() }

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

    if ($Text.Length -le $MaxLength) { return $Text }
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
    if (-not (Test-Path $script:Config.StoragePath)) {
        New-Item -ItemType Directory -Path $script:Config.StoragePath -Force | Out-Null
    }
}

function Get-StoragePath {
    param([string]$FileName)
    return Join-Path $script:Config.StoragePath $FileName
}

function Save-JsonFile {
    param(
        [string]$FileName,
        [object]$Data
    )

    $path = Get-StoragePath $FileName
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
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
    $queueState = @{
        queue = $script:State.Queue
        index = $script:State.QueueIndex
        position = if ($script:State.Player) { $script:State.Player.controls.currentPosition } else { 0 }
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
    return @{
        client = $script:Config.WebClient
        user = @{ lockedSafetyMode = $false }
        request = @{ useSsl = $true; internalExperimentFlags = @() }
    }
}

function Build-PlayerContext {
    return @{
        client = $script:Config.PlayerClient
        user = @{ lockedSafetyMode = $false }
        request = @{ useSsl = $true; internalExperimentFlags = @() }
    }
}

function Invoke-WebRequest-YTMusic {
    param(
        [string]$Endpoint,
        [hashtable]$Body
    )

    $url = "$($script:Config.BaseUrl)/$Endpoint"

    $fullBody = @{ context = Build-WebContext } + $Body
    $jsonBody = $fullBody | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        "Content-Type" = "application/json"
        "User-Agent" = $script:Config.WebUserAgent
        "Accept" = "application/json"
        "Accept-Language" = "en-US,en;q=0.9"
        "Referer" = "https://music.youtube.com/"
        "Origin" = "https://music.youtube.com"
    }

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonBody -ContentType "application/json"
        return $response
    } catch {
        $script:State.StatusMessage = "API Error: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-PlayerRequest {
    param(
        [string]$Endpoint,
        [hashtable]$Body
    )

    $url = "$($script:Config.BaseUrl)/$Endpoint"

    $fullBody = @{ context = Build-PlayerContext } + $Body
    $jsonBody = $fullBody | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        "Content-Type" = "application/json"
        "User-Agent" = $script:Config.PlayerUserAgent
        "Accept" = "application/json"
        "Accept-Language" = "en-US,en;q=0.9"
    }

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonBody -ContentType "application/json"
        return $response
    } catch {
        $script:State.StatusMessage = "API Error: $($_.Exception.Message)"
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

    # Test Player API
    Write-Host "2. Testing Player API (ANDROID_VR client)..." -ForegroundColor Yellow
    $playerBody = @{
        videoId = "dQw4w9WgXcQ"
        contentCheckOk = $true
        racyCheckOk = $true
    }
    $playerResponse = Invoke-PlayerRequest "player" $playerBody

    if ($playerResponse) {
        if ($playerResponse.playabilityStatus.status -eq "OK") {
            Write-Host "   [OK] Player API works!" -ForegroundColor Green
            $formats = $playerResponse.streamingData.adaptiveFormats
            $audioFormats = $formats | Where-Object { $_.mimeType -match "^audio/" -and $_.url }
            Write-Host "   Found $($audioFormats.Count) audio streams with direct URLs" -ForegroundColor Gray
            if ($audioFormats.Count -gt 0) {
                $best = $audioFormats | Sort-Object -Property bitrate -Descending | Select-Object -First 1
                Write-Host "   Best quality: itag=$($best.itag), bitrate=$($best.bitrate)bps" -ForegroundColor Gray
            }
        } else {
            Write-Host "   [FAIL] Playback status: $($playerResponse.playabilityStatus.status)" -ForegroundColor Red
            Write-Host "   Reason: $($playerResponse.playabilityStatus.reason)" -ForegroundColor Red
        }
    } else {
        Write-Host "   [FAIL] Player API failed" -ForegroundColor Red
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

    $results = [System.Collections.ArrayList]@()

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

    $suggestions = [System.Collections.ArrayList]@()

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

    $body = @{
        videoId = $VideoId
        contentCheckOk = $true
        racyCheckOk = $true
    }

    $response = Invoke-PlayerRequest "player" $body

    if (-not $response) { return $null }

    if ($response.playabilityStatus.status -ne "OK") {
        $reason = $response.playabilityStatus.reason
        if (-not $reason) { $reason = "Playback not allowed" }
        $script:State.StatusMessage = "Error: $reason"
        return $null
    }

    $formats = $response.streamingData.adaptiveFormats
    if (-not $formats) {
        $script:State.StatusMessage = "No audio formats available"
        return $null
    }

    $audioFormats = $formats | Where-Object {
        $_.mimeType -match "^audio/" -and $_.url
    }

    foreach ($itag in $script:Config.ItagPriority) {
        $format = $audioFormats | Where-Object { $_.itag -eq $itag } | Select-Object -First 1
        if ($format -and $format.url) {
            return @{
                url = $format.url
                itag = $format.itag
                bitrate = $format.bitrate
                mimeType = $format.mimeType
            }
        }
    }

    $bestFormat = $audioFormats | Sort-Object -Property bitrate -Descending | Select-Object -First 1
    if ($bestFormat -and $bestFormat.url) {
        return @{
            url = $bestFormat.url
            itag = $bestFormat.itag
            bitrate = $bestFormat.bitrate
            mimeType = $bestFormat.mimeType
        }
    }

    $script:State.StatusMessage = "No playable audio stream found"
    return $null
}

function Get-Recommendations {
    param([string]$VideoId)

    $body = @{
        videoId = $VideoId
        isAudioOnly = $true
    }

    $response = Invoke-WebRequest-YTMusic "next" $body

    if (-not $response) { return @() }

    $recommendations = [System.Collections.ArrayList]@()

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
        $script:State.Player = New-Object -ComObject WMPlayer.OCX
        $script:State.Player.settings.volume = $script:State.Volume
        return $true
    } catch {
        $script:State.StatusMessage = "Failed to initialize audio player"
        return $false
    }
}

function Start-Playback {
    param([object]$Song)

    if (-not $Song) { return $false }

    $script:State.StatusMessage = "Loading: $($Song.title)..."
    Render-UI

    $stream = Get-StreamUrl $Song.id
    if (-not $stream) { return $false }

    try {
        $script:State.Player.URL = $stream.url
        $script:State.Player.controls.play()
        $script:State.CurrentSong = $Song
        $script:State.IsPlaying = $true
        $script:State.StatusMessage = "Now playing"

        Add-ToHistory $Song

        return $true
    } catch {
        $script:State.StatusMessage = "Playback error: $($_.Exception.Message)"
        return $false
    }
}

function Stop-Playback {
    if ($script:State.Player) {
        $script:State.Player.controls.stop()
    }
    $script:State.IsPlaying = $false
}

function Toggle-PlayPause {
    if (-not $script:State.CurrentSong) { return }

    if ($script:State.IsPlaying) {
        $script:State.Player.controls.pause()
        $script:State.IsPlaying = $false
        $script:State.StatusMessage = "Paused"
    } else {
        $script:State.Player.controls.play()
        $script:State.IsPlaying = $true
        $script:State.StatusMessage = "Playing"
    }
}

function Seek-Position {
    param([int]$Seconds)

    if (-not $script:State.Player) { return }
    if (-not $script:State.CurrentSong) { return }

    $current = $script:State.Player.controls.currentPosition
    $duration = $script:State.CurrentSong.duration
    if ($duration -le 0 -and $script:State.Player.currentMedia) {
        $duration = $script:State.Player.currentMedia.duration
    }

    $newPos = $current + $Seconds
    $newPos = [math]::Max(0, [math]::Min($newPos, $duration - 1))

    $script:State.Player.controls.currentPosition = $newPos
}

function Set-Volume {
    param([int]$Delta)

    $script:State.Volume = [math]::Max(0, [math]::Min(100, $script:State.Volume + $Delta))

    if ($script:State.Player) {
        $script:State.Player.settings.volume = $script:State.Volume
    }

    $script:Settings.volume = $script:State.Volume
    $script:State.StatusMessage = "Volume: $($script:State.Volume)%"
}

function Get-PlaybackPosition {
    if (-not $script:State.Player) { return 0 }
    try {
        return $script:State.Player.controls.currentPosition
    } catch {
        return 0
    }
}

function Get-PlaybackState {
    if (-not $script:State.Player) { return "stopped" }
    try {
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
        $script:State.Player.controls.currentPosition = 0
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
            $script:State.Player.controls.currentPosition = 0
            return
        }
    } else {
        if ($prevIndex -lt 0) {
            if ($script:State.RepeatMode -eq "all") {
                $prevIndex = $script:State.Queue.Count - 1
            } else {
                $script:State.Player.controls.currentPosition = 0
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

    Start-Playback $song
}

#endregion

#region ==================== TUI RENDERING ====================

function Clear-Screen {
    [Console]::Clear()
    [Console]::SetCursorPosition(0, 0)
}

function Hide-Cursor {
    [Console]::CursorVisible = $false
}

function Show-Cursor {
    [Console]::CursorVisible = $true
}

function Render-UI {
    $width = [Math]::Min([Console]::WindowWidth, 80)
    $height = [Console]::WindowHeight

    [Console]::SetCursorPosition(0, 0)

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
        if ($duration -le 0 -and $script:State.Player.currentMedia) {
            $duration = $script:State.Player.currentMedia.duration
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
        $barWidth = $Width - $posStr.Length - $durStr.Length - 8
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
    Write-Color "  [1-0] Play  [Enter] Search  [Esc] Back" DarkGray
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
    if ([Console]::KeyAvailable) {
        return [Console]::ReadKey($true)
    }
    return $null
}

function Handle-Input {
    $key = Read-KeyNonBlocking
    if (-not $key) { return }

    switch ($script:State.CurrentView) {
        "player" { Handle-PlayerInput $key }
        "search" { Handle-SearchInput $key }
        "queue" { Handle-QueueInput $key }
        "help" { Handle-HelpInput $key }
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
            if ($script:State.SearchQuery.Length -gt 0) {
                $script:State.IsSearching = $true
                $script:State.StatusMessage = "Searching..."
                Render-UI
                $script:State.SearchResults = Search-Songs $script:State.SearchQuery "songs"
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
            if ($char -and [char]::IsLetterOrDigit($char) -or $char -eq ' ' -or $char -eq '-' -or $char -eq "'") {
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

    Start-Playback $script:State.Queue[0]
    $script:State.StatusMessage = "Playing favorites"
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

    Start-Playback $script:State.Queue[0]
    $script:State.StatusMessage = "Playing history"
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
                $script:State.Player.controls.currentPosition = $script:State.LastPosition
            }
        }
    }

    if ($Favorites) {
        Play-Favorites
    }

    if ($Search) {
        $script:State.CurrentView = "search"
        $script:State.SearchQuery = $Search
        $script:State.SearchResults = Search-Songs $Search "songs"
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

Main

#endregion
