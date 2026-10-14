-- Menu Options layout planner (pure; BUTTON_HIERARCHY_DESIGN.md §6.3-§6.7).
-- Plain Lua tables in and out, no UObjects, Lua 5.3/5.4. Loaded with loadfile like esc_style.lua.
--
-- Units: main/esc rectangles, row heights and label widths are in root (layout) units; settings given in
-- physical px convert by /dpi. Lobby rectangles are page units; px convert by /pageScale. Sizes are native
-- FontSize units (Play native 60). R(s) = fixedH + r*s per row; label width w*s; column width C(s) = max w*s.
local L = {}

local EPS = 1e-6
L.MIN_SIZE, L.SIZE_STEP, L.MAX_SIZE = 30, 5, 2000
L.MIN_GAP_PX, L.KEEP_OUT_PX, L.EDGE_PX, L.LABEL_INSET_PX, L.ROW_PAD_PX = 10, 10, 20, 10, 10

-- Static slider ranges (§6.1). ButtonSize is 30..H (live) on a 5 grid and is handled separately.
L.SLIDERS = {
    main = {
        TitleScale = {min = 20, max = 100, step = 5, default = 60},
        TitleMarginX = {min = 0, max = 400, step = 10, default = 40},
        TitleTop = {min = 0, max = 400, step = 10, default = 30},
        MarginX = {min = 0, max = 400, step = 20, default = 20},
        TopOffset = {min = 10, max = 200, step = 10, default = 50},
        BottomOffset = {min = 10, max = 200, step = 10, default = 50},
    },
    esc = {
        MarginX = {min = 0, max = 400, step = 20, default = 20},
        OffsetY = {min = -400, max = 400, step = 10, default = 0},
        Gap = {min = 10, max = 60, step = 2, default = 10},
        BlockHeight = {min = 50, max = 150, step = 5, default = 100},
    },
    lobby = {
        LeftOffset = {min = 0, max = 200, step = 10, default = 50},
        RightOffset = {min = 0, max = 200, step = 10, default = 50},
    },
}
local SLIDER_KEYS = {
    main = {'TitleScale', 'TitleMarginX', 'TitleTop', 'MarginX', 'TopOffset', 'BottomOffset'},
    esc = {'MarginX', 'OffsetY', 'Gap', 'BlockHeight'},
    lobby = {'LeftOffset', 'RightOffset'},
}
L.ENUMS = {Align = {'Left', 'Center', 'Right'}, Footer = {'BottomRight', 'Native'}, Title = {'Moved', 'Native'},
           TitleAlign = {'Left', 'Center', 'Right'}}
local ENUM_DEFAULTS = {
    main = {{'Align', 'Left'}, {'Footer', 'BottomRight'}, {'Title', 'Moved'}, {'TitleAlign', 'Right'}},
    esc = {{'Align', 'Center'}},
    lobby = {},
}
-- Clamp order (§6.7): Title keys, ButtonSize, Align, MarginX, offsets/OffsetY, Gap, BlockHeight.
L.ORDER = {
    main = {'TitleScale', 'TitleMarginX', 'TitleTop', 'ButtonSize', 'Align', 'MarginX', 'TopOffset', 'BottomOffset'},
    esc = {'ButtonSize', 'Align', 'MarginX', 'OffsetY', 'Gap', 'BlockHeight'},
    lobby = {'ButtonSize', 'LeftOffset', 'RightOffset'},
}
L.REASON_TEXT = {title = 'Goobies title', screen = 'screen edge', footer = 'footer', gap = 'min gap 10 px',
                 labels = 'Esc labels', block = 'Esc block height', corner = 'Back button',
                 align = 'centered alignment', unmeasured = 'open the menu once to measure',
                 invalid_metrics = 'invalid measurements, open the menu again', no_rows = 'no buttons'}
local MENU_NAME = {main = 'main menu', esc = 'Esc menu', lobby = 'lobby'}
local PIVOT_X = {Left = 0, Center = .5, Right = 1}
local TITLE_KEYS = {TitleScale = true, TitleMarginX = true, TitleTop = true}
local NO_TITLE = {mode = 'None'}

function L.ReasonText(reason, kind)
    if reason == nil then return nil end
    if reason == 'unmeasured' then return ('open the %s once to measure'):format(MENU_NAME[kind] or 'menu') end
    return L.REASON_TEXT[reason] or reason
end

-- Per-call memo ------------------------------------------------------------------------------------------
-- One table per public call (Plan/Bounds/Evaluate): metrics are fixed within a call, so computes keyed by the
-- settings that affect them are reused (Bounds re-checks the same layouts many times). Nothing outlives the call.
local CACHE
local function memo(key, fn)
    local c = CACHE
    if not c then return fn() end
    local v = c[key]
    if v == nil then v = fn(); c[key] = v end
    return v
end
local function scoped(fn)
    if CACHE then return fn() end
    CACHE = {}
    local res = table.pack(pcall(fn))
    CACHE = nil
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

