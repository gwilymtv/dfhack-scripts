-- Search for a site by name on the world map (in-fort or embark) and locate it.
--@ module = true

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

-- size of a world-map tile in pixels (the map renders at a fixed scale,
-- independent of the text grid); validated empirically across grid settings
local MAP_TILE_PX = 16
local BLINK_MS = 400

local BG_PEN = dfhack.pen.parse{ch=' ', fg=COLOR_BLACK, bg=COLOR_BLACK}

local function is_mouse_key(keys)
    return keys._MOUSE_L or keys._MOUSE_R or keys._MOUSE_M
        or keys.CONTEXT_SCROLL_UP or keys.CONTEXT_SCROLL_DOWN
        or keys.CONTEXT_SCROLL_PAGEUP or keys.CONTEXT_SCROLL_PAGEDOWN
end

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
        local type_name = df.world_site_type[site.type] or '?'
        local text = {
            {text=name},
            {gap=1, text='('..type_name..')', pen=COLOR_GRAY},
        }
        if tag then
            table.insert(text, {gap=1, text=tag, pen=tag_pen})
        end
        table.insert(choices, {
            text=text,
            search_key=name:lower(),
            site=site,
        })
    end
    table.sort(choices, function(a, b) return a.search_key < b.search_key end)
    return choices
end

-- Returns the active world/embark map viewscreen (or nil) and whether a marker
-- can be drawn on it now. Both the in-fort world map and the embark map use the
-- same region_cent + transform; the embark map's zoomed view uses a different
-- transform we don't handle, so the marker is suppressed there.
local function get_map_scr()
    local scr = dfhack.gui.getDFViewscreen(true)
    if df.viewscreen_worldst:is_instance(scr) then
        return scr, true
    end
    if df.viewscreen_choose_start_sitest:is_instance(scr) then
        return scr, not scr.zoomed_in
    end
end

-- ----------------- --
-- WorldSearchOverlay --
-- ----------------- --

WorldSearchOverlay = defclass(WorldSearchOverlay, overlay.OverlayWidget)
WorldSearchOverlay.ATTRS{
    desc='Searchable list of world sites; locate one with a blinking marker.',
    default_enabled=true,
    default_pos={x=1, y=5},
    viewscreens={'world/NORMAL', 'choose_start_site'},
    frame={w=34, h=32},
    frame_style=gui.FRAME_PANEL,
    frame_background=BG_PEN,
    frame_title='Find site',
}

function WorldSearchOverlay:init()
    self.marked = nil
    self:addviews{
        widgets.FilteredList{
            view_id='list',
            frame={t=0, l=0, r=0, b=2},
            -- search stays dormant until activated, so the world map's
            -- WASD/cursor keys aren't typed into the box (shared keys)
            edit_key='CUSTOM_CTRL_F',
            on_submit=function(_, choice)
                self:mark_site(choice and choice.site)
            end,
            edit_on_change=function()
                -- changing the search clears the current mark
                self.marked = nil
            end,
        },
        widgets.Label{
            frame={b=0, l=0},
            text={
                {text='Ctrl+F', pen=COLOR_LIGHTGREEN}, ': search', NEWLINE,
                {text='Enter/click', pen=COLOR_LIGHTGREEN}, ': locate',
            },
        },
    }
    self.subviews.list:setChoices(build_choices())
end

function WorldSearchOverlay:onInput(keys)
    if WorldSearchOverlay.super.onInput(self, keys) then
        return true
    end
    -- while the search box has focus, swallow non-mouse keys: the letters
    -- double as world-map pan keys, so letting them through would move the map
    local edit = self.subviews.list.edit
    if edit and edit.focus and not is_mouse_key(keys) then
        return true
    end
    return false
end

function WorldSearchOverlay:mark_site(site)
    self.marked = site
    if not site then return end
    local scr = get_map_scr()
    if scr then
        scr.region_cent_x = site.pos.x
        scr.region_cent_y = site.pos.y
    end
end

function WorldSearchOverlay:onRenderBody(dc)
    local site = self.marked
    if not site then return end
    local scr, drawable = get_map_scr()
    if not scr or not drawable then return end
    -- blink
    if (dfhack.getTickCount() // BLINK_MS) % 2 == 1 then return end
    local px, py = world_to_screen(site.pos, scr.region_cent_x, scr.region_cent_y)
    dfhack.screen.paintTile(
        {ch=string.byte('X'), fg=COLOR_LIGHTRED, bg=COLOR_BLACK, bold=true},
        px, py)
end

OVERLAY_WIDGETS = {panel=WorldSearchOverlay}
