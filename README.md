# SR Client

A native Krunker client for competitive and custom lobbies. The game runs as a
real desktop program (Odin + OpenGL), not inside a browser.

## Download & play
1. Go to **Releases** and download `SR-Client-Setup-x.y.z.exe`.
2. Run it. SR Client installs for your user (no admin) and starts.
3. Press **Login**, sign in to Krunker, paste a lobby invite and press **Join**.

Prefer no installer? Download `SR-Client-Portable-x.y.z.zip`, unzip anywhere,
run `sr_client.exe`.

Requirements: Windows 10/11 and a GPU with OpenGL 4.5. The Krunker login window
uses Microsoft's [WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/),
which is already installed on almost every PC. WebView2 is only used to sign in
(and for Krunker's verification check and Mods window); the game itself does not
run in a browser.

## Features
- Native rendering with shadows, lighting and night mode
- **Custom and comp games only:** join any custom game by invite link (FFA 1v1s,
  bot-hosted and private comp lobbies included). Public matches are blocked.
- **Host game:** Krunker's Comp Server Setup inside SR (maps, team size 1v1–4v4,
  rounds, timers, class limits and every other comp option). SR creates the game
  itself and you are the host. The game runs in your Default Region
  (Settings > General).
- **Always up to date:** at start-up SR checks whether Krunker updated and
  downloads changed maps before you play; no new SR release needed.
- **Hitboxes you can trust:** other players are drawn exactly where Krunker's
  server tests your shots: head, body, arms and legs all move with Krunker's
  own hitboxes (checked against Krunker's game code)
- **After a game:** the final scoreboard stays until Esc, then a fresh start
  screen; **Refresh (F5)** resets SR any time. Invite box: double-click or
  Ctrl+A selects the link, holding Backspace keeps deleting
- Krunker's 5-4-3-2-1 round countdown voice
- Sensitivity in **cm/360** with mouse DPI, optional separate ADS cm/360
- Killfeed, hitmarkers (bars or your own image) and damage borders, all customizable
- Crosshair, viewmodel, FOV, keybinds (scroll wheel, unbinding), FPS limits
- Image crosshairs from a link (Discord "Copy Link") or a file
- Krunker mods: browse Krunker's own Mods window from Settings; mods load live, no restart
- Krunker chat (Enter/T to type, Tab for Team/All), death cam, auto respawn, enemies-on-point counter, mini scoreboard
- Settings laid out like Krunker's (General, Controls, Display, Render, Game, Sound) plus an Experimental tab
- Import your Krunker (or Glorp) settings, with switches to skip keybinds,
  sensitivity or sound; settings marked **K** work exactly like Krunker's
- Uses the dedicated GPU on laptops
- Reset to defaults

Game files (maps, models, textures, sounds) are plain files in the `assets`
folder next to `sr_client.exe`, not packed into the program, so they can be
modded.

## How it works
- **Same game, same servers.** SR Client connects to Krunker's own game servers
  and speaks Krunker's network protocol, so you play in the same lobbies as
  browser players. Krunker's server decides every hit, kill and round, exactly
  as in the browser.
- **Native instead of a browser.** Krunker normally runs as a web page. SR
  draws the game itself in a desktop program (Odin + OpenGL), with Krunker's
  maps, models, textures and sounds as plain files. No browser engine runs
  while you play, which is where the FPS gains come from.
- **What you see matches the server.** Other players are drawn from the same
  numbers Krunker's server uses for its hitboxes, at the moment in time the
  server checks your shot, so what you aim at is what the server tests.
- **Login stays Krunker's.** Signing in opens Krunker's own login page in a
  small Microsoft WebView2 window; SR never sees your password. After that the
  window closes and the game runs natively.
- **Comp and custom only.** SR joins invite links and hosts comp games; public
  matchmaking is blocked.

## How it's built
- Written in [Odin](https://odin-lang.org) with OpenGL 4.5 for rendering and
  [Clay](https://github.com/nicbarker/clay) for the menus.
- `src/client`: the game client (rendering, input, HUD, audio, settings).
- `src/krunker`: Krunker's network protocol (messages, game state).
- `src/shared`: game rules shared by everything (movement, weapons, hitboxes).
- `src/menu`: menus and settings screens.
- `src/browser_helper`: the small WebView2 window for login, verification and mods.
- GitHub Actions builds the Windows installer and portable zip on every
  release; `build.bat all` builds the same locally (see below).

## Making a release (maintainers)
1. Game files (Krunker models, textures, sounds) live in `game-files/sr-game-files.zip`.
2. Bump `VERSION`, add a `CHANGELOG.md` entry, commit.
3. On GitHub: **Releases → Draft a new release**, tag `vX.Y.Z`, **Publish**.
   GitHub Actions builds and attaches the installer and portable zip.

Every normal push also builds; the files are under the run's **Artifacts**.

## Building locally
Install [Odin dev-2026-10](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10)
and Visual Studio Build Tools, then run `build.bat all` from the
"x64 Native Tools Command Prompt". Put the contents of
`game-files/sr-game-files.zip` next to `bin\sr_client.exe`.
Engine notes: [`doc/ENGINE-README.md`](doc/ENGINE-README.md).

## Logs
Bugs: send `logs\krunker-network.log` from the install folder
(`%LOCALAPPDATA%\SR-Client\app`). Set `SR_CONSOLE_LOG=1` to mirror it in the console.

## Credits
- Krunker game assets: © FRVR
- [Clay](https://github.com/nicbarker/clay) UI, Rajdhani font (SIL OFL)
