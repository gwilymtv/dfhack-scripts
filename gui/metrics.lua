-- Resizable timeseries chart of the data recorded by the `metrics` script.
--@ module = false

--[[
gui/metrics opens a resizable window that plots the per-day snapshots collected
by the `metrics` module as an ASCII timeseries chart.

Pick any number of metrics from the list on the left; each is plotted as its own
coloured line. A metric is cycled off -> left axis -> right axis with Enter, so
two differently-scaled quantities (say population and wealth) can share one chart
without squashing each other -- each axis auto-scales to only the series assigned
to it. The chart redraws live, so toggling a metric or resizing the window updates
it immediately.

Vertical resolution is doubled with the half-block glyphs (each character cell is
two sub-rows: upper, lower, or a full block), so the lines read smoothly even in a
short window.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local metrics = reqscript('metrics')

-- ------------------------------------------------------------------
-- plottable metric catalog
-- ------------------------------------------------------------------
-- Each entry exposes a scalar getter over a snapshot (see metrics.lua's snapshot
-- shape). A getter returns nil when the snapshot predates that field; the chart
-- treats nils as gaps. Happiness/stress getters reuse the module's exported math
-- so the figures match `metrics now`/`metrics dump`.
local function wealth_get(field) return function(s) return s.wealth and s.wealth[field] end end
local function food_get(field) return function(s) return s.food and s.food[field] end end
local function band_get(name) return function(s) return metrics.band_counts(s)[name] end end

local CATALOG = {
    {key='pop',              label='population',       get=function(s) return s.pop end},
    {key='military',         label='military',         get=function(s) return s.military end},
    {key='pets',             label='pets/livestock',   get=function(s) return s.pets end},
    {key='others',           label='others',           get=function(s) return s.others end},
    {key='workshops',        label='workshops',        get=function(s) return s.workshops end},
    {key='workshops_active', label='workshops active', get=function(s) return s.workshops_active end},
    {key='stress_mean',      label='stress: mean',     get=function(s) return metrics.stress_mean(s) end},
    {key='stress_p10',       label='stress: p10',      get=function(s) return metrics.stress_quantile(s, 0.1) end},
    {key='stress_median',    label='stress: median',   get=function(s) return metrics.stress_quantile(s, 0.5) end},
    {key='stress_p90',       label='stress: p90',      get=function(s) return metrics.stress_quantile(s, 0.9) end},
    {key='wealth_created',      label='wealth: total',        get=wealth_get('created')},
    {key='wealth_weapons',      label='wealth: weapons',      get=wealth_get('weapons')},
    {key='wealth_armor',        label='wealth: armor',        get=wealth_get('armor')},
    {key='wealth_furniture',    label='wealth: furniture',    get=wealth_get('furniture')},
    {key='wealth_other',        label='wealth: other',        get=wealth_get('other')},
    {key='wealth_architecture', label='wealth: architecture', get=wealth_get('architecture')},
    {key='wealth_displayed',    label='wealth: displayed',    get=wealth_get('displayed')},
    {key='wealth_held',         label='wealth: held',         get=wealth_get('held')},
    {key='wealth_imported',     label='wealth: imported',     get=wealth_get('imported')},
    {key='wealth_exported',     label='wealth: exported',     get=wealth_get('exported')},
    {key='food_total', label='food: total', get=food_get('total')},
    {key='food_drink', label='food: drink', get=food_get('drink')},
    {key='food_seeds', label='food: seeds', get=food_get('seeds')},
    {key='food_meat',  label='food: meat',  get=food_get('meat')},
    {key='food_fish',  label='food: fish',  get=food_get('fish')},
    {key='food_plant', label='food: plant', get=food_get('plant')},
    {key='food_other', label='food: other', get=food_get('other')},
}
-- happiness bands, inserted after the building rows in DF's display order
do
    local at = 6  -- after workshops_active
    for _, name in ipairs(metrics.DISPLAY_ORDER) do
        at = at + 1
        table.insert(CATALOG, at, {key='happy_'..name, label='happiness: '..name, get=band_get(name)})
    end
end

local CATALOG_BY_KEY = {}
for _, m in ipairs(CATALOG) do CATALOG_BY_KEY[m.key] = m end

-- colours assigned to series in activation order
local PALETTE = {
    COLOR_LIGHTGREEN, COLOR_LIGHTCYAN, COLOR_YELLOW, COLOR_LIGHTRED,
    COLOR_LIGHTMAGENTA, COLOR_WHITE, COLOR_LIGHTBLUE, COLOR_GREEN,
    COLOR_BROWN, COLOR_CYAN,
}

-- CP437 box-drawing / block glyphs
local C_VLINE = 179   -- vertical axis
local C_HLINE = 196   -- horizontal axis
local C_CORNER_BL = 192
local C_CORNER_BR = 217
local C_FULL = 219    -- both sub-rows
local C_UPPER = 223   -- upper sub-row
local C_LOWER = 220   -- lower sub-row

-- ------------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------------
-- compact, axis-label-friendly number (<= 6 chars): 84, 1.2k, 340k, 1.2M ...
local function fmt_short(v)
    if v == nil then return '' end
    local a = math.abs(v)
    if a >= 1e9 then return ('%.1fB'):format(v / 1e9)
    elseif a >= 1e6 then return ('%.1fM'):format(v / 1e6)
    elseif a >= 1e4 then return ('%.0fk'):format(v / 1e3)
    elseif a >= 1e3 then return ('%.1fk'):format(v / 1e3)
    else return ('%g'):format(v >= 100 and math.floor(v + 0.5) or v) end
end

local function date_of(snap)
    return ('%d-%02d-%02d'):format(snap.year, snap.month, snap.day)
end

-- min/max over every value of every series assigned to one axis; nil if no data.
-- zero_base pulls the range to include 0 so counts read against a real baseline.
local function axis_range(snaps, series, zero_base)
    local lo, hi
    for _, ser in ipairs(series) do
        for _, snap in ipairs(snaps) do
            local v = ser.get(snap)
            if v then
                lo = lo and math.min(lo, v) or v
                hi = hi and math.max(hi, v) or v
            end
        end
    end
    if not lo then return nil end
    if zero_base then lo = math.min(lo, 0); hi = math.max(hi, 0) end
    if lo == hi then  -- avoid a zero-width range
        if lo == 0 then hi = 1 else lo = lo - math.abs(lo) * 0.1; hi = hi + math.abs(hi) * 0.1 end
    end
    return lo, hi
end

-- average each snapshot's value into one of pw plot columns, then linearly fill
-- gaps between known columns. Handles both up-sampling (few days, wide window)
-- and down-sampling (more days than columns). Returns col[0..pw-1] (nil = gap).
local function sample_columns(snaps, get, pw)
    local n = #snaps
    local acc, cnt = {}, {}
    for c = 0, pw - 1 do acc[c], cnt[c] = 0, 0 end
    for i = 1, n do
        local v = get(snaps[i])
        if v then
            local c = (n == 1) and 0 or math.floor((i - 1) / (n - 1) * (pw - 1) + 0.5)
            acc[c] = acc[c] + v
            cnt[c] = cnt[c] + 1
        end
    end
    local col = {}
    for c = 0, pw - 1 do col[c] = cnt[c] > 0 and acc[c] / cnt[c] or nil end
    local last
    for c = 0, pw - 1 do
        if col[c] ~= nil then
            if last and last < c - 1 then
                local v0, v1 = col[last], col[c]
                for g = last + 1, c - 1 do
                    col[g] = v0 + (v1 - v0) * (g - last) / (c - last)
                end
            end
            last = c
        end
    end
    return col
end

-- value -> sub-row index (0 = top of plot), over nrows cells = 2*nrows sub-rows
local function val_to_sub(v, lo, hi, nrows)
    local subN = nrows * 2
    if hi <= lo then return subN - 1 end
    local frac = (v - lo) / (hi - lo)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return math.floor((1 - frac) * (subN - 1) + 0.5)
end

-- ------------------------------------------------------------------
-- chart widget
-- ------------------------------------------------------------------
Chart = defclass(Chart, widgets.Panel)
Chart.ATTRS{
    get_series = DEFAULT_NIL,     -- fun(): snapshot[]
    get_active = DEFAULT_NIL,     -- fun(): {label, get, axis('L'/'R'), color}[]
    get_zero_base = DEFAULT_NIL,  -- fun(): boolean
}

function Chart:onRenderBody(dc)
    dc:clear()
    local W, H = self.frame_body.width, self.frame_body.height
    local snaps = self.get_series()
    if not snaps or #snaps == 0 then
        dc:seek(0, 0):string('No metrics recorded yet.', COLOR_YELLOW)
        dc:seek(0, 2):string('Start collecting with: ', COLOR_GREY)
        dc:string('metrics enable', COLOR_LIGHTCYAN)
        return
    end
    local active = self.get_active()
    if #active == 0 then
        dc:seek(0, 0):string('Pick one or more metrics on the left.', COLOR_YELLOW)
        dc:seek(0, 2):string('Enter cycles a metric: off / left / right axis.', COLOR_GREY)
        return
    end

    local left, right = {}, {}
    for _, s in ipairs(active) do
        table.insert(s.axis == 'R' and right or left, s)
    end
    local zero = self.get_zero_base()
    local llo, lhi = axis_range(snaps, left, zero)
    local rlo, rhi = axis_range(snaps, right, zero)

    -- geometry: left/right gutters for axis labels, bottom rows for dates + legend
    local lgut = #left > 0 and 6 or 0
    local rgut = #right > 0 and 6 or 0
    local axis_x = lgut                              -- left axis column
    local dx0 = axis_x + 1                           -- first data column
    local rax_x = #right > 0 and (W - 1 - rgut) or nil
    local dx1 = rax_x and (rax_x - 1) or (W - 1)     -- last data column
    local pw = dx1 - dx0 + 1
    local legend_y, xlabel_y, base_y = H - 1, H - 2, H - 3
    local nrows = base_y                             -- data rows are 0..base_y-1
    if pw < 2 or nrows < 2 then
        dc:seek(0, 0):string('window too small', COLOR_RED)
        return
    end

    -- axis frame
    for y = 0, base_y - 1 do dc:seek(axis_x, y):char(C_VLINE, COLOR_GREY) end
    dc:seek(axis_x, base_y):char(C_CORNER_BL, COLOR_GREY)
    for x = dx0, dx1 do dc:seek(x, base_y):char(C_HLINE, COLOR_GREY) end
    if rax_x then
        for y = 0, base_y - 1 do dc:seek(rax_x, y):char(C_VLINE, COLOR_GREY) end
        dc:seek(rax_x, base_y):char(C_CORNER_BR, COLOR_GREY)
    end

    -- plot every series into a sub-pixel grid; last writer wins on overlap
    local grid = {}  -- "x,row" -> {top=color, bot=color}
    local function setpix(x, sr, color)
        local row = math.floor(sr / 2)
        if row < 0 or row >= base_y then return end
        local key = x .. ',' .. row
        local cell = grid[key]
        if not cell then cell = {}; grid[key] = cell end
        if sr % 2 == 0 then cell.top = color else cell.bot = color end
    end
    local function plot(series, lo, hi)
        if not lo then return end
        for _, ser in ipairs(series) do
            local col = sample_columns(snaps, ser.get, pw)
            local prev
            for c = 0, pw - 1 do
                local v = col[c]
                if v ~= nil then
                    local s = val_to_sub(v, lo, hi, nrows)
                    local s0, s1 = s, s
                    if prev then s0, s1 = math.min(s, prev), math.max(s, prev) end
                    for sr = s0, s1 do setpix(dx0 + c, sr, ser.color) end
                    prev = s
                else
                    prev = nil
                end
            end
        end
    end
    plot(left, llo, lhi)
    plot(right, rlo, rhi)

    for key, cell in pairs(grid) do
        local sx, sy = key:match('(%d+),(%d+)')
        local ch, color
        if cell.top and cell.bot then ch, color = C_FULL, cell.top
        elseif cell.top then ch, color = C_UPPER, cell.top
        else ch, color = C_LOWER, cell.bot end
        dc:seek(tonumber(sx), tonumber(sy)):char(ch, color)
    end

    -- y-axis labels (single-series axes are tinted with that series' colour)
    local function yaxis_labels(lo, hi, series, right_side)
        if not lo then return end
        local color = #series == 1 and series[1].color or COLOR_GREY
        local mid_row = math.floor((base_y - 1) / 2)
        local rows = {[0] = hi, [mid_row] = (lo + hi) / 2, [base_y - 1] = lo}
        for row, val in pairs(rows) do
            local txt = fmt_short(val)
            if right_side then
                dc:seek(rax_x + 1, row):string(txt, color)
            else
                dc:seek(axis_x - #txt, row):string(txt, color)
            end
        end
    end
    yaxis_labels(llo, lhi, left, false)
    yaxis_labels(rlo, rhi, right, true)

    -- x-axis date range
    local d0, d1 = date_of(snaps[1]), date_of(snaps[#snaps])
    dc:seek(dx0, xlabel_y):string(d0, COLOR_GREY)
    if dx0 + #d0 < dx1 - #d1 then
        dc:seek(dx1 - #d1 + 1, xlabel_y):string(d1, COLOR_GREY)
    end

    -- legend
    local lx = 0
    for _, ser in ipairs(active) do
        if lx >= W - 4 then break end
        dc:seek(lx, legend_y):char(C_FULL, ser.color)
        local tag = (' %s (%s)'):format(ser.label, ser.axis)
        dc:seek(lx + 1, legend_y):string(tag, COLOR_GREY)
        lx = lx + 1 + #tag + 2
    end
end

-- ------------------------------------------------------------------
-- window
-- ------------------------------------------------------------------
MetricsWindow = defclass(MetricsWindow, widgets.Window)
MetricsWindow.ATTRS{
    frame_title = 'Fort metrics',
    frame = {w=86, h=32},
    resizable = true,
    resize_min = {w=54, h=20},
}

function MetricsWindow:init()
    self.axis = {}    -- key -> 'L'/'R' (absent = off)
    self.colors = {}  -- key -> color (held while active)
    self.order = {}   -- active keys in activation order (legend/colour order)
    self.zero_base = true
    self.snaps = metrics.get_series()

    self:addviews{
        widgets.Panel{
            frame = {l=0, t=0, w=26, b=0},
            subviews = {
                widgets.Label{frame={t=0, l=0}, text='Metrics'},
                widgets.Label{frame={t=1, l=0}, text={
                    {text='Enter', pen=COLOR_LIGHTGREEN}, ': off / left / right'}},
                widgets.FilteredList{
                    view_id = 'list',
                    frame = {t=3, l=0, r=0, b=2},
                    on_submit = function(_, choice) self:cycle(choice) end,
                },
                widgets.Label{frame={b=0, l=0}, text={
                    {text='Shift-Z', pen=COLOR_LIGHTGREEN}, ': zero-base  ',
                    {text='Shift-R', pen=COLOR_LIGHTGREEN}, ': reload'}},
            },
        },
        Chart{
            view_id = 'chart',
            frame = {l=27, t=0, r=0, b=0},
            get_series = function() return self.snaps end,
            get_active = function() return self:get_active() end,
            get_zero_base = function() return self.zero_base end,
        },
    }
    self:refresh_list()
end

-- active series in activation order, resolved against the catalog
function MetricsWindow:get_active()
    local out = {}
    for _, key in ipairs(self.order) do
        local m = CATALOG_BY_KEY[key]
        table.insert(out, {label=m.label, get=m.get, axis=self.axis[key], color=self.colors[key]})
    end
    return out
end

-- cycle a metric off -> left axis -> right axis -> off
function MetricsWindow:cycle(choice)
    if not choice then return end
    local key = choice.metric.key
    local cur = self.axis[key]
    if cur == nil then
        self.axis[key] = 'L'
        self.colors[key] = PALETTE[#self.order % #PALETTE + 1]
        table.insert(self.order, key)
    elseif cur == 'L' then
        self.axis[key] = 'R'
    else
        self.axis[key] = nil
        self.colors[key] = nil
        for i, k in ipairs(self.order) do
            if k == key then table.remove(self.order, i); break end
        end
    end
    self:refresh_list()
end

function MetricsWindow:refresh_list()
    local list = self.subviews.list
    local filter = list:getFilter()
    local sel = list:getSelected()
    local choices = {}
    for _, m in ipairs(CATALOG) do
        local ax = self.axis[m.key]
        local marker = ax == 'L' and '[L] ' or ax == 'R' and '[R] ' or '[ ] '
        table.insert(choices, {
            text = {
                {text=marker, pen=ax and self.colors[m.key] or COLOR_GREY},
                {text=m.label, pen=ax and COLOR_WHITE or COLOR_GREY},
            },
            metric = m,
        })
    end
    list:setChoices(choices)
    list:setFilter(filter, sel)
end

-- Intercepted at the window (before the search field) so the Shift hotkeys never
-- reach the FilteredList edit field; lowercase z/r still type into the filter.
function MetricsWindow:onInput(keys)
    if keys.CUSTOM_SHIFT_Z then
        self.zero_base = not self.zero_base
        return true
    elseif keys.CUSTOM_SHIFT_R then
        self.snaps = metrics.get_series()
        return true
    end
    return MetricsWindow.super.onInput(self, keys)
end

-- ------------------------------------------------------------------
-- screen / launch
-- ------------------------------------------------------------------
MetricsScreen = defclass(MetricsScreen, gui.ZScreen)
MetricsScreen.ATTRS{
    focus_path = 'metrics',
}

function MetricsScreen:init()
    self:addviews{MetricsWindow{}}
end

function MetricsScreen:onDismiss()
    view = nil
end

if not dfhack.world.isFortressMode() then
    qerror('gui/metrics requires fortress mode')
end

view = view and view:raise() or MetricsScreen{}:show()
