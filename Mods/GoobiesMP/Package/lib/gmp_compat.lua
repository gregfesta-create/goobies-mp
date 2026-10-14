-- GoobiesMP: compatibility gate (pure). Decides, from what a host ADVERTISES and what this install IS, whether joining may proceed.
-- The check runs BEFORE authentication and BEFORE lobby entry. Nothing here downloads, installs or updates anything: every failure
-- tells the player what to do by hand.
--
-- advert (host):  { requiredMod, requiredVersion, protocol, gameVer }
-- localInfo:      { installed=bool, enabled=bool, modVer, protocol, gameVer }
-- Result: { ok=true } or { ok=false, case="A"|"B"|"C"|"D", reason=<stable code>, message=<player text>, action=<nil|"offer_enable">, required=, installed= }
--   A  GoobiesMP not installed        reason mod_not_installed     (manual install)
--   B  installed but disabled         reason mod_disabled          (offer to enable; restart required)
--   C  wrong mod version              reason version_mismatch      (manual install/update of the required version)
--   D  protocol / game incompatible   reason protocol_mismatch | game_version_mismatch | mod_mismatch
local Compat = {}

Compat.REASONS = { mod_not_installed = "A", mod_disabled = "B", version_mismatch = "C", protocol_mismatch = "D", game_version_mismatch = "D", mod_mismatch = "D" }

function Compat.Evaluate(adv, loc)
    if type(adv) ~= "table" or type(loc) ~= "table" then return { ok = false, case = "D", reason = "bad_advert", message = "The host's compatibility information is missing or invalid; joining was refused." } end
    local req = { mod = adv.requiredMod, version = adv.requiredVersion, protocol = adv.protocol, gameVer = adv.gameVer }
    local inst = { modVer = loc.modVer, protocol = loc.protocol, gameVer = loc.gameVer }
    local function fail(case, reason, msg, action) return { ok = false, case = case, reason = reason, message = msg, action = action, required = req, installed = inst } end
    if not loc.installed then
        return fail("A", "mod_not_installed", string.format("%s is required to join this game and is not installed. It must be installed manually (nothing is downloaded or installed automatically). Required version: %s.", tostring(adv.requiredMod), tostring(adv.requiredVersion)))
    end
    if not loc.enabled then
        return fail("B", "mod_disabled", "GoobiesMP is installed but disabled. Do you want to enable it?", "offer_enable")
    end
    if adv.requiredMod ~= "GoobiesMP" then
        return fail("D", "mod_mismatch", string.format("This host requires a different mod (%s); joining was refused.", tostring(adv.requiredMod)))
    end
    if adv.requiredVersion ~= loc.modVer then
        return fail("C", "version_mismatch", string.format("Wrong GoobiesMP version. The host requires %s, you have %s. Install or update the required version manually (nothing is downloaded automatically).", tostring(adv.requiredVersion), tostring(loc.modVer)))
    end
    if adv.protocol ~= loc.protocol then
        return fail("D", "protocol_mismatch", string.format("Incompatible network protocol (host %s, you %s); joining was refused.", tostring(adv.protocol), tostring(loc.protocol)))
    end
    if type(adv.gameVer) == "string" and adv.gameVer ~= "" and type(loc.gameVer) == "string" and loc.gameVer ~= "" and adv.gameVer ~= loc.gameVer then
        return fail("D", "game_version_mismatch", string.format("Different Goobies game version (host %s, you %s); joining was refused.", adv.gameVer, loc.gameVer))
    end
    return { ok = true, required = req, installed = inst }
end

-- What a host puts into SESSION_INFO (single place; values come from Config only).
function Compat.Advert(cfgModule, gameVer)
    return { requiredMod = cfgModule.MOD_NAME, requiredVersion = cfgModule.MOD_VERSION, protocol = cfgModule.PROTOCOL_VERSION, gameVer = gameVer or "" }
end

-- Plain text form, readable WITHOUT the mod (a launcher or a future Steam-lobby metadata field can carry it):
--   GMPADV1;mod=GoobiesMP;ver=<MOD_VERSION>;proto=<n>;game=
function Compat.AdvertToText(a)
    return string.format("GMPADV1;mod=%s;ver=%s;proto=%s;game=%s", tostring(a.requiredMod), tostring(a.requiredVersion), tostring(a.protocol), tostring(a.gameVer or ""))
end
function Compat.AdvertFromText(s)
    if type(s) ~= "string" or not s:match("^GMPADV1;") then return nil end
    local mod, ver, proto, game = s:match("^GMPADV1;mod=([^;]*);ver=([^;]*);proto=(%d+);game=([^;]*)$")
    if not mod or mod == "" or ver == "" then return nil end
    return { requiredMod = mod, requiredVersion = ver, protocol = tonumber(proto), gameVer = game }
end

-- Case B accepted: write Enabled=true (the SAME setting the launcher and the settings screen use) and tell the player a restart is needed.
-- Never hot-reloads. restart.ask is the question the UI must put to the player; performing the restart is the launcher's job.
function Compat.AcceptEnable(modsettings, fs, path)
    local r = modsettings.Save(fs, path, true)
    if not r.ok then return r end
    r.restart = { required = true, ask = "Restart Goobies now?" }
    return r
end

return Compat
