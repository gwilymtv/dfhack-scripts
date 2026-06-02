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
abundant usable material in the fort, across metal, stone, wood, leather,
cloth, and bone. Armor/clothing/shields read their per-subtype material
permissions; other items use a curated class list.
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
        -- exclude designations and gathering jobs (Hunt/Fish/CollectClay/etc.):
        -- those "produce" an item but are not manufacturing a mandatable good.
        if a and not a.is_designation and a.item ~= df.item_type.NONE
            and a.type ~= df.job_type_class.Gathering
        then
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
-- material selection for "any material" mandates (v2: metal, stone, wood,
-- leather, cloth, bone)
-- ------------------------------------------------------------------
-- each class says where to count its input stock and how to encode the order:
--   kind='inorganic' -> encode mat_type=0, mat_index=<best material> (or -1)
--   kind='category'  -> encode material_category[cat]=true, mat=-1:-1
local CLASSES = {
    metal   = {other = 'BAR',         kind = 'inorganic'},
    stone   = {other = 'BOULDER',     kind = 'inorganic'},
    wood    = {other = 'WOOD',        kind = 'category', cat = 'wood'},
    leather = {other = 'SKIN_TANNED', kind = 'category', cat = 'leather'},
    cloth   = {other = 'CLOTH',       kind = 'category', cat = 'cloth'},
    bone    = {other = 'CORPSEPIECE', kind = 'category', cat = 'bone', bone = true},
}

