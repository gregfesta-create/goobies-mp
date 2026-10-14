# Goobies Multiplayer (friend test build)

Online multiplayer for Goobies, played with friends over Steam. **Version 1.0.0-test.2 is a friend test build:** it is still
in development, things will break, and it exists so we can test together. It is not the final release.

## Requirements

- Goobies on Steam (Windows). Every player needs their own copy.
- **Requires Mod Menu 1.1.0-test.1 or newer**: [download it here](https://github.com/gregfesta-create/goobies-mod-menu/releases/tag/v1.1.0-test.1); install both, in any order.
  Every Goobies mod needs Mod Menu; it also brings the UE4SS mod loader.
- Optional: Menu Options ([goobies-menu-options](https://github.com/gregfesta-create/goobies-menu-options/releases)).
- Every player must use the same builds. The lobby compares the mods when you join.

## Install

1. Find the game folder: in Steam, right-click Goobies, *Manage > Browse local files*. Open `Shooter\Binaries\Win64`
   (the folder with `Shooter-Win64-Shipping.exe`); below this is called `Win64`.
2. Back up `%LOCALAPPDATA%\Shooter\Saved\SaveGames`.
3. If Windows marks a downloaded zip as blocked: right-click it, *Properties*, tick **Unblock**.
4. Put `goobies_mp_1.0.0-test.2.zip` and the Mod Menu zip into `Win64` and extract each there (*right-click > Extract All*, target `Win64`
   itself). The two zips share no files, so install both, in any order. Menu Options, if you want it, also goes into `Win64`.
5. **Achievement blocker** (optional for now, built-in blocking is coming in a Mod Menu update). It keeps Steam
   achievements from unlocking. It is the one part that cannot be extracted in place; `Win64\_achievement_blocker_move_me\README.txt` has the same steps:
   1. Open `<game>\Shooter\Plugins\SteamCorePro\SteamCorePro\Source\ThirdParty\SteamLibrary\redistributable_bin\win64\`.
   2. Rename the `steam_api64.dll` there to `steam_api64_original.dll` (keep it: the blocker loads it).
   3. Move `Win64\_achievement_blocker_move_me\steam_api64.dll` into that folder.

   While the blocker is installed no achievement unlocks, in single player too. After a Goobies update, check that
   folder again. To remove it, delete the blocker and rename `steam_api64_original.dll` back (or verify the game files in Steam).
6. Start Goobies through Steam. Goobies Multiplayer is on by default; *Multiplayer* is in the main menu.

## Host and join

- **Host:** *Multiplayer > Create lobby*, then **Invite friends** or share the **Lobby ID**. Everyone picks a class and
  presses Ready; the host starts.
- **Join:** accept the Steam invite, use *Join game* on the host in the Steam friends list, or paste the Lobby ID under
  *Multiplayer* and press *Join lobby*.
- A player who drops keeps their slot for 15 minutes and can rejoin from the menu.

## Known limits

- Achievement blocking for multiplayer is optional in this build: without the blocker, Steam achievements can unlock while you play. Built-in blocking is coming in a Mod Menu update.
- Some visual lag remains on joining players' screens (enemies and other players are smoothed and predicted).
- Changing who hosts mid-game is a developer-only test feature and is not in this build; if the host quits mid-run, the run may end for everyone.
- *Retry* from the pause menu on a joining player is not handled yet; use *End run* or leave and rejoin instead.
- A joining player rejoining an island with a very large number of enemies may stall for a while.

## Reporting a problem

`Report a problem.bat` ships inside the Mod Menu mod folder, `Win64\Mods\mod_menu`, because every Goobies mod needs
Mod Menu. From the Mod Menu README:

**Easiest way: double-click `Report a problem.bat` in your Mod Menu folder.**

Every Goobies mod needs Mod Menu, so the report tool comes with it. It is in your Goobies folder under `Shooter\Binaries\Win64\Mods\mod_menu\` (in Steam: right-click Goobies > **Manage** > **Browse local files**; if you see `Goobies_DX11` or `Goobies_Vulkan`, open the one you play).

1. Double-click `Report a problem.bat`. It works without a window, so give it a few seconds: it reports on the game copy it sits in, saves `Goobies_crash_report_<date>.zip` in your Downloads folder, opens the crash-report page in your browser and tells you in a small popup where the zip is. If Windows warns about the file, choose **More info > Run anyway**.
2. Fill in the form on that page and drag the zip into it.

## Uninstall

Delete `Win64\Mods\GoobiesMP`, `Win64\Mods\GoobiesMPNative` and `Win64\Mods\GoobiesMPAuthority`, then remove the
blocker as above. Mod Menu stays for your other mods. Your save is not changed.

## License

See `LICENSE`.
