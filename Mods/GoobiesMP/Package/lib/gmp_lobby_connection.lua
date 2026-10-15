-- Session entry controller for the eventual native Steam lobby backend.
-- No backend is assumed: existing identity/auth exports alone cannot create
-- a Steam lobby or transport game packets. Accepted requests mean queued only.
local Config=require('gmp_config')
local C={};C.__index=C
function C.new(options)
    assert(type(options)=='table' and type(options.session)=='function','actual session provider required')
    return setmetatable({o=options,serial=0},C)
end
local function lobbyId(value)
    return type(value)=='string' and #value>=1 and #value<=20 and value:match('^[1-9]%d*$')~=nil
end
function C:Bind(backend)
    for _,name in ipairs{'Snapshot','Create','Join','Cancel'} do
        if type(backend)~='table' or type(backend[name])~='function' then return false,'lobby_backend_unavailable' end
    end
    if self.pending then return false,'connection_pending' end
    self.backend=backend;self.error=nil;return true
end
function C:_snapshot()
    if not self.backend then return nil,'Steam lobby transport is not available in this build.' end
    local ok,snapshot=pcall(self.backend.Snapshot,self.backend)
    if not ok or type(snapshot)~='table' then return nil,'Lobby backend could not provide its status.' end
    if snapshot.ready~=true then return nil,snapshot.reason or 'Steam lobby transport is not ready.' end
    if type(snapshot.generation)~='number' or snapshot.generation%1~=0 or snapshot.generation<0 then return nil,'Invalid lobby backend generation.' end
    return snapshot
end
function C:Model()
    self:Tick()
    local snapshot,reason=self:_snapshot();local session,role=self.o.session()
    local joined=session and (role=='host' or role=='client') and session.identity and session.sid
    return {available=snapshot~=nil,phase=self.pending and 'connecting' or joined and 'joined' or 'idle',
        scope=snapshot and snapshot.scope,
        -- D53: the hosts to pick from (the local test lobbies, or the Steam lobbies list)
        lobbies=snapshot and (snapshot.lobbies or (type(self.backend.ListLobbies)=='function' and self.backend:ListLobbies(self.friendsOnly~=false))) or nil,
        friendsOnly=self.friendsOnly~=false,
        status=self.error or (self.pending and 'Connecting to multiplayer lobby...') or reason or (snapshot and snapshot.status) or (joined and 'Multiplayer session active.' or 'Create a lobby or join by lobby ID.'),
        canCreate=snapshot~=nil and snapshot.canCreate~=false and not joined and not self.pending,
        canJoin=snapshot~=nil and snapshot.canJoin~=false and not joined and not self.pending,canCancel=self.pending~=nil,
        -- D52: the host refused a join because a run is in progress: offer to wait for the next game
        canWait=self.waitOffer~=nil and snapshot~=nil and not joined and not self.pending or false,
        -- the local test lobby: anyone; a Steam lobby: clients (1.0.1)
        canLeave=joined and snapshot and (snapshot.scope=='local_sockets' or role=='client') and type(self.backend.Leave)=='function' or false,
        -- t3 friend reports (Coder A): the host of a Steam lobby closes it (Cancel)
        canClose=joined and role=='host' and snapshot~=nil and snapshot.scope~='local_sockets' and type(self.backend.CloseLobby)=='function' or false,
        -- Steam overlay invite while hosting a real Steam lobby (CROSS_PC_GAPS 1.1).
        canInvite=joined and role=='host' and snapshot~=nil and snapshot.scope~='local_sockets' and type(self.backend.CanInvite)=='function'
            and self.backend:CanInvite()==true or false}
end
function C:Begin(kind,settings)
    if kind~='create' and kind~='join' then return false,'invalid_connection_action' end
    if self.pending then return false,'connection_pending' end
    local session=self.o.session();if session then return false,'session_already_active' end
    local snapshot,reason=self:_snapshot();if not snapshot then return false,reason end
    settings=settings or {}
    if kind=='join' and not lobbyId(settings.lobbyId) then return false,'invalid_lobby_id' end
    -- D55: a lobby is created with the default size (2..MAX_PLAYERS_LIMIT); the host may change it in the lobby.
    local mp=settings.maxPlayers
    if kind=='create' and (math.type(mp)~='integer' or mp<2 or mp>Config.MAX_PLAYERS_LIMIT) then return false,'invalid_player_count' end
    self.serial=self.serial+1
    local request=kind..':'..snapshot.generation..':'..self.serial
    local operation={request=request,generation=snapshot.generation,kind=kind,
        lobbyId=settings.lobbyId,maxPlayers=settings.maxPlayers,wait=kind=='join' and settings.wait==true or nil}
    local method=kind=='create' and self.backend.Create or self.backend.Join
    local ok,accepted,why=pcall(method,self.backend,operation)
    if not ok or accepted~=true then self.error=ok and (why or 'connection_rejected') or 'connection_callback_failed';return false,self.error end
    self.pending=operation;self.error=nil;self.waitOffer=nil
    if kind=='join' then self.lastJoinLobby=settings.lobbyId end
    return true
