-- Track and view the evolution of the fort over time.
--@ module = true
--@ enable = true

--[[
metrics records a daily (in-game) snapshot of fort-wide scalar figures -- the
kind shown in the game's top bar -- and persists them with the save so you can
review how the fort has changed over time.

v1 captures the low-hanging fruit:
  * population      -- live count of fort citizens
  * happiness       -- citizens bucketed into DF's 7 stress bands
  * wealth          -- created / imported / exported
  * stocks (food)   -- food total, drink, seeds, meat, fish, plant, other

Population and happiness are computed live from the citizen list. Wealth and
stock figures are read straight from df.global.plotinfo.tasks (the same
periodically-recomputed aggregates DF shows in the status/top bar), so they
update on DF's own cadence rather than the instant the snapshot is taken.

Data is kept per-fort in site data and dumped to the console with `metrics dump`.
]]

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'metrics'

-- in-game calendar constants
local TICKS_PER_DAY = 1200
local DAYS_PER_MONTH = 28
local DAYS_PER_YEAR = 336  -- 12 months * 28 days

-- Stress is recorded as a Prometheus-style "classic" cumulative histogram so
-- averages and quantiles can be derived later by linear interpolation (see
-- stress_quantile / stress_mean). Buckets mirror DF's named stress ratings and
-- are defined by an upper bound on the stress value (Prometheus 'le'), ordered
-- ascending (least-stressed first); the stored count for bucket j is the number
-- of citizens with stress < le[j], i.e. cumulative. The top bucket is open
-- (le = +inf), so its count == population.
--
-- DFHack's dfhack.units.getStressCategory returns category 0 (most stressed,
-- "miserable") through NUM_BANDS-1 (least stressed, "ecstatic"). Bucket j (1-based,
-- ascending) therefore corresponds to category NUM_BANDS-j; STRESS_BUCKET_NAMES
-- lists the band names in bucket order. Names match DF's happiness faces; see
-- plugins/lua/spectate.lua.
local STRESS_BUCKET_NAMES = {'ecstatic', 'happy', 'pleased', 'content',
                             'displeased', 'unhappy', 'miserable'}
local NUM_BANDS = #STRESS_BUCKET_NAMES

-- display columns keep the conventional most-stressed-first reading order.
-- Exported (module global) so gui/metrics can label the happiness bands.
DISPLAY_ORDER = {'miserable', 'unhappy', 'displeased', 'content',
                 'pleased', 'happy', 'ecstatic'}

-- Finite bucket upper bounds (Prometheus 'le'), 1-indexed and ascending, length
-- NUM_BANDS-1; the top bucket's bound is +inf and is left implicit. Derived from
-- dfhack.units.getStressCutoffs(), which returns the band boundaries high-to-low
-- (its last entry does not bound a band -- see Units::getStressCategoryRaw -- so
-- it is dropped). Reversing the remaining boundaries gives the ascending le set.
-- Memoized; persisted with the data so the histogram stays interpretable even if
-- DFHack's cutoffs ever change.
local _bucket_le
local function get_bucket_le()
    if _bucket_le then return _bucket_le end
    local raw = dfhack.units.getStressCutoffs()  -- 0-indexed, descending
    local le = {}
    for j = 1, NUM_BANDS - 1 do
        le[j] = raw[NUM_BANDS - 1 - j]
    end
    _bucket_le = le
    return le
end

-- persistent enabled state (per fort)
enabled = enabled or false

function isEnabled()
    return enabled
end

