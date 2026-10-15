-- GoobiesMP production: M1 message schemas (session/identity/roster only; NO gameplay messages yet).
-- Each message type has a fixed direction, a fixed channel and an ORDERED field list (field order = wire order).
--   dir: "C2H" client->host, "H2C" host->client, "BOTH"
--   ch : "R" = needs reliable delivery (exactly-once processing, resent until acked), "U" = unreliable (latest wins, may be dropped)
-- Field types: int, str, bool, list (of = ordered record schema; record atoms are int/str/bool).
local Messages = {}

local function F(name, t, of) return { name = name, type = t, of = of } end

Messages.Schema = {
    STEAM_AUTHORITY_PROOF = { dir='H2C',ch='R',fields={F('hostKey','str'),F('term','int'),F('proofNonce','str')} },
    STEAM_AUTHORITY_ACK = { dir='C2H',ch='R',fields={F('hostKey','str'),F('term','int'),F('proofNonce','str')} },
    -- host announces the session to a newly connected peer
    SESSION_INFO = { dir = "H2C", ch = "R", fields = {
        F("mode", "str"), F("maxPlayers", "int"), F("currentPlayers", "int"), F("phase", "str"),
        F("allowRejoin", "bool"), F("modVer", "str"),
        -- compatibility advertisement (lobby milestone; trailing = additive). The client checks these BEFORE it authenticates or joins.
        F("requiredMod", "str"), F("protocol", "int"), F("gameVer", "str") } },
    -- client asks to join (identity is a CLAIM until the transport authenticates it; the host decides everything else)
    JOIN_REQ = { dir = "C2H", ch = "R", fields = {
        F("key", "str"), F("name", "str"), F("modVer", "str"), F("gameVer", "str"), F("reqColor", "str") } },
    JOIN_ACCEPT = { dir = "H2C", ch = "R", fields = {
        F("key", "str"), F("slot", "int"), F("color", "str"), F("token", "str"), F("rosterRev", "int") } },
    JOIN_REJECT = { dir = "H2C", ch = "R", fields = { F("reason", "str") } },
    -- full player list/state (host authoritative); rev increases on every roster change
    ROSTER = { dir = "H2C", ch = "R", fields = {
        F("rev", "int"), F("phase", "str"), F("maxPlayers", "int"), F("currentPlayers", "int"),
        F("players", "list", { F("key", "str"), F("name", "str"), F("slot", "int"), F("color", "str"), F("role", "str"), F("conn", "str") }) } },
    -- slot/colour assignment of ONE player (incremental; the full ROSTER carries the same data)
    ASSIGN = { dir = "H2C", ch = "R", fields = { F("rev", "int"), F("key", "str"), F("slot", "int"), F("color", "str") } },
    -- client REQUEST for a colour change; host answers with ASSIGN (accepted) or REQ_DENIED
    COLOR_REQ = { dir = "C2H", ch = "R", fields = { F("color", "str") } },
    REQ_DENIED = { dir = "H2C", ch = "R", fields = { F("ofType", "str"), F("reason", "str") } },
    -- disconnect
    LEAVE = { dir = "C2H", ch = "R", fields = { F("reason", "str") } },
    KICK = { dir = "H2C", ch = "R", fields = { F("reason", "str") } },
    -- reconnect (claimSlot/claimColor are CLAIMS the host verifies against its own record; 0 / "" = no claim)
    REJOIN_REQ = { dir = "C2H", ch = "R", fields = {
        F("key", "str"), F("token", "str"), F("claimSlot", "int"), F("claimColor", "str"), F("modVer", "str"), F("gameVer", "str") } },
    REJOIN_ACCEPT = { dir = "H2C", ch = "R", fields = { F("key", "str"), F("slot", "int"), F("color", "str"), F("rosterRev", "int") } },
    REJOIN_REJECT = { dir = "H2C", ch = "R", fields = { F("reason", "str") } },
    -- AUTHENTICATION (PHASE2 12.17/12.18). Identity in AUTH_HELLO is a CLAIM; only AUTH_RESULT ok=true (host's own verdict) makes it
    -- an authenticated identity. Ticket bytes travel as hex text in chunks (the codec is text and limited to one packet).
    AUTH_HELLO = { dir = "C2H", ch = "R", fields = { F("key", "str"), F("scheme", "str") } },
    AUTH_CHALLENGE = { dir = "H2C", ch = "R", fields = { F("hostKey", "str"), F("nonce", "str"), F("scheme", "str") } },
    AUTH_TICKET = { dir = "C2H", ch = "R", fields = { F("nonce", "str"), F("idx", "int"), F("total", "int"), F("data", "str") } },
    AUTH_HOST_TICKET = { dir='H2C',ch='R',fields={F('nonce','str'),F('idx','int'),F('total','int'),F('data','str')} },
    AUTH_HOST_ACK = { dir='C2H',ch='R',fields={F('nonce','str'),F('hostKey','str'),F('ok','bool'),F('reason','str')} },
    AUTH_RESULT = { dir = "H2C", ch = "R", fields = { F("ok", "bool"), F("key", "str"), F("reason", "str") } },
    -- LOBBY (host authoritative). Identity/slot/colour/connection stay in ROSTER; LOBBY_STATE carries the pre-game extras keyed by IDENTITY KEY.
    -- lrev increases on every lobby change; state = open | handoff_pending (Start accepted, gameplay hand-off NOT implemented).
    LOBBY_STATE = { dir = "H2C", ch = "R", fields = {
        F("lrev", "int"), F("state", "str"), F("allowRejoin", "bool"), F("maxPlayers", "int"),
        F("players", "list", { F("key", "str"), F("ready", "bool"), F("class", "str"), F("artifacts", "str") }) } },
    READY_REQ = { dir = "C2H", ch = "R", fields = { F("ready", "bool"), F("policyRevision", "int") } },
    SELECT_REQ = { dir = "C2H", ch = "R", fields = { F("class", "str"), F("artifacts", "str") } },
    ACCEPTED_SELECTION = {dir='H2C',ch='R',fields={F('term','int'),F('key','str'),F('revision','int'),F('class','str'),F('artifacts','str'),F('frozen','bool'),F('runGeneration','int')}},
    -- chat: the author is the key the HOST bound to the peer; CHAT_REQ carries no identity at all
    CHAT_REQ = { dir = "C2H", ch = "R", fields = { F("text", "str") } },
    CHAT = { dir = "H2C", ch = "R", fields = { F("seq", "int"), F("key", "str"), F("name", "str"), F("text", "str") } },
    -- host-only actions. A client may ASK; the host always answers REQ_DENIED(not_host) (the host is never a peer).
    SETTINGS_REQ = { dir = "C2H", ch = "R", fields = { F("maxPlayers", "int"), F("allowRejoin", "bool") } },
    KICK_REQ = { dir = "C2H", ch = "R", fields = { F("key", "str") } },
    START_REQ = { dir = "C2H", ch = "R", fields = { F("note", "str") } },
    START = { dir = "H2C", ch = "R", fields = { F("state", "str"), F("lrev", "int") } },
    -- presence; rosterRev = newest roster revision the sender knows (lets the host notice a stale client)
    HEARTBEAT = { dir = "BOTH", ch = "U", fields = { F("rosterRev", "int") } },
}

-- Stable ordered list of type names (for tests / docs).
Messages.Types = {}
for name in pairs(Messages.Schema) do Messages.Types[#Messages.Types + 1] = name end
table.sort(Messages.Types)

-- D52: wait for the next game. Session messages of every mode, kept out of the pinned Types list (like the presence
-- types). WAIT_REQ carries the JOIN_REQ fields; the host answers WAIT_ACCEPT (waiting outside the roster until the
-- lobby return), JOIN_ACCEPT (the lobby is open, or the player holds a slot) or JOIN_REJECT.
-- WAIT_MOVE (the host changes: F5 handover or a graceful departure): where the waiter follows (hostKey, the new
-- transport term) and its place in the waiting list (rank, 1 = first); its WAIT_REQ to the new host carries the rank
-- (0 = a new arrival) so the new host inherits the waiting list in order.
Messages.WaitTypes = { "WAIT_REQ", "WAIT_ACCEPT", "WAIT_MOVE" }
Messages.Schema.WAIT_REQ = { dir = "C2H", ch = "R", fields = {
    F("key", "str"), F("name", "str"), F("modVer", "str"), F("gameVer", "str"), F("reqColor", "str"), F("rank", "int") } }
Messages.Schema.WAIT_ACCEPT = { dir = "H2C", ch = "R", fields = { F("key", "str"), F("rosterRev", "int") } }
Messages.Schema.WAIT_MOVE = { dir = "H2C", ch = "R", fields = { F("hostKey", "str"), F("term", "int"), F("rank", "int") } }

-- M3.1 PRESENCE messages (position and alive/dead; unreliable, latest wins). They are registered in Schema like every other type, but they are
-- deliberately NOT part of Messages.Types: that list is the pinned set of the 27 core types (test_codec.lua [12]). They are listed in
-- Messages.PresenceTypes. Coordinates are integer centimetres; `seg` is the sender's pawn-session counter (it changes when the sender's pawn
-- changes, and tells the receiver to re-anchor its approximate marker). PLAYER_STATE has NO identity field: the host uses the peer's bound key.
Messages.PresenceTypes = { "PLAYER_STATE", "WORLD_STATE" }
Messages.Schema.PLAYER_STATE = { dir = "C2H", ch = "U", fields = { F("seg", "int"), F("x", "int"), F("y", "int"), F("z", "int"), F("dead", "bool") } }
Messages.Schema.WORLD_STATE = { dir = "H2C", ch = "U", fields = {
    F("players", "list", { F("key", "str"), F("seg", "int"), F("x", "int"), F("y", "int"), F("z", "int"), F("dead", "bool"), F("age", "int") }) } }

Messages.Schema.PLAYER_STATE_VISUAL = {dir='C2H',ch='U',fields={
    F('seg','int'),F('x','int'),F('y','int'),F('z','int'),F('dead','bool'),
    F('pitch','int'),F('yaw','int'),F('roll','int'),F('motion','int')}}
Messages.Schema.WORLD_STATE_VISUAL = {dir='H2C',ch='U',fields={F('players','list',{
    F('key','str'),F('seg','int'),F('x','int'),F('y','int'),F('z','int'),F('dead','bool'),F('age','int'),
    F('pitch','int'),F('yaw','int'),F('roll','int'),F('motion','int')})}}
-- Separate appearance messages preserve the earlier animation wire format.
Messages.Schema.PLAYER_AVATAR_STATE={dir='C2H',ch='U',fields={
    F('seg','int'),F('x','int'),F('y','int'),F('z','int'),F('dead','bool'),
    F('pitch','int'),F('yaw','int'),F('roll','int'),F('motion','int'),F('model','int')}}
Messages.Schema.WORLD_AVATAR_STATE={dir='H2C',ch='U',fields={F('players','list',{
    F('key','str'),F('seg','int'),F('x','int'),F('y','int'),F('z','int'),F('dead','bool'),F('age','int'),
    F('pitch','int'),F('yaw','int'),F('roll','int'),F('motion','int'),F('model','int')})}}
-- Opt-in shared island handoff; all lifecycle messages use reliable delivery.
Messages.Schema.PORTAL_REQ={dir='C2H',ch='R',fields={F('epoch','int'),F('island','int')}}
Messages.Schema.TRAVEL_CHECK={dir='H2C',ch='R',fields={F('epoch','int'),F('island','int'),F('token','int')}}
Messages.Schema.TRAVEL_WAIT={dir='H2C',ch='R',fields={F('epoch','int'),F('island','int'),F('token','int'),F('players','list',{F('slot','int')})}}
Messages.Schema.TRAVEL_STATUS={dir='C2H',ch='R',fields={F('epoch','int'),F('island','int'),F('token','int'),F('blocked','bool')}}
Messages.Schema.NATIVE_WORLD_READY={dir='C2H',ch='R',fields={F('term','int'),F('epoch','int'),F('island','int')}}
Messages.Schema.DEV_CYCLE_REPLACEMENT_ACK={dir='C2H',ch='R',fields={F('term','int'),F('epoch','int'),F('island','int'),F('revision','int'),F('sequence','int'),F('digest','str')}}
Messages.Schema.DEV_CYCLE_READY={dir='H2C',ch='R',fields={F('term','int'),F('epoch','int'),F('island','int'),F('revision','int'),F('sequence','int'),F('digest','str')}}
for _,kind in ipairs{'ROSTER','LOBBY_STATE'}do
    local fields={F('part','int'),F('total','int'),F('rowCount','int')}
    for _,field in ipairs(Messages.Schema[kind].fields)do fields[#fields+1]=field end
    Messages.Schema[kind..'_PAGE']={dir='H2C',ch='R',fields=fields}
end
Messages.Schema.DEV_CYCLE_START={dir='H2C',ch='R',fields={F('term','int'),F('epoch','int'),F('island','int'),F('revision','int'),F('sequence','int'),F('digest','str'),F('cycle','int'),F('targetSlot','int')}}
Messages.Schema.DEV_CYCLE_ABORT={dir='BOTH',ch='R',fields={F('term','int'),F('epoch','int'),F('island','int'),F('reason','str')}}
Messages.Schema.ISLAND_BEGIN={dir='H2C',ch='R',fields={F('epoch','int'),F('island','int')}}
Messages.Schema.ISLAND_MANIFEST={dir='H2C',ch='R',fields={
    F('epoch','int'),F('island','int'),F('seed','int'),F('stage','int'),F('chunks','int'),F('foliage','int'),F('artifactBiome','bool'),
    F('biomes','list',{F('name','str')})}}
Messages.Schema.PAUSE_REQ={dir='C2H',ch='R',fields={F('paused','bool')}}
Messages.Schema.CHECKPOINT_CHUNK={dir='H2C',ch='R',fields={F('term','int'),F('sequence','int'),
    F('index','int'),F('total','int'),F('size','int'),F('digest','str'),F('data','str')}}
Messages.Schema.CHECKPOINT_ACK={dir='C2H',ch='R',fields={F('term','int'),F('sequence','int'),F('digest','str')}}
Messages.Schema.PLAYER_STATE_CHUNK={dir='C2H',ch='R',fields={F('term','int'),F('sequence','int'),
    F('index','int'),F('total','int'),F('size','int'),F('digest','str'),F('data','str')}}
Messages.Schema.HANDOVER_FORCE_REQ={dir='C2H',ch='R',fields={F('term','int'),F('sequence','int'),F('digest','str')}}
-- D59: answer = true "become the new host", false "no"
Messages.Schema.DEPARTURE_CLAIM={dir='C2H',ch='R',fields={F('term','int'),F('revision','int'),F('request','str'),F('answer','bool')}}
Messages.Schema.DEPARTURE_STATE={dir='H2C',ch='R',fields={F('term','int'),F('revision','int'),F('sequence','int'),
    F('digest','str'),F('coordinator','str'),F('eligible','bool'),F('active','bool'),F('paused','bool'),
    F('winner','str'),F('request','str'),F('accepted','bool'),F('reason','str'),F('phase','str')}}
Messages.Schema.HANDOVER_STAGE={dir='H2C',ch='R',fields={F('term','int'),F('sequence','int'),F('digest','str'),F('hostKey','str'),F('formerHost','str'),F('nonce','str')}}
Messages.Schema.DEPARTURE_STAGE={dir='H2C',ch='R',fields=Messages.Schema.HANDOVER_STAGE.fields}
Messages.Schema.HANDOVER_STAGE_ACK={dir='C2H',ch='R',fields={F('term','int'),F('sequence','int'),F('digest','str'),F('ready','bool')}}
Messages.Schema.PAUSE_STATE={dir='H2C',ch='R',fields={F('revision','int'),F('paused','bool'),F('locked','bool'),F('hostOnly','bool'),F('owner','str'),F('reason','str')}}
Messages.Schema.PAUSE_ACK={dir='C2H',ch='R',fields={F('revision','int'),F('paused','bool')}}
Messages.Schema.ISLAND_END={dir='H2C',ch='R',fields={F('epoch','int')}}
Messages.Schema.ISLAND_WAIT={dir='H2C',ch='R',fields={F('epoch','int'),F('island','int'),F('players','list',{F('slot','int')})}}
Messages.Schema.ISLAND_RESUME_REQ={dir='C2H',ch='R',fields={F('token','int')}}
Messages.Schema.ISLAND_RESUME={dir='H2C',ch='R',fields={F('token','int'),F('epoch','int'),F('island','int'),F('seed','int'),F('stage','int'),F('chunks','int'),F('foliage','int'),F('artifactBiome','bool'),F('biomes','list',{F('name','str')})}}
Messages.Schema.ISLAND_READY={dir='C2H',ch='R',fields={F('epoch','int'),F('island','int'),F('stamp','str')}}
Messages.Schema.ISLAND_COMMIT={dir='H2C',ch='R',fields={F('epoch','int'),F('island','int'),F('stamp','str')}}
-- Complete host-owned enemy snapshots are fragmented below the relay budget.
-- Clients never send authoritative enemy state.
Messages.Schema.ENEMY_SNAPSHOT={dir='H2C',ch='R',fields={
    F('epoch','int'),F('revision','int'),F('index','int'),F('total','int'),F('count','int'),
    F('enemies','list',{F('id','str'),F('slot','int'),F('enemyType','int'),
        F('x','int'),F('y','int'),F('z','int'),F('hp','str'),F('dead','bool')})}}
Messages.Schema.ENEMY_SNAPSHOT_V2={dir='H2C',ch='R',fields={
    F('version','int'),F('epoch','int'),F('revision','int'),F('index','int'),F('total','int'),F('count','int'),
    F('enemies','list',{F('id','str'),F('slot','int'),F('enemyType','int'),
        F('x','int'),F('y','int'),F('z','int'),F('hp','str'),F('dead','bool'),F('damage','str')})}}
-- Protocol 9: achievements are always blocked during multiplayer (D16), so the policy carries no achievement flag.
-- The host-picked artifacts and hostUnlocked rows (D25/D29) are Lua policy fields; their paged wire form belongs to W11.
Messages.Schema.SESSION_POLICY={dir='H2C',ch='R',fields={F('revision','int'),F('locked','bool'),F('runGeneration','int')}}
Messages.Schema.SESSION_POLICY_ACK={dir='C2H',ch='R',fields={F('revision','int')}}
Messages.Schema.OUTCOME_V1={dir='H2C',ch='R',fields={
 F('version','int'),F('term','int'),F('worldEpoch','int'),F('context','str'),F('revision','int'),F('journalSeq','int'),
 F('index','int'),F('total','int'),F('enemyCount','int'),F('pickupCount','int'),
 F('enemies','list',{F('id','str'),F('slot','int'),F('enemyType','int'),F('x','int'),F('y','int'),F('z','int'),F('hp','str'),F('dead','bool'),F('damage','str')}),
 F('pickups','list',{F('id','str'),F('kind','str'),F('amount','int'),F('x','int'),F('y','int'),F('z','int'),F('state','str')})}}
Messages.Schema.OUTCOME_ACK={dir='C2H',ch='R',fields={F('term','int'),F('worldEpoch','int'),F('revision','int'),F('journalSeq','int')}}

------------------------------------------------------------------ C0 world-entry contract (PLAN_WORLD_ENTRY.md 3.2)
-- Reserved messages. Their stub handlers record receipt only; the owning units implement them:
--   S (gmp_host.lua / gmp_client.lua): AUTHORITY_PREP, AUTHORITY_PREP_STATE, ATTACK_INTENT, ATTACK_RESULT, RUN_STATS
--   W (gmp_host_entry.lua / gmp_client_entry.lua): RUN_ABORT, LOBBY_RETURN, POLICY_LIST (W11) and the refusal code reservation_expired
-- `key` is the RunContext key. ATTACK_INTENT is the gmp_host_combat.lua intent ({context, sequence, enemyId, attack});
-- clients never send damage. RUN_STATS pages one end-screen set (S8a): `part`/`total` number the parts of the WHOLE set
-- (1..total, like POLICY_LIST page/pages); each part carries one row's slot and totals and at most 12 of its weapons.
-- See Messages.RunStats / ValidateRunStatsPart / RunStatsParts / RunStatsReceive below.
Messages.Schema.AUTHORITY_PREP={dir='C2H',ch='R',fields={F('key','str'),F('phase','str'),F('ok','bool'),F('reason','str')}}
Messages.Schema.AUTHORITY_PREP_STATE={dir='H2C',ch='R',fields={F('key','str'),F('phase','str'),F('waiting','list',{F('slot','int')})}}
Messages.Schema.ATTACK_INTENT={dir='C2H',ch='R',fields={F('context','str'),F('sequence','int'),F('enemyId','str'),F('attack','int')}}
Messages.Schema.ATTACK_RESULT={dir='H2C',ch='R',fields={F('sequence','int'),F('ok','bool')}}
Messages.Schema.RUN_STATS={dir='H2C',ch='R',fields={F('runGeneration','int'),F('slot','int'),F('part','int'),F('total','int'),
    F('kills','int'),F('damage','int'),F('weapons','list',{F('type','str'),F('damage','int'),F('kills','int')})}}
Messages.Schema.RUN_ABORT={dir='H2C',ch='R',fields={F('runGeneration','int'),F('reason','str')}}
Messages.Schema.LOBBY_RETURN={dir='H2C',ch='R',fields={F('runGeneration','int')}}
-- Paged session-policy lists (reserved for W11): `list` is 'artifacts' or 'hostUnlocked'; one page carries at most
-- Messages.Policy.LIST_PAGE_ENTRIES actor paths. See ValidatePolicyList / PolicyListPages / PolicyListReceive below.
Messages.Schema.POLICY_LIST={dir='H2C',ch='R',fields={F('policyRevision','int'),F('list','str'),F('page','int'),F('pages','int'),
    F('entries','list',{F('path','str')})}}
Messages.ReservedTypes={'ATTACK_INTENT','ATTACK_RESULT','AUTHORITY_PREP','AUTHORITY_PREP_STATE','LOBBY_RETURN','POLICY_LIST','RUN_ABORT','RUN_STATS'}
-- Additive dev message (amendment, post-R1; CLIENT_UPGRADE_DAMAGE): a client's weapon upgrade state for its stand-in
-- (gmp_native_host_damage.lua ApplyStats). Numbers travel as %.17g text, like enemy HP. Not in Types/ReservedTypes, so
-- the protocol-9 pinned lists and golden files are unchanged; the host ignores it unless the run sync enabled the intake.
Messages.Schema.PLAYER_STATS={dir='C2H',ch='R',fields={F('revision','int'),F('damageMulti','str'),F('aoeMulti','str'),F('bonusDamage','str')}}
-- CLIENT_DAMAGE (post-R1 dev flag): the host's contact hit on one client (gmp_run_sync_contact.lua); the client
-- applies it with its own BP_Player.ChangeHP. Ignored unless the run sync enabled the intake.
Messages.Schema.CLIENT_HIT={dir='H2C',ch='R',fields={F('context','str'),F('sequence','int'),F('damage','str'),F('enemies','int')}}
-- SHARED_LIVES (D32, post-R1 dev flag): a client went down (a lethal hit it did not apply), the host's lives state, and
-- the host's revive of one client. `policy.lives` stays reserved (nil) in protocol 9; the pool lives in LIVES_STATE.
Messages.Schema.PLAYER_DOWN={dir='C2H',ch='R',fields={F('context','str'),F('sequence','int')}}
Messages.Schema.LIVES_STATE={dir='H2C',ch='R',fields={F('context','str'),F('revision','int'),F('lives','int'),F('ended','bool'),
    F('ghosts','list',{F('slot','int'),F('progress','int')})}}
Messages.Schema.PLAYER_REVIVE={dir='H2C',ch='R',fields={F('context','str'),F('sequence','int'),F('hp','str'),F('invulnerable','str')}}
-- Enemy delta stream (dev, client rows mode; gmp_enemy_delta.lua): per client, within a bandwidth budget. ENEMY_LIFE
-- (reliable) carries spawns (s), deaths (d) and damage updates (u); ENEMY_MOTION (unreliable) carries position/HP deltas
-- stamped with the host's time in ms. Numbers that are not integers travel as strings ('' = none).
Messages.Schema.ENEMY_LIFE={dir='H2C',ch='R',fields={F('epoch','int'),
    F('events','list',{F('kind','str'),F('id','str'),F('slot','int'),F('enemyType','int'),F('x','int'),F('y','int'),
        F('hp','str'),F('damage','str')})}}
-- ENEMY_MOTION.data: packed rows, 9 characters each (gmp_enemy_delta.lua EncodeRow: slot*16 + lifetime parity, then x
-- and y quantized to 4 cm; URL-safe base64 digits, never escaped by the codec).
Messages.Schema.ENEMY_MOTION={dir='H2C',ch='U',fields={F('epoch','int'),F('t','int'),F('data','str')}}
-- ATTACK_AOE (dev, CLIENT_ATTACKS; R1 attempt 5): one skipped client DamageAOE of a movement/contact class passive
-- (Bingus nova, Hoozey fire trail; research section 12) as an observation: attack = itemTypeIndex + 1 (0 = no item),
-- the observed position (cm), radius and damage text. The host resolves it itself (gmp_run_sync.lua).
Messages.Schema.ATTACK_AOE={dir='C2H',ch='R',fields={F('context','str'),F('sequence','int'),F('attack','int'),
    F('x','int'),F('y','int'),F('radius','int'),F('damage','str')}}
-- CHEAT_STATE (dev, W; D41): the host's player cheats for every client (Cheat Mod reads them through the shared
-- GoobiesMPCheatPolicy interface). A rising revision; sent on change and to each newly joined peer.
Messages.Schema.CHEAT_STATE={dir='H2C',ch='R',fields={F('revision','int'),F('invulnerable','bool'),F('unlockClasses','bool')}}
-- ACTOR_INFO (dev, D43): one host boss/unique actor's look for the clients' visual-only copy of its row: kind boss|unique,
-- the static mesh object path (/Game/...), scale, display name and max HP (the boss bar).
Messages.Schema.ACTOR_INFO={dir='H2C',ch='R',fields={F('epoch','int'),F('id','str'),F('kind','str'),F('mesh','str'),
    F('scale','str'),F('name','str'),F('maxHp','str')}}
-- LIVE_STATS (dev, W; test 10): a client's own live HUD numbers as the host credits them (gmp_live_hud.lua): kills
-- and damage per second, 1-2 per second.
Messages.Schema.LIVE_STATS={dir='H2C',ch='R',fields={F('runGeneration','int'),F('kills','int'),F('dps','int')}}
function Messages.ValidateLiveStats(f)
    if type(f)~='table' then return nil,'live_stats' end
    for _,k in ipairs({'runGeneration','kills','dps'}) do
        if math.type(f[k])~='integer' or f[k]<0 or f[k]>9007199254740991 then return nil,'live_stats_'..k end
    end
    if f.runGeneration<1 then return nil,'live_stats_runGeneration' end
    return {runGeneration=f.runGeneration,kills=f.kills,dps=f.dps}
end
-- PORTAL_STATE (dev, S; test 10): the host's portals on its current island, "x,y,z,yaw;..." (at most PORTAL_MAX, one
-- decimal), for the clients' copies of the game's portal (gmp_portal_mirror.lua). An empty list: no portal.
Messages.PORTAL_MAX=8
Messages.Schema.PORTAL_STATE={dir='H2C',ch='R',fields={F('epoch','int'),F('island','int'),F('spots','str')}}
function Messages.ValidatePortalState(f)
    if type(f)~='table' or math.type(f.epoch)~='integer' or f.epoch<0 or math.type(f.island)~='integer' or f.island<0
        or type(f.spots)~='string' or #f.spots>Messages.PORTAL_MAX*48 then return nil,'portal_state' end
    local spots={}
    if f.spots~='' then
        for part in (f.spots..';'):gmatch('([^;]*);') do
            if #spots>=Messages.PORTAL_MAX then return nil,'portal_state_count' end
            local x,y,z,yaw=part:match('^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$')
            x,y,z,yaw=tonumber(x),tonumber(y),tonumber(z),tonumber(yaw)
            if not (x and y and z and yaw) or math.abs(x)>2000000 or math.abs(y)>2000000 or math.abs(z)>100000
                or math.abs(yaw)>720 then return nil,'portal_state_spot' end
            spots[#spots+1]={x=x,y=y,z=z,yaw=yaw}
        end
    end
    return {epoch=f.epoch,island=f.island,spots=spots}
end
-- MOD_MANIFEST (dev, W; D42): the host's gameplay mods and versions (gmp_mod_manifest.lua, "id:version;...").
Messages.Schema.MOD_MANIFEST={dir='H2C',ch='R',fields={F('mods','str')}}
Messages.DevTypes={'PLAYER_STATS','CLIENT_HIT','PLAYER_DOWN','LIVES_STATE','PLAYER_REVIVE','ENEMY_LIFE','ENEMY_MOTION','ATTACK_AOE','CHEAT_STATE','ACTOR_INFO','LIVE_STATS','MOD_MANIFEST','PORTAL_STATE'}
require('gmp_pickups_wire').Install(Messages)   -- D45 hook (Coder C): 8 shared XP / pickup dev schemas, appended to DevTypes
require('gmp_cheat_requests').InstallMessages(Messages)   -- D56 (Coder D): CHEAT_REQ dev schema, appended to DevTypes
Messages.PlayerStats={MULTI_MIN=0.01,MULTI_MAX=1000,BONUS_MAX=1000000,TEXT_BYTES=32}
local function statNumber(text,lo,hi)
    if type(text)~='string' or #text<1 or #text>Messages.PlayerStats.TEXT_BYTES
        or not text:match('^[%-]?%d+%.?%d*[eE]?[%-+]?%d*$') then return nil end
    local n=tonumber(text)
    if type(n)~='number' or n~=n or n<lo or n>hi then return nil end
    return n
end
-- PLAYER_STATS fields -> {revision, damageMulti, aoeMulti, bonusDamage} (numbers) or nil, reason.
function Messages.ValidatePlayerStats(f)
    if type(f)~='table' or math.type(f.revision)~='integer' or f.revision<1 or f.revision>2147483647 then return nil,'player_stats_revision' end
    local P=Messages.PlayerStats
    local dm=statNumber(f.damageMulti,P.MULTI_MIN,P.MULTI_MAX)
    if not dm then return nil,'player_stats_damage_multi' end
    local am=statNumber(f.aoeMulti,P.MULTI_MIN,P.MULTI_MAX)
    if not am then return nil,'player_stats_aoe_multi' end
    local bonus=statNumber(f.bonusDamage,0,P.BONUS_MAX)
    if not bonus then return nil,'player_stats_bonus_damage' end
    return {revision=f.revision,damageMulti=dm,aoeMulti=am,bonusDamage=bonus}
end
-- CLIENT_HIT fields -> {context, sequence, damage, enemies} (damage a number in (0, 1e6]) or nil, reason.
function Messages.ValidateClientHit(f)
    if type(f)~='table' or type(f.context)~='string' or #f.context<1 or #f.context>256 then return nil,'client_hit_context' end
    if math.type(f.sequence)~='integer' or f.sequence<1 or f.sequence>2147483647 then return nil,'client_hit_sequence' end
    local damage=statNumber(f.damage,0,1000000)
    if not damage or damage<=0 then return nil,'client_hit_damage' end
    if math.type(f.enemies)~='integer' or f.enemies<1 or f.enemies>4096 then return nil,'client_hit_enemies' end
    return {context=f.context,sequence=f.sequence,damage=damage,enemies=f.enemies}
end
local function devContext(v) return type(v)=='string' and #v>=1 and #v<=256 end
local function devSequence(v) return math.type(v)=='integer' and v>=1 and v<=2147483647 end
function Messages.ValidatePlayerDown(f)
    if type(f)~='table' or not devContext(f.context) or not devSequence(f.sequence) then return nil,'player_down' end
    return {context=f.context,sequence=f.sequence}
end
-- LIVES_STATE: lives 0..99, at most 4 ghosts with unique slots 1..4 and progress 0..1000 (per mille).
function Messages.ValidateLivesState(f)
    if type(f)~='table' or not devContext(f.context) or not devSequence(f.revision) or math.type(f.lives)~='integer'
        or f.lives<0 or f.lives>99 or type(f.ended)~='boolean' or type(f.ghosts)~='table' or #f.ghosts>4 then return nil,'lives_state' end
    local ghosts,seen={},{}
    for i,g in ipairs(f.ghosts) do
        if type(g)~='table' or math.type(g.slot)~='integer' or g.slot<1 or g.slot>4 or seen[g.slot]
            or math.type(g.progress)~='integer' or g.progress<0 or g.progress>1000 then return nil,'lives_state_ghost' end
        seen[g.slot]=true;ghosts[i]={slot=g.slot,progress=g.progress}
    end
    return {context=f.context,revision=f.revision,lives=f.lives,ended=f.ended,ghosts=ghosts}
end
-- PLAYER_REVIVE: heal to hp x HP_MAX (0 < hp <= 1) and `invulnerable` seconds of invulnerability (0.5..3).
function Messages.ValidatePlayerRevive(f)
    if type(f)~='table' or not devContext(f.context) or not devSequence(f.sequence) then return nil,'player_revive' end
    local hp,invulnerable=statNumber(f.hp,0,1),statNumber(f.invulnerable,0.5,3)
    if not hp or hp<=0 or not invulnerable then return nil,'player_revive_values' end
    return {context=f.context,sequence=f.sequence,hp=hp,invulnerable=invulnerable}
end
-- ATTACK_AOE fields -> {context, sequence, attack 0..256, x, y (|v| <= 2e6), radius 1..100000, damage >= 0} or nil.
function Messages.ValidateAttackAoe(f)
    if type(f)~='table' or not devContext(f.context) or not devSequence(f.sequence) then return nil,'attack_aoe' end
    local function int(v,lo,hi) return math.type(v)=='integer' and v>=lo and v<=hi end
    if not int(f.attack,0,256) or not int(f.x,-2000000,2000000) or not int(f.y,-2000000,2000000)
        or not int(f.radius,1,100000) then return nil,'attack_aoe_values' end
    local damage=statNumber(f.damage,0,1e12)
    if not damage then return nil,'attack_aoe_damage' end
    return {context=f.context,sequence=f.sequence,attack=f.attack,x=f.x,y=f.y,radius=f.radius,damage=damage}
end
local ACTOR_KINDS={boss=true,unique=true}
-- ACTOR_INFO fields -> {epoch, id, kind, mesh, scale 0..100, name <= 64, maxHp >= 0} or nil.
function Messages.ValidateActorInfo(f)
    if type(f)~='table' or math.type(f.epoch)~='integer' or f.epoch<1 or type(f.id)~='string' or #f.id>32
        or not f.id:match('^%d+:%d+$') or not ACTOR_KINDS[f.kind] then return nil,'actor_info' end
    if type(f.mesh)~='string' or #f.mesh>256 or not f.mesh:match('^/Game/[%w_/%.]+$') then return nil,'actor_info_mesh' end
    if type(f.name)~='string' or #f.name>64 then return nil,'actor_info_name' end
    local scale,maxHp=statNumber(f.scale,0,100),statNumber(f.maxHp,0,1e12)
    if not scale or scale<=0 or not maxHp then return nil,'actor_info_values' end
    return {epoch=f.epoch,id=f.id,kind=f.kind,mesh=f.mesh,scale=scale,name=f.name,maxHp=maxHp}
end
-- Stable refusal codes reserved for later units (REJOIN_REJECT / JOIN_REJECT reasons).
Messages.Refusal={RESERVATION_EXPIRED='reservation_expired'}

local function positiveInt(v) return math.type(v)=='integer' and v>=1 and v<=9007199254740991 end
local function count(v) return math.type(v)=='integer' and v>=0 and v<=9007199254740991 end
-- Session policy schema {revision, runGeneration, locked, artifacts, hostUnlocked}.
--   artifacts     host-picked actor paths applied to every player (D25), at most 32
--   hostUnlocked  actor paths unlocked in the host's normal save (D29 glow), at most 256
--   lives         RESERVED (D32): absent in protocol 9; any value is refused until L1 defines it
-- LIST_PAGE_ENTRIES: four 256-byte paths plus maximal framing stay under Codec.MAX_PACKET (1400).
Messages.Policy={MAX_ARTIFACTS=32,MAX_HOST_UNLOCKED=256,MAX_PATH_BYTES=256,RESERVED={'lives'},LIST_PAGE_ENTRIES=4}
local POLICY_FIELDS={revision=true,runGeneration=true,locked=true,artifacts=true,hostUnlocked=true}
local function actorPaths(list,limit)
    if type(list)~='table' or #list>limit then return false end
    local n,seen=0,{}
    for key,path in pairs(list) do
        n=n+1
        if math.type(key)~='integer' or key<1 or key>#list or type(path)~='string' or #path<1
            or #path>Messages.Policy.MAX_PATH_BYTES or not path:match('^/[%w_%-%./]+$') or seen[path] then return false end
        seen[path]=true
    end
    return n==#list
end
function Messages.ValidatePolicy(p)
    if type(p)~='table' then return false,'policy_missing' end
    if p.lives~=nil then return false,'policy_lives_reserved' end
    for key in pairs(p) do if not POLICY_FIELDS[key] then return false,'policy_unknown_field' end end
    if not positiveInt(p.revision) then return false,'policy_revision' end
    if not positiveInt(p.runGeneration) then return false,'policy_run_generation' end
    if type(p.locked)~='boolean' then return false,'policy_locked' end
    if not actorPaths(p.artifacts,Messages.Policy.MAX_ARTIFACTS) then return false,'policy_artifacts' end
    if not actorPaths(p.hostUnlocked,Messages.Policy.MAX_HOST_UNLOCKED) then return false,'policy_host_unlocked' end
    return true
end
function Messages.CopyPolicy(p)
    local artifacts,unlocked={},{}
    for i,path in ipairs(p.artifacts or {}) do artifacts[i]=path end
    for i,path in ipairs(p.hostUnlocked or {}) do unlocked[i]=path end
    return {revision=p.revision,runGeneration=p.runGeneration,locked=p.locked,artifacts=artifacts,hostUnlocked=unlocked}
end

------------------------------------------------------------------ paged policy lists (POLICY_LIST, reserved for W11)
local LIST_LIMIT={artifacts=Messages.Policy.MAX_ARTIFACTS,hostUnlocked=Messages.Policy.MAX_HOST_UNLOCKED}
local function maxPages(list) return math.max(1,math.ceil(LIST_LIMIT[list]/Messages.Policy.LIST_PAGE_ENTRIES)) end
-- One page: positive policyRevision, known list, 1<=page<=pages<=max pages for that list, at most LIST_PAGE_ENTRIES
-- valid unique paths. Only a single-page (empty) list may carry an empty page.
function Messages.ValidatePolicyList(f)
    if type(f)~='table' or not positiveInt(f.policyRevision) or not LIST_LIMIT[f.list] then return false end
    if math.type(f.pages)~='integer' or f.pages<1 or f.pages>maxPages(f.list)
        or math.type(f.page)~='integer' or f.page<1 or f.page>f.pages then return false end
    if type(f.entries)~='table' or #f.entries>Messages.Policy.LIST_PAGE_ENTRIES or (#f.entries==0 and f.pages>1) then return false end
    local paths={}
    for i,entry in ipairs(f.entries) do if type(entry)~='table' then return false end;paths[i]=entry.path end
    return actorPaths(paths,Messages.Policy.LIST_PAGE_ENTRIES)
end
-- Host side: the fewest pages carrying policy[list] at policy.revision, or nil when the policy or list is invalid.
function Messages.PolicyListPages(policy,list)
    if not LIST_LIMIT[list] or not Messages.ValidatePolicy(policy) then return nil end
    local paths,per=policy[list],Messages.Policy.LIST_PAGE_ENTRIES
    local count=math.max(1,math.ceil(#paths/per));local pages={}
    for page=1,count do
        local entries={}
        for i=(page-1)*per+1,math.min(page*per,#paths) do entries[#entries+1]={path=paths[i]} end
        pages[page]={policyRevision=policy.revision,list=list,page=page,pages=count,entries=entries}
    end
    return pages
end
-- Client side reassembly. `state` is a caller-owned table (one per session); `revision` is the mirrored SESSION_POLICY
-- revision. Returns nil while a set is incomplete, (true, paths) when the complete set arrived, or (false, reason).
-- Rules: the page revision must equal `revision`; pages arrive as 1..pages exactly once and in order (a duplicate,
-- skipped or out-of-order page discards the partial set); the page count may not change within a set; the reassembled
-- list must pass the policy bounds. A page 1 at a newer revision restarts the set.
function Messages.PolicyListReceive(state,f,revision)
    if not Messages.ValidatePolicyList(f) then return false,'policy_list_page_invalid' end
    if f.policyRevision~=revision then return false,'policy_list_revision_mismatch' end
    local current=state[f.list]
    if f.page==1 and (not current or current.revision~=f.policyRevision) then
        current={revision=f.policyRevision,pages=f.pages,next=1,paths={}};state[f.list]=current
    end
    if not current or current.revision~=f.policyRevision then state[f.list]=nil;return false,'policy_list_out_of_order' end
    if f.page<current.next then state[f.list]=nil;return false,'policy_list_duplicate_page' end
    if f.page>current.next then state[f.list]=nil;return false,'policy_list_out_of_order' end
    if f.pages~=current.pages then state[f.list]=nil;return false,'policy_list_pages_changed' end
    for _,entry in ipairs(f.entries) do current.paths[#current.paths+1]=entry.path end
    current.next=current.next+1
    if f.page<f.pages then return nil end
    state[f.list]=nil
    if not actorPaths(current.paths,LIST_LIMIT[f.list]) then return false,'policy_list_invalid' end
    return true,current.paths
end

-- Logical end-screen row shape (D21/D23): {runGeneration, rows<=4 x {slot, kills, damage, weapons<=16 x {type<=64 B, damage, kills}}}.
function Messages.ValidateRunStats(stats)
    if type(stats)~='table' or not positiveInt(stats.runGeneration) or type(stats.rows)~='table' or #stats.rows>4 then return false end
    local slots={}
    for _,row in ipairs(stats.rows) do
        if type(row)~='table' or math.type(row.slot)~='integer' or row.slot<1 or row.slot>4 or slots[row.slot]
            or not count(row.kills) or not count(row.damage) or type(row.weapons)~='table' or #row.weapons>16 then return false end
        slots[row.slot]=true
        local types={}
        for _,weapon in ipairs(row.weapons) do
            if type(weapon)~='table' or type(weapon.type)~='string' or #weapon.type<1 or #weapon.type>64 or types[weapon.type]
                or not count(weapon.damage) or not count(weapon.kills) then return false end
            types[weapon.type]=true
        end
    end
    return true
end

------------------------------------------------------------------ paged run stats (RUN_STATS, S8a)
-- The wire shape stays {runGeneration, slot, part, total, kills, damage, weapons}. A logical set (ValidateRunStats)
-- is sent as parts 1..total: rows in ascending slot order, each row in ceil(#weapons/12) contiguous parts (one empty
-- part for a row without weapons), every part repeating its row's kills and damage. PART_WEAPONS: 12 weapons of
-- 64-byte types with maximal integers stay under Codec.MAX_PACKET (1400); 16 do not. Weapon types on the wire are
-- printable ASCII without the codec separators (% | , ;), so they are never escaped and 64 bytes stay 64 bytes.
Messages.RunStats={MAX_ROWS=4,MAX_WEAPONS=16,PART_WEAPONS=12,MAX_TYPE_BYTES=64}
Messages.RunStats.MAX_PARTS=Messages.RunStats.MAX_ROWS*math.ceil(Messages.RunStats.MAX_WEAPONS/Messages.RunStats.PART_WEAPONS)
local RS=Messages.RunStats
local function wireType(v)
    return type(v)=='string' and #v>=1 and #v<=RS.MAX_TYPE_BYTES and not v:find('[^ -~]') and not v:find('[%%|,;]')
end
-- One RUN_STATS part: positive runGeneration, slot 1..4, 1<=part<=total<=MAX_PARTS, count kills/damage, at most
-- PART_WEAPONS weapons with unique wire-safe types and count damage/kills.
function Messages.ValidateRunStatsPart(f)
    if type(f)~='table' or not positiveInt(f.runGeneration) or math.type(f.slot)~='integer' or f.slot<1 or f.slot>RS.MAX_ROWS
        or math.type(f.total)~='integer' or f.total<1 or f.total>RS.MAX_PARTS
        or math.type(f.part)~='integer' or f.part<1 or f.part>f.total
        or not count(f.kills) or not count(f.damage) or type(f.weapons)~='table' or #f.weapons>RS.PART_WEAPONS then return false end
    local n,types=0,{}
    for key,weapon in pairs(f.weapons) do
        n=n+1
        if math.type(key)~='integer' or type(weapon)~='table' or not wireType(weapon.type) or types[weapon.type]
            or not count(weapon.damage) or not count(weapon.kills) then return false end
        types[weapon.type]=true
    end
    return n==#f.weapons
end
-- Host side: the fewest parts carrying a valid set, or nil, reason.
function Messages.RunStatsParts(stats)
    if not Messages.ValidateRunStats(stats) then return nil,'run_stats_invalid' end
    if #stats.rows==0 then return nil,'run_stats_no_rows' end
    local rows={}
    for i,row in ipairs(stats.rows) do
        for _,weapon in ipairs(row.weapons) do if not wireType(weapon.type) then return nil,'run_stats_weapon_type' end end
        rows[i]=row
    end
    table.sort(rows,function(a,b) return a.slot<b.slot end)
    local parts,per={},RS.PART_WEAPONS
    for _,row in ipairs(rows) do
        local count=math.max(1,math.ceil(#row.weapons/per))
        for chunk=1,count do
            local weapons={}
            for i=(chunk-1)*per+1,math.min(chunk*per,#row.weapons) do
                local w=row.weapons[i];weapons[#weapons+1]={type=w.type,damage=w.damage,kills=w.kills}
            end
            parts[#parts+1]={runGeneration=stats.runGeneration,slot=row.slot,part=0,total=0,kills=row.kills,damage=row.damage,weapons=weapons}
        end
    end
    for i,part in ipairs(parts) do part.part,part.total=i,#parts end
    return parts
end
-- Client side reassembly, modelled on PolicyListReceive. `state` is a caller-owned table (one per session);
-- `generation` is the client's current runGeneration. Returns nil while the set is incomplete, (true, stats) with
-- stats={runGeneration, rows} when the complete set arrived, or (false, reason).
-- Rules: the part's runGeneration must equal `generation`; parts arrive as 1..total exactly once and in order (a
-- duplicate, skipped or out-of-order part discards the partial set); `total` may not change within a set; slots
-- ascend; a row's continuation parts repeat its kills/damage and are never empty (and never follow an empty part);
-- the reassembled set must pass ValidateRunStats (rows<=4, weapons<=16 per row, unique types).
function Messages.RunStatsReceive(state,f,generation)
    if not Messages.ValidateRunStatsPart(f) then return false,'run_stats_part_invalid' end
    if f.runGeneration~=generation then return false,'run_stats_generation_mismatch' end
    local current=state.runStats
    if f.part==1 and (not current or current.runGeneration~=f.runGeneration) then
        current={runGeneration=f.runGeneration,total=f.total,next=1,rows={}};state.runStats=current
    end
    if not current or current.runGeneration~=f.runGeneration then state.runStats=nil;return false,'run_stats_out_of_order' end
    if f.part<current.next then state.runStats=nil;return false,'run_stats_duplicate_part' end
    if f.part>current.next then state.runStats=nil;return false,'run_stats_out_of_order' end
    if f.total~=current.total then state.runStats=nil;return false,'run_stats_parts_changed' end
    local row=current.rows[#current.rows]
    if row and f.slot==row.slot then
        if f.kills~=row.kills or f.damage~=row.damage then state.runStats=nil;return false,'run_stats_row_changed' end
        if #f.weapons==0 or #row.weapons==0 then state.runStats=nil;return false,'run_stats_empty_part' end
    else
        if row and f.slot<row.slot then state.runStats=nil;return false,'run_stats_row_order' end
        row={slot=f.slot,kills=f.kills,damage=f.damage,weapons={}};current.rows[#current.rows+1]=row
    end
    for _,w in ipairs(f.weapons) do row.weapons[#row.weapons+1]={type=w.type,damage=w.damage,kills=w.kills} end
    current.next=current.next+1
    if f.part<f.total then return nil end
    state.runStats=nil
    local result={runGeneration=current.runGeneration,rows=current.rows}
    if not Messages.ValidateRunStats(result) then return false,'run_stats_invalid' end
    return true,result
end
return Messages
