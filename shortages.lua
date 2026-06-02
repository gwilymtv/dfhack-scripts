-- Aggregate job-cancellation material shortages into a fort overlay.
--@module = true
--[====[

shortages
=========
Watch job-cancellation announcements (e.g. "Urist cancels Make cloth hood:
needs 1 unused plant cloth") and keep an aggregated, on-screen summary of the
materials your fort is currently short on, so you don't have to read the
announcement log. Shortages fall off the list once they stop being reported
within a rolling window (7 days by default).

Usage::

    shortages [list]                show the current shortage summary
    shortages window <days>         set the rolling window (default 7)
    shortages group item|job|both   set how shortages are grouped

The window is measured in DF days; a DF month is 28 days and a DF year is 336
days (4 seasons of 84 days), so a 7-day window is a quarter of a month.

An overlay (enabled by default) shows the summary in the corner of the fort map
and hides itself when there are no shortages. Press Ctrl-G on it to cycle the
grouping.

]====]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local GLOBAL_KEY = 'shortages'

local TICKS_PER_DAY = 1200
local TICKS_PER_YEAR = 403200
local MAX_LINES = 10

-- module-level state, survives script reload (per the prioritize.lua pattern).
-- config (window_days, group_mode) is persisted per-site. cache maps a report id to
-- its parsed components (or false if it isn't a material shortage), so each report's
-- text is parsed at most once; agg/lines are re-derived from the live log each pass.
state = state or {
    window_days = 7,
    group_mode = 'item',  -- 'item' | 'job' | 'both'
    cache = {},           -- [report_id] = {job=, item=, base_n=} | false
    agg = {},             -- bucket key -> summed quantity needed
    lines = {},           -- precomputed display lines (rendered by the overlay)
}

local function now_tick()
    return df.global.cur_year * TICKS_PER_YEAR + df.global.cur_year_tick
end

-- the real in-game time the report was generated (reports carry their own stamp;
-- report.time and cur_year_tick share the same 'season_count' unit)
local function report_tick(r)
    return r.year * TICKS_PER_YEAR + r.time
end

-- the only thing that varies with group_mode; computed from cached components, never
-- from report text, so grouping and re-derivation are pure math.
local function bucket_key(c)
    if state.group_mode == 'job' then
        return c.job
    elseif state.group_mode == 'both' then
        return ('%s: %s'):format(c.job, c.item)
    end
    return c.item
end

-- parse exactly once per report. the announcement_type gate already told us this is a
-- job cancellation; here we pull the components out of the text, keeping only the
-- material-shortage ("needs ...") variants: "<who> cancels <job>: [Nn]eeds <n> <item>[.]".
-- returns job, item, qty-per-occurrence, or nil if not a material shortage.
local function parse_cancellation(text)
    local job, reason = text:match('cancels%s+(.-):%s*[Nn]eeds%s+(.+)$')
    if not job then return end
    reason = reason:gsub('%.%s*$', ''):gsub('%s+$', '')  -- drop trailing period/space
    local qty, item = reason:match('^(%d+)%s+(.+)$')
    local n = 1
    if qty then
        n = tonumber(qty)
    else
        item = reason
    end
    if not item or item == '' then return end
    return job, item:lower(), n
end

local function sorted_aggregate()
    local arr = {}
    for k, qty in pairs(state.agg) do
        arr[#arr+1] = {key=k, qty=qty}
    end
    table.sort(arr, function(a, b)
        if a.qty ~= b.qty then return a.qty > b.qty end
        return a.key < b.key
    end)
    return arr
end

local function recompute_lines()
    local arr = sorted_aggregate()
    local lines = {}
    for i, e in ipairs(arr) do
        if i > MAX_LINES then
            lines[MAX_LINES] = ('...and %d more'):format(#arr - (MAX_LINES-1))
            break
        end
        lines[i] = ('%d %s'):format(e.qty, e.key)
    end
    state.lines = lines
end

-- re-derive the aggregate from the live report log. only walks the tail of the log
-- (reports are time-ordered, so we stop at the window edge), parses each report's text
-- at most once (cached by id), and reads repeat_count fresh so recurring shortages keep
-- climbing. a report's "x2" display means repeat_count==1, i.e. 2 occurrences.
local function rebuild()
    local reports = df.global.world.status.reports
    local cutoff = now_tick() - state.window_days * TICKS_PER_DAY
    local cache = state.cache
    local agg = {}
    local seen = {}
    for i = #reports-1, 0, -1 do
        local r = reports[i]
        if report_tick(r) < cutoff then break end
        if r.type == df.announcement_type.CANCEL_JOB then
            local id = r.id
            seen[id] = true
            local c = cache[id]
            if c == nil then
                local job, item, base_n = parse_cancellation(r.text)
                c = job and {job=job, item=item, base_n=base_n} or false
                cache[id] = c
            end
            if c then
                local k = bucket_key(c)
                agg[k] = (agg[k] or 0) + c.base_n * (r.repeat_count + 1)
            end
        end
    end
    -- forget reports that have aged out of the window (bounds cache growth)
    for id in pairs(cache) do
        if not seen[id] then cache[id] = nil end
    end
    state.agg = agg
    recompute_lines()
end

local function clear()
    state.cache = {}
    state.agg = {}
    state.lines = {}
end

local function persist()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {
        window_days=state.window_days,
        group_mode=state.group_mode,
    })
end

local function load_config()
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    state.window_days = d.window_days or 7
    state.group_mode = d.group_mode or 'item'
end

--
-- overlay
--

ShortageOverlay = defclass(ShortageOverlay, overlay.OverlayWidget)
ShortageOverlay.ATTRS{
    desc='Aggregates job-cancellation material shortages.',
    default_pos={x=2, y=-7},
    default_enabled=true,
    viewscreens='dwarfmode/Default',
    overlay_onupdate_max_freq_seconds=3,
    -- rows: title(0), grouping(1), gap(2), MAX_LINES lines (3..2+MAX_LINES), +2 border
    frame={w=44, h=MAX_LINES+5},
    frame_style=gui.FRAME_MEDIUM,
    frame_background=gui.CLEAR_PEN,
    -- hide (frame and all) when there are no shortages; overlay_onupdate still runs
    -- while hidden, so new shortages are detected and the panel reappears.
    visible=function() return next(state.agg) ~= nil end,
}

function ShortageOverlay:init()
    self:addviews{
        widgets.Label{
            frame={t=0, l=0},
            text={{text=function()
                return ('Shortages (last %dd)'):format(state.window_days)
            end, pen=COLOR_YELLOW}},
        },
        widgets.CycleHotkeyLabel{
            view_id='group',
            frame={t=1, l=0},
            key='CUSTOM_CTRL_G',
            label='Group by:',
            options={
                {label='item', value='item'},
                {label='job', value='job'},
                {label='both', value='both'},
            },
            initial_option=state.group_mode,
            on_change=function(new)
                state.group_mode = new
                rebuild()
                persist()
            end,
        },
    }
    -- one label per line; each reads its slot from state.lines at render time, which
    -- is the same dynamic-token pattern as the (working) title above.
    for i = 1, MAX_LINES do
        self:addviews{
            widgets.Label{
                frame={t=2+i, l=0},
                text={{text=function() return state.lines[i] or '' end}},
            },
        }
    end
end

function ShortageOverlay:overlay_onupdate()
    rebuild()
end

OVERLAY_WIDGETS = {
    shortages=ShortageOverlay,
}

--
-- lifecycle + command line
--

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        clear()  -- report ids restart per fort; drop the cache to avoid collisions
        return
    end
    if sc ~= SC_MAP_LOADED or df.global.gamemode ~= df.game_mode.DWARF then
        return
    end
    load_config()
end

if dfhack_flags.module then
    return
end

if df.global.gamemode ~= df.game_mode.DWARF then
    qerror('shortages requires a loaded fortress')
end

load_config()

local function usage()
    print(([[Usage:
  shortages [list]                show the current shortage summary
  shortages window <days>         set the rolling window (default 7)
  shortages group item|job|both   set how shortages are grouped
(window is in DF days: 28 days/month, 336 days/year)]]))
end

local args = {...}
local command = args[1]

if command == 'help' or command == '?' then
    usage()
elseif not command or command == 'list' then
    rebuild()
    local arr = sorted_aggregate()
    if #arr == 0 then
        print('No material shortages in the last '..state.window_days..' days.')
    else
        print(('Material shortages (last %d days, grouped by %s):')
            :format(state.window_days, state.group_mode))
        for _, e in ipairs(arr) do
            print(('  %4d  %s'):format(e.qty, e.key))
        end
    end
elseif command == 'window' then
    local days = tonumber(args[2])
    if not days or days <= 0 then
        qerror('usage: shortages window <days>')
    end
    state.window_days = math.floor(days)
    persist()
    print('shortages window set to '..state.window_days..' days')
elseif command == 'group' then
    local mode = args[2]
    if mode ~= 'item' and mode ~= 'job' and mode ~= 'both' then
        qerror('usage: shortages group item|job|both')
    end
    state.group_mode = mode
    persist()
    print('shortages grouping set to '..mode)
else
    dfhack.printerr('unknown command: '..command)
    usage()
end