-- ------------------------------------------------------------------
-- persistence
-- ------------------------------------------------------------------
-- All state is stored as a single site-data table under GLOBAL_KEY (so it lives
-- and dies with the fort). dfhack.persistent serializes it to JSON, so the
-- structure must be plain Lua tables/numbers/strings/bools -- no functions,
-- no df objects, no integer keys with gaps.
--
--   {
--     enabled          = <bool>, -- whether daily collection is running
--     stress_bucket_le = { ... },-- ascending finite upper bounds (Prometheus 'le')
--                                --   of the stress histogram buckets, length
--                                --   NUM_BANDS-1 (the top bucket's bound is +inf,
--                                --   left implicit). Stored once so the histogram
--                                --   stays interpretable if DFHack's cutoffs change.
--     series           = {       -- one entry per recorded in-game day, in order
--       <snapshot>,
--       ...
--     },
--   }
--
-- A <snapshot> (built by take_snapshot()) is:
--
--   {
--     -- when (in-game calendar)
--     year      = <int>,        -- df.global.cur_year
--     month     = <int>,        -- 1..12
--     day       = <int>,        -- 1..28
--     day_index = <int>,        -- absolute day since year 0 (year*336 + day_of_year);
--                               --   monotonic key used to order entries and to
--                               --   detect/dedupe the current day
--
--     -- population: live count of fort citizens
--     pop = <int>,
--
--     -- military: fort citizens assigned to a squad
--     military = <int>,
--
--     -- creatures present, matching the Citizens screen's Pets/Livestock and
--     --   Others tabs (fort animals vs everyone else alive: visitors, merchants,
--     --   residents, invaders, wildlife). See collect_creatures.
--     pets = <int>,
--     others = <int>,
--
--     -- workshop/furnace buildings, and how many have an actively-worked job
--     --   (a non-suspended job with a worker assigned). See collect_buildings.
--     workshops = <int>,
--     workshops_active = <int>,
--
--     -- happiness: a CUMULATIVE stress histogram in Prometheus "classic" form.
--     --   1-indexed array of NUM_BANDS counts where stress[j] is the number of
--     --   citizens with stress < stress_bucket_le[j] (bucket STRESS_BUCKET_NAMES[j]
--     --   and every less-stressed band). Non-decreasing; stress[NUM_BANDS] == pop
--     --   (the open +inf top bucket). A single band's count is stress[j]-stress[j-1].
--     --   Cumulative + boundaries let quantiles be recovered by linear
--     --   interpolation -- see stress_quantile.
--     stress = { <int>, <int>, ... },  -- length NUM_BANDS
--
--     -- exact sum of every citizen's raw stress value (soulless units, which have
--     --   no stress, contribute 0). The Prometheus '_sum' companion to the buckets:
--     --   with pop as the count, the mean (stress_sum/pop) is exact, free of the
--     --   buckets' midpoint bias -- see stress_mean.
--     stress_sum = <int>,
--
--     -- wealth: breakdown from plotinfo.tasks.wealth (created == total wealth).
--     wealth = {
--       created=<int>, weapons=<int>, armor=<int>, furniture=<int>, other=<int>,
--       architecture=<int>, displayed=<int>, held=<int>, imported=<int>, exported=<int>,
--     },
--
--     -- stocks: food aggregates from plotinfo.tasks.food
--     food = {
--       total=<int>, drink=<int>, seeds=<int>, meat=<int>,
--       fish=<int>, plant=<int>, other=<int>,
--     },
--   }
--
-- Snapshots are append-only except that the latest day's entry is overwritten
-- in place (see record_snapshot) so a mid-day save/reload doesn't duplicate it.
local function load_data()
    return dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled=false, series={}})
end

local function save_data(data)
    dfhack.persistent.saveSiteData(GLOBAL_KEY, data)
end

-- the recorded series (oldest..newest), for read-only consumers like gui/metrics.
-- Returns the live array from site data; callers should treat it as read-only.
function get_series()
    return load_data().series
end

local function load_state()
    enabled = load_data().enabled or false
end

local function persist_enabled()
    local data = load_data()
    data.enabled = enabled
    save_data(data)
end

-- ------------------------------------------------------------------
-- date helpers
-- ------------------------------------------------------------------
-- absolute day index since year 0; lets us order snapshots and detect a new day
local function current_date()
    local day_of_year = df.global.cur_year_tick // TICKS_PER_DAY
    return {
        year = df.global.cur_year,
        month = day_of_year // DAYS_PER_MONTH + 1,  -- 1..12
        day = day_of_year % DAYS_PER_MONTH + 1,     -- 1..28
        day_index = df.global.cur_year * DAYS_PER_YEAR + day_of_year,
    }
end

local function date_str(snap)
    return ('%d-%02d-%02d'):format(snap.year, snap.month, snap.day)
end

