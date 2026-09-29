#!/bin/bash
# Measure how long the Genshin global dispatch request takes from your connection.
# The game (7.1) gives up after roughly 1 second; if "total" is close to or above that,
# it falls back to loading its kernel anti-cheat driver, which crashes under Wine.
URL=https://dispatchosglobal.yuanshen.com/
for i in 1 2 3 4 5; do
    curl -4 -sS -o /dev/null -m 10 \
        -w "connect %{time_connect}s  tls-done %{time_appconnect}s  total %{time_total}s\n" "$URL"
    sleep 1
done | tee /dev/stderr | awk '{gsub("s","",$6); t+=$6} END {printf "\naverage total: %.2f s  (game limit ~1.0 s)\n", t/NR}'
