-- Create manager work orders from active noble production mandates.
--@ module = true

--[[
automandate looks at the fort's active "Make X" production mandates (the ones
nobles issue, e.g. "Make maces (0/3)") and turns each into a manager work order
so the mandate actually gets fulfilled.

Mandate data lives in df.global.world.mandates.all. Each Make mandate carries an
item_type + item_subtype + (optional) material and a remaining count. We resolve
the item_type to its production job via df.job_type.attrs[].item.

For mandates that don't specify a material ("any material"), we pick the most
abundant usable material in the fort. v1 considers metal and wood only; other
material classes (leather, cloth, bone, stone, ...) are listed but not yet
auto-created.
]]

local df = df
local world = df.global.world

-- ------------------------------------------------------------------
-- item_type -> production job resolver
--
-- IMPORTANT: key off the `item` attribute alone. Do NOT gate on
-- job_type_class.Manufacture: a few make-jobs (notably MakeShield) omit the
-- `type` attr and default to Misc, so gating on the class silently drops them.
-- ------------------------------------------------------------------
local _item_job_map
local function get_item_job_map()
    if _item_job_map then return _item_job_map end
    local map = {}
    for i = 0, df.job_type._last_item do
        local a = df.job_type.attrs[i]
        if a and not a.is_designation and a.item ~= df.item_type.NONE then
            if map[a.item] == nil then
                map[a.item] = i
            end
        end
    end
    _item_job_map = map
    return map
end

-- which material capability flag a given item type requires (material_flags).
-- wood satisfies ITEMS_HARD but not the weapon/armor/etc. flags, so this table
-- is what naturally steers e.g. maces to metal and shields to metal-or-wood.
local MAT_FLAG_BY_ITEM = {
    WEAPON = df.material_flags.ITEMS_WEAPON,
    AMMO = df.material_flags.ITEMS_AMMO,
    SIEGEAMMO = df.material_flags.ITEMS_AMMO,
    ARMOR = df.material_flags.ITEMS_ARMOR,
    HELM = df.material_flags.ITEMS_ARMOR,
    GLOVES = df.material_flags.ITEMS_ARMOR,
    SHOES = df.material_flags.ITEMS_ARMOR,
    PANTS = df.material_flags.ITEMS_ARMOR,
    ANVIL = df.material_flags.ITEMS_ANVIL,
}
local function required_mat_flag(item_type)
    return MAT_FLAG_BY_ITEM[df.item_type[item_type]] or df.material_flags.ITEMS_HARD
end

