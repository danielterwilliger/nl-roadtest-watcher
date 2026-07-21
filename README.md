# nl-roadtest-watcher

Watches the Newfoundland & Labrador Motor Registration Division (MRD) online
appointment system for open booking slots and pings a Discord webhook the
moment one appears.

Built because Class 05 road test appointments at busy MRD offices are released
~30 days out and get snapped up almost instantly — the only realistic way to
catch one (or a cancellation) is to check constantly. This does the checking;
you do the booking.

**This tool only reads availability** — the same information the public
booking page shows anyone. It never reserves, holds, or books anything, has no
login, and sends no personal data. Polling is 2 lightweight requests every
2 minutes, far less traffic than a human refreshing the page.

## How it works

The MRD booking site ([SmartCJM](https://gov-nl-ca.saas.smartcjm.com/m/mrdappointments/extern/calendar/?uid=91352e54-5c34-4e55-975b-d33c8ebe3da8&lang=en))
is a server-rendered booking wizard, but it exposes a JSON search API:

```
GET /m/mrdappointments/api/appointment/search?services=<service-uid>&locations=<location-uid>
```

The API returns `403 ACCESS_DENIED` without a session — but a single GET of
the public calendar page sets the required session cookie. With it, the API
returns every open slot as JSON. `watcher.py` does exactly that once per run:

1. GET the calendar page (establishes session)
2. GET the search API for the configured service + location
3. If slots exist that weren't already announced → post to the Discord webhook
   (and, in the Windows variant, raise a loud toast notification)

State lives in `state.json` (which slots were announced, failure streak,
heartbeat date). The watcher also sends a daily "still alive" heartbeat and a
warning if 5 consecutive checks fail (site changed / network down), so a silent
death doesn't go unnoticed.

A slot can vanish and later reappear: the booking wizard holds a slot while
someone walks the checkout flow, and the hold expires after ~20 minutes if
they don't finish. When an already-announced slot cycles back, the watcher
alerts again with a *(re-opened)* label — a repeat alert for the same time
is the site re-releasing the slot, not a duplicate bug. Slot times are also
written to `watcher.log` so any alert can be reconstructed later.

## Setup

```bash
git clone https://github.com/danielterwilliger/nl-roadtest-watcher.git
cd nl-roadtest-watcher
cp config.example.json config.json
# edit config.json: webhook URL, mentions, service/location (see below)
```

### Config

| Key | Meaning |
|---|---|
| `discordWebhookUrl` | Webhook URL for the channel to notify (see below) |
| `mentionEveryone` | `true` to prefix alerts with `@everyone` |
| `mentionUserIds` | Discord user IDs to `@`-tag directly in alerts |
| `serviceUid` / `serviceName` | Which MRD service to watch (default: Road Test – Passenger, Class 05) |
| `locationUid` / `locationName` | Which office (default: Mount Pearl Driver Examiners) |
| `bookingUrl` | Link included in alerts — where you go to actually book |
| `heartbeatHour` | Local hour after which the once-daily heartbeat sends |
| `maxSlotsInMessage` | Cap on slot lines per Discord message |

To watch a different service or office, view the source of the booking page:
every service checkbox (`service_<uid>`) and location checkbox
(`location_<uid>`) carries its UID.

### Linux (systemd timer — recommended, e.g. an always-on home server)

```bash
sudo ./install.sh          # installs + starts a 2-minute systemd timer
journalctl -u roadtest-watcher -f   # watch it work
```

### Windows (Task Scheduler)

Use `windows\RoadTestWatcher.ps1` (same logic + a loud looping toast alert).
Register it every 2 minutes:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\RoadTestWatcher.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName "NL Road Test Watcher" -Action $action -Trigger $trigger -Settings $settings
```

The config file (`config.json`) sits next to the script in both variants.

## Discord notifications

1. In a Discord server you control, create a **private channel** (only the
   people who should get pinged can see it).
2. **Channel settings (gear) → Integrations → Webhooks → New Webhook** →
   point it at that channel → **Copy Webhook URL** → paste into
   `config.json` as `discordWebhookUrl`.
3. To `@`-tag specific people: Discord **Settings → Advanced → Developer
   Mode** on, then right-click a user → **Copy User ID** → add the IDs to
   `mentionUserIds`. (Or set `mentionEveryone: true` — in a two-person
   private channel it's equivalent.)
4. Make sure both phones have notifications enabled for that channel.

Treat the webhook URL like a password — anyone who has it can post to your
channel. It's why `config.json` is gitignored.

## Testing

```bash
./watcher.py --test-notify    # fakes one slot and sends a real notification
```

## Pausing / stopping

- **Pause** (e.g. right after you snag an appointment): create a file named
  `STOP` next to the script — checks become no-ops until you delete it.
- **Stop for good**: `sudo systemctl disable --now roadtest-watcher.timer`
  (Linux) or `Unregister-ScheduledTask "NL Road Test Watcher"` (Windows).

## Be a good citizen

This exists to spare two humans from refreshing a government website all day,
not to give anyone an unfair edge — it doesn't book, hold, or queue
anything. Keep the polling interval civil (the default 2 minutes is plenty;
availability is checked 2 requests at a time) and stop the watcher once
you've booked.
