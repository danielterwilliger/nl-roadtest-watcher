#!/bin/bash
# Install the watcher as a systemd timer. Run from the repo directory:
#   sudo ./install.sh
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_USER="${SUDO_USER:-$USER}"

if [ ! -f "$INSTALL_DIR/config.json" ]; then
    echo "config.json not found - copy config.example.json to config.json first." >&2
    exit 1
fi

sed -e "s|__USER__|$RUN_USER|g" -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    "$INSTALL_DIR/systemd/roadtest-watcher.service" > /etc/systemd/system/roadtest-watcher.service
cp "$INSTALL_DIR/systemd/roadtest-watcher.timer" /etc/systemd/system/roadtest-watcher.timer

systemctl daemon-reload
systemctl enable --now roadtest-watcher.timer

echo "Installed. Timer status:"
systemctl list-timers roadtest-watcher.timer --no-pager
echo
echo "Run a single check now with:  systemctl start roadtest-watcher.service"
echo "Watch logs with:              journalctl -u roadtest-watcher -f"
echo "Pause checks with:            touch $INSTALL_DIR/STOP"
echo "Stop for good with:           sudo systemctl disable --now roadtest-watcher.timer"
