Goobies Multiplayer friend test build: the achievement blocker
==============================================================

Multiplayer must never unlock or change Steam achievements. This folder holds the blocker
(steam_api64.dll). It is the only part of the zip that cannot be extracted in place: it belongs
in the game's Steam plugin folder, not in Win64. Do this once, with the game closed:

1. Open this folder (Steam: right-click Goobies > Manage > Browse local files, then go to):
   Shooter\Plugins\SteamCorePro\SteamCorePro\Source\ThirdParty\SteamLibrary\redistributable_bin\win64
2. Rename the steam_api64.dll that is already there to steam_api64_original.dll.
   Keep it and never delete it: the blocker loads it.
3. Move the steam_api64.dll from this _achievement_blocker_move_me folder into that folder.
4. Optional check in PowerShell: Get-FileHash "<that folder>\steam_api64.dll"
   must show 342C54A15CA3B2B268A5BD29CD5380A6A04F7679BB57BA79B292C5CB2893556C.

While the blocker is installed, no Steam achievement unlocks, in single player too.
After a Goobies update on Steam, check that folder again: an update can put the original
steam_api64.dll back. Then delete the restored steam_api64.dll (keep steam_api64_original.dll)
and repeat step 3.

To remove the blocker: delete the blocker steam_api64.dll there and rename
steam_api64_original.dll back to steam_api64.dll (or let Steam verify the game files).

You can delete this _achievement_blocker_move_me folder afterwards.
