-- Claim-driven, roam-friendly nestbox manager.
--@enable = true
--@module = true

local argparse = require('argparse')
local utils = require('utils')
local repeatutil = require('repeat-util')
local quickfort = reqscript('quickfort')

local GLOBAL_KEY = 'nestegg'
-- how often the enabled background cycle runs
local CYCLE_TICKS = 1200

-- configuration / persistent state

local function get_default_state()
    return {enabled=false}
end

state = state or get_default_state()

function isEnabled()
    return state.enabled
end

local function persist_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {enabled=state.enabled})
end

local function load_state()
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY, get_default_state())
    state.enabled = data.enabled
end

-- helpers

local function nestbox_pos(nb)
    return xyz2pos(nb.x1, nb.y1, nb.z)
end

local function is_active_pen(zone)
    return df.building_civzonest:is_instance(zone)
        and dfhack.buildings.isPenPasture(zone)
        and dfhack.buildings.isActive(zone)
end

local function is_one_by_one(zone)
    return zone.x1 == zone.x2 and zone.y1 == zone.y2
end

-- returns the 1x1 pen managed by nestegg over this nestbox (or nil), plus a
-- boolean for whether the nestbox is covered by any active pen at all (used to
-- decide whether a new 1x1 pasture is needed)
local function find_pens_over(nb)
    local civzones = dfhack.buildings.findCivzonesAt(nestbox_pos(nb))
    local managed, covered = nil, false
    if civzones then
        for _, zone in ipairs(civzones) do
            if is_active_pen(zone) then
                covered = true
                if not managed and is_one_by_one(zone) then
                    managed = zone
                end
            end
        end
    end
    return managed, covered
end

local function get_assigned_civzone(unit)
    local ref = dfhack.units.getGeneralRef(unit, df.general_ref_type.BUILDING_CIVZONE_ASSIGNED)
    return ref and ref:getBuilding() or nil
end

-- BUILDING_CAGED is normally only set for dwarves; caged animals get
-- CONTAINED_IN_ITEM, so we confirm the containing item is a built cage
local function is_in_built_cage(unit)
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld:getType() == df.building_type.Cage then
            for _, uid in ipairs(bld.assigned_units) do
                if uid == unit.id then return true end
            end
        end
    end
    return false
end

-- chained/restrained or (built) caged: cannot reach or be reassigned to a pen
local function is_confined(unit)
    if dfhack.units.getGeneralRef(unit, df.general_ref_type.BUILDING_CHAIN)
            or dfhack.units.getGeneralRef(unit, df.general_ref_type.BUILDING_CAGED) then
        return true
    end
    return dfhack.units.getGeneralRef(unit, df.general_ref_type.CONTAINED_IN_ITEM)
        and is_in_built_cage(unit)
end

local function unassign_unit_from_pen(unit, pen)
    for idx, uid in ipairs(pen.assigned_units) do
        if uid == unit.id then
            pen.assigned_units:erase(idx)
            break
        end
    end
    for idx = #unit.general_refs - 1, 0, -1 do
        local ref = unit.general_refs[idx]
        if df.general_ref_building_civzone_assignedst:is_instance(ref)
                and ref.building_id == pen.id then
            unit.general_refs:erase(idx)
            ref:delete()
        end
    end
end

-- remove every assignment from a pen so its animals roam free
local function empty_pen(pen)
    -- snapshot the ids first: unassign mutates pen.assigned_units
    local ids = {}
    for _, uid in ipairs(pen.assigned_units) do table.insert(ids, uid) end
    for _, uid in ipairs(ids) do
        local unit = df.unit.find(uid)
        if unit then
            unassign_unit_from_pen(unit, pen)
        else
            for idx, id2 in ipairs(pen.assigned_units) do
                if id2 == uid then
                    pen.assigned_units:erase(idx)
                    break
                end
            end
        end
    end
end

local function assign_unit_to_pen(unit, pen)
    local ref = df.new(df.general_ref_building_civzone_assignedst)
    ref.building_id = pen.id
    unit.general_refs:insert('#', ref)
    utils.insert_sorted(pen.assigned_units, unit.id)
end

