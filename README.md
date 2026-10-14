# Goobies Multiplayer (friend test build)

Online multiplayer for Goobies, played with friends over Steam. **Version 1.0.0-test.1 is a friend test build:** it is still
in development, things will break, and it exists so we can test together. It is not the final release.

## Requirements

- Goobies on Steam (Windows). Every player needs their own copy.
- Nothing else: Mod Menu, its UE4SS loader, Menu Options and Goobies Multiplayer are all in the zip.
- Every player must use the same build. The lobby compares the mods when you join.

## Install

1. Download `goobies_mp_friend_1.0.0-test.1.zip` from the release. If Windows marks it as blocked: right-click it, *Properties*, tick **Unblock**.
2. Find the game folder: in Steam, right-click Goobies, *Manage > Browse local files*. Open `Shooter\Binaries\Win64`
   (the folder with `Shooter-Win64-Shipping.exe`); below this is called `Win64`.
3. Back up `%LOCALAPPDATA%\Shooter\Saved\SaveGames`, and your `Win64\Mods` and `Win64\Configs` if you use other UE4SS mods.
4. Put the zip into `Win64` and extract it there (*right-click > Extract All*, target `Win64` itself). Allow it to replace files.
5. **Achievement blocker** (optional for now, built-in blocking is coming in a Mod Menu update). It keeps Steam
   achievements from unlocking. It is the one part that cannot be extracted in place; `Win64\_achievement_blocker_move_me\README.txt` has the same steps:
   1. Open `<game>\Shooter\Plugins\SteamCorePro\SteamCorePro\Source\ThirdParty\SteamLibrary\redistributable_bin\win64\`.
   2. Rename the `steam_api64.dll` there to `steam_api64_original.dll` (keep it: the blocker loads it).
   3. Move `Win64\_achievement_blocker_move_me\steam_api64.dll` into that folder.

   While the blocker is installed no achievement unlocks, in single player too. After a Goobies update, check that
   folder again. To remove it, delete the blocker and rename `steam_api64_original.dll` back (or verify the game files in Steam).
6. Start Goobies through Steam. Goobies Multiplayer is already on.

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

**Easiest way: double-click `Report a problem.bat` in your Mod Menu folder.**

Every Goobies mod needs Mod Menu, so the report tool comes with it. It is in your Goobies folder under `Shooter\Binaries\Win64\Mods\mod_menu\` (in Steam: right-click Goobies > **Manage** > **Browse local files**; if you see `Goobies_DX11` or `Goobies_Vulkan`, open the one you play).

1. Double-click `Report a problem.bat`. It works without a window, so give it a few seconds: it reports on the game copy it sits in, saves `Goobies_crash_report_<date>.zip` in your Downloads folder, opens the crash-report page in your browser and tells you in a small popup where the zip is. If Windows warns about the file, choose **More info > Run anyway**.
2. Fill in the form on that page and drag the zip into it.

In this build the tool is `Win64\Mods\mod_menu\Report a problem.bat`. This build has no automatic upload: nothing is
sent unless you attach the zip yourself.

## Uninstall

Delete `Win64\Mods\GoobiesMP`, `Win64\Mods\GoobiesMPNative` and `Win64\Mods\GoobiesMPAuthority` (all mods: also
`Mods\mod_menu`, `Mods\MenuOptions`, `UE4SS.dll`, `dwmapi.dll`, `UE4SS-settings.ini`), then remove the blocker as above.
Your save is not changed.

## License

See `LICENSE`. UE4SS is MIT-licensed (`Mods\mod_menu\ThirdParty\UE4SS-LICENSE.txt`).
