# Goobies Multiplayer changelog

Versions are set in `mod_menu.ini` and `Scripts/gmp_config.lua`. Test builds are published as GitHub pre-releases.

## Unreleased

- Development in progress.

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