-- armor/clothing/shields carry an armor_properties.props.flags flagarray that
-- precisely says which material classes each subtype permits (so a breastplate
-- stays metal-only while a robe stays soft). We read it instead of guessing.
-- itemdef_shieldst has no props compound, so shields are handled via the
-- curated list below, not here.
local ARMOR_LIKE = {
    ARMOR = true, HELM = true, GLOVES = true, SHOES = true, PANTS = true,
}
local function flagset_to_classes(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    return out
end

local function armor_classes(def)
    local set = {}
    local f = def.props.flags
    if f.METAL or f.HARD then set.metal = true end
    if f.HARD then set.wood, set.bone = true, true end
    if f.LEATHER then set.leather = true end
    if f.SOFT then set.cloth = true end
    return flagset_to_classes(set)
end

-- tools carry per-subtype material permissions in their tool_flags, so (like
-- armor) we read them rather than guess. Glass/ceramic/shell are not v2 classes.
local function tool_classes(def)
    local set = {}
    local f = def.flags
    if f.METAL_MAT or f.METAL_WEAPON_MAT or f.HARD_MAT then set.metal = true end
    if f.STONE_MAT or f.HARD_MAT then set.stone = true end
    if f.WOOD_MAT or f.HARD_MAT then set.wood = true end
    if f.BONE_MAT or f.HARD_MAT then set.bone = true end
    if f.LEATHER_MAT then set.leather = true end
    if f.SOFT_MAT or f.SILK_MAT or f.THREAD_PLANT_MAT then set.cloth = true end
    return flagset_to_classes(set)
end

-- items whose only valid materials are classes v2 does not handle (glass, cut
-- gems, or items assembled from components). Listed but not auto-created.
local UNSUPPORTED = {
    WINDOW = 'glass only',
    GEM = 'cut from a rough gem',
    TRACTION_BENCH = 'assembled from components',
}

-- non-armor items lack props, so their valid classes are curated (grounded in
-- observed manager orders + DF item/material rules). Default covers furniture.
local ITEM_CLASSES = {
    WEAPON = {'metal'},
    AMMO = {'metal', 'bone', 'wood'},
    SHIELD = {'metal', 'wood'},
    ANVIL = {'metal'},
    FLASK = {'leather'},
    BACKPACK = {'leather', 'cloth'},
    QUIVER = {'leather', 'cloth'},
    BAG = {'leather', 'cloth'},
    CHAIN = {'metal', 'cloth'},
    TOTEM = {'bone'},
    FIGURINE = {'metal', 'stone', 'wood', 'bone'},
    AMULET = {'metal', 'stone', 'wood', 'bone'},
    BRACELET = {'metal', 'stone', 'wood', 'bone'},
    EARRING = {'metal', 'stone', 'wood', 'bone'},
    RING = {'metal', 'stone', 'wood', 'bone'},
    CROWN = {'metal', 'stone', 'wood', 'bone'},
    SCEPTER = {'metal', 'stone', 'wood', 'bone'},
    COIN = {'metal'},
    -- material-restricted furniture/parts (default below is stone/metal/wood)
    BED = {'wood'},
    QUERN = {'stone'},
    MILLSTONE = {'stone'},
    SLAB = {'metal', 'stone'},
    TRAPPARTS = {'metal', 'stone'},
    TRAPCOMP = {'metal'},
    CAGE = {'metal', 'wood'},
    BARREL = {'metal', 'wood'},
    BIN = {'metal', 'wood'},
    BUCKET = {'metal', 'wood'},
    ANIMALTRAP = {'metal', 'wood'},
    PIPE_SECTION = {'metal', 'wood'},
    CRUTCH = {'metal', 'wood'},
    SPLINT = {'metal', 'wood'},
    -- siege parts and ballista arrows are wood; arrowheads are metal
    CATAPULTPARTS = {'wood'},
    BALLISTAPARTS = {'wood'},
    BOLT_THROWER_PARTS = {'wood'},
    SIEGEAMMO = {'wood'},
    BALLISTAARROWHEAD = {'metal'},
}
local DEFAULT_CLASSES = {'metal', 'stone', 'wood'}

local function valid_classes(item_type, subtype)
    local name = df.item_type[item_type]
    if subtype >= 0 then
        if ARMOR_LIKE[name] then
            local def = dfhack.items.getSubtypeDef(item_type, subtype)
            if def and def.props then
                local c = armor_classes(def)
                if #c > 0 then return c end
            end
        elseif name == 'TOOL' then
            local def = dfhack.items.getSubtypeDef(item_type, subtype)
            if def and def.flags then
                local c = tool_classes(def)
                if #c > 0 then return c end
            end
        end
    end
    return ITEM_CLASSES[name] or DEFAULT_CLASSES
end

local function is_bone_item(item)
    return item.material_amount[df.corpse_material_type.Bone] > 0
end

-- gather every usable material candidate for an item across its valid classes,
-- as a list sorted by descending stock count. Inorganic classes contribute one
-- candidate per concrete material (iron, copper, ...); organic classes
-- contribute a single "any <category>" candidate (the order doesn't pin a
-- species). Each candidate carries the fields create_order needs plus a desc.
local function gather_candidates(item_type, subtype, accessible)
    accessible = accessible or get_accessible_groups()
    local cands = {}
    for _, class in ipairs(valid_classes(item_type, subtype)) do
        local cdef = CLASSES[class]
        local vec = world.items.other[df.items_other_id[cdef.other]]
        if cdef.kind == 'inorganic' then
            -- gate on the item's capability flag so e.g. gold is kept out of weapons
            local req = required_mat_flag(item_type)
            local counts = {}
            for _, item in ipairs(vec) do
                if item.mat_type == 0 and item_is_usable(item, accessible) then
                    local mi = dfhack.matinfo.decode(item)
                    if mi and mi.material and mi.material.flags[req] then
                        counts[item.mat_index] = (counts[item.mat_index] or 0) + item.stack_size
                    end
                end
            end
            for idx, n in pairs(counts) do
                local mi = dfhack.matinfo.decode(0, idx)
                cands[#cands + 1] = {
                    kind = 'inorganic', class = class, mat_index = idx, count = n,
                    desc = mi and mi:toString() or ('inorganic#' .. tostring(idx)),
                }
            end
        else
            local n = 0
            for _, item in ipairs(vec) do
                if (not cdef.bone or is_bone_item(item)) and item_is_usable(item, accessible) then
                    n = n + item.stack_size
                end
            end
            if n > 0 then
                cands[#cands + 1] = {kind = 'category', class = class, cat = cdef.cat, count = n, desc = class}
            end
        end
    end
    table.sort(cands, function(a, b) return a.count > b.count end)
    return cands
end

-- returns (chosen, candidates): the most abundant candidate plus the full list.
-- When nothing is in stock, returns a valid "any" choice and an empty list.
local function choose_material(item_type, subtype, accessible)
    local cands = gather_candidates(item_type, subtype, accessible)
    if cands[1] then return cands[1], cands end
    local classes = valid_classes(item_type, subtype)
    local cdef = CLASSES[classes[1]]
    if cdef.kind == 'inorganic' then
        return {kind = 'inorganic', class = classes[1], mat_index = -1, count = 0,
                desc = 'any ' .. classes[1]}, cands
    end
    return {kind = 'category', class = classes[1], cat = cdef.cat, count = 0,
            desc = classes[1]}, cands
end

-- print the ranked candidate list under a result line (top = chosen)
local MAX_CANDIDATES_SHOWN = 6
local function print_candidates(cands)
    for i = 1, math.min(#cands, MAX_CANDIDATES_SHOWN) do
        local c = cands[i]
        print(('        %-18s %5d%s'):format(c.desc, c.count, i == 1 and '   <- chosen' or ''))
    end
    if #cands > MAX_CANDIDATES_SHOWN then
        print(('        ... (+%d more)'):format(#cands - MAX_CANDIDATES_SHOWN))
    end
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
        amount = m.amount_remaining,
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
    elseif choice.kind == 'inorganic' then
        order.mat_type = 0
        order.mat_index = choice.mat_index -- -1 = any inorganic
    else -- 'category'
        order.mat_type = -1
        order.mat_index = -1
        order.material_category[choice.cat] = true
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

-- Shared by `list` (create=false, dry run) and `now` (create=true). Both print
-- the same per-mandate breakdown; only order creation and the footer differ.
local function process_mandates(create)
    local mandates = get_make_mandates()
    if #mandates == 0 then
        print('No active production mandates.')
        return
    end
    local accessible = get_accessible_groups()
    local pending, queued, satisfied, unsupported = 0, 0, 0, 0
    print(('%d active production mandate%s:'):format(#mandates, #mandates == 1 and '' or 's'))
    for _, m in ipairs(mandates) do
        print('  ' .. describe_mandate(m))
        local t, reason = resolve_target(m)
        local unsup = t and t.any_material and UNSUPPORTED[df.item_type[t.item_type]]
        if not t then
            print('      -> SKIP: ' .. reason)
        elseif t.amount <= 0 then
            print('      -> [mandate already satisfied]')
            satisfied = satisfied + 1
        elseif unsup then
            print('      -> SKIP: ' .. unsup .. ' (material class not yet supported)')
            unsupported = unsupported + 1
        elseif find_matching_order(t) then
            print(('      -> %s x%d  [matching order already queued]'):format(t.job_name, t.amount))
            queued = queued + 1
        else
            local choice, cands
            if t.any_material then
                choice, cands = choose_material(t.item_type, t.subtype, accessible)
            end
            local matstr = choice and choice.desc or material_desc(t.mat_type, t.mat_index)
            print(('      -> %s x%d (%s)'):format(t.job_name, t.amount, matstr))
            if cands then print_candidates(cands) end
            if create then create_order(t, choice) end
            pending = pending + 1
        end
    end
    print()
    local verb = create and 'created' or 'would be created'
    print(('automandate: %d order%s %s, %d already queued, %d satisfied, %d unsupported.'):format(
        pending, pending == 1 and '' or 's', verb, queued, satisfied, unsupported))
    if not create then
        print('Run `automandate now` to create the orders.')
    end
end

local function cmd_list() process_mandates(false) end
local function cmd_now() process_mandates(true) end

-- intermediate/consumable item types that are produced by jobs but never
-- mandated; excluded from the simulation domain.
local SIM_SKIP = {
    BAR = true, SMALLGEM = true, ROUGH = true, POWDER_MISC = true, FOOD = true,
    CLOTH = true, THREAD = true, CHEESE = true, FISH = true, LIQUID_MISC = true,
}

-- Simulate an any-material mandate for every mandatable item+subtype and show
-- the order that would be created. Lets you exercise the resolver and material
-- selection without having to wait for nobles to issue real mandates.
local function cmd_simulate()
    local accessible = get_accessible_groups()
    local map = get_item_job_map()
    local rows, seen = {}, {}
    local function add(it, sub, label)
        -- many item subtypes are defined once per civ with identical names;
        -- collapse them so the preview shows each distinct item once
        if seen[label] then return end
        seen[label] = true
        table.insert(rows, {it = it, sub = sub, label = label})
    end
    for it in pairs(map) do
        local name = df.item_type[it]
        if not SIM_SKIP[name] then
            local dt = df['itemdef_' .. name:lower() .. 'st']
            if dt then
                for _, d in ipairs(dt.get_vector()) do
                    -- skip incomplete tool parts (e.g. instrument pieces)
                    if not (name == 'TOOL' and d.flags.INCOMPLETE_ITEM) then
                        add(it, d.subtype, name .. ' / ' .. d.name)
                    end
                end
            else
                add(it, -1, name)
            end
        end
    end
    table.sort(rows, function(a, b) return a.label < b.label end)
    print(('Simulating %d any-material make-mandates:'):format(#rows))
    for _, r in ipairs(rows) do
        local unsup = UNSUPPORTED[df.item_type[r.it]]
        if unsup then
            print(('  %-30s -> %s [UNSUPPORTED: %s]'):format(
                r.label, df.job_type[map[r.it]], unsup))
        else
            local choice, cands = choose_material(r.it, r.sub, accessible)
            print(('  %-30s -> %s (%s)'):format(r.label, df.job_type[map[r.it]], choice.desc))
            print_candidates(cands)
        end
    end
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
    ['simulate'] = cmd_simulate,
    ['-?'] = function() print(dfhack.script_help()) end,
    ['help'] = function() print(dfhack.script_help()) end,
}

local action = actions[(...) or '']
if not action then
    qerror('Unknown command: ' .. tostring((...)) .. ' (try: list, now, simulate)')
end
action(...)
