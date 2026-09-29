# Genshin Impact 7.1 on Linux (Epic / Heroic) — why it crashes and how we got it running

Genshin Impact **7.1.0** (Epic Games version, launched through **Heroic** + Proton) closed about 2 seconds
after pressing *Start Game*, with no window. This repo documents how we diagnosed it, what did **not**
work, and the setup that finally runs it — plus a few performance fixes.

> ⚠️ **Read the risk section before copying anything.** The working setup uses a Wine patch that
> changes a network timeout value inside the running game's memory. Many Linux/macOS players use it,
> and we found no ban reports, but HoYoverse does not support Linux and we cannot promise it is safe.

Tested on: Linux Mint 22.3 (Cinnamon, X11), kernel 7.0, MSI Katana 15 (i7-13620H + RTX 4060 Laptop,
NVIDIA 595 open driver, PRIME on-demand), Heroic 2.22.3, game 7.1.0 (Epic channel, `cps=pcseaepic`).

---

## Symptom

- HoYoPlay opens fine; after *Start Game* the game process lives ~2 s, then exits.
- `games/Genshin Impact game/driverError.log`:
  ```
  initDriver Failed: Error [4,1114,0].
  ```
- Wine/Proton log:
  ```
  err:module:import_dll Library WDFLDR.SYS (which is needed by L"C:\\windows\\system32\\HoYoKProtect.sys") not found
  err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\HoYoProtect": c0000142
  ```

`HoYoKProtect.sys` is HoYoverse's Windows **kernel** anti-cheat driver. It can never load under Wine.
But the game normally does **not** try to load it on Linux — so the real question is *why it tried*.

## Root cause (measured, not guessed)

At startup the game uses its **own built-in libcurl 7.51** (not WinHTTP) to fetch a security
configuration from `dispatchosglobal.yuanshen.com`, with a **~1 second total timeout**.

- If the config arrives in time **and** the game runs under Steam's `steam.exe` environment, it
  follows HoYoverse's server-side config and runs **without** the kernel driver (this is why it works
  for many Linux players).
- If the request fails for **any** reason — timeout **or** no network at all — 7.1 falls back to loading
  the kernel driver → impossible under Wine → the game exits.

That dispatch host sits behind Cloudflare Spectrum, only speaks **TLS 1.2**, and forwards to a distant
origin (~300 ms per round trip from our location). The exchange needs 4 sequential round trips:

| Event (passive `tcpdump` on the host) | Time |
|---|---|
| TCP connect to Cloudflare edge | +15 ms |
| TLS ServerHello (origin reached) | +0.60 s |
| TLS finished, HTTP request sent | +0.93 s |
| **Game hangs up the connection itself** | **+0.99 s** |
| Server reply arrives (too late) | +1.24 s |
| `driverError.log` written | +1.42 s |

`curl` measurement, repeated: TLS done ≈ 0.95 s, full reply ≈ **1.25 s** — always over the limit.
Regional game servers were fast (EU 0.13 s, US 0.25 s, Asia 0.63 s); only this global dispatch is slow.

On **Windows** the exact same timeout happens too — but there the fallback (loading the kernel driver)
simply succeeds, so nobody notices. That's why "it works on Windows" and fails on Linux with the same
internet connection.

Check your own latency with [`scripts/check-dispatch-latency.sh`](scripts/check-dispatch-latency.sh).
If the total is comfortably under ~0.9 s, you probably don't need the timeout fix at all.

## What did NOT work

| Attempt | Result |
|---|---|
| Stock Proton 10 | timeout → driver → crash `[4,1114,0]` |
| Different DNS resolvers (1.1.1.1, 8.8.8.8, 9.9.9.9) | all return the same Cloudflare IP |
| VPN in Singapore (math) | direct RTT ~272 ms → 4 × 272 ms ≈ 1.09 s, still over the limit |
| Start the game offline, reconnect later | **fails on 7.1** — the driver is loaded on *any* config failure |
| Spritz-Wine with `WINE_ENABLE_TIMEOUT_FIX=1` (plain Wine) | config now arrives, but no `steam.exe` environment for the game → crash `[4,643,0]` |
| "Giving the anti-cheat a kernel" (WDF stubs) | not possible under Wine; faking it is the riskiest option and reportedly fails anyway |

## The setup that works

**Runner:** [dwproton](https://dawn.wine/dawn-winery/dwproton) `dwproton-11.0-13` (a Proton fork for these
games; verify the `.sha512sum` from the release page). It contains the `ws2_32` timeout patch and runs
the game inside the Proton/Steam environment.

**Environment variables** (Heroic → Genshin → Settings → Advanced → Environment Variables):

