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
URL="heroic://launch?appName=$APP_NAME&runner=legendary"

# a second click while the first one is still waiting does nothing
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/genshin-launch.lock"
flock -n 9 || exit 0

if pgrep -f "^$HEROIC_BIN\$" >/dev/null && ! pgrep -f 'GenshinImpact.exe|launcher_epic.exe' >/dev/null; then
    : # Heroic already open: its current log says whether it's online (checked below)
elif ! pgrep -f "^$HEROIC_BIN\$" >/dev/null; then
    old=$(stat -c %i "$LOG" 2>/dev/null)
    setsid "$HEROIC_BIN" >/dev/null 2>&1 < /dev/null &
    # Heroic starts a new log file on every start: wait for the new one, so an "online"
    # line from the previous session can't trigger the launch too early
    for _ in $(seq 1 30); do
        [ "$(stat -c %i "$LOG" 2>/dev/null)" != "$old" ] && break
        sleep 0.5
    done
else
    exit 0 # the game is already starting or running
fi
for _ in $(seq 1 60); do
    grep -q 'Connectivity: online' "$LOG" 2>/dev/null && break
    sleep 1
done
sleep 3
xdg-open "$URL"