-- ensure the pen holds only the claimant, removing any other occupants
local function keep_only(pen, claimant)
    local present = false
    local ids = {}
    for _, uid in ipairs(pen.assigned_units) do table.insert(ids, uid) end
    for _, uid in ipairs(ids) do
        if uid == claimant.id then
            present = true
        else
            local other = df.unit.find(uid)
            if other then
                unassign_unit_from_pen(other, pen)
            else
                for idx, id2 in ipairs(pen.assigned_units) do
                    if id2 == uid then
                        pen.assigned_units:erase(idx)
                        break
                    end
                end
            end
        end
    end
    if not present then
        assign_unit_to_pen(claimant, pen)
        return true
    end
    return false
end

-- reconcile a nestbox's 1x1 pasture with the nestbox's claim state
local function reconcile(nb, pen, stats)
    local claimant
    if nb.claimed_by >= 0 then
        claimant = df.unit.find(nb.claimed_by)
        if claimant and not dfhack.units.isActive(claimant) then
            claimant = nil
        end
    end

    if not claimant then
        -- unclaimed, or claimed by a dead/missing unit: free the pen to roam
        if nb.claimed_by >= 0 then
            nb.claimed_by = -1
            stats.cleared = stats.cleared + 1
        end
        if #pen.assigned_units > 0 then
            empty_pen(pen)
            stats.freed = stats.freed + 1
        end
        return
    end

    -- decide whether we can keep the claimant on its nest
    local reason
    if dfhack.units.isGrazer(claimant) then
        reason = 'grazer'  -- would starve confined to a 1x1 pen
    elseif is_confined(claimant) then
        reason = 'confined'  -- caged/chained/restrained
    else
        local cur = get_assigned_civzone(claimant)
        if cur and cur.id ~= pen.id then
            reason = 'other-pasture'  -- yield to the player's own zone
        end
    end

    if reason then
        -- couldn't assign the claimant: clear the claim and free the pen
        nb.claimed_by = -1
        stats.cleared = stats.cleared + 1
        if #pen.assigned_units > 0 then
            empty_pen(pen)
        end
        return
    end

    if keep_only(pen, claimant) then
        stats.assigned = stats.assigned + 1
    end
end

-- main action

local function action(quiet)
    local stats = {created=0, assigned=0, freed=0, cleared=0}

    -- pass A: create a 1x1 pasture over every nestbox not already in a pen
    for _, nb in ipairs(df.global.world.buildings.other.NEST_BOX) do
        local _, covered = find_pens_over(nb)
        if not covered then
            quickfort.apply_blueprint{mode='zone', pos=nestbox_pos(nb), data='n'}
            stats.created = stats.created + 1
        end
    end

    -- pass B: reconcile each managed 1x1 pasture with its nestbox claim
    for _, nb in ipairs(df.global.world.buildings.other.NEST_BOX) do
        local managed = find_pens_over(nb)
        if managed then
            reconcile(nb, managed, stats)
            dfhack.buildings.notifyCivzoneModified(managed)
        end
    end

    if not quiet then
        print(('nestegg: created %d pasture(s), assigned %d, freed %d, cleared %d claim(s)')
            :format(stats.created, stats.assigned, stats.freed, stats.cleared))
    end
    return stats
end

-- enable management

local function start()
    if state.enabled then
        repeatutil.scheduleUnlessAlreadyScheduled(GLOBAL_KEY, CYCLE_TICKS, 'ticks',
            function() action(true) end)
    end
end

local function stop()
    repeatutil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        state.enabled = false
        return
    end
    if sc ~= SC_MAP_LOADED or df.global.gamemode ~= df.game_mode.DWARF then
        return
    end
    load_state()
    start()
end

if dfhack_flags.module then
    return
end

if dfhack_flags.enable then
    if not dfhack.isMapLoaded() then
        qerror('nestegg requires a loaded fortress map')
    end
    if dfhack_flags.enable_state then
        state.enabled = true
        start()
    else
        state.enabled = false
        stop()
    end
    persist_state()
    return
end

-- command line

load_state()
local positionals = argparse.processArgsGetopt({...}, {})
local cmd = positionals[1]

if not cmd or cmd == 'status' then
    print(('nestegg is %s'):format(state.enabled and 'enabled' or 'not enabled'))
elseif cmd == 'now' then
    if not dfhack.isMapLoaded() then
        qerror('nestegg requires a loaded fortress map')
    end
    action(false)
else
    qerror('unrecognized command: ' .. tostring(cmd))
end