-- ------------------------------------------------------------------
-- metric collection
-- ------------------------------------------------------------------
-- live: population, military count, a cumulative stress histogram, and the exact
-- sum of raw stress values, in a single pass over citizens. Returns pop, the
-- 1-indexed array of NUM_BANDS ascending cumulative counts, stress_sum, and the
-- number of citizens assigned to a squad. The sum is the Prometheus '_sum'
-- companion to the buckets: it makes the mean exact, free of midpoint bias.
local function collect_citizens()
    local pop = 0
    local military = 0
    local stress_sum = 0
    local per_bucket = {}  -- per_bucket[j] = citizens whose band is bucket j
    for j = 1, NUM_BANDS do per_bucket[j] = 0 end
    for _, unit in ipairs(dfhack.units.getCitizens()) do
        pop = pop + 1
        -- in the military iff assigned to a squad (squad_id -1 means none)
        if unit.military.squad_id ~= -1 then military = military + 1 end
        -- category 0 (most stressed) -> bucket NUM_BANDS; category NUM_BANDS-1 -> bucket 1
        local j = NUM_BANDS - dfhack.units.getStressCategory(unit)
        per_bucket[j] = per_bucket[j] + 1
        -- soulless units have no stress value; getStressCategory buckets them as
        -- the middle band, so count them as 0 stress to stay consistent
        local soul = unit.status.current_soul
        if soul then stress_sum = stress_sum + soul.personality.stress end
    end
    -- accumulate ascending into the cumulative histogram (stress[NUM_BANDS] == pop)
    local stress = {}
    local running = 0
    for j = 1, NUM_BANDS do
        running = running + per_bucket[j]
        stress[j] = running
    end
    return pop, stress, stress_sum, military
end

-- live counts of fort animals and other creatures present, matching the in-game
-- Citizens screen's Pets/Livestock and Others tabs. A pet/livestock unit is a
-- (non-sapient) animal belonging to the fort's civ; "others" is everything else
-- alive and present that isn't a citizen or a fort animal -- visitors, merchants,
-- residents, invaders, and wildlife. Fort-animal test follows autobutcher's
-- isInappropriateUnit (modules/autobutcher.cpp): isOwnCiv + alive.
local function collect_creatures()
    local pets, others = 0, 0
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isActive(unit) and not dfhack.units.isDead(unit) then
            if dfhack.units.isAnimal(unit) and dfhack.units.isOwnCiv(unit) then
                pets = pets + 1
            elseif not dfhack.units.isCitizen(unit, true) then
                others = others + 1
            end
        end
    end
    return pets, others
end

-- live counts of workshop/furnace buildings and how many of those currently have
-- at least one non-suspended job with a worker assigned (i.e. actively worked).
local function collect_buildings()
    local total, active = 0, 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        local t = bld:getType()
        if t == df.building_type.Workshop or t == df.building_type.Furnace then
            total = total + 1
            for _, job in ipairs(bld.jobs) do
                if not job.flags.suspend and dfhack.job.getWorker(job) then
                    active = active + 1
                    break
                end
            end
        end
    end
    return total, active
end

-- wealth breakdown from the fort's activity statistics (the same figures shown in
-- the in-game wealth screen). All precomputed by DF; we just copy them.
local function collect_wealth()
    local w = df.global.plotinfo.tasks.wealth
    return {
        -- DF's "created wealth" top-bar figure is the fort's total wealth
        created = w.total,
        weapons = w.weapons,
        armor = w.armor,            -- armor and garb
        furniture = w.furniture,
        other = w.other,            -- other objects
        architecture = w.architecture,
        displayed = w.displayed,
        held = w.held,              -- held/worn
        imported = w.imported,
        exported = w.exported,
    }
end

local function collect_food()
    local f = df.global.plotinfo.tasks.food
    return {
        total = f.total,
        drink = f.drink,
        seeds = f.seeds,
        meat = f.meat,
        fish = f.fish,
        plant = f.plant,
        other = f.other,
    }
end

local function take_snapshot()
    local date = current_date()
    local pop, stress, stress_sum, military = collect_citizens()
    local pets, others = collect_creatures()
    local workshops, workshops_active = collect_buildings()
    return {
        year = date.year,
        month = date.month,
        day = date.day,
        day_index = date.day_index,
        pop = pop,
        military = military,
        pets = pets,
        others = others,
        workshops = workshops,
        workshops_active = workshops_active,
        stress = stress,
        stress_sum = stress_sum,
        wealth = collect_wealth(),
        food = collect_food(),
    }
end

