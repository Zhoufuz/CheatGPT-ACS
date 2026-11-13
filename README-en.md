<h1 align="center">CheatGPT.cc</h1>

<p align="center"><strong>ACS Weapon System Universal Script</strong></p>

<p align="center">
  <a href="src/main.lua"><img src="https://img.shields.io/badge/Release-1.2.2-94a3b8?style=flat-square&amp;labelColor=161b22" alt="Release 1.2.2"></a>
  <a href="https://www.lua.org/manual/5.1/"><img src="https://img.shields.io/badge/LuaU-818cf8?style=flat-square&amp;logo=lua&amp;logoColor=white&amp;labelColor=161b22" alt="Written in LuaU"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-34d399?style=flat-square&amp;labelColor=161b22" alt="License MIT"></a>
</p>

<p align="center">
  <a href="README.md">中文</a> /
English
</p>

---

<p align="center">
  <a href="#quick-start">Quick Start</a> ·
  <a href="#usage">Usage Guide</a> ·
  <a href="#config">Configuration</a> ·
  <a href="#executor-compat">Executor Compatibility</a> ·
  <a href="#faq">FAQ</a> 
</p>

<a id="features"></a>

## Features

| Module | Feature | Description |
| --- | --- | --- |
| **Legit — Aim Assist** | Auto-aim | `Lock` / `Adaptive` modes, selectable aim part, FOV, smoothing speed, distance, team/wall/scope filters, optional FOV circle |
| **Legit — Combat** | Triggerbot | Fires automatically when the crosshair passes over an enemy; supports reaction delay, distance, team and scope limits |
| **Rage — RageBot** | Silent aim | Constructs ACS damage requests directly; supports multi-target, target priority, hit part, multi-threading, burst, HitLog and hit sounds |
| **Visual** | Visual feedback | Hit Marker, hit effect, kill effect (Valorant / Battlefield 1), impact marker, spread FOV, Arms / Character / Tool Chams, Bullet Trace |
| **LocalPlayer** | Local weapon & movement | Fly, Speed, Noclip, SpinBot, 3rd Cam, plus ACS mod changes such as No Recoil / No Spread / Steady Aim / Infinite Ammo / Rapid Fire |
| **PlayersList** | Player management | Live player list, Friend / Enemy / None roles, right-click copy of display name / username / ID, join/leave notifications |
| **Setting** | UI settings | Draggable Watermark, custom text, join/leave notifications, GUI keybind, notification toggle, Clear Config |
| **Debug (hidden)** | Diagnostics | Executor info, UI scale, Steady Aim status, image/download queues, lifetime kills & score, missing APIs, recent error log |

> The Debug tab is hidden by default: click the **`Release-v1.2.2`** label next to the title **7 times** to unlock it.

<a id="quick-start"></a>

## Quick Start

Run this in your executor:

```Lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Zhoufuz/CheatGPT-ACS/refs/heads/master/src/main.lua", true))()
```

### Requirements