| Variable | Why |
|---|---|
| `WINE_ENABLE_TIMEOUT_FIX=1` | raises the game's libcurl timeout so the real config from HoYoverse arrives |
| `UMU_USE_STEAM=1` | run through `steam.exe` — the anti-cheat's Linux path needs it |
| `WINE_DISABLE_VULKAN_OPWR=1` | part of dwproton's own Genshin fix |
| `PROTON_USE_XALIA=0` | optional: disables Proton's accessibility helper (wasted ~10 % CPU in-game) |

Why set them manually: dwproton applies its Genshin fix (`umu-genshin`: `UMU_USE_STEAM=1`,
`WINE_DISABLE_VULKAN_OPWR=1`) only when it launches `GenshinImpact.exe` directly. The **Epic** version is
launched as `launcher_epic.exe` with UMU id `umu-7d690c122fde4c60bed85405f343ad10`, so the fix is **not**
applied automatically.

Example per-game Heroic config: [`heroic/GamesConfig-example.json`](heroic/GamesConfig-example.json)
(Epic app id `41869934302e4b8cafac2d3c0e7c293d`).

### Heroic launch race (HoYoPlay never opens)

If you launch through a `heroic://launch?...` link (desktop shortcut) **while Heroic is not running**,
Heroic may process the launch before its connectivity check finishes (`Epic is Offline right now`).
`launcher_epic.exe` then gets an **empty** `-AUTH_PASSWORD=` and waits forever — HoYoPlay never appears.
Fix: start Heroic first, wait for `Connectivity: online` in `heroic.log`, then launch.
[`scripts/genshin-launch.sh`](scripts/genshin-launch.sh) does exactly that.

## Performance fixes (lag, map tiles not loading, FPS drops)

1. **NTSync** — Genshin does huge amounts of thread synchronisation. Without NTSync, Wine fell back to
   fsync, the game used ~3 CPU cores and the map loaded only a small square around the player.
   ```sh
   sudo modprobe ntsync
   echo ntsync | sudo tee /etc/modules-load.d/ntsync.conf
   ```
   dwproton's wineserver uses `/dev/ntsync` automatically when it exists (opt-out: `PROTON_NO_NTSYNC`).
2. **Don't composite fullscreen games (Cinnamon):**
   `gsettings set org.cinnamon.muffin unredirect-fullscreen-windows true`
3. **Bigger NVIDIA shader cache** (`~/.config/environment.d/nvidia-shader-cache.conf`):
   ```
   __GL_SHADER_DISK_CACHE_SIZE=10737418240
   __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
   ```
4. **CPU thermals** — remaining FPS dips on this laptop were the CPU sitting at 90–95 °C and throttling
   (GPU only ~35 % busy). Max fans (MSI Cooler Boost via the `msi-ec` driver) raised average CPU clocks ~8 %.

## Risk — please read

- `WINE_ENABLE_TIMEOUT_FIX` (patch `0009-HACK-ws2_32` from
  [Spritz-Wine](https://github.com/NelloKudo/spritz-wine)) walks the game's heap for libcurl's handle
  (magic `0xC0DEDBAD`) and overwrites its timeout fields. It changes only a network timeout and nothing
  is faked towards the anti-cheat — the game receives and follows HoYoverse's genuine config — but it
  **is** a modification of a protected game's memory.
- Everything else here (Proton, `steam.exe`, NTSync, compositor, shader cache) is ordinary Linux/Proton
  behaviour.
- Don't stack anything else on top (FPS unlockers, 3DMigoto/mods, ReShade, injected overlays).
- Use at your own risk. This is not affiliated with HoYoverse, Epic, Valve or any Wine project.

## Credits / references

- Timeout patch: [Spritz-Wine `0009-HACK-ws2_32-Allow-changing-request-timeout…`](https://github.com/NelloKudo/spritz-wine/tree/master/patches/0001-spritz) (teapot4195, NelloKudo, Lily)
- [dwproton](https://dawn.wine/dawn-winery/dwproton) and its `umu-genshin` protonfix
- TwintailLauncher [#325](https://github.com/TwintailTeam/TwintailLauncher/issues/325) — explanation of the security-config timeout
- YAAGL [#763](https://github.com/yaagl/yet-another-anime-game-launcher/issues/763), [#764](https://github.com/yaagl/yet-another-anime-game-launcher/issues/764), [#551](https://github.com/yaagl/yet-another-anime-game-launcher/issues/551)
- AAGL [#694](https://github.com/an-anime-team/an-anime-game-launcher/issues/694) (WDF stub still fails)
- [Heroic wiki — Anime Games](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/wiki/Anime-Games)
