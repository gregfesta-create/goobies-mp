-- The dev, probe and self-test modules a friend or production build may leave out (the friend zip does:
-- tools/release_mapping.py reads this list). Every one of them is reached only behind a dev or diagnostic gate and is
-- loaded lazily, so a build without them loads, boots and ticks; a diagnostic asked for in such a build is switched
-- off with one log line (gmp_app.lua App.DIAGNOSTICS). Dev builds ship them all.
-- NOT on the list although the names say dev: gmp_dev_slot (main.lua reads the launch slot in every build) and
-- gmp_dev_autostart (the lobby's world entry driver, gmp_lobby_runtime.lua).
local Dev = {}
Dev.LIST = {
    -- the local test lobby (release_bundle.py DEV_ONLY_MODULES; its gmp_dev_steam_socket_transport is the qa_four
    -- tools' transport and never in Scripts)
    'gmp_dev_socket_lobby_backend',
    'gmp_dev_socket_lobby_check',
    -- the dev identity provider (AUTH_MODE=dev, dev builds only)
    'gmp_auth_dev',
    -- self-tests and scripted checks
    'gmp_selftest',
    'gmp_lobby_selftest',
    'gmp_lobby_ui_check',
    'gmp_steam_lobby_check',
    'gmp_m3',
    'gmp_s2',
    'gmp_presence_probe',
    -- native probes and captures (dev_probes)
    'gmp_native_binding_probe',
    'gmp_native_spawn_probe',
    'gmp_native_timer_probe',
    'gmp_native_xp_capture',
    'gmp_native_rebuild_probe',
    'gmp_native_state_probe',
    'gmp_native_enemy_actor_capture',
    'gmp_progression_restore_probe',
    'gmp_enemy_binding_probe',
    'gmp_combat_binding_probe',
    -- dev cycles and dispatch probes (dev_probes)
    'gmp_dev_enemy_motion',
    'gmp_dev_migration_cycle',
    'gmp_dev_controller_probe',
    'gmp_dev_dispatch_probe',
    'gmp_dev_pickup_combined_probe',
    'gmp_dev_pickup_compaction_probe',
    'gmp_handover_f5',
}
Dev.SET = {}
for _, name in ipairs(Dev.LIST) do Dev.SET[name] = true end

-- name -> module | nil, reason ('not_in_build' when the file is not there; the load error otherwise)
function Dev.Load(name)
    local ok, module = pcall(require, name)
    if ok then return module end
    local text = tostring(module)
    if text:find("module '" .. name .. "' not found", 1, true) then return nil, 'not_in_build' end
    return nil, text:sub(1, 300)
end
-- A table that loads the module on first use (for the few that are used as module-level values).
function Dev.Lazy(name)
    return setmetatable({}, { __index = function(_, key) return require(name)[key] end })
end
return Dev