-- Geometry helpers ------------------------------------------------------------------------------------
local function rect(x, y, w, h) return {x = x, y = y, w = w, h = h} end
local function grow(r, m) return rect(r.x - m, r.y - m, r.w + 2 * m, r.h + 2 * m) end
local function copy(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end
local function contains(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

-- General rectangle-disjoint test; touching edges are disjoint. `margin` expands b on every side.
function L.Disjoint(a, b, margin)
    if margin and margin ~= 0 then b = grow(b, margin) end
    return a.x + a.w <= b.x + EPS or b.x + b.w <= a.x + EPS or a.y + a.h <= b.y + EPS or b.y + b.h <= a.y + EPS
end
function L.OnScreen(r, W, H)
    return r.x >= -EPS and r.y >= -EPS and r.x + r.w <= W + EPS and r.y + r.h <= H + EPS
end
-- First keep-out the box (x, y, w, h) conflicts with (keep-out grown by margin): its reason, else nil.
local function hits(x, y, w, h, keeps, margin)
    for _, k in ipairs(keeps) do
        local r = k.rect
        if not (x + w <= r.x - margin + EPS or r.x + r.w + margin <= x + EPS
                or y + h <= r.y - margin + EPS or r.y + r.h + margin <= y + EPS) then
            return k.reason or 'screen'
        end
    end
end
local function conflict(r, keeps, margin) return hits(r.x, r.y, r.w, r.h, keeps, margin) end
local function gridFloor(x) return L.SIZE_STEP * math.floor(x / L.SIZE_STEP + 1e-9) end
local function searchTop(upper) return math.min(gridFloor(math.min(upper, L.MAX_SIZE)) + L.SIZE_STEP, L.MAX_SIZE) end
local function alignX(align, W, margin, w)
    if align == 'Left' then return margin elseif align == 'Center' then return (W - w) / 2 end
    return W - margin - w
end
local function rowH(r, s) return (r.fixedH or 0) + (r.r or 0) * s end
local function colWidth(rows, s)
    local c = 0
    for _, r in ipairs(rows) do if not r.tail and r.w * s > c then c = r.w * s end end
    return c
end

-- Live size slider step: keeps at most 20 intervals over 30..max (§4.4).
function L.SizeStep(maxSize)
    local span = (maxSize or L.MIN_SIZE) - L.MIN_SIZE
    if span <= 0 then return L.SIZE_STEP end
    return L.SIZE_STEP * math.ceil(span / 100)
end

-- Settings normalization (§6.1 validation) -------------------------------------------------------------
local function cleanRaw(v) return (tostring(v):gsub('%c', '')):sub(1, 32) end
local function number(raw)
    local n = tonumber(raw)
    if n and n == n and math.abs(n) < 1e6 then return n end
end
local function snap(v, spec)
    if v < spec.min then v = spec.min elseif v > spec.max then v = spec.max end
    v = spec.min + spec.step * math.floor((v - spec.min) / spec.step + .5)
    if v > spec.max then v = v - spec.step end
    return v
end
local function seedSize(raw)
    if raw.ButtonSize ~= nil then return raw.ButtonSize, 'ButtonSize' end
    if raw.MainMenuFontSize ~= nil then return raw.MainMenuFontSize, 'MainMenuFontSize' end
    local legacy = number(raw.MainMenuFontScale)
    if legacy then return legacy <= 50 and 30 * legacy / 50 or 30 + 30 * (legacy - 50) / 50, 'MainMenuFontScale' end
end

-- L.Settings(kind, raw, metrics) -> normalized settings, diagnostics. Never mutates `raw`. The title position
-- comes only from the §6.1 keys (TitleAlign, TitleMarginX, TitleTop measured from the top).
function L.Settings(kind, raw, metrics)
    raw = raw or {}
    local out, diag = {}, {}
    local function bad(key, value)
        diag[#diag + 1] = ('%s: invalid %s=%s, using default'):format(kind, key, cleanRaw(value))
    end
    for _, pair in ipairs(ENUM_DEFAULTS[kind] or {}) do
        local key, default = pair[1], pair[2]
        local v = raw[key]
        out[key] = default
        if v ~= nil then
            local hit
            for _, option in ipairs(L.ENUMS[key]) do if tostring(v):lower() == option:lower() then hit = option end end
            if hit then out[key] = hit else bad(key, v) end
        end
    end
    for _, key in ipairs(SLIDER_KEYS[kind] or {}) do
        local spec = L.SLIDERS[kind][key]
        local default = spec.default
        if kind == 'esc' and key == 'Gap' and type(metrics) == 'table' and number(metrics.nativeGap) then
            default = math.max(L.MIN_GAP_PX, metrics.nativeGap * (number(metrics.dpi) or 1))
        end
        local v = raw[key]
        local n = v ~= nil and number(v)
        if v ~= nil and not n then bad(key, v) end
        out[key] = snap(n or default, spec)
    end
    if L.SLIDERS[kind] then
        local v, from = seedSize(raw)
        if kind == 'lobby' and from ~= 'ButtonSize' then v = nil end
        local n = v ~= nil and number(v)
        if v ~= nil and not n then bad(from, v) end
        n = n or L.MIN_SIZE
        n = L.SIZE_STEP * math.floor(n / L.SIZE_STEP + .5)
        out.ButtonSize = math.max(L.MIN_SIZE, math.min(L.MAX_SIZE, n))
    end
    return out, diag
end

-- Metrics validation (§6.6 record) ---------------------------------------------------------------------
-- validate -> nil when usable, else 'unmeasured' (no record yet) or 'invalid_metrics' (malformed: never a crash,
-- never a plan). prepare -> a pruned copy (zero-width rows/labels are collapsed widgets: not present) or nil,
-- reason ('no_rows' when nothing is left).
local function finite(v) return type(v) == 'number' and v == v and v > -math.huge and v < math.huge end
local function positive(v) return finite(v) and v > 0 end
local function nonNeg(v) return finite(v) and v >= 0 end
local function opt(v, check) return v == nil or check(v) end
local function isString(v) return type(v) == 'string' end
local function goodRect(r) return type(r) == 'table' and finite(r.x) and finite(r.y) and nonNeg(r.w) and nonNeg(r.h) end
local function goodRow(r)
    return type(r) == 'table' and nonNeg(r.r) and nonNeg(r.w) and opt(r.fixedH, nonNeg) and opt(r.fixedW, nonNeg)
        and opt(r.nativeFontSize, positive)
end
local function goodKeep(k) return type(k) == 'table' and goodRect(k.rect) and opt(k.reason, isString) end
local function goodList(list, check)
    if list == nil then return true end
    if type(list) ~= 'table' then return false end
    for i = 1, #list do if not check(list[i]) then return false end end
    return true
end
local function goodSize(e) return type(e) == 'table' and nonNeg(e.w) and nonNeg(e.h) end
local function goodFooter(f)
    if f == nil then return true end
    if type(f) ~= 'table' or not goodList(f.missing, isString) then return false end
    for _, key in ipairs({'leaderboard', 'wishlist', 'versionnumber'}) do
        if not opt(f[key], goodSize) then return false end
    end
    return f.leaderboard == nil or opt(f.leaderboard.rect, goodRect)
end
local function goodTitle(t) return t == nil or (type(t) == 'table' and goodRect(t.rect) and opt(t.widgetRect, goodRect)) end
local function goodCorner(c) return c == nil or (type(c) == 'table' and goodRect(c.rect) and nonNeg(c.r) and positive(c.w)) end

local function validate(kind, m)
    if type(m) ~= 'table' or m.measured == false or type(m.rows) ~= 'table' then return 'unmeasured' end
    if kind == 'main' and (m.viewportW == nil or m.viewportH == nil) then return 'unmeasured' end
    if kind == 'esc' and (m.viewportH == nil or m.nativeBlockHeight == nil) then return 'unmeasured' end
    if kind == 'lobby' and (m.band == nil or m.pageScale == nil) then return 'unmeasured' end
    local ok = goodList(m.rows, goodRow) and goodList(m.keepOuts, goodKeep)
    if kind == 'main' then
        ok = ok and positive(m.dpi) and positive(m.viewportW) and positive(m.viewportH) and opt(m.nativeFontSize, positive)
            and goodTitle(m.title) and goodFooter(m.footer)
    elseif kind == 'esc' then
        ok = ok and positive(m.dpi) and positive(m.viewportW) and positive(m.viewportH) and positive(m.nativeBlockHeight)
            and opt(m.nativeBlockCenterY, finite) and opt(m.nativeGap, finite) and goodList(m.labels, goodRow)
    else
        ok = ok and positive(m.pageScale) and goodRect(m.band) and opt(m.pageW, positive) and opt(m.pageH, positive)
            and goodCorner(m.corner)
    end
    if not ok then return 'invalid_metrics' end
end
local function visible(list)
    local out = {}
    for _, e in ipairs(list or {}) do if e.w > 0 then out[#out + 1] = e end end
    return out
end
local function prepare(kind, metrics, keepOuts)
    local why = validate(kind, metrics)
    if why then return nil, why end
    if not goodList(keepOuts, goodKeep) then return nil, 'invalid_metrics' end
    local m = copy(metrics)
    m.rows = visible(metrics.rows)
    if kind == 'esc' then m.labels = visible(metrics.labels) end
    if keepOuts and #keepOuts > 0 then
        m.keepOuts = {}
        for _, k in ipairs(metrics.keepOuts or {}) do m.keepOuts[#m.keepOuts + 1] = k end
        for _, k in ipairs(keepOuts) do m.keepOuts[#m.keepOuts + 1] = k end
    end
    if #m.rows == 0 then return nil, 'no_rows' end
    return m
end

-- Size search: largest grid size whose layout is valid, scanning down from one step above the closed-form
-- bound (validity is not proven monotone in s with keep-outs, so no binary search). eval(s) is the light
-- check; eval(s, true) builds the full layout. Returns H|nil, reason the next step fails, full eval at H/30.
-- With `monotone` (a single row: its rect only grows from a fixed anchor, so validity only decreases with s) a
-- binary search returns the same H as the scan.
-- `light` returns the light verdict instead of the full layout (callers that only need fit/ok).
local function solve(eval, upper, monotone, light)
    local top = searchTop(upper)
    local full = not light
    if monotone and top >= L.MIN_SIZE and eval(L.MIN_SIZE).ok then
        local a, b = 0, (top - L.MIN_SIZE) // L.SIZE_STEP -- grid index a is valid
        while a < b do
            local mid = (a + b + 1) // 2
            if eval(L.MIN_SIZE + mid * L.SIZE_STEP).ok then a = mid else b = mid - 1 end
        end
        local s = L.MIN_SIZE + a * L.SIZE_STEP
        return s, eval(s + L.SIZE_STEP).reason, eval(s, full)
    end
    if not monotone then
        for s = top, L.MIN_SIZE, -L.SIZE_STEP do
            if eval(s).ok then return s, eval(s + L.SIZE_STEP).reason, eval(s, full) end
        end
    end
    local e = eval(L.MIN_SIZE, full)
    return nil, e.reason, e
end

-- Main menu (§6.3, §6.4) --------------------------------------------------------------------------------
local function titleOf(st)
    return {mode = st.Title, scale = st.TitleScale, align = st.TitleAlign, marginX = st.TitleMarginX,
            top = st.TitleTop, vertical = 'Top'} -- §6.1: TitleTop is measured from the top; Bottom is fallback-only
end
local function titleRect(m, tv, u)
    local t = m.title
    if not t or tv.mode == 'None' then return nil end
    local n = t.rect
    if tv.mode == 'Native' then -- the vanilla lettering may extend past the viewport: keep out its visible part
        local x0, y0 = math.max(0, n.x), math.max(0, n.y)
        local x1, y1 = math.min(m.viewportW, n.x + n.w), math.min(m.viewportH, n.y + n.h)
        if x1 <= x0 or y1 <= y0 then return nil end
        return rect(x0, y0, x1 - x0, y1 - y0)
    end
    local k = tv.scale / 100
    local w, h = n.w * k, n.h * k
    local x = alignX(tv.align, m.viewportW, tv.marginX * u, w)
    local y = tv.vertical == 'Bottom' and m.viewportH - tv.top * u - h or tv.top * u
    return rect(x, y, w, h)
end
-- Render transform with pivot (0,0) at the widget origin o: p' = o + (p - o) * k + t.
local function titleTransform(m, tv, r)
    local n, o = m.title.rect, m.title.widgetRect or rect(0, 0, 0, 0)
    local k = tv.scale / 100
    return {scale = {X = k, Y = k}, pivot = {X = 0, Y = 0},
            translation = {X = r.x - (o.x + (n.x - o.x) * k), Y = r.y - (o.y + (n.y - o.y) * k)}}
end
local function footerMissing(f, key)
    return not f[key] or contains(f.missing, key) or (key == 'wishlist' and contains(f.missing, 'wishlistnewgame'))
end
-- Bottom-right stack: leaderboard, ad, version bottom-most; right-aligned at 20 px, 10 px apart.
local function footerStack(m, u)
    local f = m.footer
    if not f then return nil, 'missing' end
    for _, key in ipairs({'leaderboard', 'wishlist', 'versionnumber'}) do
        if footerMissing(f, key) then return nil, 'missing' end
    end
    local W, H, e, g = m.viewportW, m.viewportH, L.EDGE_PX * u, L.MIN_GAP_PX * u
    local v = rect(W - e - f.versionnumber.w, H - e - f.versionnumber.h, f.versionnumber.w, f.versionnumber.h)
    local a = rect(W - e - f.wishlist.w, v.y - g - f.wishlist.h, f.wishlist.w, f.wishlist.h)
    local l = rect(W - e - f.leaderboard.w, a.y - g - f.leaderboard.h, f.leaderboard.w, f.leaderboard.h)
    local stack = {{id = 'leaderboard', rect = l}, {id = 'wishlistnewgame', rect = a}, {id = 'versionnumber', rect = v}}
    for _, item in ipairs(stack) do if not L.OnScreen(item.rect, W, H) then return nil, 'screen' end end
    return stack
end

-- Rows at size s: light verdict {ok, fit, reason} (no row tables) unless `full`.
local function mainEval(S, s, full)
    local st, u, W, Hv, rows = S.st, S.u, S.W, S.Hv, S.rows
    local top, A, g = st.TopOffset * u, Hv - (st.TopOffset + st.BottomOffset) * u, L.MIN_GAP_PX * u
    local n, total = #rows, 0
    for i = 1, n do total = total + rowH(rows[i], s) end
    local gap = n > 1 and (A - total) / (n - 1) or 0
    local C, mx = colWidth(rows, s), st.MarginX * u
    local cx = alignX(st.Align, W, mx, C)
    local reason, fit
    if total + (n - 1) * g > A + EPS then
        reason, fit = 'gap', false
    else
        local y = top
        for i = 1, n do
            local r = rows[i]
            local h, w = rowH(r, s), r.tail and r.fixedW or C
            local x = r.tail and alignX(st.Align, W, mx, w) or cx
            if x < -EPS or y < -EPS or x + w > W + EPS or y + h > Hv + EPS then reason = 'screen' break end
            y = y + h + gap
        end
        if not reason then
            local margin = L.KEEP_OUT_PX * u
            y = top
            for i = 1, n do
                local r = rows[i]
                local h, w = rowH(r, s), r.tail and r.fixedW or C
                reason = hits(r.tail and alignX(st.Align, W, mx, w) or cx, y, w, h, S.keeps, margin)
                if reason then break end
                y = y + h + gap
            end
        end
    end
    if not full then return {ok = not reason, fit = fit, reason = reason} end
    local out, y = {}, top
    for i, r in ipairs(rows) do
        local h, w = rowH(r, s), r.tail and r.fixedW or C
        out[i] = {id = r.id, tail = r.tail, rect = rect(r.tail and alignX(st.Align, W, mx, w) or cx, y, w, h)}
        y = y + h + gap
    end
    return {ok = not reason, fit = fit, reason = reason, rows = out, gap = gap, available = A, column = C, x = cx,
            top = top, size = s}
end
-- Scroll box (§6.7): the grown column width C(30), widened to the widest fixed-width native tail row (the
-- wishlist ad can be wider than the column) so no row is clipped; every row aligns inside it at the same anchor.
local function mainScrollBox(S)
    local st, u = S.st, S.u
    local C = colWidth(S.rows, L.MIN_SIZE)
    for _, r in ipairs(S.rows) do if r.tail and r.fixedW > C then C = r.fixedW end end
    return rect(alignX(st.Align, S.W, st.MarginX * u, C), st.TopOffset * u, C, S.Hv - (st.TopOffset + st.BottomOffset) * u)
end
-- Closed-form upper bound on H. With `rows` = metrics rows only (no native tail rows) it is also an upper bound
-- for every footer mode and title (tails and keep-outs only lower H); it is monotone in the offsets and MarginX.
local function mainUpperOf(rows, st, u, W, Hv)
    local A, n = Hv - (st.TopOffset + st.BottomOffset) * u, #rows
    local sumr, fixed, wmax = 0, 0, 0
    for _, r in ipairs(rows) do
        sumr, fixed = sumr + (r.r or 0), fixed + (r.fixedH or 0)
        if not r.tail and r.w > wmax then wmax = r.w end
    end
    local fit = sumr > 0 and (A - (n - 1) * L.MIN_GAP_PX * u - fixed) / sumr or L.MAX_SIZE
    local width = wmax > 0 and ((st.Align == 'Center' and W or W - st.MarginX * u) / wmax) or L.MAX_SIZE
    return math.min(fit, width)
end
local function mainUpper(S) return mainUpperOf(S.rows, S.st, S.u, S.W, S.Hv) end

-- Builds the per-title-variant setup: title keep-out, footer mode (stack or native tail rows + leaderboard).
-- A moved title must be on screen and clear of every extra keep-out (and of the native leaderboard when the
-- footer stays native); the stack must clear the title, every extra keep-out and the column. Else nil, reason.
local function mainSetup(m, st, tv)
    local u = 1 / m.dpi
    local S = {kind = 'main', m = m, st = st, tv = tv, u = u, W = m.viewportW, Hv = m.viewportH, keeps = {}, rows = {}}
    local margin = L.KEEP_OUT_PX * u
    local extra = m.keepOuts or {}
    local tr = titleRect(m, tv, u)
    local moved = tr and tv.mode == 'Moved'
    if moved then
        if not L.OnScreen(tr, S.W, S.Hv) then return nil, 'screen' end
        local why = conflict(tr, extra, margin)
        if why then return nil, why end
    end
    S.title = tr
    for _, k in ipairs(extra) do S.keeps[#S.keeps + 1] = k end
    local titleKeep = tr and {{rect = tr, reason = 'title'}}
    if tr then S.keeps[#S.keeps + 1] = titleKeep[1] end
    for i, r in ipairs(m.rows) do S.rows[i] = r end
    local stack, why, stackKeeps
    if st.Footer ~= 'BottomRight' then why = 'native' else
        local fs = memo('fs', function() -- the stack and its keep-outs depend on the metrics only
            local s, w = footerStack(m, u)
            local keeps = {}
            for _, f in ipairs(s or {}) do keeps[#keeps + 1] = {rect = f.rect, reason = 'footer'} end
            return {stack = s or false, why = w, keeps = keeps}
        end)
        stack, why, stackKeeps = fs.stack or nil, fs.why, fs.keeps
    end
    if stack and tr then
        for _, f in ipairs(stack) do
            if conflict(f.rect, titleKeep, margin) then stack, why = nil, 'title' break end
        end
    end
    if stack then
        for _, f in ipairs(stack) do
            if conflict(f.rect, extra, margin) then stack, why = nil, 'keepout' break end
        end
    end
    if stack then -- the stack must also clear the column at the minimum size (or its scroll box)
        -- rows at 30 and the scroll box do not depend on the title or keep-outs: one verdict per column geometry
        local clear = memo(table.concat({'k', st.Align, st.MarginX, st.TopOffset, st.BottomOffset}, '|'), function()
            -- mainEval's row geometry at 30 (stack mode: no tail rows), without building the rows
            local s, rows = L.MIN_SIZE, S.rows
            local top, A = st.TopOffset * u, S.Hv - (st.TopOffset + st.BottomOffset) * u
            local n, total = #rows, 0
            for i = 1, n do total = total + rowH(rows[i], s) end
            if total + (n - 1) * L.MIN_GAP_PX * u > A + EPS then return not conflict(mainScrollBox(S), stackKeeps, margin) end
            local gap = n > 1 and (A - total) / (n - 1) or 0
            local C = colWidth(rows, s)
            local x, y = alignX(st.Align, S.W, st.MarginX * u, C), top
            for i = 1, n do
                local h = rowH(rows[i], s)
                if hits(x, y, C, h, stackKeeps, margin) then return false end
                y = y + h + gap
            end
            return true
        end)
        if clear then for _, k in ipairs(stackKeeps) do S.keeps[#S.keeps + 1] = k end else stack, why = nil, 'column' end
    end
    if stack then
        S.footer = {mode = 'BottomRight', stack = stack}
    else
        S.footer = {mode = 'Native', reason = why}
        local f = m.footer
        if f then -- native tail rows (counted in n) and the leaderboard area as a keep-out
            for _, pair in ipairs({{'versionnumber', 'versionnumber'}, {'wishlist', 'wishlistnewgame'}}) do
                if not footerMissing(f, pair[1]) then
                    S.rows[#S.rows + 1] = {id = pair[2], tail = true, fixedH = f[pair[1]].h, fixedW = f[pair[1]].w}
                end
            end
            if not footerMissing(f, 'leaderboard') and f.leaderboard.rect then
                if moved and not L.Disjoint(tr, f.leaderboard.rect, margin) then return nil, 'footer' end
                S.keeps[#S.keeps + 1] = {rect = f.leaderboard.rect, reason = 'footer'}
            end
        end
    end
    return S
end
local function mainKey(st, tv)
    return table.concat({'m', st.Align, st.MarginX, st.TopOffset, st.BottomOffset, st.Footer, tv.mode, tv.scale or '',
                         tv.align or '', tv.vertical or '', tv.marginX or '', tv.top or ''}, '|')
end
local function mainSetupMemo(m, st, tv)
    local r = memo('s' .. mainKey(st, tv), function()
        local S, why = mainSetup(m, st, tv)
        return {S = S, why = why}
    end)
    return r.S, r.why
end
-- The first row sits at TopOffset and (n > 1) the last row ends at the bottom offset whatever s is, so each only
-- grows with s: the largest size at which both are on screen and clear of keep-outs (binary search) bounds H.
local function anchoredBound(S, upper)
    local st, u, W, Hv, rows = S.st, S.u, S.W, S.Hv, S.rows
    local top, A, mx, margin = st.TopOffset * u, Hv - (st.TopOffset + st.BottomOffset) * u, st.MarginX * u, L.KEEP_OUT_PX * u
    local first, last = rows[1], #rows > 1 and rows[#rows] or nil
    local function clean(x, y, w, h)
        return x >= -EPS and y >= -EPS and x + w <= W + EPS and y + h <= Hv + EPS and not hits(x, y, w, h, S.keeps, margin)
    end
    local function ok(s)
        local C = colWidth(rows, s)
        if not clean(alignX(st.Align, W, mx, C), top, C, rowH(first, s)) then return false end
        if last then
            local h, w = rowH(last, s), last.tail and last.fixedW or C
            if not clean(alignX(st.Align, W, mx, w), top + A - h, w, h) then return false end
        end
        return true
    end
    local hi = searchTop(upper)
    if hi < L.MIN_SIZE or not ok(L.MIN_SIZE) then return math.min(upper, L.MIN_SIZE - 1) end
    local a, b = 0, (hi - L.MIN_SIZE) // L.SIZE_STEP
    while a < b do
        local mid = (a + b + 1) // 2
        if ok(L.MIN_SIZE + mid * L.SIZE_STEP) then a = mid else b = mid - 1 end
    end
    return math.min(upper, L.MIN_SIZE + a * L.SIZE_STEP)
end
local function mainCompute(m, st, tv)
    return memo(mainKey(st, tv), function()
        local S, why = mainSetupMemo(m, st, tv)
        if not S then return {reason = why} end
        local eval = function(s, full) return mainEval(S, s, full) end
        local single = #S.rows == 1
        local upper = mainUpper(S)
        if not single then upper = anchoredBound(S, upper) end
        local H, reason, e = solve(eval, upper, single, true) -- callers re-evaluate the layout they plan
        return {S = S, H = H, reason = reason, e = e, eval = eval, needScroll = not H and e.fit == false}
    end)
end
local function scrollBoxClean(S)
    local box = mainScrollBox(S)
    return L.OnScreen(box, S.W, S.Hv) and not conflict(box, S.keeps, L.KEEP_OUT_PX * S.u)
end
-- Scroll fallback candidate for a title variant: size 30 does not fit and the scroll box is clean.
local function scrollCandidate(m, st, tv)
    local r = memo('c' .. mainKey(st, tv), function()
        local S = mainSetupMemo(m, st, tv)
        if not S or mainEval(S, L.MIN_SIZE).fit ~= false or not scrollBoxClean(S) then return false end
        return {S = S, reason = 'gap'}
    end)
    return r or nil
end
-- H with any title is at most H without one (same footer mode, fewer keep-outs); the footer may only fall back to
-- native, so max(H free, H free with a native footer) bounds every title variant. Likewise a title variant can
-- only scroll when a free layout of the same footer mode scrolls with a clean box. Returns H bound, possible, why.
local function mainFree(m, st)
    local H, possible, why = nil, false, nil
    local modes = {st}
    if st.Footer == 'BottomRight' then local t = copy(st); t.Footer = 'Native'; modes[2] = t end
    for i, t in ipairs(modes) do
        local c = mainCompute(m, t, NO_TITLE)
        if i == 1 then why = c.reason end
        if c.H and (not H or c.H > H) then H = c.H end
        possible = possible or c.H ~= nil or (c.needScroll and c.S ~= nil and scrollBoxClean(c.S))
    end
    return H, possible, why
end

-- Title fallback variants (§6.4 apply-time step 1): shrink in place toward 20%, then the corner(s) farthest
-- from the column, largest scale first; last, the vanilla title position. Each list runs largest to smallest.
local titleVariantList
local function titleVariantGroups(st)
    return memo(table.concat({'g', st.Title, st.TitleScale, st.TitleAlign, st.TitleMarginX, st.TitleTop, st.Align}, '|'),
        function() return titleVariantList(st) end)
end
function titleVariantList(st)
    local groups = {}
    if st.Title ~= 'Moved' then return groups end
    local function group(align, vertical, from, step)
        local list = {}
        for k = from, 20, -5 do
            list[#list + 1] = {mode = 'Moved', scale = k, align = align, vertical = vertical, marginX = st.TitleMarginX,
                               top = st.TitleTop, step = step}
        end
        return list
    end
    if st.TitleScale > 20 then groups[#groups + 1] = group(st.TitleAlign, 'Top', st.TitleScale - 5, 'shrink_title') end
    local corners
    if st.Align == 'Left' then corners = {{'Right', 'Top'}, {'Right', 'Bottom'}}
    elseif st.Align == 'Right' then corners = {{'Left', 'Top'}, {'Left', 'Bottom'}}
    else corners = {{'Right', 'Top'}, {'Left', 'Top'}, {'Right', 'Bottom'}, {'Left', 'Bottom'}} end
    for _, c in ipairs(corners) do
        if not (c[1] == st.TitleAlign and c[2] == 'Top') then
            groups[#groups + 1] = group(c[1], c[2], st.TitleScale, 'move_title')
        end
    end
    groups[#groups + 1] = {{mode = 'Native', scale = st.TitleScale, align = st.TitleAlign, vertical = 'Top',
                            marginX = st.TitleMarginX, top = st.TitleTop, step = 'native_title'}}
    return groups
end
-- First variant (largest scale) in a group whose try(variant) succeeds. Smaller titles are subsets of larger
-- ones at the same anchor, so success is treated as monotone in scale (binary search).
local function searchGroup(list, try)
    local last = try(list[#list])
    if not last then return nil end
    local lo, hi, best, bestI = 1, #list, last, #list
    while lo < hi do
        local mid = (lo + hi) // 2
        local c = try(list[mid])
        if c then best, bestI, hi = c, mid, mid else lo = mid + 1 end
    end
    return best, list[bestI]
end
local function searchVariants(m, st, need)
    local function try(tv) local c = mainCompute(m, st, tv) return c.H and c.H >= need and c or nil end
    for _, list in ipairs(titleVariantGroups(st)) do
        local c, tv = searchGroup(list, try)
        if c then return c, tv end
    end
end
local function titleDiag(st, tv)
    if tv.mode == 'Native' then return 'main: native_title (vanilla title position), stored values kept' end
    return ('main: %s TitleScale %d -> %d (%s/%s), stored values kept'):format(tv.step, st.TitleScale, tv.scale, tv.align, tv.vertical)
end

local function mainRowsOut(S, e, size, H)
    local st, out = S.st, {}
    for i, row in ipairs(e.rows) do
        local src = S.rows[i]
        local item = {id = row.id, rect = row.rect}
        if src.tail then
            item.tail = true
        else
            local nf = src.nativeFontSize or S.m.nativeFontSize or 30
            local px = PIVOT_X[st.Align]
            local function inner(s)
                local w, h = src.w * s, src.r * s
                return rect(row.rect.x + (row.rect.w - w) * px, row.rect.y + (row.rect.h - h) / 2, w, h)
            end
            item.pivot = {X = px, Y = .5}
            item.scale, item.hoverScale = size / nf, H / nf
            item.label, item.hover = inner(size), inner(H)
        end
        out[i] = item
    end
    return out
end
local function mainPlanOut(m, st, comp, tv, size, H, fallback, diag, scroll)
    local S, eff = comp.S, copy(st)
    eff.Title, eff.TitleScale, eff.TitleAlign, eff.TitleVertical = tv.mode, tv.scale, tv.align, tv.vertical
    eff.ButtonSize = size
    local plan = {kind = 'main', H = H, size = size, scroll = scroll or false, settings = eff, fallback = fallback,
                  diagnostics = diag, reason = comp.reason, footer = S.footer, keepOuts = S.keeps,
                  units = {pxToRoot = S.u}}
    if S.title then
        plan.title = {mode = tv.mode, rect = S.title, scale = tv.mode == 'Moved' and tv.scale or 100, align = tv.align,
                      vertical = tv.vertical, transform = tv.mode == 'Moved' and titleTransform(m, tv, S.title) or nil}
    else
        plan.title = {mode = m.title and tv.mode or 'None'}
    end
    if scroll then
        local box = mainScrollBox(S)
        local u, rows, y, C = S.u, {}, box.y, colWidth(S.rows, L.MIN_SIZE)
        for i, r in ipairs(S.rows) do
            local h, w = rowH(r, L.MIN_SIZE), r.tail and r.fixedW or C
            rows[i] = {id = r.id, tail = r.tail, rect = rect(alignX(st.Align, S.W, st.MarginX * u, w), y, w, h)}
            y = y + h + L.MIN_GAP_PX * u
        end
        plan.rows = mainRowsOut(S, {rows = rows}, size, H)
        plan.scrollBox, plan.contentHeight, plan.available = box, y - box.y - L.MIN_GAP_PX * u, box.h
        plan.gap = L.MIN_GAP_PX * u
        plan.column = box
    else
        local e = mainEval(S, H, true)
        plan.rows, plan.gap, plan.available = mainRowsOut(S, e, size, H), e.gap, e.available
        plan.column = rect(e.x, e.top, e.column, e.available)
    end
    return plan
end
local function vanillaPlan(kind, m, st, fallback, diag, reason)
    fallback[#fallback + 1] = 'vanilla'
    diag[#diag + 1] = ('%s: vanilla layout, no valid plan at this resolution (%s)'):format(kind, reason or 'screen')
    local plan = {kind = kind, vanilla = true, rows = {}, labels = {}, settings = st, fallback = fallback,
                  diagnostics = diag, reason = reason or 'screen', scroll = false}
    if kind == 'main' then
        plan.title = {mode = 'Native', rect = m.title and copy(m.title.rect) or nil}
        plan.footer = {mode = 'Native', reason = 'vanilla'}
    end
    return plan
end

local function planMain(m, st, diag, fallback)
    local size = st.ButtonSize
    local stored = titleOf(st)
    local c0 = mainCompute(m, st, stored)
    if c0.H and c0.H >= size then return mainPlanOut(m, st, c0, stored, size, c0.H, fallback, diag) end
    -- (1) shrink, then move the title (else vanilla title), only when the title is what blocks this size
    local free = m.title and st.Title == 'Moved' and mainCompute(m, st, NO_TITLE) or c0
    if st.Title == 'Moved' and m.title and free.H and free.H >= size then
        local c, tv = searchVariants(m, st, size)
        if c then
            fallback[#fallback + 1] = tv.step
            diag[#diag + 1] = titleDiag(st, tv)
            return mainPlanOut(m, st, c, tv, size, c.H, fallback, diag)
        end
    end
    -- (2) cap ButtonSize to H (stored title first, then title variants)
    local c, tv = c0, stored
    if not c0.H then c, tv = searchVariants(m, st, L.MIN_SIZE) end
    if c and c.H then
        if tv ~= stored then fallback[#fallback + 1] = tv.step; diag[#diag + 1] = titleDiag(st, tv) end
        local use = math.min(size, c.H)
        if c.H < size then
            fallback[#fallback + 1] = 'cap_size'
            diag[#diag + 1] = ('main: cap_size ButtonSize %d -> %d (%s), stored value kept'):format(size, c.H, c.reason or 'gap')
        end
        return mainPlanOut(m, st, c, tv, use, c.H, fallback, diag)
    end
    -- (3) scroll when even size 30 does not fit vertically (only a fit failure can be rescued by scrolling)
    if (c0.needScroll or free.needScroll) and select(2, mainFree(m, st)) then
        local sc, stv = scrollCandidate(m, st, stored), stored
        if not sc then
            local function try(tv) return scrollCandidate(m, st, tv) end
            for _, list in ipairs(titleVariantGroups(st)) do
                sc, stv = searchGroup(list, try)
                if sc then break end
            end
        end
        if sc then
            if stv ~= stored then fallback[#fallback + 1] = stv.step end
            fallback[#fallback + 1] = 'scroll'
            diag[#diag + 1] = 'main: scroll, size 30 does not fit (gap)'
            return mainPlanOut(m, st, sc, stv, L.MIN_SIZE, L.MIN_SIZE, fallback, diag, true)
        end
    end
    -- (4) vanilla; name the blocker that remains without the title (else the title itself)
    local reason = free.H and 'title' or free.reason or c0.reason
    return vanillaPlan('main', m, st, fallback, diag, reason)
end

-- Esc block (§6.5) --------------------------------------------------------------------------------------
local function escSetup(m, st)
    return {kind = 'esc', m = m, st = st, u = 1 / m.dpi, W = m.viewportW, Hv = m.viewportH, rows = m.rows,
            keeps = m.keepOuts or {}}
end
-- Labels stack from 10 px, 10 px apart, aligned per Esc Align/MarginX. Like rows, each label reserves a slot at
-- slotSize (H) and is drawn at `size` (<= H) at the top of its slot with the same horizontal anchor, so the
-- drawn label lies inside its slot: a stack valid at H is valid at every smaller ButtonSize.
local function escLabels(S, size, slotSize)
    local st, u = S.st, S.u
    slotSize = slotSize or size
    local out, y, bottom = {}, L.LABEL_INSET_PX * u, 0
    for i, l in ipairs(S.m.labels or {}) do
        local sw, sh, w, h = l.w * slotSize, l.r * slotSize, l.w * size, l.r * size
        out[i] = {id = l.id, slot = rect(alignX(st.Align, S.W, st.MarginX * u, sw), y, sw, sh),
                  rect = rect(alignX(st.Align, S.W, st.MarginX * u, w), y, w, h)}
        bottom = y + sh
        y = bottom + L.LABEL_INSET_PX * u
    end
    return out, bottom
end
-- Every label slot on screen and clear of every keep-out + 10 px (§0.4: never overlap).
local function labelsClear(S, labels)
    for _, l in ipairs(labels) do
        if not L.OnScreen(l.slot, S.W, S.Hv) or conflict(l.slot, S.keeps, L.KEEP_OUT_PX * S.u) then return false end
    end
    return true
end
local function escAvailable(S, labelBottom, hasLabels)
    local blockA = S.st.BlockHeight / 100 * S.m.nativeBlockHeight
    local screenA = S.Hv - labelBottom - L.EDGE_PX * S.u
    if screenA < blockA then return screenA, hasLabels and 'labels' or 'screen' end
    return blockA, 'block'
end
-- Light verdict at size s ({ok, fit, reason}, no tables): same checks and order as the full escEval below.
local function escVerdict(S, s)
    local st, u, W, Hv, m = S.st, S.u, S.W, S.Hv, S.m
    local inset, margin, mx = L.LABEL_INSET_PX * u, L.KEEP_OUT_PX * u, st.MarginX * u
    local labels = m.labels or {}
    local y, lb = inset, 0
    for _, l in ipairs(labels) do lb = y + l.r * s; y = lb + inset end
    local A, limit = escAvailable(S, lb, #labels > 0)
    local g, n, total = st.Gap * u, #S.rows, 0
    for _, r in ipairs(S.rows) do total = total + rowH(r, s) end
    local B = total + (n - 1) * g
    if B > A + EPS then return {ok = false, fit = false, reason = limit} end
    y = inset
    for _, l in ipairs(labels) do
        local w, h = l.w * s, l.r * s
        local x = alignX(st.Align, W, mx, w)
        if x < -EPS or y < -EPS or x + w > W + EPS or y + h > Hv + EPS or hits(x, y, w, h, S.keeps, margin) then
            return {ok = false, reason = 'labels'}
        end
        y = y + h + inset
    end
    local C = colWidth(S.rows, s)
    local cx = alignX(st.Align, W, mx, C)
    local want = (m.nativeBlockCenterY or Hv / 2) + st.OffsetY * u - B / 2
    local lo, hi = lb + inset, Hv - inset - B
    local top = want
    if want < lo - EPS then top = lo elseif want > hi + EPS then top = hi end
    y = top
    for _, r in ipairs(S.rows) do
        local h = rowH(r, s)
        if cx < -EPS or y < -EPS or cx + C > W + EPS or y + h > Hv + EPS then return {ok = false, reason = 'screen'} end
        y = y + h + g
    end
    y = top
    for _, r in ipairs(S.rows) do
        local h = rowH(r, s)
        local why = hits(cx, y, C, h, S.keeps, margin)
        if why then return {ok = false, reason = why} end
        y = y + h + g
    end
    return {ok = true}
end
-- Rows reserved at size s, label slots at s, labels drawn at labelSize (defaults to s).
local function escEval(S, s, labelSize)
    local st, u, W, Hv = S.st, S.u, S.W, S.Hv
    local labels, lb = escLabels(S, labelSize or s, s)
    local A, limit = escAvailable(S, lb, #labels > 0)
    local g, n, total = st.Gap * u, #S.rows, 0
    for _, r in ipairs(S.rows) do total = total + rowH(r, s) end
    local B = total + (n - 1) * g
    local C = colWidth(S.rows, s)
    local cx = alignX(st.Align, W, st.MarginX * u, C)
    local want = (S.m.nativeBlockCenterY or Hv / 2) + st.OffsetY * u - B / 2
    local lo, hi = lb + L.LABEL_INSET_PX * u, Hv - L.LABEL_INSET_PX * u - B
    local top, clampedTop, clampedBottom = want, false, false
    if want < lo - EPS then top, clampedTop = lo, true elseif want > hi + EPS then top, clampedBottom = hi, true end
    local rows, y = {}, top
    for i, r in ipairs(S.rows) do
        rows[i] = {id = r.id, rect = rect(cx, y, C, rowH(r, s))}
        y = y + rowH(r, s) + g
    end
    local e = {ok = true, rows = rows, labels = labels, labelBottom = lb, available = A, block = B, top = top, x = cx,
               column = C, clamped = clampedTop or clampedBottom, clampedTop = clampedTop, clampedBottom = clampedBottom}
    if B > A + EPS then e.ok, e.fit, e.reason = false, false, limit return e end
    if not labelsClear(S, labels) then e.ok, e.reason = false, 'labels' return e end
    for _, row in ipairs(rows) do
        if not L.OnScreen(row.rect, W, Hv) then e.ok, e.reason = false, 'screen' return e end
    end
    for _, row in ipairs(rows) do
        local why = conflict(row.rect, S.keeps, L.KEEP_OUT_PX * u)
        if why then e.ok, e.reason = false, why return e end
    end
    return e
end
-- Closed-form upper bound on H: decreasing in Gap and MarginX, increasing in BlockHeight, independent of OffsetY.
local function escUpper(S)
    local st, u = S.st, S.u
    local lb, y, sumr, wmax = 0, L.LABEL_INSET_PX * u, 0, 0
    for _, l in ipairs(S.m.labels or {}) do -- label stack bottom at size 30 (smallest stack: largest A)
        lb = y + l.r * L.MIN_SIZE
        y = lb + L.LABEL_INSET_PX * u
        if l.w > wmax then wmax = l.w end
    end
    local A = escAvailable(S, lb, #(S.m.labels or {}) > 0)
    for _, r in ipairs(S.rows) do sumr = sumr + (r.r or 0); if r.w > wmax then wmax = r.w end end
    local fit = sumr > 0 and (A - (#S.rows - 1) * st.Gap * u) / sumr or L.MAX_SIZE
    local width = wmax > 0 and ((st.Align == 'Center' and S.W or S.W - st.MarginX * u) / wmax) or L.MAX_SIZE
    return math.min(fit, width)
end
-- Without keep-outs the verdict at every size is independent of OffsetY (the block is clamped on screen and the fit
-- guarantees room between the labels and the bottom edge), so the size search is shared across OffsetY values.
local function escCompute(m, st)
    local offset = #(m.keepOuts or {}) > 0 and st.OffsetY or '*'
    local core = memo(table.concat({'e', st.Align, st.MarginX, offset, st.Gap, st.BlockHeight}, '|'), function()
        local S = escSetup(m, st)
        local H, reason, e = solve(function(s, full) if full then return escEval(S, s) end return escVerdict(S, s) end, escUpper(S))
        return {H = H, reason = reason, fit = e.fit}
    end)
    local S = escSetup(m, st)
    return {S = S, H = core.H, reason = core.reason, eval = function(s) return escEval(S, s) end,
            needScroll = not core.H and core.fit == false}
end
local function rowsOut(src, rows, size, H, pivot)
    local out = {}
    for i, row in ipairs(rows) do
        local r = src[i]
        local nf = r.nativeFontSize or 30
        out[i] = {id = row.id, rect = row.rect, slot = row.slot, pivot = pivot, scale = size / nf, hoverScale = H / nf}
    end
    return out
end
local function planEsc(m, st, diag, fallback)
    local size = st.ButtonSize
    local c = escCompute(m, st)
    local S = c.S
    if c.H then
        if c.H < size then
            fallback[#fallback + 1] = 'cap_size'
            diag[#diag + 1] = ('esc: cap_size ButtonSize %d -> %d (%s), stored value kept'):format(size, c.H, c.reason or 'block')
            size = c.H
        end
        local e = escEval(S, c.H, size) -- same geometry as the verdict at H; labels drawn at size inside their slots
        local eff = copy(st); eff.ButtonSize = size
        return {kind = 'esc', H = c.H, size = size, scroll = false, settings = eff, fallback = fallback, diagnostics = diag,
                reason = c.reason, rows = rowsOut(S.rows, e.rows, size, c.H, {X = PIVOT_X[st.Align], Y = .5}),
                labels = e.labels, available = e.available, block = rect(e.x, e.top, e.column, e.block),
                clamped = e.clamped, units = {pxToRoot = S.u}}
    end
    if c.needScroll then
        local u = S.u
        local labels, lb = escLabels(S, L.MIN_SIZE)
        local A = escAvailable(S, lb, #labels > 0)
        local C = colWidth(S.rows, L.MIN_SIZE)
        local want = (m.nativeBlockCenterY or S.Hv / 2) + st.OffsetY * u - A / 2
        local top = math.max(lb + L.LABEL_INSET_PX * u, math.min(S.Hv - L.LABEL_INSET_PX * u - A, want))
        local box = rect(alignX(st.Align, S.W, st.MarginX * u, C), top, C, A)
        local rows, y = {}, top
        for i, r in ipairs(S.rows) do
            rows[i] = {id = r.id, rect = rect(box.x, y, C, rowH(r, L.MIN_SIZE))}
            y = y + rowH(r, L.MIN_SIZE) + L.MIN_GAP_PX * u
        end
        local content = y - top - L.MIN_GAP_PX * u
        -- scroll only when the content (10 px gap) is taller than the box; a stored Gap that alone breaks the fit
        -- was already clamped to its bounds (§6.7) before this fallback
        if A > 0 and content > A + EPS and L.OnScreen(box, S.W, S.Hv) and not conflict(box, S.keeps, L.KEEP_OUT_PX * u)
            and labelsClear(S, labels) then
            fallback[#fallback + 1] = 'scroll'
            diag[#diag + 1] = ('esc: scroll, size 30 does not fit (%s)'):format(c.reason or 'block')
            local eff = copy(st); eff.ButtonSize = L.MIN_SIZE
            return {kind = 'esc', H = L.MIN_SIZE, size = L.MIN_SIZE, scroll = true, settings = eff, fallback = fallback,
                    diagnostics = diag, reason = c.reason, rows = rowsOut(S.rows, rows, 30, 30, {X = PIVOT_X[st.Align], Y = .5}),
                    labels = labels, available = A, scrollBox = box, contentHeight = content,
                    clamped = false, units = {pxToRoot = u}}
        end
    end
    return vanillaPlan('esc', m, st, fallback, diag, c.reason)
end

-- Lobby row (§6.3 lobby rules; Back in the top-right corner) ---------------------------------------------
local function lobbySetup(m, st)
    return {kind = 'lobby', m = m, st = st, u = 1 / m.pageScale, rows = m.rows, keeps = m.keepOuts or {},
            W = m.pageW or 1280, Hv = m.pageH or 720}
end
local function backRect(m, s)
    local c = m.corner
    if not c then return nil end
    local w, h = c.w * s, c.r * s
    return rect(c.rect.x + c.rect.w - w, c.rect.y, w, h)
end
local function lobbyEval(S, s)
    local m, st, u, band = S.m, S.st, S.u, S.m.band
    local back = backRect(m, s)
    local overlap = back and not (back.y + back.h <= band.y + EPS or band.y + band.h <= back.y + EPS)
    local A = band.w - (st.LeftOffset + st.RightOffset) * u - (overlap and back.w or 0)
    local pad, g = L.ROW_PAD_PX * u, L.MIN_GAP_PX * u
    local n, total, maxh = #S.rows, 0, 0
    for _, r in ipairs(S.rows) do total = total + r.w * s + 2 * pad; if r.r * s > maxh then maxh = r.r * s end end
    local gap = n > 1 and (A - total) / (n - 1) or 0
    local rows, x = {}, band.x + st.LeftOffset * u
    for i, r in ipairs(S.rows) do
        local w, h = r.w * s, r.r * s
        local y = band.y + (band.h - h) / 2
        rows[i] = {id = r.id, slot = rect(x, y, w + 2 * pad, h), rect = rect(x + pad, y, w, h)}
        x = x + w + 2 * pad + gap
    end
    local e = {ok = true, rows = rows, available = A, gap = gap, corner = back and {id = m.corner.id, rect = back, pivot = {X = 1, Y = 0}}}
    if total + (n - 1) * g > A + EPS then e.ok, e.fit, e.reason = false, false, 'gap' return e end
    if maxh > band.h + EPS then e.ok, e.reason = false, 'screen' return e end
    for _, row in ipairs(rows) do
        if not L.OnScreen(row.slot, S.W, S.Hv) then e.ok, e.reason = false, 'screen' return e end
    end
    if back and not L.OnScreen(back, S.W, S.Hv) then e.ok, e.reason = false, 'screen' return e end
    -- Back never moves (§0.7.1): growing it into a keep-out invalidates this size (smaller sizes may clear it)
    local backWhy = back and conflict(back, S.keeps, L.KEEP_OUT_PX * u)
    if backWhy then e.ok, e.reason = false, backWhy return e end
    for _, row in ipairs(rows) do
        if back and not L.Disjoint(row.rect, back, L.KEEP_OUT_PX * u) then e.ok, e.reason = false, 'corner' return e end
        local why = conflict(row.rect, S.keeps, L.KEEP_OUT_PX * u)
        if why then e.ok, e.reason = false, why return e end
    end
    return e
end
-- Closed-form upper bound on H: decreasing in both offsets.
local function lobbyUpper(S)
    local st, u, band = S.st, S.u, S.m.band
    local n, sumw, maxr = #S.rows, 0, 0
    for _, r in ipairs(S.rows) do sumw = sumw + r.w; if r.r > maxr then maxr = r.r end end
    local fit = sumw > 0 and (band.w - (st.LeftOffset + st.RightOffset) * u - n * 2 * L.ROW_PAD_PX * u - (n - 1) * L.MIN_GAP_PX * u) / sumw or L.MAX_SIZE
    local height = maxr > 0 and band.h / maxr or L.MAX_SIZE
    return math.min(fit, height)
end
local function lobbyCompute(m, st)
    return memo(table.concat({'l', st.LeftOffset, st.RightOffset}, '|'), function()
        local S = lobbySetup(m, st)
        local eval = function(s) return lobbyEval(S, s) end
        local H, reason, e = solve(eval, lobbyUpper(S), #S.rows == 1) -- one row + Back: both grow from fixed anchors
        return {S = S, H = H, reason = reason, e = e, eval = eval, needScroll = not H and e.fit == false}
    end)
end
local function planLobby(m, st, diag, fallback)
    local size = st.ButtonSize
    local c = lobbyCompute(m, st)
    local S = c.S
    if c.H then
        if c.H < size then
            fallback[#fallback + 1] = 'cap_size'
            diag[#diag + 1] = ('lobby: cap_size ButtonSize %d -> %d (%s), stored value kept'):format(size, c.H, c.reason or 'gap')
            size = c.H
        end
        local e = lobbyEval(S, c.H)
        local eff = copy(st); eff.ButtonSize = size
        return {kind = 'lobby', H = c.H, size = size, scroll = false, settings = eff, fallback = fallback, diagnostics = diag,
                reason = c.reason, rows = rowsOut(S.rows, e.rows, size, c.H, {X = .5, Y = .5}), corner = e.corner,
                available = e.available, gap = e.gap, units = {pxToPage = S.u}}
    end
    if c.needScroll then
        local e30, u, band = c.e, S.u, m.band
        local maxh = 0
        for _, r in ipairs(S.rows) do if r.r * L.MIN_SIZE > maxh then maxh = r.r * L.MIN_SIZE end end
        local box = rect(band.x + st.LeftOffset * u, band.y + (band.h - maxh) / 2, e30.available, maxh)
        local back = e30.corner and e30.corner.rect
        local ok = maxh <= band.h + EPS and e30.available > 0 and L.OnScreen(box, S.W, S.Hv)
            and not (back and not L.Disjoint(box, back, L.KEEP_OUT_PX * u)) and not conflict(box, S.keeps, L.KEEP_OUT_PX * u)
            and not (back and not L.OnScreen(back, S.W, S.Hv)) and not (back and conflict(back, S.keeps, L.KEEP_OUT_PX * u))
        if ok then
            local rows, x = {}, box.x
            for i, r in ipairs(S.rows) do
                local w, h = r.w * L.MIN_SIZE, r.r * L.MIN_SIZE
                local slot = rect(x, band.y + (band.h - h) / 2, w + 2 * L.ROW_PAD_PX * u, h)
                rows[i] = {id = r.id, slot = slot, rect = rect(x + L.ROW_PAD_PX * u, slot.y, w, h)}
                x = x + slot.w + L.MIN_GAP_PX * u
            end
            fallback[#fallback + 1] = 'scroll'
            diag[#diag + 1] = ('lobby: scroll, size 30 does not fit (%s)'):format(c.reason or 'gap')
            local eff = copy(st); eff.ButtonSize = L.MIN_SIZE
            return {kind = 'lobby', H = L.MIN_SIZE, size = L.MIN_SIZE, scroll = true, settings = eff, fallback = fallback,
                    diagnostics = diag, reason = c.reason, rows = rowsOut(S.rows, rows, 30, 30, {X = .5, Y = .5}),
                    corner = e30.corner, available = e30.available, scrollBox = box,
                    contentWidth = x - box.x - L.MIN_GAP_PX * u, units = {pxToPage = u}}
        end
    end
    return vanillaPlan('lobby', m, st, fallback, diag, c.reason)
end

-- Validity checks behind the bounds ---------------------------------------------------------------------
local PLANNERS = {main = planMain, esc = planEsc, lobby = planLobby}
local function compute(kind, m, st)
    if kind == 'main' then return mainCompute(m, st, titleOf(st)) end
    if kind == 'esc' then return escCompute(m, st) end
    return lobbyCompute(m, st)
end
local function settingsKey(st)
    return table.concat({st.ButtonSize, st.Align or '', st.MarginX or '', st.TopOffset or '', st.BottomOffset or '',
                         st.Footer or '', st.Title or '', st.TitleScale or '', st.TitleAlign or '', st.TitleMarginX or '',
                         st.TitleTop or '', st.OffsetY or '', st.Gap or '', st.BlockHeight or '', st.LeftOffset or '',
                         st.RightOffset or ''}, '|')
end
-- Search top of the size scan for settings st (H <= it), from closed-form bounds only (no layout).
local function topBound(kind, m, st)
    if kind == 'main' then return searchTop(mainUpperOf(m.rows, st, 1 / m.dpi, m.viewportW, m.viewportH)) end
    if kind == 'esc' then return searchTop(escUpper(escSetup(m, st))) end
    return searchTop(lobbyUpper(lobbySetup(m, st)))
end

-- Strict validity of a candidate (stored title, no fallback, no scroll, H >= ButtonSize). Returns ok, reason.
local function strictCheck(kind, m, st, key)
    local class = (TITLE_KEYS[key] and 't') or (kind == 'esc' and key == 'OffsetY' and 'o') or ''
    local r = memo('S' .. kind .. class .. settingsKey(st), function()
        -- valid at ButtonSize itself => H >= ButtonSize (H is the largest valid size), no size scan needed
        if kind == 'main' then
            local S, why = mainSetupMemo(m, st, titleOf(st))
            if not S then return {false, why} end
            if class == 't' and st.Footer == 'BottomRight' and S.title then
                for _, f in ipairs(footerStack(m, S.u) or {}) do
                    if not L.Disjoint(f.rect, S.title, L.KEEP_OUT_PX * S.u) then return {false, 'footer'} end
                end
            end
            if mainEval(S, st.ButtonSize).ok then return {true} end
        elseif kind == 'lobby' then
            if lobbyEval(lobbySetup(m, st), st.ButtonSize).ok then return {true} end
        elseif class == '' then
            if escVerdict(escSetup(m, st), st.ButtonSize).ok then return {true} end
        end
        local c = compute(kind, m, st)
        if not c.S then return {false, c.reason} end
        if not c.H then return {false, c.reason} end
        if c.H < st.ButtonSize then
            local e = c.eval(st.ButtonSize)
            return {false, e.ok and c.reason or e.reason}
        end
        if class == 'o' then -- the block clamp at H (escEval's placement, computed without building the layout)
            local S, H = c.S, c.H
            local u, labels = S.u, m.labels or {}
            local inset, y, lb, total = L.LABEL_INSET_PX * u, L.LABEL_INSET_PX * u, 0, 0
            for _, l in ipairs(labels) do lb = y + l.r * H; y = lb + inset end
            for _, r in ipairs(S.rows) do total = total + rowH(r, H) end
            local B = total + (#S.rows - 1) * st.Gap * u
            local want = (m.nativeBlockCenterY or S.Hv / 2) + st.OffsetY * u - B / 2
            if want < lb + inset - EPS then return {false, #labels > 0 and 'labels' or 'screen'} end
            if want > S.Hv - inset - B + EPS then return {false, 'screen'} end
        end
        return {true}
    end)
    return r[1], r[2]
end
-- Cheap necessary condition before strictCheck: the size scan cannot reach ButtonSize.
-- `bounded`: key can change topBound (else it was checked once for the whole slider).
local function strictFast(kind, m, st, key, bounded)
    if bounded and topBound(kind, m, st) < st.ButtonSize then return false end
    return (strictCheck(kind, m, st, key))
end
-- Relaxed validity: the planner (with its fallbacks) yields a non-vanilla plan.
local function relaxedCheck(kind, m, st)
    local key = settingsKey(st)
    if kind == 'esc' and #(m.keepOuts or {}) == 0 then -- verdict independent of OffsetY (see escCompute)
        local t = copy(st); t.OffsetY = '*'; key = settingsKey(t)
    end
    local r = memo('R' .. kind .. key, function()
        if kind == 'main' then
            local _, possible, why = mainFree(m, st)
            if not possible then return {false, why or 'screen'} end
            -- planMain's verdict without building a plan (same steps, existence only): (1)/(2) an H at the stored
            -- title, or a variant group whose smallest title has H >= 30 (searchGroup succeeds iff its last
            -- variant does); (3) a scroll candidate at the stored title or a group's smallest title; else (4) vanilla.
            local stored = titleOf(st)
            local c0 = mainCompute(m, st, stored)
            if c0.H then return {true} end
            local groups = titleVariantGroups(st)
            for _, list in ipairs(groups) do
                if mainCompute(m, st, list[#list]).H then return {true} end
            end
            local free = m.title and st.Title == 'Moved' and mainCompute(m, st, NO_TITLE) or c0
            if c0.needScroll or free.needScroll then
                if scrollCandidate(m, st, stored) then return {true} end
                for _, list in ipairs(groups) do
                    if scrollCandidate(m, st, list[#list]) then return {true} end
                end
            end
            return {false, free.H and 'title' or free.reason or c0.reason or 'screen'}
        end
        local plan = PLANNERS[kind](m, st, {}, {})
        if plan.vanilla then return {false, plan.reason or 'screen'} end
        return {true}
    end)
    return r[1], r[2]
end
local function readonlyEntry(v, reason)
    return {min = v, max = v, value = v, readonly = true, reasonMin = reason, reasonMax = reason}
end
-- The value of key at which topBound is largest (it is monotone in each slider key, see the upper bounds).
local FAVOR = {main = {TopOffset = 'min', BottomOffset = 'min', MarginX = 'min'},
               esc = {Gap = 'min', BlockHeight = 'max', MarginX = 'min'},
               lobby = {LeftOffset = 'min', RightOffset = 'min'}}
-- §6.7 run for one slider: maximal contiguous run of grid values containing the (clamped) current value for which
-- the plan is strictly valid with the others held, else (relaxed) non-vanilla. valueOnly returns {value, reason}
-- without measuring the run (used to clamp stored values at apply time).
local function scanSlider(kind, m, st, key, spec, valueOnly)
    local values = {}
    for i = 0, math.floor((spec.max - spec.min) / spec.step + .5) do values[#values + 1] = spec.min + i * spec.step end
    local cur = 1
    for i, v in ipairs(values) do if math.abs(v - st[key]) < EPS then cur = i end end
    local function at(i) local t = copy(st); t[key] = values[i]; return t end
    -- Esc OffsetY without keep-outs: H does not depend on OffsetY, so strictCheck's verdict for each value is its
    -- clamp test at that H; evaluate the same expressions directly instead of one check per value.
    local offsetVerdict
    if kind == 'esc' and key == 'OffsetY' and #(m.keepOuts or {}) == 0 then
        local c = compute(kind, m, st)
        if c.H and c.H >= st.ButtonSize then
            local S, H, labels = c.S, c.H, m.labels or {}
            local u = S.u
            local inset, y, lb, total = L.LABEL_INSET_PX * u, L.LABEL_INSET_PX * u, 0, 0
            for _, l in ipairs(labels) do lb = y + l.r * H; y = lb + inset end
            for _, r in ipairs(S.rows) do total = total + rowH(r, H) end
            local B = total + (#S.rows - 1) * st.Gap * u
            offsetVerdict = function(v)
                local want = (m.nativeBlockCenterY or S.Hv / 2) + v * u - B / 2
                if want < lb + inset - EPS then return false, #labels > 0 and 'labels' or 'screen' end
                if want > S.Hv - inset - B + EPS then return false, 'screen' end
                return true
            end
        end
    end
    for _, relaxed in ipairs({false, true}) do
        local cache = {}
        local function ok(i)
            if cache[i] == nil then
                if relaxed then cache[i] = relaxedCheck(kind, m, at(i))
                elseif offsetVerdict then cache[i] = (offsetVerdict(values[i]))
                else cache[i] = strictFast(kind, m, at(i), key, FAVOR[kind][key] ~= nil) end
            end
            return cache[i]
        end
        local function why(i)
            if relaxed then return select(2, relaxedCheck(kind, m, at(i))) end
            if offsetVerdict then return select(2, offsetVerdict(values[i])) end
            return select(2, strictCheck(kind, m, at(i), key))
        end
        local possible = true
        if not relaxed then -- skip the strict scan when no value of this slider can reach ButtonSize
            local favor = FAVOR[kind][key]
            local best = favor == 'min' and 1 or favor == 'max' and #values or cur
            possible = topBound(kind, m, at(best)) >= st.ButtonSize
            if possible and kind == 'main' and TITLE_KEYS[key] then
                local H = mainFree(m, st)
                possible = H ~= nil and H >= st.ButtonSize
            elseif possible and kind == 'esc' and key == 'OffsetY' and #(m.keepOuts or {}) == 0 then
                local H = compute(kind, m, st).H -- H does not depend on OffsetY here (see escCompute)
                possible = H ~= nil and H >= st.ButtonSize
            end
        end
        local start
        if possible then
            if ok(cur) then start = cur else
                for d = 1, #values do
                    if cur - d >= 1 and ok(cur - d) then start = cur - d break end
                    if cur + d <= #values and ok(cur + d) then start = cur + d break end
                end
            end
        end
        if start then
            if valueOnly then return {value = values[start], reason = start ~= cur and why(cur) or nil} end
            local lo, hi = start, start
            while lo > 1 and ok(lo - 1) do lo = lo - 1 end
            while hi < #values and ok(hi + 1) do hi = hi + 1 end
            local e = {min = values[lo], max = values[hi], value = values[start], relaxed = relaxed or nil}
            if lo > 1 then e.reasonMin = why(lo - 1) end
            if hi < #values then e.reasonMax = why(hi + 1) end
            if lo == hi then e.readonly = true end
            return e
        end
        if relaxed then
            if valueOnly then return {value = values[cur]} end
            return readonlyEntry(values[cur], why(cur) or 'screen')
        end
    end
end
local function sizeEntry(kind, m, st)
    local c = compute(kind, m, st)
    local maxv = c.H or L.MIN_SIZE
    local e = {min = L.MIN_SIZE, max = maxv, value = math.max(L.MIN_SIZE, math.min(maxv, st.ButtonSize)),
               step = L.SizeStep(maxv), reasonMax = c.reason, reasonMin = not c.H and c.reason or nil}
    if maxv <= L.MIN_SIZE then e.readonly = true end
    return e, c
end
local function alignEntry(kind, m, st)
    local options, value = {}, nil
    for i, option in ipairs(L.ENUMS.Align) do
        local t = copy(st); t.Align = option
        local good, why = strictCheck(kind, m, t, 'Align')
        if not good then good, why = relaxedCheck(kind, m, t) end
        options[i] = {value = option, available = good, reason = not good and why or nil}
        if good and option == st.Align then value = option end
    end
    if not value then for _, o in ipairs(options) do if o.available then value = o.value break end end end
    return {value = value or st.Align, options = options}
end
local function fixedKey(kind, m, st, key)
    if key == 'MarginX' and st.Align == 'Center' then return 'align' end
    if TITLE_KEYS[key] and (st.Title ~= 'Moved' or not m.title) then return 'title' end
end

-- Apply-time clamp (§6.7 wins over §6.4): every stored value is first clamped to its current bounds, in the
-- §6.7 order (displayed, never rewritten); the §6.4 fallback order runs only if the plan is still invalid.
local function clampSettings(kind, m, st, diag)
    st = copy(st)
    local fallback = {}
    for _, key in ipairs(L.ORDER[kind]) do
        if key == 'ButtonSize' then
            local e, c = sizeEntry(kind, m, st)
            if c.H and e.value < st.ButtonSize then
                fallback[#fallback + 1] = 'cap_size'
                diag[#diag + 1] = ('%s: cap_size ButtonSize %d -> %d (%s), stored value kept'):format(kind, st.ButtonSize, e.value, c.reason or 'gap')
            end
            st.ButtonSize = e.value
        else
            local from, to, why = st[key], st[key], nil
            if key == 'Align' then
                local good = strictCheck(kind, m, st, 'Align') or relaxedCheck(kind, m, st)
                if not good then
                    local a = alignEntry(kind, m, st)
                    to, why = a.value, select(2, relaxedCheck(kind, m, st))
                end
            elseif not fixedKey(kind, m, st, key) then
                local r = scanSlider(kind, m, st, key, L.SLIDERS[kind][key], true)
                to, why = r.value, r.reason
            end
            if to ~= from then
                st[key] = to
                if not contains(fallback, 'clamp') then fallback[#fallback + 1] = 'clamp' end
                diag[#diag + 1] = ('%s: clamp %s %s -> %s (%s), stored value kept'):format(kind, key, tostring(from), tostring(to), why or 'screen')
            end
        end
    end
    return st, fallback
end

-- Public API --------------------------------------------------------------------------------------------
-- L.Plan(kind, metrics, settings[, keepOuts]) -> plan | nil, why. Stored settings are never rewritten;
-- plan.settings holds the effective values after clamping/fallback.
function L.Plan(kind, metrics, settings, keepOuts)
    local planner = PLANNERS[kind]
    if not planner then return nil, 'unknown_kind' end
    return scoped(function()
        local m, why = prepare(kind, metrics, keepOuts)
        if not m then return nil, why end
        local st, diag = L.Settings(kind, settings, m)
        local fallback
        st, fallback = clampSettings(kind, m, st, diag)
        return planner(m, st, diag, fallback)
    end)
end

-- L.Evaluate(kind, metrics, settings, s) -> raw layout at a forced size s (no search, no clamp, no fallback):
-- {ok, reason, fit, rows, available, labels (esc), corner (lobby)}.
function L.Evaluate(kind, metrics, settings, s)
    if not PLANNERS[kind] then return nil, 'unknown_kind' end
    return scoped(function()
        local m, why = prepare(kind, metrics)
        if not m then return nil, why end
        local st = L.Settings(kind, settings, m)
        if kind == 'main' then
            local S, bad = mainSetup(m, st, titleOf(st))
            if not S then return {ok = false, reason = bad, rows = {}} end
            return mainEval(S, s, true)
        elseif kind == 'esc' then
            return escEval(escSetup(m, st), s)
        end
        return lobbyEval(lobbySetup(m, st), s)
    end)
end

-- L.Bounds(kind, metrics, settings[, keepOuts]) -> {[key] = {min, max, value, reasonMin, reasonMax, readonly,
-- step?}}, in the clamp order L.ORDER[kind]; Align = {value, options = {{value, available, reason}}}. keepOuts is
-- merged with metrics.keepOuts exactly as in L.Plan, so the bounds describe the layout Plan builds.
function L.Bounds(kind, metrics, settings, keepOuts)
    if not PLANNERS[kind] then return nil, 'unknown_kind' end
    return scoped(function()
        local m, why = prepare(kind, metrics, keepOuts)
        local st = L.Settings(kind, settings, m)
        local out = {}
        if not m then -- no usable record: code defaults read-only with the refusal reason
            for _, key in ipairs(L.ORDER[kind]) do out[key] = readonlyEntry(st[key], why) end
            return out
        end
        for _, key in ipairs(L.ORDER[kind]) do
            if key == 'ButtonSize' then
                out[key] = sizeEntry(kind, m, st)
                st.ButtonSize = out[key].value
            elseif key == 'Align' then
                out[key] = alignEntry(kind, m, st)
                st.Align = out[key].value
            else
                local fixed = fixedKey(kind, m, st, key)
                if fixed then out[key] = readonlyEntry(st[key], fixed)
                else out[key] = scanSlider(kind, m, st, key, L.SLIDERS[kind][key]) end
                st[key] = out[key].value
            end
        end
        return out
    end)
end

return L
