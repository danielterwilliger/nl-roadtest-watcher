# NL Road Test appointment watcher (Windows variant)
# Polls the SmartCJM booking API for available Road Test slots and notifies
# via Discord webhook + Windows toast. Designed to run every 5 min from Task Scheduler.
# Requires Windows PowerShell 5.1 (powershell.exe) for the toast notification.
param(
    [switch]$TestNotify   # fake one slot to exercise the notification path
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Config    = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
$StateFile = Join-Path $Root 'state.json'
$LogFile   = Join-Path $Root 'watcher.log'

$BaseUrl = 'https://gov-nl-ca.saas.smartcjm.com/m/mrdappointments'
$UA      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

function Write-Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ((Get-Item $LogFile).Length -gt 1MB) {
        Get-Content $LogFile -Tail 2000 | Set-Content $LogFile -Encoding UTF8
    }
}

function Get-State {
    if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json }
    else { [pscustomobject]@{ lastNotifiedSlots = @(); consecutiveFailures = 0; lastHeartbeatDate = ''; checksSinceHeartbeat = 0 } }
}

function Save-State($state) { $state | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8 }

function Get-MentionPrefix {
    $parts = @()
    if ($Config.mentionUserIds) {
        $parts += $Config.mentionUserIds | Where-Object { $_ -notlike 'PASTE_*' } | ForEach-Object { "<@$_>" }
    }
    if ($Config.mentionEveryone) { $parts += '@everyone' }
    if ($parts.Count -gt 0) { ($parts -join ' ') + ' ' } else { '' }
}

function Send-Discord([string]$content) {
    if (-not $Config.discordWebhookUrl -or $Config.discordWebhookUrl -like 'PASTE_*') {
        Write-Log 'Discord webhook not configured - skipping Discord notification.'
        return
    }
    $body = @{ content = $content } | ConvertTo-Json
    Invoke-RestMethod -Uri $Config.discordWebhookUrl -Method Post -ContentType 'application/json' -Body $body | Out-Null
}

function Send-Toast([string]$title, [string]$text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $template = @"
<toast scenario="urgent" duration="long">
  <visual><binding template="ToastGeneric">
    <text>$title</text>
    <text>$text</text>
  </binding></visual>
  <audio src="ms-winsoundevent:Notification.Looping.Alarm" loop="true"/>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('NL Road Test Watcher').Show($toast)
    } catch {
        Write-Log "Toast failed: $($_.Exception.Message)"
    }
}

function Get-Slots {
    # a bare GET to the calendar page establishes the session the API requires
    $session = $null
    Invoke-WebRequest -Uri "$BaseUrl/extern/calendar/?uid=91352e54-5c34-4e55-975b-d33c8ebe3da8&lang=en&set_lang_ui=en" `
        -UserAgent $UA -SessionVariable session -UseBasicParsing -TimeoutSec 30 | Out-Null
    $api = "$BaseUrl/api/appointment/search?services=$($Config.serviceUid)&locations=$($Config.locationUid)"
    $resp = Invoke-RestMethod -Uri $api -UserAgent $UA -WebSession $session -TimeoutSec 30 `
        -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Referer' = "$BaseUrl/extern/calendar/" }
    if ($resp.status -ne 'SUCCESS') { throw "API returned status '$($resp.status)'" }
    ,@($resp.items | ForEach-Object { $_.dt })
}

# ---------------- main ----------------
if (Test-Path (Join-Path $Root 'STOP')) {
    Write-Log 'STOP file present - skipping check. Delete the STOP file to resume.'
    return
}

$state = Get-State

try {
    if ($TestNotify) {
        $slots = @((Get-Date).AddDays(3).ToString('yyyy-MM-ddTHH:mm:00-02:30'))
        Write-Log 'TEST NOTIFY run - using one fake slot.'
    } else {
        $slots = Get-Slots
    }

    $state.consecutiveFailures = 0
    $state.checksSinceHeartbeat = [int]$state.checksSinceHeartbeat + 1

    if ($slots.Count -gt 0) {
        $known = @($state.lastNotifiedSlots)
        $new   = @($slots | Where-Object { $known -notcontains $_ })
        Write-Log "AVAILABLE: $($slots.Count) slot(s), $($new.Count) new."

        if ($new.Count -gt 0) {
            $pretty = $slots | Sort-Object | Select-Object -First $Config.maxSlotsInMessage | ForEach-Object {
                ([DateTimeOffset]::Parse($_)).ToString('ddd MMM d, h:mm tt')
            }
            $more = if ($slots.Count -gt $Config.maxSlotsInMessage) { "`n...and $($slots.Count - $Config.maxSlotsInMessage) more" } else { '' }
            $msg = "$(Get-MentionPrefix)**SLOT OPEN!** $($Config.serviceName) at $($Config.locationName):`n" +
                   (($pretty | ForEach-Object { "- $_" }) -join "`n") + $more +
                   "`nBOOK NOW -> $($Config.bookingUrl)"
            Send-Discord $msg
            Send-Toast 'ROAD TEST SLOT OPEN!' ("{0} slot(s) open - earliest {1}. Go book NOW." -f $slots.Count, $pretty[0])
            $state.lastNotifiedSlots = $slots
        }
    } else {
        Write-Log 'No slots.'
        if (@($state.lastNotifiedSlots).Count -gt 0) { $state.lastNotifiedSlots = @() }  # reset so a re-appearance pings again
    }

    # daily heartbeat so you know the watcher is alive
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ((Get-Date).Hour -ge $Config.heartbeatHour -and $state.lastHeartbeatDate -ne $today) {
        Send-Discord ("Watcher alive - {0} checks since last heartbeat, no open slots at {1} right now." -f $state.checksSinceHeartbeat, $Config.locationName)
        $state.lastHeartbeatDate = $today
        $state.checksSinceHeartbeat = 0
    }
}
catch {
    $state.consecutiveFailures = [int]$state.consecutiveFailures + 1
    Write-Log "FAILURE #$($state.consecutiveFailures): $($_.Exception.Message)"
    if ($state.consecutiveFailures -eq 5) {
        Send-Discord "WARNING: watcher has failed 5 checks in a row (site changed or network down). Last error: $($_.Exception.Message)"
        Send-Toast 'Road test watcher broken' 'Five consecutive failures - check watcher.log'
    }
}

Save-State $state