end
-- D52: join the lobby that refused us again, this time to wait for the next game (WAIT_REQ).
function C:Wait()
    local offer=self.waitOffer;if not offer then return false,'no_wait_offer' end
    return self:Begin('join',{lobbyId=offer.lobbyId,wait=true})
end
-- Test 15: re-pull the host list now (the backend decides how: dev beacons, Steam GMP_Lob_ListReq).
function C:RefreshLobbies()
    if not self.backend or type(self.backend.RefreshLobbies)~='function' then return false,'refresh_unavailable' end
    local ok,accepted,why=pcall(self.backend.RefreshLobbies,self.backend,self.friendsOnly~=false)
    if not ok or accepted~=true then return false,ok and (why or 'refresh_refused') or 'refresh_failed' end
    return true
end
function C:Invite()
    if not self.backend or type(self.backend.Invite)~='function' then return false,'invite_unavailable' end
    local ok,accepted,why=pcall(self.backend.Invite,self.backend)
    if not ok or accepted~=true then return false,ok and (why or 'invite_refused') or 'invite_callback_failed' end
    return true
end
-- An accepted Steam invite (or +connect_lobby) starts the normal Join, only while no session is active. A lobby id
-- read at boot (App:_bootSteamLobby, queuedJoin) goes first. The operation is marked fromInvite (the lobby screen opens).
function C:_pendingJoin()
    if self.pending or not self.backend or type(self.backend.PendingJoin)~='function' then return end
    if self.o.session() then return end
    local lobby=self.queuedJoin
    if lobby then self.queuedJoin=nil
    else local ok,value=pcall(self.backend.PendingJoin,self.backend);lobby=ok and value or nil end
    if lobbyId(lobby) and self:Begin('join',{lobbyId=lobby}) and self.pending then self.pending.fromInvite=true end
end
function C:Tick()
    self:_pendingJoin()
    local pending=self.pending;if not pending then return end
    local snapshot,reason=self:_snapshot()
    if not snapshot or snapshot.generation~=pending.generation then
        self.pending=nil;self.error=reason or 'Lobby backend changed during connection.';return false
    end
    local receipt=snapshot.receipt
    if not receipt or receipt.request~=pending.request then return nil end
    if receipt.accepted~=true then self.pending=nil;self.error=receipt.reason or 'connection_failed';return false end
    -- Native lobby membership alone does not establish mod handshake/auth.
    -- Publish success only when the actual shared owner exposes that session.
    local session,role=self.o.session()
    if not session or not session.identity or not session.sid or session.sid~=receipt.sid
        or role~=(pending.kind=='create' and 'host' or 'client') then return nil end
    if role=='client' and (type(session.State)~='function'
        or not (session:State()=='joined' or pending.wait and session:State()=='waiting')) then return nil end
    self.pending=nil;self.error=nil;return true
end
-- D52: the session ended the attempt (the host refused the join): no pending operation, the reason on the screen.
-- offerWait: a run is in progress; the screen offers "Wait for the next game" for that lobby (C:Wait).
function C:Fail(reason,offerWait)
    local lobby=self.pending and self.pending.kind=='join' and self.pending.lobbyId or self.lastJoinLobby
    self.waitOffer=offerWait and lobby and {lobbyId=lobby} or nil
    self.pending=nil;self.error=reason;return true
end
function C:Cancel()
    local pending=self.pending;if not pending then return false,'no_connection_pending' end
    local ok,accepted,why=pcall(self.backend.Cancel,self.backend,pending.request,pending.generation)
    if not ok or accepted~=true then return false,ok and (why or 'cancel_rejected') or 'cancel_callback_failed' end
    self.pending=nil;self.error=nil;self.waitOffer=nil;return true
end
-- t3 friend reports (Coder A): the host closes its lobby; everyone in it is told and returns to the multiplayer screen.
function C:CloseLobby()
    if not self.backend or type(self.backend.CloseLobby)~='function' then return false,'close_unavailable' end
    local ok,accepted,why=pcall(self.backend.CloseLobby,self.backend)
    if not ok or accepted~=true then return false,ok and (why or 'close_refused') or 'close_callback_failed' end
    self.pending=nil;self.error=nil;return true
end
function C:Leave()
    if not self.backend or type(self.backend.Leave)~='function'then return false,'leave_unavailable'end
    local ok,accepted,why=pcall(self.backend.Leave,self.backend)
    if not ok or accepted~=true then return false,ok and why or 'leave_callback_failed'end
    self.pending=nil;self.error=nil;return true
end
return C
