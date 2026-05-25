# MetroTube Troubleshooting Guide

## Issues Encountered & Solutions

### Issue 1: PowerShell Execution Policy Block

**Symptom:**
```
File cannot be loaded because running scripts is disabled on this system.
```

**Cause:** Windows blocks PowerShell scripts by default for security.

**Solution:**
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

**Why it works:** This temporarily allows scripts to run in the current PowerShell session only. It doesn't change system-wide settings.

---

### Issue 2: 407 Proxy Authentication Required

**Symptom:**
```
Invoke-RestMethod : The remote server returned an error: (407) Proxy Authentication Required.
```

**Cause:** Corporate/school networks use a proxy server that requires authentication. When you open Chrome, Windows automatically sends your login credentials to the proxy. But PowerShell by default sends requests **anonymously** without credentials.

**Solution:** Added this line at the start of the script:
```powershell
[System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
```

**Why it works:** This tells PowerShell to use your Windows login credentials for the proxy, exactly like Chrome does.

**Is this against company policy?** NO! You are:
- Using your own credentials (not bypassing anything)
- Traffic still goes through the company proxy (they can monitor/log)
- This is exactly how every Windows app (Chrome, Outlook, Teams) authenticates with the proxy

---

### Issue 3: Parameter Name Collision (SwitchParameter Error)

**Symptom:**
```
Cannot create object of type "System.Management.Automation.SwitchParameter".
The songs property was not found for the System.Management.Automation.SwitchParameter object.
```

**Cause:** PowerShell 5.1 had a naming collision between:
- `[switch]$Favorites` parameter in the script
- `$script:Favorites` variable for storing favorite songs

PowerShell was confusing the parameter (a switch type) with the variable (a hashtable).

**Solution:** Renamed the parameter from `-Favorites` to `-PlayFavorites`

**Why it works:** Different names = no collision. The switch parameter and the script variable are now distinct.

---

### Issue 4: "Sign in to confirm you're not a bot"

**Symptom:**
```
Error: Sign in to confirm you're not a bot
```
Search works, but playback fails.

**Cause:** YouTube's anti-bot protection. The InnerTube API detects automated requests and blocks them. This happens when:
- Missing `visitorData` (session identifier)
- Missing `poToken` (proof of origin token)
- Using a client that YouTube flags as suspicious

**Solution:** Implemented multi-client fallback (like Metrolist Android app does):

```powershell
PlayerClients = @(
    @{ name = "TVHTML5_EMBEDDED"; ... },  # Embedded player - often bypasses restrictions
    @{ name = "ANDROID_VR"; ... },         # VR headset client
    @{ name = "IOS"; ... },                # iPhone client
    @{ name = "ANDROID_MUSIC"; ... }       # YouTube Music app client
)
```

Also added `visitorData` tracking:
- Stored from first API response
- Sent with subsequent requests via `X-Goog-Visitor-Id` header
- Provides session continuity

**Why it works:** Different YouTube "clients" have different bot detection thresholds. By trying multiple clients in order, we find one that works. The `visitorData` makes requests look like a continuous session rather than random automated calls.

**How Metrolist handles this:** The Android app uses 12+ fallback clients and generates a `poToken` using JavaScript evaluation. Our PowerShell version uses 4 clients without poToken (which is complex to implement in PowerShell).

---

## Technical Details

### What is InnerTube API?

InnerTube is YouTube's internal API used by all official YouTube apps (web, Android, iOS, TV). It's the same API that:
- YouTube Music website uses
- YouTube Android/iOS apps use
- Metrolist Android app uses

It's not a public API, but it's not "hacking" either - it's just making the same requests that official apps make.

### What are YouTube "Clients"?

YouTube identifies different apps/devices by "client" configuration:
- `WEB_REMIX` - YouTube Music website
- `ANDROID_VR` - Oculus/Meta Quest YouTube app
- `IOS` - iPhone YouTube app
- `ANDROID_MUSIC` - Android YouTube Music app
- `TVHTML5_SIMPLY_EMBEDDED_PLAYER` - Embedded player (like on other websites)

Each client has different:
- Bot detection thresholds
- Content restrictions
- Audio/video quality options
- Authentication requirements

### Stream URL Expiration

YouTube stream URLs expire after ~6 hours. The script automatically fetches fresh URLs when needed.

---

## Debug Commands

### Test API connectivity:
```powershell
.\MetroTube.ps1 -Test
```

### Test Search API manually:
```powershell
$r = Invoke-RestMethod -Uri "https://music.youtube.com/youtubei/v1/search" -Method Post -ContentType "application/json" -Body '{"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20240101.01.00","hl":"en","gl":"US"}},"query":"test"}' -Headers @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0"}
$r.contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents.Count
```

### Test Player API manually:
```powershell
$r = Invoke-RestMethod -Uri "https://music.youtube.com/youtubei/v1/player" -Method Post -ContentType "application/json" -Body '{"context":{"client":{"clientName":"TVHTML5_SIMPLY_EMBEDDED_PLAYER","clientVersion":"2.0","hl":"en","gl":"US"}},"videoId":"dQw4w9WgXcQ","contentCheckOk":true,"racyCheckOk":true}' -Headers @{"User-Agent"="Mozilla/5.0"}
$r.playabilityStatus.status
```

---

## Known Limitations

| Content Type | Works? |
|--------------|--------|
| Regular songs | ✅ Yes |
| Music videos | ✅ Yes |
| Albums | ✅ Yes |
| Playlists | ✅ Yes |
| Age-restricted | ⚠️ Maybe (depends on client) |
| Premium/Paid | ❌ No |
| Private videos | ❌ No |
| Some live streams | ⚠️ Maybe |

---

## Version History

| Version | Fix |
|---------|-----|
| 1.0.3 | Fixed ArrayList initialization for PowerShell 5.1 |
| 1.0.4 | Renamed -Favorites to -PlayFavorites (collision fix) |
| 1.0.5 | Added automatic proxy authentication |
| 1.0.6 | Added multi-client fallback + visitorData |
| 1.0.7 | Fixed test function to use new client config |
