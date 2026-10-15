# Goobies Multiplayer changelog

Versions are set in `mod_menu.ini` and `Scripts/gmp_config.lua`. Test builds are published as GitHub releases marked Latest; `-test.N` in the version marks a test build.

## Unreleased

- Development in progress.

## 1.0.0-test.4 (2026-10-14)

Fourth friend test build (tag `v1.0.0-test.4`). It requires Mod Menu 1.1.0-test.3 or newer; install both, in any order,
into the same `Shooter\Binaries\Win64` folder.

- Over Steam, players and enemies now show up for everyone. In 1.0.0-test.3 a Steam lobby never started the live
  updates, so each player saw the same island but played it alone.
- Goobies Multiplayer has its own settings page in Mod Menu (the gear next to it under *Mods*): default lobby size,
  allow auto rejoin, only host can pause, and how long a dropped player keeps their slot. Changes apply the next time
  you start Goobies.
- Each player picks their own level-up upgrades. The level-up, loot and bush choice screens wait about 10 seconds
  for you, and only a screen you leave unanswered is picked for you. Roulette screens close by themselves 2 seconds
  after the first player finishes.
- Players show their Steam names in the lobby, and the pause notice says who paused ("Paused by <name> (host)").
- The *End run* and *Pause* buttons no longer show the stray "BINGOS" text.
- When a joining player ends the run, the game's end screen opens. Its *Retry* button becomes *Rejoin* and takes you
  back into the host's run with the same slot; *Quit* keeps your slot for a while.
- When the host ends the run, everyone still playing is asked "Become the new host?". The best-connected volunteer
  takes over; if nobody does, the run ends for everyone.
- Shared lives are on: when anyone dies, the host included, they become a ghost and a teammate standing nearby revives
  them. The run only ends when everyone is down.
- If the host's game crashes or disconnects, another player takes over as host automatically and the run continues;
  the original host can rejoin as a normal player (the new host stays host).
- Players can now join a host that took over (fixed a check that turned them away).
- *End run* and host changes can no longer freeze the game: a stuck handover is released automatically.
- A player who dies keeps their slot, and *Rejoin* on their end screen brings them back into the run.
- Rejoining over Steam after *End run* works (it failed with an island error before).
- Rejoining after restarting the game puts you back with the class you had in the run (on any island); if that ever
  fails, the lobby tells you why.
- Joining after a refused join, or after *End run*, starts a fresh Steam connection.
- A version mismatch now says that both players need the same version, and the game stops retrying.
- A first join that cannot reach the host ends with a message instead of reconnecting forever.
- The lobby list marks lobbies that run another version, and you cannot join them.
- The host has a *Cancel* button in the lobby: it closes the lobby and tells everyone.
- *Tab* pauses the game for everyone (unless only the host can pause).

## 1.0.0-test.3 (2026-10-14)

Third friend test build (tag `v1.0.0-test.3`). It requires Mod Menu (the README names the version); install both, in
any order, into the same `Shooter\Binaries\Win64` folder.

- The settings now ship as Goobies Multiplayer's own defaults (`Mods\GoobiesMP\Defaults\Configs\GoobiesMP.ini`).
  Mod Menu creates `Configs\GoobiesMP.ini` from them on the first start and keeps your own values when an update adds
  new settings. The zip no longer contains `Configs\GoobiesMP.ini`, so extracting it again never resets your settings.
- The GoobiesMPAuthority helper is hidden in the Mods menu, like GoobiesMPNative (it showed up as "unmanaged" with
  version "?").
- Achievements: Mod Menu 1.1.0-test.2 blocks them by itself; there is no blocker file to move any more.
- The Esc menu in multiplayer leaves the game's own rows alone (no stray "BINGOS" text, no lost row) and says who
  paused ("Paused by Player N (host)").

## 1.0.0-test.2 (2026-10-14)

Second friend test build (tag `v1.0.0-test.2`); the same multiplayer as 1.0.0-test.1, packaged
one mod per repository.

- The zip now holds only Goobies Multiplayer (with its two helper mods). It requires Mod Menu 1.1.0-test.1
  or newer (its own zip from the goobies-mod-menu repository); install both, in any order, into the same
  `Shooter\Binaries\Win64` folder. The two zips share no files. Menu Options is optional.
- Goobies Multiplayer is switched on by default: Mod Menu starts it on the first launch after install.
- The zip no longer replaces Mod Menu's files (`Mods\mods.txt`, `Configs\ModList.ini`, the UE4SS loader).

## 1.0.0-test.1 (2026-10-14)

First friend test build (tag `v1.0.0-test.1`, a GitHub pre-release). It is a test version, not the final release.

- One zip that you extract into the game's `Shooter\Binaries\Win64` folder. It contains everything needed to play:
  Goobies Multiplayer, Mod Menu with its UE4SS loader, and Menu Options.
- Play Goobies online with friends over Steam: create a lobby, invite friends or share the Lobby ID, and join through
  a Steam invite, *Join game* in the friends list, or the Lobby ID.
- The host runs the shared world: everyone plays the same islands, and the host's enemies and bosses appear for every
  player. Your hits on enemies count through the host, and enemies attack every player, with their attack effects
  shown on every screen.
- Shared XP: the team levels up together from everyone's pickups; upgrades and rewards stay per player.
- You see the other players in your world, animated and with their own class look. Pausing pauses everyone.
- A player who drops keeps their slot for 15 minutes and can rejoin from the menu.
- `Report a problem.bat` in `Mods\mod_menu` collects the logs into a zip for a bug report.
- The achievement blocker is included but optional in this build; built-in blocking is coming in a Mod Menu update.
