-- Search for a site by name on the world map (in-fort or embark) and locate it.
--@ module = true

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

-- size of a world-map tile in pixels (the map renders at a fixed scale,
-- independent of the text grid); validated empirically across grid settings
local MAP_TILE_PX = 16
local BLINK_MS = 400

-- embark tiles per world tile (site.global_min/max_* are in embark tiles)
local EMBARK_PER_WORLD = 16

local BG_PEN = dfhack.pen.parse{ch=' ', fg=COLOR_BLACK, bg=COLOR_BLACK}

-- dialog state remembered for the session (reset when the script is reloaded),
-- so reopening the finder restores the filters, search, and window geometry
local session = {race='all', sav='all', search='', frame=nil}

-- compute the screen tile that a world position renders at, given the current
-- view center. anchor is round(dim/2) (round-half-up); scale is map-px per
-- text-cell-px, which differs per axis because text cells aren't square.
local function world_to_screen(pos, cent_x, cent_y)
    local g = df.global.gps
    local px = ((g.dimx+1)//2) +
        math.floor((pos.x - cent_x) * MAP_TILE_PX / g.tile_pixel_x + 0.5)
    local py = ((g.dimy+1)//2) +
        math.floor((pos.y - cent_y) * MAP_TILE_PX / g.tile_pixel_y + 0.5)
    return px, py
end

-- Sum the residents of a site. Returns the total head-count, a {race=count}
-- table for residents with a known creature race, and the count of residents
-- whose race is unset (race < 0).
local function get_population(site)
    local total, by_race, other = 0, {}, 0
    for _, group in ipairs(site.populace.inhabitants) do
        local count = group.count
        total = total + count
        local race = group.pop_spec.race
        if race and race >= 0 then
            by_race[race] = (by_race[race] or 0) + count
        else
            other = other + count
        end
    end
    return total, by_race, other
end

-- savagery is 0-100; the brackets come from the region_map_entry doc comment
local function savagery_label(s)
    if s <= 32 then return 'Calm'
    elseif s <= 65 then return 'Neutral'
    else return 'Savage' end
end

local function savagery_pen(s)
    if s <= 32 then return COLOR_GREEN
    elseif s <= 65 then return COLOR_GRAY
    else return COLOR_LIGHTRED end
end

-- Maximum savagery across every world (region_map) tile the site overlaps.
-- The site rectangle is given in embark tiles, so divide down to world tiles.
-- Returns nil if no in-bounds tile was found.
local function get_max_savagery(site)
    local wd = df.global.world.world_data
    local rmap = wd and wd.region_map
    if not rmap then return end
    local x0 = site.global_min_x // EMBARK_PER_WORLD
    local x1 = site.global_max_x // EMBARK_PER_WORLD
    local y0 = site.global_min_y // EMBARK_PER_WORLD
    local y1 = site.global_max_y // EMBARK_PER_WORLD
    local maxsav
    for x = x0, x1 do
        if x >= 0 and x < wd.world_width then
            for y = y0, y1 do
                if y >= 0 and y < wd.world_height then
                    local s = rmap[x]:_displace(y).savagery
                    if not maxsav or s > maxsav then maxsav = s end
                end
            end
        end
    end
    return maxsav
end

local function race_name(race)
    local craw = df.global.world.raws.creatures.all[race]
    if not craw then return 'race '..race end
    if craw.name[1] ~= '' then return craw.name[1] end  -- plural
    if craw.name[0] ~= '' then return craw.name[0] end  -- singular
    return craw.creature_id
end

local function cap(s)
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- adjective form of a race, capitalized (e.g. "Elven"); falls back to the
-- singular noun or raw id if the adjective is missing
local function race_adj(race)
    local craw = df.global.world.raws.creatures.all[race]
    if not craw then return 'race '..race end
    if craw.name[2] ~= '' then return cap(craw.name[2]) end
    if craw.name[0] ~= '' then return cap(craw.name[0]) end
    return craw.creature_id
end

-- race of the site's current owner (falling back to its civilization), or nil
local function get_owner_race(site)
    local eid = site.cur_owner_id
    if eid < 0 then eid = site.civ_id end
    if eid < 0 then return end
    local ent = df.historical_entity.find(eid)
    if not ent or ent.race < 0 then return end
    return ent.race
end

local function build_choices()
    local choices = {}
    local own_civ = df.global.plotinfo.civ_id
    local own_site = df.global.plotinfo.site_id
    for _, site in ipairs(df.global.world.world_data.sites) do
        local name = dfhack.translation.translateName(site.name, true)
        if not name or #name == 0 then name = '(unnamed)' end
        local tag, tag_pen
        if site.id == own_site then
            tag, tag_pen = 'your fort', COLOR_LIGHTGREEN
        elseif site.civ_id == own_civ then
            tag, tag_pen = 'your civ', COLOR_GREEN
        end
        -- build a parenthesized summary: "(Race Sitetype, pop N, savagery)"
        local type_name = df.world_site_type[site.type] or '?'
        local race = get_owner_race(site)
        local head = race and (race_adj(race)..' '..type_name) or type_name
        local text = {
            {text=name},
            {gap=1, text='('..head, pen=COLOR_GRAY},
        }
        local pop = get_population(site)
        if pop > 0 then
            table.insert(text, {text=', pop '..pop, pen=COLOR_GRAY})
        end
        local sav = get_max_savagery(site)
        if sav then
            table.insert(text, {text=', ', pen=COLOR_GRAY})
            table.insert(text, {text=savagery_label(sav), pen=savagery_pen(sav)})
        end
        table.insert(text, {text=')', pen=COLOR_GRAY})
        if tag then
            table.insert(text, {gap=1, text=tag, pen=tag_pen})
        end
        table.insert(choices, {
            text=text,
            search_key=name:lower(),
            site=site,
            race_id=race,  -- for the race filter (may be nil)
            sav=sav,       -- for the savagery filter (may be nil)
        })
    end
    table.sort(choices, function(a, b) return a.search_key < b.search_key end)
    return choices
end

-- Returns the active map viewscreen (or nil), its kind, and whether a marker can
-- be drawn on it now. getDFViewscreen(true) skips this lua screen and returns the
-- underlying DF map screen. The in-fort world map and embark map keep the view
-- center on the viewscreen (region_cent); during worldgen it lives on
-- worldgen_status.cursor instead, and the map only renders once generation has
-- advanced past setup. The embark map's zoomed view uses a transform we don't
-- handle, so the marker is suppressed there.
local function get_map()
    local scr = dfhack.gui.getDFViewscreen(true)
    if df.viewscreen_worldst:is_instance(scr) then
        return scr, 'world', true
    end
    if df.viewscreen_choose_start_sitest:is_instance(scr) then
        return scr, 'embark', not scr.zoomed_in
    end
    if df.viewscreen_new_regionst:is_instance(scr) then
        local shown = df.global.world.worldgen_status.state >
            df.world_generatorst.T_state.Initializing
        return scr, 'worldgen', shown
    end
end

local function get_center(scr, kind)
    if kind == 'worldgen' then
        local ws = df.global.world.worldgen_status
        return ws.cursor_x, ws.cursor_y
    end
    return scr.region_cent_x, scr.region_cent_y
end

local function set_center(scr, kind, x, y)
    if kind == 'worldgen' then
        local ws = df.global.world.worldgen_status
        ws.cursor_x, ws.cursor_y = x, y
    else
        scr.region_cent_x, scr.region_cent_y = x, y
    end
end

-- --------------- --
-- WorldSearchWindow --
-- --------------- --

WorldSearchWindow = defclass(WorldSearchWindow, widgets.Window)
WorldSearchWindow.ATTRS{
    frame_title='Find site',
    -- anchored top-left so the located site (centered on the map) stays visible;
    -- Window is draggable by default and resizable via the corner handle
    frame={l=2, t=4, w=40, h=30},
    frame_background=BG_PEN,
    resizable=true,
    resize_min={w=24, h=12},
}

function WorldSearchWindow:init()
    self.all_choices = build_choices()

    -- race filter options: 'All' plus each distinct owner race present
    local race_seen, race_ids = {}, {}
    for _, c in ipairs(self.all_choices) do
        if c.race_id and not race_seen[c.race_id] then
            race_seen[c.race_id] = true
            table.insert(race_ids, c.race_id)
        end
    end
    table.sort(race_ids, function(a, b) return race_adj(a) < race_adj(b) end)
    local race_opts = {{label='All', value='all'}}
    for _, rid in ipairs(race_ids) do
        table.insert(race_opts, {label=race_adj(rid), value=rid})
    end

    -- restore the remembered race selection only if that race still exists
    local race_init = 'all'
    for _, o in ipairs(race_opts) do
        if o.value == session.race then race_init = session.race break end
    end

    self:addviews{
        widgets.CycleHotkeyLabel{
            view_id='race_filter',
            frame={t=0, l=0},
            key='CUSTOM_CTRL_R',
            label='Race:',
            label_width=9,
            options=race_opts,
            initial_option=race_init,
            on_change=function() self:apply_filters() end,
        },
        widgets.CycleHotkeyLabel{
            view_id='sav_filter',
            frame={t=1, l=0},
            key='CUSTOM_CTRL_G',
            label='Savagery:',
            label_width=9,
            initial_option=session.sav,
            options={
                {label='All', value='all'},
                {label='Calm', value='Calm', pen=COLOR_GREEN},
                {label='Neutral', value='Neutral', pen=COLOR_GRAY},
                {label='Savage', value='Savage', pen=COLOR_LIGHTRED},
            },
            on_change=function() self:apply_filters() end,
        },
        widgets.FilteredList{
            view_id='list',
            -- row 2 is left blank to separate the filters from the name search
            frame={t=3, l=0, r=0, b=2},
            on_submit=function(_, choice)
                self.parent_view:mark_site(choice and choice.site)
            end,
            edit_on_change=function()
                -- changing the search clears the current mark
                self.parent_view.marked = nil
            end,
        },
        widgets.Label{
            frame={b=0, l=0},
            text={
                {text='Enter/click', pen=COLOR_LIGHTGREEN}, ': locate',
                NEWLINE,
                {text='Esc/right-click', pen=COLOR_LIGHTGREEN}, ': close',
            },
        },
    }
    self.subviews.list.edit:setText(session.search)
    self:apply_filters()
end

-- Narrow the list to choices matching the race and savagery cycles, then
-- reapply the current name-search text (setChoices clears it).
function WorldSearchWindow:apply_filters()
    local race = self.subviews.race_filter:getOptionValue()
    local sav = self.subviews.sav_filter:getOptionValue()
    local subset = {}
    for _, c in ipairs(self.all_choices) do
        if (race == 'all' or c.race_id == race)
                and (sav == 'all' or (c.sav and savagery_label(c.sav) == sav)) then
            table.insert(subset, c)
        end
    end
    local list = self.subviews.list
    local text = list.edit.text
    list:setChoices(subset)
    list:setFilter(text)
end

-- --------------- --
-- WorldSearchScreen --
-- --------------- --

WorldSearchScreen = defclass(WorldSearchScreen, gui.ZScreen)
WorldSearchScreen.ATTRS{
    focus_path='worldsearch',
    -- keep focus when clicking the map; right-click / Esc closes
    defocusable=false,
}

function WorldSearchScreen:init()
    self.marked = nil
    local win = WorldSearchWindow{view_id='window'}
    -- restore remembered position/size (set before layout)
    if session.frame then win.frame = copyall(session.frame) end
    self:addviews{win}
end

-- remember the dialog state for the rest of the session
function WorldSearchScreen:onDismiss()
    session.race = self.subviews.race_filter:getOptionValue()
    session.sav = self.subviews.sav_filter:getOptionValue()
    session.search = self.subviews.list.edit.text
    session.frame = copyall(self.subviews.window.frame)
end

function WorldSearchScreen:mark_site(site)
    self.marked = site
    if not site then return end
    local scr, kind = get_map()
    if scr then
        set_center(scr, kind, site.pos.x, site.pos.y)
    end
end

-- the site under the mouse in the list, or nil
function WorldSearchScreen:get_hover_site()
    local flist = self.subviews.list
    if not flist or not flist.list then return end
    local idx = flist.list:getIdxUnderMouse()
    if not idx then return end
    local choice = flist:getVisibleChoices()[idx]
    return choice and choice.site
end

-- detail lines for the hover tooltip; cached per site since savagery requires
-- scanning every world tile the site touches
function WorldSearchScreen:get_detail_lines(site)
    if self._detail_site_id == site.id then return self._detail_lines end
    local lines = {}
    local total, by_race, other = get_population(site)
    table.insert(lines, {text=('Population: %d'):format(total), pen=COLOR_WHITE})
    local races = {}
    for race, count in pairs(by_race) do
        table.insert(races, {race=race, count=count})
    end
    table.sort(races, function(a, b) return a.count > b.count end)
    if #races == 0 and other == 0 then
        table.insert(lines, {text='  (no known residents)', pen=COLOR_GRAY})
    end
    for _, r in ipairs(races) do
        table.insert(lines,
            {text=('  %d %s'):format(r.count, race_name(r.race)), pen=COLOR_GRAY})
    end
    if other > 0 then
        table.insert(lines, {text=('  %d unknown'):format(other), pen=COLOR_GRAY})
    end
    local sav = get_max_savagery(site)
    if sav then
        table.insert(lines, {text=('Max savagery: %d (%s)')
            :format(sav, savagery_label(sav)), pen=COLOR_WHITE})
    end
    self._detail_site_id = site.id
    self._detail_lines = lines
    return lines
end

-- draw the hover tooltip next to the window (to the right, or left if it would
-- run off the screen edge)
function WorldSearchScreen:render_detail()
    local site = self:get_hover_site()
    if not site then return end
    local win = self.subviews.window
    local pr, fr = win.frame_parent_rect, win.frame_rect
    if not pr or not fr then return end
    local lines = self:get_detail_lines(site)
    local title = 'Site detail'
    local maxlen = #title + 2
    for _, l in ipairs(lines) do maxlen = math.max(maxlen, #l.text) end
    local boxw = maxlen + 4   -- left/right border + one space of padding each
    local boxh = #lines + 2   -- top/bottom border
    local g = df.global.gps
    local win_x1, win_x2 = fr.x1 + pr.x1, fr.x2 + pr.x1
    local x1 = win_x2 + 2
    if x1 + boxw - 1 >= g.dimx then
        x1 = win_x1 - boxw - 1  -- not enough room on the right; flip to the left
    end
    x1 = math.max(0, x1)
    local y1 = fr.y1 + pr.y1
    if y1 + boxh - 1 >= g.dimy then y1 = math.max(0, g.dimy - boxh) end
    local x2, y2 = x1 + boxw - 1, y1 + boxh - 1
    local dc = gui.Painter.new()
    dc:fill(x1, y1, x2, y2, BG_PEN)
    gui.paint_frame(dc, {x1=x1, y1=y1, x2=x2, y2=y2}, gui.FRAME_INTERIOR, title)
    for i, l in ipairs(lines) do
        dc:seek(x1 + 2, y1 + i):string(l.text, l.pen)
    end
end

function WorldSearchScreen:render_marker()
    local site = self.marked
    if not site then return end
    local scr, kind, drawable = get_map()
    if not scr or not drawable then return end
    -- blink
    if (dfhack.getTickCount() // BLINK_MS) % 2 == 1 then return end
    local cx, cy = get_center(scr, kind)
    local px, py = world_to_screen(site.pos, cx, cy)
    dfhack.screen.paintTile(
        {ch=string.byte('X'), fg=COLOR_LIGHTRED, bg=COLOR_BLACK, bold=true},
        px, py)
end

function WorldSearchScreen:onRenderFrame(dc, rect)
    WorldSearchScreen.super.onRenderFrame(self, dc, rect)
    self:render_detail()
    self:render_marker()
end

-- ----------------- --
-- WorldSearchOverlay --
-- ----------------- --

WorldSearchOverlay = defclass(WorldSearchOverlay, overlay.OverlayWidget)
WorldSearchOverlay.ATTRS{
    desc='Searchable list of world sites; locate one with a blinking marker.',
    default_enabled=true,
    default_pos={x=1, y=5},
    viewscreens={'world/NORMAL', 'choose_start_site', 'new_region'},
    frame={w=21, h=3},
}

function WorldSearchOverlay:init()
    self:addviews{
        widgets.Panel{
            frame={t=0, l=0, w=21, h=3},
            frame_style=gui.FRAME_PANEL,
            frame_background=BG_PEN,
            -- on the worldgen screen, only show once the map is actually
            -- displayed (not during parameter setup), to avoid covering its UI
            visible=function()
                local scr, kind, drawable = get_map()
                if not scr then return false end
                return kind ~= 'worldgen' or drawable
            end,
            subviews={
                widgets.HotkeyLabel{
                    frame={t=0, l=0},
                    key='CUSTOM_CTRL_F',
                    label='Find site',
                    on_activate=function() WorldSearchScreen{}:show() end,
                },
            },
        },
    }
end

OVERLAY_WIDGETS = {panel=WorldSearchOverlay}
