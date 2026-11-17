# SR Client engine notes

A Krunker.io fantasy: a native rewrite of the game, built with [Odin](https://odin-lang.org/).
SR Client can join live Krunker lobbies or run on its own dedicated server, and aims to behave 1:1
with the browser game.

![SR Client running Littletown](doc/demo.png)

## Features

- **Live Krunker lobbies.** Paste an invite link and play, with Windows browser login.
- **Native multiplayer.** SR Client's own authoritative dedicated server, plus offline Local practice.
- **Krunker's HUD.**
  - The Tab leaderboard and the end-of-match screen.
  - Ping and FPS.
  - Nametags and healthbars, which follow line-of-sight rules.
- **Krunker-style settings.**
  - Key binds, sensitivity in cm/360, video, visuals, viewmodel, crosshair and audio.
  - Fuzzy settings search.
  - Import and export of Krunker settings text.
  - Reset to defaults (all settings, or just the current tab), with a confirmation step.

## Requirements

- The [Odin compiler](https://odin-lang.org/) and a system linker (MSVC or MinGW-w64 on Windows).
- An OpenGL 4.5 GPU ([compatibility notes](doc/supported-gpus.md)).
- Windows only: the [WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/),
  used for logging in to live lobbies.
- Linux only: GLFW (`sudo apt install pkg-config libglfw3 libglfw3-dev`).
- The game assets. Unpack a compatible Krunker `mod.zip` into `assets/` so that `assets/models/`,
  `assets/textures/` and `assets/sound/` exist ([asset notes](assets/README.md)). The server
  doesn't need them.

## Build

```bat
.\build.bat            :: client + server (Windows)
.\build.bat client     :: or: server, tests, check, clean
```

```bash
make                   # client + server (Linux)
make client            # or: server, test, check
```

**Developer build:** `.\build.bat dev` (or `make dev`) builds `bin/sr_client_dev.exe` with debug tools compiled in (`-define:SR_DEV=true`): press `F3` (rebindable) or pass `--perf-overlay` for the debug performance window (FPS, 1% low, frame/CPU/GPU time, graph, draw calls). Normal and tester builds don't include it.

An optimization level can follow the target (`none`, `minimal`, `size`, `speed`, or
`aggressive`, the default), e.g. `.\build.bat client speed`.

The first Windows client build needs internet access to fetch the WebView2 loader.

Windows releases (installer + portable zip) are built by GitHub Actions (`.github/workflows/build.yml`).
`sr_client.exe --asset-sweep` checks that every map, class, weapon and sound asset loads.
`python package-linux.py` still packages Linux builds from a seed asset archive.

<details>
<summary>Fresh Odin installs on Linux/macOS</summary>

```bash
sh "$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"   # audio
make -C "$(odin root)/vendor/stb/src"                       # if STB libraries are missing
```
</details>

## Run

Run from the repository root so asset paths resolve.

```bash
./bin/sr_client              # menu: paste an invite and Join, or Local practice
./bin/sr_client --offline    # straight into an offline session
./bin/sr_server              # native dedicated server
```

To join a live lobby, copy a `https://krunker.io/?game=<id>` link and press **Join**.

- **Windows:** **Login** first, which opens the official site in an embedded browser.
- **macOS/Linux:** set `KRUNKER_ACCESS_TOKEN` in `.env` instead.

Join problems are logged to `logs/krunker-network.log`.

| Option | Description |
| --- | --- |
| `-m, --map <name>` | Load a specific map, e.g. `ss_v3` |
| `-c, --class <name>` | Preselect a class, e.g. `hunter` |
| `--offline` | Run the simulation locally without a server |
| `--fps` | Show the FPS meter |
| `-h, --help` | List every map and class |

Settings are saved to `client-settings.json` and `audio-settings.json` in the working directory.

## Controls

These are the default bindings. Rebind them in **Settings → Key binds**: select a slot and press a key or mouse button (Escape cancels). To unbind a slot, click its **X**, right-click it, or focus it and press Delete or Backspace.

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move |
| Mouse | Look |
| Left / right mouse | Fire / aim |
| `Space` | Jump (also wall jump with Run N Gun, Agent and Runner) |
| Left `Shift` | Crouch or slide |
| `R` | Reload |
| `E` / `Q` | Secondary / melee |
| `F` | Inspect weapon |
| `Tab` (hold) | Leaderboard |
| `Esc` | Menu / release the cursor |
| `F11` | Toggle fullscreen |

## Configuration

- **Classes:** [`krunker-configs/class-configs.json`](krunker-configs/class-configs.json).
- **Weapons and match rules:** [`assets/config/game.toml`](assets/config/game.toml).
- **Maps:** run `python download_maps.py` to refresh all 47 official maps.

## Testing

```bat
.\build.bat tests                                                      :: headless simulation tests
odin test src/client -o:none -define:ODIN_TEST_THREADS=1              :: client tests (needs a GPU)
```

## Project layout

| Path | Contents |
| --- | --- |
| `src/client/` | OpenGL client, HUD, audio, input, live Krunker client |
| `src/menu/` | Menus and settings |
| `src/krunker/` | Krunker protocol: MessagePack, matchmaking, world state |
| `src/server/` | Native dedicated server |
| `src/shared/` | Simulation, maps, configuration, native protocol |
| `src/tests/` | Headless simulation and menu tests |
| `assets/` | Maps, shaders, configuration and local runtime assets |
| `doc/` | Browser access, protocol notes, GPU notes |

## Roadmap

The goal is a functional, playable game that matches Krunker. The phases are ordered by dependency;
later ones are broad and may change.

### Done recently

- [x] Join live Krunker lobbies, with Windows browser login and CAPTCHA handoff.
- [x] Competitive Hardpoint ruleset: team assignment, objective capture, contesting, scoring,
      rotation timing, score limits and tie breakers.
- [x] Krunker HUD:
  - [x] Tab leaderboard and end-of-match screen.
  - [x] Show Ping.
  - [x] Nametags and healthbars with line-of-sight gating.
- [x] Settings:
  - [x] Key binds, cm/360 sensitivity, video, visuals, viewmodel, Precision crosshair, trails and audio.
  - [x] Fuzzy settings search.
  - [x] Krunker settings import/export.
  - [x] Reset settings to defaults.
- [x] Fixed the fullscreen resolution picker and the mid-round class-change softlock.

### Phase 1: Playable core

- [ ] Complete the four-site objective cycle and round progression, including best-of-three
      match resolution.
- [ ] Lock the competitive class pool and match each class's health, speed, regeneration,
      wall-jump ability, hitbox, restrictions and loadout.
- [ ] Match Krunker's tick order, fixed timestep, movement constants and speed caps, including
      SRM movement (ramp sliding, dash, wall-dash and cooldowns).
- [ ] Implement every competitive weapon exactly: fire cadence, reload/swap timing, spread, recoil,
      falloff, pierce, headshots, melee and projectiles. Crossbow, building and charge mechanics
      are still missing.
- [ ] Match hitboxes, kill attribution, regeneration, respawn timing, spawn selection and spawn
      protection.
- [ ] Make competitive map collision exact, including terrain (which also blocks nametag line of sight).
- [ ] Deterministic simulation with replay-vector tests between server and predicted client.

### Phase 2: Multiplayer foundation

- [ ] Move native networking from TCP to UDP (Odin ENet bindings), handling loss, ordering and reconnects.
- [ ] Profile and optimize the simulation and renderer for larger matches.
- [ ] Replay system for viewing and sharing matches.

### Phase 3: Presentation and customization

- [ ] Remaining HUD parity:
  - [ ] Clan tags and badges on nametags and the leaderboard.
  - [ ] Leaderboard Toggle mode.
  - [ ] End-screen map voting and medals.
  - [ ] Hide Nametags (Allies).
  - [ ] Network stats.
- [ ] Image crosshairs and the remaining Krunker visual settings.
- [ ] Better lighting and shaders. GLB/glTF/FBX map assets.
- [ ] Account UI and ranked account management.

### Phase 4: Extensibility

- [ ] **Exploratory:** in-game developer console using Odin Lua bindings, with permissions and
      build-mode restrictions before scripting is exposed in multiplayer.
- [ ] **Exploratory:** a map editor.

### Phase 5: Platform and networking experiments

- [ ] **Exploratory:** macOS support through Odin's Darwin bindings.
- [ ] **Exploratory:** GGPO-style peer-to-peer for private sessions, once the simulation is deterministic.
- [ ] **Exploratory:** anti-cheat, starting with server validation, trusted state and abuse reporting.

### Phase 6: Future content

- [ ] Ranked ladder and tournament tooling.
- [ ] Dedicated server binaries the community can run themselves.

## Acknowledgements

- [Odin](https://odin-lang.org/): the language, standard library and vendor bindings for GLFW, OpenGL, STB and miniaudio.
- [Clay](https://github.com/nicbarker/clay): menu layout and pointer interaction.