-- ------------------------------------------------------------------
-- "usable stock" screen (adapted from buildingplan's itemPassesScreen)
-- ------------------------------------------------------------------
local BAD_FLAGS = {
    'dump', 'forbid', 'garbage_collect', 'hostile', 'on_fire', 'rotten',
    'trader', 'in_building', 'construction', 'in_job', 'owned', 'removed',
    'encased', 'spider_web',
}

-- walkability groups reachable by a citizen; an item is usable only if it sits
-- in one of these (grounded on citizens, not a build site, so no location needed)
local function get_accessible_groups()
    local groups = {}
    for _, unit in ipairs(dfhack.units.getCitizens()) do
        local g = dfhack.maps.getWalkableGroup(unit.pos)
        if g and g ~= 0 then groups[g] = true end
    end
    return groups
end

local function item_is_usable(item, accessible)
    local f = item.flags
    for _, name in ipairs(BAD_FLAGS) do
        if f[name] then return false end
    end
    -- NOTE: unlike buildingplan we keep stockpiled items; a workshop pulls from
    -- stockpiles, so reserved-to-stockpile is not a disqualifier here.
    local g = dfhack.maps.getWalkableGroup(xyz2pos(dfhack.items.getPosition(item)))
    return accessible[g] == true
end

-- ------------------------------------------------------------------
-- material selection for "any material" mandates (v1: metal + wood)
-- ------------------------------------------------------------------
-- returns a choice table describing the encoding to use:
--   {kind='metal', mat_index=N}  -- concrete inorganic, encode mat=0:N
--   {kind='metal_any'}           -- any inorganic, encode mat=0:-1
--   {kind='wood'}                -- any wood, encode material_category.wood
local function choose_material(item_type, accessible)
    accessible = accessible or get_accessible_groups()
    local req = required_mat_flag(item_type)

    -- most abundant capable metal (counted per inorganic, encoded concretely)
    local metal_count = {}
    for _, item in ipairs(world.items.other[df.items_other_id.BAR]) do
        if item.mat_type == 0 and item_is_usable(item, accessible) then
            local mi = dfhack.matinfo.decode(item)
            if mi and mi.material and mi.material.flags[req] then
                metal_count[item.mat_index] =
                    (metal_count[item.mat_index] or 0) + item.stack_size
            end
        end
    end
    local best_metal, best_metal_n = nil, 0
    for idx, n in pairs(metal_count) do
        if n > best_metal_n then best_metal, best_metal_n = idx, n end
    end

    -- total capable wood (encoded as "any wood")
    local wood_n = 0
    for _, item in ipairs(world.items.other[df.items_other_id.WOOD]) do
        if item_is_usable(item, accessible) then
            local mi = dfhack.matinfo.decode(item)
            if mi and mi.material and mi.material.flags[req] then
                wood_n = wood_n + item.stack_size
            end
        end
    end

    if best_metal_n == 0 and wood_n == 0 then
        -- nothing in stock: emit a valid "any" order DF can still fill later
        if req == df.material_flags.ITEMS_HARD then
            return {kind = 'wood'}
        end
        return {kind = 'metal_any'}
    end
    if wood_n > best_metal_n then
        return {kind = 'wood', count = wood_n}
    end
    return {kind = 'metal', mat_index = best_metal, count = best_metal_n}
end

local function choice_desc(c)
    if c.kind == 'wood' then return 'wood' end
    if c.kind == 'metal_any' then return 'any metal' end
    local mi = dfhack.matinfo.decode(0, c.mat_index)
    return mi and mi:toString() or ('inorganic#' .. tostring(c.mat_index))
end

-- ------------------------------------------------------------------
-- display helpers
-- ------------------------------------------------------------------
local function item_desc(item_type, subtype)
    local def = subtype and subtype >= 0 and dfhack.items.getSubtypeDef(item_type, subtype)
    if def then return def.name end
    return tostring(df.item_type[item_type]):lower():gsub('_', ' ')
end

local function material_desc(mat_type, mat_index)
    if mat_type < 0 then return 'any material' end
    local mat = dfhack.matinfo.decode(mat_type, mat_index)
    return mat and mat:toString() or 'any material'
end

local function noble_name(m)
    if not m.unit then return '?' end
    return dfhack.df2console(dfhack.units.getReadableName(m.unit))
end

-- ------------------------------------------------------------------
-- mandate -> order target
-- ------------------------------------------------------------------
local function get_make_mandates()
    local res = {}
    for _, m in ipairs(world.mandates.all) do
        if m.mode == df.mandate_type.Make then
            table.insert(res, m)
        end
    end
    return res
end

local function resolve_target(m)
    local job_id = get_item_job_map()[m.item_type]
    if not job_id then
        return nil, ('no production job for item type %s'):format(df.item_type[m.item_type])
    end
    return {
        job_id = job_id,
        job_name = df.job_type[job_id],
        item_type = m.item_type,
        subtype = (m.item_subtype and m.item_subtype >= 0) and m.item_subtype or -1,
        any_material = not (m.mat_type and m.mat_type >= 0),
        mat_type = m.mat_type,
        mat_index = m.mat_index,
        amount = m.amount_remaining > 0 and m.amount_remaining or m.amount_total,
    }
end

-- An any-material mandate is satisfied by ANY existing order for the item; a
-- material-specific mandate needs an order of that material.
local function find_matching_order(t)
    for _, o in ipairs(world.manager_orders.all) do
        if o.job_type == t.job_id and o.item_subtype == t.subtype then
            if t.any_material then return o end
            if o.mat_type == t.mat_type and o.mat_index == t.mat_index then return o end
        end
    end
end

local function create_order(t, choice)
    local order = df.manager_order:new()
    order.id = world.manager_orders.manager_order_next_id
    world.manager_orders.manager_order_next_id = order.id + 1
    order.job_type = t.job_id
    if t.subtype >= 0 then
        order.item_type = t.item_type
        order.item_subtype = t.subtype
    end
    if not t.any_material then
        order.mat_type = t.mat_type
        order.mat_index = t.mat_index
    elseif choice.kind == 'wood' then
        order.mat_type = -1
        order.mat_index = -1
        order.material_category.wood = true
    elseif choice.kind == 'metal_any' then
        order.mat_type = 0
        order.mat_index = -1
    else -- 'metal'
        order.mat_type = 0
        order.mat_index = choice.mat_index
    end
    order.amount_left = t.amount
    order.amount_total = t.amount
    order.frequency = df.workquota_frequency_type.OneTime
    world.manager_orders.all:insert('#', order)
    return order
end

-- ------------------------------------------------------------------
-- commands
-- ------------------------------------------------------------------
local function describe_mandate(m)
    local mat = material_desc(m.mat_type, m.mat_index)
    return ('%s%s, %d/%d, mandated by %s'):format(
        mat == 'any material' and '' or (mat .. ' '),
        item_desc(m.item_type, m.item_subtype),
        m.amount_remaining, m.amount_total, noble_name(m))
end

local function cmd_list()
    local mandates = get_make_mandates()
    if #mandates == 0 then
        print('No active production mandates.')
        return
    end
    local accessible = get_accessible_groups()
    print(('%d active production mandate%s:'):format(#mandates, #mandates == 1 and '' or 's'))
    for _, m in ipairs(mandates) do
        print('  ' .. describe_mandate(m))
        local t, reason = resolve_target(m)
        if not t then
            print('      -> SKIP: ' .. reason)
        elseif find_matching_order(t) then
            print(('      -> %s x%d  [matching order already queued]'):format(t.job_name, t.amount))
        else
            local matstr
            if t.any_material then
                matstr = choice_desc(choose_material(t.item_type, accessible))
            else
                matstr = material_desc(t.mat_type, t.mat_index)
            end
            print(('      -> %s x%d (%s)'):format(t.job_name, t.amount, matstr))
        end
    end
    print()
    print('Run `automandate now` to create work orders for these mandates.')
end

local function cmd_now()
    local mandates = get_make_mandates()
    local accessible = get_accessible_groups()
    local created, skipped = 0, 0
    for _, m in ipairs(mandates) do
        if m.amount_remaining > 0 then
            local t, reason = resolve_target(m)
            if not t then
                dfhack.printerr('Skipping ' .. item_desc(m.item_type, m.item_subtype) .. ': ' .. reason)
            elseif find_matching_order(t) then
                skipped = skipped + 1
            else
                local choice = t.any_material and choose_material(t.item_type, accessible) or nil
                create_order(t, choice)
                local matstr = t.any_material and choice_desc(choice)
                    or material_desc(t.mat_type, t.mat_index)
                print(('Queued %s x%d (%s)'):format(t.job_name, t.amount, matstr))
                created = created + 1
            end
        end
    end
    print(('automandate: %d order%s created, %d already queued.'):format(
        created, created == 1 and '' or 's', skipped))
end

-- ------------------------------------------------------------------
-- dispatch
-- ------------------------------------------------------------------
if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('automandate requires fortress mode')
end

local actions = {
    [''] = cmd_list,
    ['list'] = cmd_list,
    ['now'] = cmd_now,
    ['-?'] = function() print(dfhack.script_help()) end,
    ['help'] = function() print(dfhack.script_help()) end,
}

local action = actions[(...) or '']
if not action then
    qerror('Unknown command: ' .. tostring((...)) .. ' (try: list, now)')
end
action(...)
