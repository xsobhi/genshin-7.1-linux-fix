#!/bin/bash
# Launch Genshin Impact (Epic) through Heroic without hitting Heroic's startup race.
#
# If a heroic:// launch link is opened while Heroic is not running, Heroic can process the
# launch before its connectivity check finishes ("Epic is Offline right now"). launcher_epic.exe
# then receives an empty -AUTH_PASSWORD= and waits forever, so HoYoPlay never appears.
# Fix: start Heroic first, wait until it reports "Connectivity: online", then launch.
APP_NAME=41869934302e4b8cafac2d3c0e7c293d   # Genshin Impact, Epic Games Store
HEROIC_BIN=${HEROIC_BIN:-/opt/Heroic/heroic}
LOG=~/.local/state/Heroic/logs/heroic.log

if ! pgrep -x heroic >/dev/null; then
    before=$(grep -c 'Connectivity: online' "$LOG" 2>/dev/null || echo 0)
    nohup "$HEROIC_BIN" >/dev/null 2>&1 &
    for _ in $(seq 1 60); do
        [ "$(grep -c 'Connectivity: online' "$LOG" 2>/dev/null || echo 0)" -gt "$before" ] && break
        sleep 1
    done
    sleep 3
fi
xdg-open "heroic://launch?appName=$APP_NAME&runner=legendary"