| Item | Requirement |
| --- | --- |
| Game | A Roblox game running the **ACS (Advanced Combat System)** weapon framework |
| Executor | Must support `getsenv`; `debug.getupvalues`, `hookfunction` and `newcclosure` are recommended (see [Executor Compatibility](#executor-compat)) |
| Network | The first run needs internet access to download UI assets (icons, sounds, font, kill effects) |
| File permissions | The executor must support `writefile` / `readfile` to save config, and `getcustomasset` (or `getsynasset`) to load assets |

### Steps

1. **Join the game and wait for it to load**: make sure your character has spawned and an ACS weapon (e.g. a rifle) is equipped, so `ACS_Client` and the weapon settings finish initializing first.
2. **Run the script**: paste the contents of [`src/main.lua`](src/main.lua) into your executor (or load the file with it) and execute.
3. **Wait for initialization**: the script waits up to **12 seconds** for a readable ACS environment, then creates the UI. The first run also downloads assets in the background, which may take a few extra seconds.
4. **Open the menu**: the window appears automatically after initialization and opens on the **Rage** tab by default; afterwards you can show/hide it with **RightShift** (the default GUI Key).
5. **Enable features as needed**: some toggles depend on executor APIs; when an API is missing they are greyed out with a message listing the missing function. See [Executor Compatibility](#executor-compat).

> If no window appears after execution, press F9 to check the console and make sure the game, character and ACS weapon have all loaded; see [FAQ](#faq).

<a id="usage"></a>

## Usage Guide

### Window Controls

  - Drag the title bar to **move** the window; it scales automatically with your resolution (there are no manual resize/close buttons).
  - Tabs scroll horizontally; switching slides the pages left/right with an animated underline.
  - On mobile (touch-only), a draggable floating round button opens/closes the menu.
  - The UI uses a fixed dark theme; there is no theme switcher.

### Tabs and Features

#### Legit

  - `Aim Assist`: master toggle, supports a keybind.
  - `Mode`: `Lock` (direct lock) / `Adaptive` (humanized smoothing with reaction delay, jitter and overshoot).
  - `AimPart`: `Head` / `Torso` / `Left Arm` / `Right Arm` / `Left Leg` / `Right Leg`.
  - `Aim speed`: 1–30 (default 10); `Max Distance`: 0–10000 (default 1500).
  - `Only Enemy` / `Team Check` / `Wall Check` / `Only Scope`: target filters.
  - `Draw Fov` + `Fov size` (0–200) + `Fov Color`: draw the aim range circle.
  - `Trigger`: fires automatically when the crosshair passes over a target (**requires `getsenv`**).
  - `Reaction Time (ms)`: 0–1000 (default 100); `Max Distance`: 0–10000; plus `Team Check` / `Only Enemy` / `Only Scope`.

#### Rage

  - `RageBot`: silent aim that sends damage requests directly (**requires `getsenv` + `debug.getupvalues`**).
  - `Only Enemy` / `Team Check`: target filters; `WallBang`: allow hits through walls.
  - `Multi Target`: 1–8 (default 3); `Thread`: 1–9 (default 1).
  - `Target Priority`: `Distance` / `Centre`; `Hit Part`: head, torso, arms and legs.
  - `HitLog`: on-screen hit log, with `HitLog Size` (8–24, default 16) and `Duration Time (s)` (0.5–10, default 2.2).
  - `Hitsound`: 12 hit sounds, default `Skeet`; `Hitsounds` toggle and `Volume` (0–5, default 0.8).

#### Visual

  - `Hit Marker`: hit marker, position selectable as `Centre` / `Impact Point`.
  - `Hit effect`: hit particle effect with adjustable color and transparency.
  - `Kill effect`: kill banner effect.
  - `Kill effect style`: `Valorant` / `Battlefield 1`.
  - `Collection Style` (Valorant only): `2021 Vandal` / `Recon` / `Rogue` / `Singularity`
  - `Kill Sounds Volume`: 0–5 (default 2).
  - `Show Impact`: impact marker with adjustable color, transparency, `Impact Material` (`Neon` / `ForceField` / `Glass` / `SmoothPlastic`) and size.
  - `Spread FOV`: shows the weapon spread range circle with adjustable color and transparency.
  - `Arms Chams` / `Character Chams` / `Tool Chams`: ForceField-material see-through highlight, each with its own color.
  - `Bullet Trace`: bullet trails with configurable self/others colors, transparency, show targets, `Trace Lifetime`, `Trace Width` and `Trace Style` (`Basic` / `Styled`).

#### LocalPlayer

  - `Fly` + `Fly Speed` (1–100, default 1): fly in the direction of the camera.
  - `Speed` + `Speed Value` (0–80): modify movement speed.
  - `Noclip`: disable character collision.
  - `No Fall Dmg`: prevents ACS fall damage while enabled and restores it when disabled. Off by default; saved in the config and automatically reapplied after respawning. Requires the executor APIs listed below.
  - ACS weapon enhancements (**all require the corresponding executor debug/hook APIs**):
  - `No Suppression`: removes suppression/tinnitus and other negative effects.
  - `No Malfunction`: the weapon never jams.
  - `Steady Aim`: removes view shake when aiming/moving.
  - `No Recoil`: removes recoil.
  - `No Spread`: removes spread.
  - `Accelerate Muzzle Velocity`: increases bullet velocity.
  - `Rapid Fire`: no fire interval.
  - `Infinite Ammo`: unlimited ammo.
  - `Instant Aim`, `Instant Equip`: aim/equip animations complete instantly.
  - `3rd Cam`: enables third-person view.
  - `SpinBot` + `Spin Speed`: spins the character.

#### PlayersList

- Shows the server's players in real time: avatar, `DisplayName (@username)` and role button.
- Roles are **Friend** (green) / **Enemy** (red) / **None** (grey); you are shown as **Local**. Roles affect the `Only Enemy` / `Team Check` filters of Aim Assist, Trigger and RageBot.
- Right-click a player row (long-press for 0.5 s on touch) to open the context menu: `Copy display name` / `Copy username` / `Copy user ID`.
- Friend / Enemy lists are saved automatically to `whitelist.json` / `enemylist.json`.

#### Setting

- `Watermark`: top-left watermark; multi-select items from `FPS`, `PING`, `PLAYERS`, `USERNAME`, `TIME`, `CUSTOM`, `Kills`, `Score`, `Runtime` (default FPS + PING); `Custom` accepts your own text.
- `Enemy leave notify` / `Friend leave notify` / `Enemy join notify` / `Friend join notify`: four independent join/leave notification toggles (off by default).
- `GUI Key`: menu show/hide keybind (default `RightShift`).
- `Notifications`: script notification toggle (falls back to native Roblox notifications when off).
- `Clear Config`: clears the saved configuration and resets all controls (keeps player lists and cache), with a confirmation dialog.

#### Debug (hidden)

> Click the version label 7 times to unlock.

Includes:

- Executor name and version, viewport size and UI scale, Steady Aim status and hook/pin counts;
- Image ready/waiting/busy counts, asset download queue length;
- Lifetime `Kills` / `Score`, stats storage path `CheatGPT/ACS/misc.json`, `Missing APIs` (executor APIs that are missing);
- The last 8 error log entries;
- Buttons: `Refresh diagnostics`, `Retry unloaded images`, `Copy diagnostics`, `Test notification / bug icon`, `Clear error log`.

<a id="config"></a>

## Configuration

The script creates a `CheatGPT/ACS/` directory in the executor's working directory:

| Path | Content |
| --- | --- |
| `CheatGPT/ACS/Config.yaml` | Current main configuration (YAML, version 2) |
| `CheatGPT/ACS/Config.json` | Legacy main configuration used for automatic migration; retained afterward |
| `CheatGPT/ACS/whitelist.json` | Friend list |
| `CheatGPT/ACS/enemylist.json` | Enemy list |
| `CheatGPT/ACS/misc.json` | Lifetime kills and score |
| `CheatGPT/ACS/ClientId.json` | Local identifier, stored locally only |
| `CheatGPT/ACS/Cache/` | Cached icons, sounds, kill-effect frames, font, etc. |

- **Auto-save**: changes are written after **4 seconds**.
- **Automatic legacy migration**: startup reads `Config.yaml` first. If only the legacy `Config.json` exists, it is automatically converted to YAML and read back for verification, preserving the settings and original JSON file. No manual conversion is needed. Subsequent saves write to `Config.yaml`.
- **Damaged-file protection**: if configuration reading or parsing fails, auto-save is paused to avoid overwriting the original file. Fix the file and rerun the script, or use `Clear Config` to restore defaults.
- **Clear config**: `Clear Config` deletes both `Config.yaml` and the legacy `Config.json`, preventing old settings from being migrated again on the next launch.
- If the executor does not support `writefile` / `readfile`, the configuration will not be saved.

<a id="executor-compat"></a>

## Executor Compatibility

The script detects executor capabilities at startup and enables/disables features accordingly.

### Required and Optional APIs

| API | Purpose | Effect if missing |
| --- | --- | --- |
| `getsenv` | Read the ACS environment | **Required**: the script cannot run |
| `debug.getupvalues` / `debug.getupvalue` / `debug.setupvalue` | Read/write ACS weapon mods | Most ACS enhancement toggles are disabled |
| `hookfunction` / `newcclosure` | Hook ACS functions | `Rapid Fire`, `Instant Equip`, `Steady Aim`, etc. are disabled |
| `getconnections` / `getgc` / `getfenv` / `debug.getconstants` | Locate ACS render and character-state callbacks | `Steady Aim` and `No Fall Dmg` are disabled |
| `writefile` / `readfile` | Save config, write asset cache | Config is not saved; assets cannot be cached |
| `getcustomasset` / `getsynasset` | Register local asset URIs | Icons/sounds/kill effects/font are unavailable |
| `request` / `http_request` / `syn.request` / `http.request` | Download assets | Falls back to `game:HttpGet` |
| `setclipboard` / `getclipboard` | Copy diagnostics, player names, colors | Related buttons are disabled |
| `crypt.generatebytes` | Generate ClientId | Only affects `ClientId.json`, not main features |
| `identifyexecutor` | Show executor info | Shows `Unknown` in Debug |
| `gethui` | Store the runtime-lock sentinel (falls back to `CoreGui`) | No functional impact |
| `syn.protect_gui` | Protect the UI (optional) | No functional impact |

### API Preview

| Feature | Required APIs |
| --- | --- |
| `Trigger` | `getsenv` |
| `No Fall Dmg` | `getconnections` or `getgc`, `getfenv`, `debug.getconstants`, `debug.getupvalues`, `debug.getupvalue`, `debug.setupvalue` |
| `RageBot`, `No Malfunction`, `No Recoil`, `No Spread`, `Accelerate Muzzle Velocity` | `getsenv` + `debug.getupvalues` |
| `Rapid Fire` | `getsenv`, `hookfunction`, `newcclosure`, `getcallingscript`, `debug.getupvalues`, `debug.setupvalue` |
| `Infinite Ammo` | `getsenv`, `debug.getupvalues`, `debug.setupvalue` |
| `Instant Aim` | `getsenv`, `debug.getupvalues`, `debug.getupvalue`, `debug.setupvalue` |
| `Instant Equip` | `getsenv`, `debug.getupvalues`, `debug.setupvalue`, `hookfunction`, `newcclosure` |
| `Steady Aim` | `getsenv`, `getconnections` or `getgc`, `getfenv`, `debug.getconstants`, `debug.getupvalues`, `debug.getupvalue`, `debug.setupvalue`, `hookfunction`, `newcclosure` |

- Toggles missing a dependency are **forced off and greyed out**; clicking them shows `Your executor doesn't support '<API>' function`.

<a id="faq"></a>

## FAQ

<details>
<summary><b>No window appears after running the script?</b></summary>

1. Make sure the game uses the ACS framework and that your character has spawned with an ACS weapon equipped;
2. Make sure the executor supports `getsenv`;
3. Press F9 to check the console, or look at the script's notifications/error messages;
4. Try rejoining.
</details>

<details>
<summary><b>It says "12 秒内未找到可读取的 ACS 环境" (no readable ACS environment found within 12 seconds)?</b></summary>

The script could not find an `ACS_Client` environment under your character within 12 seconds. Wait for the character and weapon to fully load and try again, or rejoin; if it still fails, the current game may not be a compatible ACS implementation.
</details>

<details>
<summary><b>It says "执行器缺少 getsenv，无法读取 ACS 环境" (executor is missing getsenv, cannot read the ACS environment)?</b></summary>

Your executor does not support `getsenv`, so the script cannot read the ACS environment. You must switch to an executor that supports this API.
</details>

<details>
<summary><b>Some toggles are greyed out / clicking them says unsupported?</b></summary>

These features require additional executor APIs (such as `debug.getupvalues`, `hookfunction`, `newcclosure`). Compare against [Executor Compatibility](#executor-compat), or open the Debug tab and check `Missing APIs` (the Debug tab must be unlocked by clicking the version label 7 times first). Switching to a more complete, higher-tier executor unlocks them.
</details>

<details>
<summary><b>Hit sounds, kill effects or the font do not show up?</b></summary>

These assets require an internet download and an executor that supports `writefile` and `getcustomasset` (or `getsynasset`). Check the download queue and failure records in Debug and click `Retry unloaded images`; if the font fails to load, the UI automatically falls back to the default font without affecting functionality. Changing the kill effect requires resetting your character to take effect.
</details>

<details>
<summary><b>Settings are not saved?</b></summary>

The configuration is written to `CheatGPT/ACS/Config.yaml`, and the executor must support `writefile` / `readfile`; make sure the executor allows file access and check whether the `CheatGPT/ACS/` directory exists. The legacy `Config.json` is retained after migration and is no longer updated when settings change. A configuration parsing error preserves the original file and pauses auto-save; fix the file and rerun the script, or clear the configuration to restore defaults.
</details>

<details>
<summary><b>How do I restore the default settings?</b></summary>

Open Setting → `Clear Config` → `Clear and Reset`. This deletes both `Config.yaml` and the legacy `Config.json` and resets all controls, while keeping the Friend/Enemy lists, lifetime kills and score, and the asset cache.
</details>

<details>
<summary><b>Can I run the script more than once?</b></summary>

Yes, but the script has a runtime lock: when an existing instance is detected it tries to re-show the existing window instead of starting a second copy. If the window is lost or the state is broken, leave and rejoin the server before running it again.
</details>

<a id="structure"></a>

## Project Structure

```text
CheatGPT-ACS/
├─ src/
│  └─ main.lua      # Main module
├─ README.md        # Chinese README
├─ README-en.md     # This document (English)
└─ LICENSE          # MIT License
```

<a id="license"></a>

## License

[MIT License](LICENSE) , Copyright © 2026 CheatGPT.cc.

---

<p align="center">
  <sub>CheatGPT.cc · ACS Universal Script · Release v1.2.2</sub><br>
</p>
