# Goobies Multiplayer: friend test build

> **Draft.** This file will become the README of the friend build repository (D48). There is no installer: you extract one zip.

This is a **test build** for playing Goobies with friends over Steam. Each player installs it on their own PC. It is not the final release.

## Before you start

- **Every player** needs Goobies on Steam. Everything else (Mod Menu, its UE4SS loader, Menu Options and Goobies Multiplayer) is in the zip.
- Every player must have **the same build**. When you join, the lobby compares the game-changing mods with the host's. If they differ, you leave the lobby and see the list of differences.
- **Find the game folder:** in Steam, right-click Goobies, then *Manage → Browse local files*. Below, `<game>` means that folder, and `Win64` means `<game>\Shooter\Binaries\Win64` (the folder with `Shooter-Win64-Shipping.exe`).

## 1. Back up

Multiplayer runs use your **normal save** until a separate multiplayer save exists. Copy this folder somewhere safe first:

```
%LOCALAPPDATA%\Shooter\Saved\SaveGames
```

(Paste that path into the Explorer address bar.) If you already use other UE4SS mods, also back up `Win64\Mods`, `Win64\Configs`, `UE4SS.dll`, `dwmapi.dll` and `UE4SS-settings.ini`: the zip replaces the loader, `Mods\mods.txt` and `Configs\ModList.ini`.

## 2. Extract the zip into Win64

1. If Windows marks the downloaded zip as blocked, unblock it first: right-click the zip → *Properties* → tick **Unblock** → *OK*.
2. Put the zip into `Win64` and extract it there (*right-click → Extract All…*, and make sure the target is `Win64` itself, not a new subfolder). Allow it to replace files.
3. You should now have, inside `Win64`:
   - `UE4SS.dll`, `dwmapi.dll`, `UE4SS-settings.ini` (the mod loader)
   - `Mods\mod_menu\` (Mod Menu, with `Report a problem.bat`), `Mods\GoobiesMP\` (the mod), `Mods\GoobiesMPNative\` and `Mods\GoobiesMPAuthority\` (hidden helpers; they do not show in Mod Menu), `Mods\MenuOptions\`
   - `Mods\mods.txt`, `Configs\ModList.ini`, `Configs\GoobiesMP.ini` (everything is already switched on)
   - `_achievement_blocker_move_me\` (see step 3)

## 3. Move the achievement blocker (optional for now, built-in blocking is coming in a Mod Menu update)

The blocker keeps Steam achievements from unlocking. The blocker is the one part that cannot be extracted in place: it belongs in the game's Steam plugin folder. `Win64\_achievement_blocker_move_me\README.txt` has the same steps:

1. Open
   ```
   <game>\Shooter\Plugins\SteamCorePro\SteamCorePro\Source\ThirdParty\SteamLibrary\redistributable_bin\win64\
   ```
2. **Rename** the existing `steam_api64.dll` to `steam_api64_original.dll`. Keep it, and never delete it: the blocker loads it.
3. Move `Win64\_achievement_blocker_move_me\steam_api64.dll` into that folder.
4. Optional check in PowerShell:
   ```powershell
   Get-FileHash "<that folder>\steam_api64.dll"
   ```
   The hash must be `342C54A15CA3B2B268A5BD29CD5380A6A04F7679BB57BA79B292C5CB2893556C`.

Please know before you install:
- **While the blocker is installed, no Steam achievement unlocks, in single player too.** To get achievements back, uninstall it (see below).
- **After every Goobies update on Steam**, check this folder again. An update can put the original `steam_api64.dll` back. In that case, delete the restored `steam_api64.dll` (keep your `steam_api64_original.dll`) and repeat step 3. The mod does not detect this yet.
- Windows SmartScreen or Defender may warn about the unsigned DLLs. Choose *More info → Run anyway*, or allow the file.

## 4. Start

Start Goobies through Steam. Goobies Multiplayer is already on; *Multiplayer* is in the main menu.

## 5. Play together

- **Host:**
  1. *Multiplayer → Create lobby*.
  2. Use **Invite friends**, or share the **Lobby ID**: click it, press Ctrl+A, then Ctrl+C, and paste it to your friends.
  3. Everyone picks a class and presses Ready; then the host starts.
- **Friends** can join in any of these ways:
  - accept the Steam invite;
  - use *Join game* on the host in the Steam friends list (Shift+Tab works while the game is running);
  - *Multiplayer*, paste the Lobby ID, then *Join lobby*. The Join box also accepts a pasted `steam://joinlobby/...` link or "Lobby ID: …" text.
- If someone drops by accident, their slot is held for 15 minutes; they can rejoin from the menu.

## Reporting a problem

Double-click `Win64\Mods\mod_menu\Report a problem.bat` (or use Mod Menu's *Report a problem*). It collects the logs into a zip on your Desktop with personal information removed, then opens the crash-report page. Please say what you were doing and what you expected.

## Uninstall

1. Delete `Win64\Mods\GoobiesMP\`, `Win64\Mods\GoobiesMPNative\` and `Win64\Mods\GoobiesMPAuthority\`. To remove everything, also delete `Win64\Mods\mod_menu\`, `Win64\Mods\MenuOptions\`, `UE4SS.dll`, `dwmapi.dll` and `UE4SS-settings.ini`.
2. Restore the original Steam DLL:
   1. In the `...\redistributable_bin\win64\` folder, delete the blocker `steam_api64.dll`.
   2. Rename `steam_api64_original.dll` back to `steam_api64.dll`.

   Alternatively, use *Steam → Goobies → Properties → Installed Files → Verify integrity of game files*.
3. Optional: delete `Win64\Configs\GoobiesMP.ini`.

Your save is not changed by uninstalling. Restore your backup from step 1 if you want the save from before multiplayer.

## What this build is

This build runs `MODE=friend`:
- like the release, it uses a real Steam lobby, Steam invites and Steam authentication;
- like the playtests, it runs the multiplayer gameplay;
- it uses the achievement blocker above;
- every developer test switch is off.

Its settings file is `Win64\Configs\GoobiesMP.ini`; please don't edit it for the test.
