# MetroTube

A terminal-based YouTube Music player for Windows. Zero dependencies - just PowerShell.

## Features

- Search YouTube Music
- Play/Pause/Skip tracks
- Queue management with shuffle & repeat
- Volume control
- Auto-recommendations
- Local favorites (no YouTube login needed)
- Play history
- Full TUI with colors and progress bar
- Session persistence (resume where you left off)

## Requirements

- Windows 10/11
- PowerShell 5.1+ (built-in)
- Windows Media Player (built-in)

## Usage

### First Time Setup (Required)

Windows blocks PowerShell scripts by default. Run this first:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

Or run the script directly with bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\MetroTube.ps1
```

### Test API Connection

Before using the player, test if the API is accessible from your network:

```powershell
.\MetroTube.ps1 -Test
```

You should see output like:
```
Testing YouTube Music API...

1. Testing Search API (WEB_REMIX client)...
   [OK] Search API works!
   Found approximately 20 results

2. Testing Player API (ANDROID_VR client)...
   [OK] Player API works!
   Found 4 audio streams with direct URLs
   Best quality: itag=251, bitrate=142718bps

API Test Complete!
```

If you see `[FAIL]` messages, the API may be blocked on your network.

### Running the Script

```powershell
# Run it
.\MetroTube.ps1

# Start with a search
.\MetroTube.ps1 -Search "bohemian rhapsody"

# Play your favorites
.\MetroTube.ps1 -PlayFavorites

# Resume last session
.\MetroTube.ps1 -Resume
```

## Keyboard Controls

| Key | Action |
|-----|--------|
| `Space` | Play/Pause |
| `N` | Next track |
| `P` | Previous track |
| `→` | Seek forward 10s |
| `←` | Seek backward 10s |
| `↑` | Volume up |
| `↓` | Volume down |
| `L` | Like/Unlike song |
| `S` | Search |
| `Q` | Show queue |
| `R` | Toggle repeat (Off/All/One) |
| `Z` | Toggle shuffle |
| `F` | Play favorites |
| `H` | Play history |
| `?` | Help |
| `Esc` | Exit |

## Data Storage

All data is saved to `%APPDATA%\MetroTube\`:

- `config.json` - User preferences
- `favorites.json` - Liked songs
- `history.json` - Play history
- `queue.json` - Queue state for resume

## How It Works

Uses the YouTube Music InnerTube API (same API the Metrolist Android app uses) with the ANDROID_VR client configuration, which returns direct playable URLs without requiring cipher deobfuscation.

## Limitations

- Cannot play age-restricted content
- Cannot play YouTube Premium/paid content
- Stream URLs expire after ~6 hours (script fetches fresh URLs automatically)

## License

MIT