-- per-band citizen counts keyed by band name (so display can use any order).
-- De-cumulates the snapshot's cumulative histogram; tolerates snapshots predating
-- the histogram (legacy plain-count `happiness` map) or with no stress data at all.
-- For display only. Exported for gui/metrics.
function band_counts(snap)
    local counts = {}
    if snap.stress then
        local prev = 0
        for j = 1, NUM_BANDS do
            local c = snap.stress[j] or prev
            counts[STRESS_BUCKET_NAMES[j]] = c - prev
            prev = c
        end
    else
        for _, name in ipairs(STRESS_BUCKET_NAMES) do
            counts[name] = snap.happiness and snap.happiness[name] or 0
        end
    end
    return counts
end

-- ------------------------------------------------------------------
-- stress histogram analysis (Prometheus classic-histogram math)
--
-- The histogram is coarse (NUM_BANDS buckets), so a quantile that lands inside a
-- bucket is refined by assuming the stress values are uniformly distributed
-- across that bucket and interpolating linearly between its bounds -- exactly how
-- Prometheus' histogram_quantile() treats classic (non-native) histograms. The
-- two open buckets can't be interpolated (no finite edge to interpolate toward),
-- so they fall back to their one finite bound.
-- ------------------------------------------------------------------

-- the finite lower/upper stress bounds of bucket j; either may be nil (-inf for
-- the least-stressed bucket, +inf for the most-stressed one).
local function bucket_bounds(j)
    local le = get_bucket_le()
    return le[j - 1], le[j]  -- lower = previous bucket's upper; upper = this le
end

-- interpolated stress value at quantile phi (0..1) over a snapshot's histogram.
-- phi=0.5 is the median. Returns nil when there is no population.
function stress_quantile(snap, phi)
    local cum = snap.stress
    if not cum then return nil end
    local total = cum[NUM_BANDS] or 0
    if total == 0 then return nil end
    local rank = phi * total
    local b = NUM_BANDS
    for j = 1, NUM_BANDS do
        if cum[j] >= rank then b = j; break end
    end
    local lower, upper = bucket_bounds(b)
    if not lower then return upper end  -- least-stressed bucket: unbounded below
    if not upper then return lower end  -- most-stressed bucket: unbounded above
    local prev = b > 1 and cum[b - 1] or 0
    local count = cum[b] - prev
    if count == 0 then return lower end
    return lower + (upper - lower) * (rank - prev) / count
end

-- mean stress. Exact when the snapshot carries stress_sum (the Prometheus '_sum');
-- otherwise falls back to weighting each bucket by its midpoint (open buckets use
-- their one finite edge), which is biased by bucket width. nil if no population.
function stress_mean(snap)
    local cum = snap.stress
    if not cum then return nil end
    local total = cum[NUM_BANDS] or 0
    if total == 0 then return nil end
    if snap.stress_sum then return snap.stress_sum / total end
    local sum, prev = 0, 0
    for j = 1, NUM_BANDS do
        local count = cum[j] - prev
        prev = cum[j]
        if count > 0 then
            local lower, upper = bucket_bounds(j)
            local mid = (not lower and upper) or (not upper and lower)
                or (lower + upper) / 2
            sum = sum + mid * count
        end
    end
    return sum / total
end

-- calendar day_index of the last recorded snapshot, cached so the frequent tick
-- check (see start_loop) doesn't have to deserialize the whole series every time.
local last_recorded_day

