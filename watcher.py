#!/usr/bin/env python3
"""NL road test appointment watcher.

Polls the Newfoundland & Labrador Motor Registration Division online booking
system (SmartCJM) for available appointment slots and notifies a Discord
webhook when one opens up. Designed to run every few minutes from a systemd
timer (Linux) or Task Scheduler (Windows).

The booking API requires a session cookie, which a single GET of the public
calendar page provides. No login, no personal data — this only reads the
same availability the booking website shows anyone.
"""

import argparse
import http.cookiejar
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = "https://gov-nl-ca.saas.smartcjm.com/m/mrdappointments"
CALENDAR_UID = "91352e54-5c34-4e55-975b-d33c8ebe3da8"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")

ROOT = Path(__file__).resolve().parent


def log(msg: str) -> None:
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}"
    print(line)
    log_file = ROOT / "watcher.log"
    with log_file.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
    if log_file.stat().st_size > 1_000_000:
        lines = log_file.read_text(encoding="utf-8").splitlines()[-2000:]
        log_file.write_text("\n".join(lines) + "\n", encoding="utf-8")


def load_json(path: Path, default):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return default


def get_slots(config: dict) -> list[str]:
    """Return the datetime strings of every open slot for the configured
    service at the configured location."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("User-Agent", UA)]

    # establish the session the API requires
    with opener.open(f"{BASE}/extern/calendar/?uid={CALENDAR_UID}&lang=en", timeout=30):
        pass

    query = urllib.parse.urlencode(
        {"services": config["serviceUid"], "locations": config["locationUid"]}
    )
    req = urllib.request.Request(
        f"{BASE}/api/appointment/search?{query}",
        headers={
            "X-Requested-With": "XMLHttpRequest",
            "Referer": f"{BASE}/extern/calendar/",
        },
    )
    with opener.open(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if data.get("status") != "SUCCESS":
        raise RuntimeError(f"API returned status {data.get('status')!r}")
    return [item["dt"] for item in data.get("items", [])]


def mention_prefix(config: dict) -> str:
    parts = [f"<@{uid}>" for uid in config.get("mentionUserIds", [])]
    if config.get("mentionEveryone"):
        parts.append("@everyone")
    return " ".join(parts) + " " if parts else ""


def send_discord(config: dict, content: str) -> None:
    url = config.get("discordWebhookUrl", "")
    if not url or url.startswith("PASTE_"):
        log("Discord webhook not configured - skipping notification.")
        return
    body = json.dumps({"content": content}).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json", "User-Agent": UA}
    )
    with urllib.request.urlopen(req, timeout=30):
        pass


def pretty(dt_str: str) -> str:
    dt = datetime.fromisoformat(dt_str)
    return f"{dt:%a %b} {dt.day}, {dt.hour % 12 or 12}:{dt:%M} {dt:%p}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-notify", action="store_true",
                        help="fake one open slot to exercise the notification path")
    args = parser.parse_args()

    if (ROOT / "STOP").exists():
        log("STOP file present - skipping check. Delete the STOP file to resume.")
        return 0

    config = load_json(ROOT / "config.json", None)
    if config is None:
        print("config.json not found - copy config.example.json and fill it in.")
        return 2

    state_file = ROOT / "state.json"
    state = load_json(state_file, {
        "lastNotifiedSlots": [],
        "consecutiveFailures": 0,
        "lastHeartbeatDate": "",
        "checksSinceHeartbeat": 0,
    })

    try:
        if args.test_notify:
            slots = [datetime.now().replace(microsecond=0).isoformat() + "-02:30"]
            log("TEST NOTIFY run - using one fake slot.")
        else:
            slots = get_slots(config)

        state["consecutiveFailures"] = 0
        state["checksSinceHeartbeat"] += 1

        if slots:
            new = [s for s in slots if s not in state["lastNotifiedSlots"]]
            log(f"AVAILABLE: {len(slots)} slot(s), {len(new)} new.")
            if new:
                shown = sorted(slots)[: config.get("maxSlotsInMessage", 20)]
                lines = "\n".join(f"- {pretty(s)}" for s in shown)
                more = (f"\n...and {len(slots) - len(shown)} more"
                        if len(slots) > len(shown) else "")
                msg = (f"{mention_prefix(config)}**SLOT OPEN!** "
                       f"{config['serviceName']} at {config['locationName']}:\n"
                       f"{lines}{more}\nBOOK NOW -> {config['bookingUrl']}")
                send_discord(config, msg)
                state["lastNotifiedSlots"] = slots
        else:
            log("No slots.")
            state["lastNotifiedSlots"] = []  # a re-appearance should ping again

        today = f"{datetime.now():%Y-%m-%d}"
        if (datetime.now().hour >= config.get("heartbeatHour", 9)
                and state["lastHeartbeatDate"] != today):
            send_discord(config, (
                f"Watcher alive - {state['checksSinceHeartbeat']} checks since "
                f"last heartbeat, no open slots at {config['locationName']} right now."))
            state["lastHeartbeatDate"] = today
            state["checksSinceHeartbeat"] = 0

    except Exception as exc:  # noqa: BLE001 - any failure counts against the streak
        state["consecutiveFailures"] += 1
        log(f"FAILURE #{state['consecutiveFailures']}: {exc}")
        if state["consecutiveFailures"] == 5:
            try:
                send_discord(config, (
                    "WARNING: watcher has failed 5 checks in a row "
                    f"(site changed or network down). Last error: {exc}"))
            except Exception as notify_exc:  # noqa: BLE001
                log(f"Failure alert could not be sent: {notify_exc}")
        state_file.write_text(json.dumps(state, indent=2), encoding="utf-8")
        return 1

    state_file.write_text(json.dumps(state, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
