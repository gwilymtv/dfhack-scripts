-- Overlay: shift+click a crop in a farm plot to set it for every plantable season
--@ module = true

if not dfhack_flags.module then
    qerror('farmplot cannot be called directly')
end

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local getBuild = dfhack.gui.getSelectedBuilding

local DEBUG = false  -- set true to log crop changes to the console

-- plant_raw season flags, indexed by season 0-3 (Spring/Summer/Autumn/Winter)
local SEASON_FLAGS = {'SPRING', 'SUMMER', 'AUTUMN', 'WINTER'}

local function plant_name(id)
    if id == nil or id < 0 then return 'none' end
    local p = df.plant_raw.find(id)
    return p and p.id or ('?'..id)
end

local function snap_names(snap)
    return ('[%s|%s|%s|%s]'):format(
        plant_name(snap[1]), plant_name(snap[2]),
        plant_name(snap[3]), plant_name(snap[4]))
end

-- number of frames to keep watching for the crop change to land after a
-- shift+click (the change may register a frame or two after the click)
local ARM_FRAMES = 6

local function is_farm(bld)
    return bld and bld:getType() == df.building_type.FarmPlot
end

local function snapshot(farm)
    return {farm.plant_id[0], farm.plant_id[1], farm.plant_id[2], farm.plant_id[3]}
end

AllSeasonsOverlay = defclass(AllSeasonsOverlay, overlay.OverlayWidget)
AllSeasonsOverlay.ATTRS{
    desc='Shift+click a farm plot crop to set it for all plantable seasons.',
    default_pos={x=-40, y=10},
    default_enabled=true,
    viewscreens='dwarfmode/ViewSheets/BUILDING/FarmPlot',
    frame={w=33, h=1},
}

function AllSeasonsOverlay:init()
    self.prev = nil      -- last seen plant_id snapshot for prev_id
    self.prev_id = nil   -- building id the snapshot belongs to
    self.armed = 0       -- frames remaining to honor a shift+click
    self:addviews{
        widgets.Label{
            frame={t=0, l=0},
            text={{text='shift+click crop: set all seasons', pen=COLOR_GREY}},
        },
    }
end

-- copy plant_id to every season whose plant_raw allows planting then
function AllSeasonsOverlay:propagate(farm, plant_id)
    local plant = df.plant_raw.find(plant_id)
    if not plant then return end
    for s = 0, 3 do
        if plant.flags[SEASON_FLAGS[s+1]] then
            farm.plant_id[s] = plant_id
        end
    end
end

function AllSeasonsOverlay:onInput(keys)
    if keys._MOUSE_L and dfhack.internal.getModifiers().shift then
        -- arm; the actual crop change is detected in render() once DF applies it
        self.armed = ARM_FRAMES
        if DEBUG then print('[farmplot] shift+click armed') end
    end
    -- never consume: let DF process the click and set the crop normally
    return AllSeasonsOverlay.super.onInput(self, keys)
end

function AllSeasonsOverlay:render(dc)
    local farm = getBuild()
    if is_farm(farm) then
        if self.prev_id ~= farm.id then
            -- different plot selected: reset baseline, never act on the switch
            self.prev_id = farm.id
            self.prev = snapshot(farm)
            self.armed = 0
        else
            local cur = snapshot(farm)
            local changed
            for s = 0, 3 do
                if cur[s+1] ~= self.prev[s+1] then
                    changed = s
                    break
                end
            end
            if DEBUG and (self.armed > 0 or changed) then
                print(('[farmplot] f=%d armed=%d prev=%s cur=%s changed=%s'):format(
                    df.global.world.frame_counter, self.armed,
                    snap_names(self.prev), snap_names(cur), tostring(changed)))
            end
            -- only propagate a real crop (>= 0) that changed within the armed window
            if changed and self.armed > 0 and cur[changed+1] >= 0 then
                if DEBUG then
                    print(('[farmplot] PROPAGATE season %d -> %s'):format(
                        changed, plant_name(cur[changed+1])))
                end
                self:propagate(farm, cur[changed+1])
                self.armed = 0
            end
            self.prev = snapshot(farm)
            if self.armed > 0 then self.armed = self.armed - 1 end
        end
    end
    AllSeasonsOverlay.super.render(self, dc)
end

OVERLAY_WIDGETS = {
    allseasons = AllSeasonsOverlay,
}