-- record today's snapshot, replacing any existing one for the same day so a
-- mid-day save/reload (which re-fires the loop) doesn't create duplicates.
-- returns the snapshot and whether it was a new day.
local function record_snapshot()
    local data = load_data()
    -- keep the stored bucket bounds current so the histogram stays interpretable
    data.stress_bucket_le = get_bucket_le()
    local snap = take_snapshot()
    local last = data.series[#data.series]
    local is_new_day = not last or last.day_index ~= snap.day_index
    if is_new_day then
        table.insert(data.series, snap)
    else
        data.series[#data.series] = snap
    end
    save_data(data)
    last_recorded_day = snap.day_index
    return snap, is_new_day
end

-- ------------------------------------------------------------------
-- console output
-- ------------------------------------------------------------------
local function fmt_stress(v)
    return v and ('%.0f'):format(v) or 'n/a'
end

local function print_snapshot(snap)
    print(('  date %s'):format(date_str(snap)))
    print(('    population %d (military %d)'):format(snap.pop, snap.military or 0))
    print(('    creatures  pets/livestock %d, others %d'):format(snap.pets or 0, snap.others or 0))
    print(('    buildings  workshops %d (%d actively worked)'):format(
        snap.workshops or 0, snap.workshops_active or 0))
    local counts = band_counts(snap)
    local parts = {}
    for _, band in ipairs(DISPLAY_ORDER) do
        table.insert(parts, ('%s %d'):format(band, counts[band]))
    end
    print('    happiness  ' .. table.concat(parts, ', '))
    -- stress stats: exact mean (from stress_sum) + interpolated quantiles
    print(('    stress     mean %s (exact); p10 %s, median %s, p90 %s (interpolated)'):format(
        fmt_stress(stress_mean(snap)),
        fmt_stress(stress_quantile(snap, 0.1)),
        fmt_stress(stress_quantile(snap, 0.5)),
        fmt_stress(stress_quantile(snap, 0.9))))
    local w = snap.wealth
    print(('    wealth     created %d (imported %d, exported %d)'):format(
        w.created, w.imported, w.exported))
    print(('               weapons %d, armor %d, furniture %d, other %d, architecture %d, displayed %d, held %d'):format(
        w.weapons or 0, w.armor or 0, w.furniture or 0, w.other or 0,
        w.architecture or 0, w.displayed or 0, w.held or 0))
    print(('    stocks     food %d, drink %d, seeds %d, meat %d, fish %d, plant %d, other %d'):format(
        snap.food.total, snap.food.drink, snap.food.seeds, snap.food.meat,
        snap.food.fish, snap.food.plant, snap.food.other))
end

-- `dump` emits the whole series as CSV (header row + one row per in-game day) for
-- piping into a spreadsheet/analysis tool, not for pretty in-console reading -- use
-- `now` for that. Each column is {name, getter(snap, band_counts)}; happiness is the
-- per-band (de-cumulated) count. Add a column here and it appears in the output.
-- Missing fields (older snapshots) emit empty cells.
local CSV_COLUMNS = {
    {'year', function(s) return s.year end},
    {'month', function(s) return s.month end},
    {'day', function(s) return s.day end},
    {'population', function(s) return s.pop end},
    {'military', function(s) return s.military end},
    {'pets_livestock', function(s) return s.pets end},
    {'others', function(s) return s.others end},
    {'workshops', function(s) return s.workshops end},
    {'workshops_active', function(s) return s.workshops_active end},
    {'happiness_miserable', function(s, h) return h.miserable end},
    {'happiness_unhappy', function(s, h) return h.unhappy end},
    {'happiness_displeased', function(s, h) return h.displeased end},
    {'happiness_content', function(s, h) return h.content end},
    {'happiness_pleased', function(s, h) return h.pleased end},
    {'happiness_happy', function(s, h) return h.happy end},
    {'happiness_ecstatic', function(s, h) return h.ecstatic end},
    {'stress_sum', function(s) return s.stress_sum end},
    {'wealth_created', function(s) return s.wealth and s.wealth.created end},
    {'wealth_weapons', function(s) return s.wealth and s.wealth.weapons end},
    {'wealth_armor', function(s) return s.wealth and s.wealth.armor end},
    {'wealth_furniture', function(s) return s.wealth and s.wealth.furniture end},
    {'wealth_other', function(s) return s.wealth and s.wealth.other end},
    {'wealth_architecture', function(s) return s.wealth and s.wealth.architecture end},
    {'wealth_displayed', function(s) return s.wealth and s.wealth.displayed end},
    {'wealth_held', function(s) return s.wealth and s.wealth.held end},
    {'wealth_imported', function(s) return s.wealth and s.wealth.imported end},
    {'wealth_exported', function(s) return s.wealth and s.wealth.exported end},
    {'food_total', function(s) return s.food and s.food.total end},
    {'food_drink', function(s) return s.food and s.food.drink end},
    {'food_seeds', function(s) return s.food and s.food.seeds end},
    {'food_meat', function(s) return s.food and s.food.meat end},
    {'food_fish', function(s) return s.food and s.food.fish end},
    {'food_plant', function(s) return s.food and s.food.plant end},
    {'food_other', function(s) return s.food and s.food.other end},
}

local function csv_header()
    local names = {}
    for _, col in ipairs(CSV_COLUMNS) do names[#names + 1] = col[1] end
    return table.concat(names, ',')
end

local function csv_row(snap)
    local h = band_counts(snap)
    local cells = {}
    for _, col in ipairs(CSV_COLUMNS) do
        local v = col[2](snap, h)
        cells[#cells + 1] = v ~= nil and tostring(v) or ''
    end
    return table.concat(cells, ',')
end

local function cmd_dump()
    local data = load_data()
    if #data.series == 0 then
        print('metrics: no data points recorded yet.' ..
            (enabled and ' Collection is enabled; a snapshot is taken each in-game day.'
                     or ' Run `metrics enable` to start collecting.'))
        return
    end
    print(csv_header())
    for _, snap in ipairs(data.series) do
        print(csv_row(snap))
    end
end

local function cmd_now()
    if not dfhack.world.isFortressMode() then
        qerror('metrics requires fortress mode')
    end
    local snap, is_new_day = record_snapshot()
    print('metrics: snapshot recorded' .. (is_new_day and '' or ' (updated existing entry for today)') .. ':')
    print_snapshot(snap)
end

local function cmd_status()
    local data = load_data()
    print('metrics is ' .. (enabled and 'enabled' or 'disabled') .. '.')
    print(('%d data point%s recorded.'):format(#data.series, #data.series == 1 and '' or 's'))
    if #data.series > 0 then
        print(('range: %s to %s'):format(
            date_str(data.series[1]), date_str(data.series[#data.series])))
    end
end

local function cmd_clear()
    local data = load_data()
    local n = #data.series
    data.series = {}
    save_data(data)
    print(('metrics: cleared %d data point%s.'):format(n, n == 1 and '' or 's'))
end

-- ------------------------------------------------------------------
-- enable / background loop
-- ------------------------------------------------------------------
-- DFHack timers count world->frame_counter (simulation frames while unpaused),
-- and treat "1 day" as a fixed 1200 frames (see LuaTools.cpp dfhack_timeout).
-- That equals one calendar day only when the calendar advances 1:1 with frames.
-- `timestream` breaks that assumption: it advances cur_year_tick faster than
-- frame_counter to simulate a higher FPS, so a frame-counted "daily" timer fires
-- far less often than once per in-game day. Instead we poll on a short frame
-- interval and record only when the *calendar* day actually changes. 50 frames is
-- well under the minimum frames-per-calendar-day even when timestream is skipping
-- aggressively (its timeskip is clamped to not cross season ticks, ~10/frame, so
-- a day spans >100 frames), so we never miss a day. The per-check work is just a
-- date comparison; the snapshot scan only runs on a day boundary.
local CHECK_TICKS = 50

local function check_day()
    if current_date().day_index ~= last_recorded_day then
        record_snapshot()
    end
end

local function start_loop()
    -- prime the cache from stored data so a reload mid-day doesn't re-record today
    local series = load_data().series
    last_recorded_day = series[#series] and series[#series].day_index or nil
    -- scheduleEvery fires immediately (recording at once if it's a new day), then
    -- every CHECK_TICKS frames
    repeatutil.scheduleEvery(GLOBAL_KEY, CHECK_TICKS, 'ticks', check_day)
end

local function do_enable()
    enabled = true
    persist_enabled()
    start_loop()
end

local function do_disable()
    enabled = false
    persist_enabled()
    repeatutil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        return
    end
    if sc ~= SC_MAP_LOADED or df.global.gamemode ~= df.game_mode.DWARF then
        return
    end
    load_state()
    if enabled then
        start_loop()
    end
end

-- ------------------------------------------------------------------
-- dispatch
-- ------------------------------------------------------------------
if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('metrics requires fortress mode')
end

-- control-panel toggles arrive as dfhack_flags.enable
local args = {...}
if dfhack_flags and dfhack_flags.enable then
    args = {dfhack_flags.enable_state and 'enable' or 'disable'}
end

load_state()

local cmd = args[1] or 'status'
if cmd == 'enable' then
    do_enable()
    print('metrics enabled; recording a snapshot each in-game day.')
elseif cmd == 'disable' then
    do_disable()
    print('metrics disabled.')
elseif cmd == 'status' then
    cmd_status()
elseif cmd == 'now' then
    cmd_now()
elseif cmd == 'dump' then
    cmd_dump()
elseif cmd == 'gui' then
    dfhack.run_script('gui/metrics')
elseif cmd == 'clear' then
    cmd_clear()
elseif cmd == 'help' or cmd == '-?' then
    print(dfhack.script_help())
else
    qerror('Unknown command: ' .. tostring(cmd) .. ' (try: enable, disable, status, now, dump, clear, gui)')
end
