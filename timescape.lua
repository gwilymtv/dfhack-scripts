-- Replace the fort date display with a custom format and an art area.
--@module = true
--[====[

timescape
=========
Covers Dwarf Fortress's stock date readout in the top-right of the fort map with
a compact custom format (``YYYY-MM-DD (Mon)``, e.g. ``173-08-15 (SND)``) plus ASCII
art. The art is procedurally generated; edit ``get_art_lines`` to supply your own.

DF time reference: 1200 ticks/day, 28 days/month, 12 months (336 days)/year, and
50 ticks/hour (1200/24).

Usage::

    timescape              show usage and current settings
    timescape anim on|off  enable or disable the animation (to gauge its FPS cost)
    timescape ticks <n>    regenerate the art at most once per <n> game ticks; the
                           cap is in game time, so it scales with game speed and
                           stops while paused. 0 = every tick (uncapped); default 5.
                           Reference: 50 ticks/hour, 1200 ticks/day.
    timescape help         show this help

The display is an overlay (enabled by default). Reposition it over the stock date
with ``gui/overlay`` or by dragging in overlay edit mode. To measure the overlay's
full cost, disable it outright with ``overlay disable timescape.date`` (this also
restores the stock date readout); ``timescape anim off`` instead isolates just the
animation's regeneration cost while keeping the display visible.

]====]

local overlay = require('plugins.overlay')

local TICKS_PER_DAY = 1200
local DAYS_PER_MONTH = 28
local DAYS_PER_SEASON = 84
local TICKS_PER_HOUR = TICKS_PER_DAY // 24  -- 50

-- Runtime knobs, shared between this module and its command line (in-memory; not
-- saved across restarts). The art is procedural and regenerated as the game runs;
-- these let you gauge and cap that cost. `CONFIG or {}` keeps the current settings
-- if the module is reloaded. Toggle them with the command:
--   timescape anim off    -- freeze the animation (generate once, then hold)
--   timescape ticks <n>   -- update at most once per <n> game ticks (0 = every tick)
-- The cap is in game ticks, so it tracks in-game time and pauses when the game does.
-- Reference: 50 ticks/hour, 1200 ticks/day.
CONFIG = CONFIG or {
    animate = true,
    ticks = 5,
}

-- Visual tunables for the procedural art -- the knobs worth playing with, gathered in
-- one place. (The on/off switch and the regeneration cap are runtime settings, in
-- CONFIG above.) Most values are 0..1 fractions; a few are in tiles or game ticks.
local TUNE = {
    -- lighting: how the sky lights the ground
    moonlight_floor   = 0.10,  -- minimum ground brightness at night (raise = lighter nights)
    sun_ground_spill  = 0.70,  -- how much a low sun brightens the ground beneath it
    snow_depth_step   = 0.06,  -- extra snow brightness per winter third (early -> late)
    feature_light     = 0.40,  -- minimum light for flowers/leaves/etc to be drawn

    -- the sun's warm sunrise/sunset tint on the ground (kept gentler than the sky)
    ground_warm_min     = 0.45,  -- glow needed before ground takes a warm hue (higher = less red)
    ground_warm_feather = 0.40,  -- dither spread of that threshold (softer, sparser warm edge)

    -- the sun's warm glow in the sky, in tiles of reach
    glow_spread_near  = 4,      -- glow half-width when the sun is high
    glow_spread_low   = 6,      -- extra half-width added as the sun nears the horizon

    -- stars
    star_density      = 0.78,   -- higher = fewer stars
    star_twinkle      = 25,     -- game ticks per twinkle step (higher = slower flicker)
    star_flare_chance = 0.85,   -- higher = rarer coloured flares

    -- daylight level splitting night from day: below it stars come out, above it clouds
    twilight_level    = 0.35,
}

-- star colours: the brightness/flicker cycle, and the rare coloured flares (see build_sky)
local STAR_BRIGHT = {[0]=COLOR_DARKGREY, [1]=COLOR_DARKGREY, [2]=COLOR_GREY, [3]=COLOR_WHITE}
local STAR_FLARE  = {COLOR_LIGHTCYAN, COLOR_YELLOW, COLOR_LIGHTBLUE}

-- decompose the current time into its calendar parts
local function get_date_parts()
    local tick = df.global.cur_year_tick
    local doy = tick // TICKS_PER_DAY            -- 0..335
    return {
        year   = df.global.cur_year,
        month  = doy // DAYS_PER_MONTH + 1,      -- 1..12
        day    = doy % DAYS_PER_MONTH + 1,       -- 1..28
        hour   = (tick % TICKS_PER_DAY) // TICKS_PER_HOUR,  -- 0..23
        season = doy // DAYS_PER_SEASON,         -- 0..3 (spring..winter)
        -- a season is exactly three months, so this is its early/mid/late third
        season_phase = (doy % DAYS_PER_SEASON) // DAYS_PER_MONTH,  -- 0/1/2
    }
end

-- "173-08-15 (SND)": numeric year-month-day (year in full; DF years exceed 99)
-- followed by the three-letter month name. The hour is no longer shown -- time of day
-- is conveyed by the art. DF has no official month abbreviations, so these are our own:
-- the first three letters, tweaked where awkward (SND/TMB/MNS/OPL for Sandstone/Timber/
-- Moonstone/Opal).
local MONTHS = {'GRA','SLA','FEL','HEM','MAL','GAL','LIM','SND','TMB','MNS','OPL','OBS'}
local function get_date_string()
    local p = get_date_parts()
    return ('%d-%02d-%02d (%s)'):format(p.year, p.month, p.day, MONTHS[p.month])
end

--
-- procedural art
--
-- Two 15-wide rows that react to the live game state: row 1 is the sky (sun arc,
-- stars, clouds, precipitation) and row 2 is the ground (seasonal terrain, frost,
-- heat shimmer). Everything is keyed off the sim clock, the season, the felt
-- temperature, and the actual weather, so it animates as the fort's day passes and
-- freezes when the game is paused. Moon phase is deliberately omitted (shown
-- elsewhere). Each cell is {ch=<1-char string>, fg=<color>, bg=<color 0..7>}.

local W = 15

-- deterministic pseudo-random value in [0,1) from integer-ish seeds; stable per
-- cell so features (stars, flowers, grass texture) don't jitter frame to frame.
local function hash(a, b)
    local x = math.sin(a * 12.9898 + (b or 0) * 78.233) * 43758.5453
    return x - math.floor(x)
end

-- the animation clock. cur_year_tick advances only while the game is unpaused, so
-- driving motion from it keeps the art in step with the sim and still on pause.
local function clock()
    return df.global.cur_year_tick
end

-- current_weather is a 5x5 grid of weather_type covering the local area; the centre
-- cell is what's overhead. Available in fortress mode. The enum only defines
-- 0=None 1=Rain 2=Snow; the heavier/exotic branches below are defensive (e.g. for
-- interaction-driven weather like dragonfire) and simply no-op on a stock game.
local function get_weather()
    local ok, w = pcall(function() return df.global.current_weather[2][2] end)
    return (ok and w) or 0
end

-- felt-temperature band: 0 freezing .. 4 hot. Derived from the season, a day/night
-- swing, and the weather (snow forces freezing). To drive this from the real map
-- temperature instead, sample a surface block's temperature_1[][] near the fort and
-- bucket the value here.
local SEASON_BASE = {[0]=2, [1]=4, [2]=2, [3]=0}  -- spring, summer, autumn, winter
local function temp_band(p, weather)
    local h = p.hour + (clock() % TICKS_PER_HOUR) / TICKS_PER_HOUR
    local swing = math.cos((h - 15) / 24 * 2 * math.pi)  -- +1 near 15h, -1 near 3h
    local t = (SEASON_BASE[p.season] or 2) + swing
    if weather == 1 then t = t - 1 end                   -- rain cools things off
    if weather == 2 or weather == 3 then t = 0 end       -- snow/blizzard: freezing
    t = math.floor(t + 0.5)
    return t < 0 and 0 or t > 4 and 4 or t
end

-- ordered-dither toolkit. A shaded block glyph lets one cell blend two colours: the
-- fg "ink" covers 0/25/50/75/100% of the bg. A per-column threshold (a 1D ordered-
-- dither pattern) nudges the rounding so a single, constant blend spread across the
-- row reads as a smooth gradient instead of five hard bands -- and because the blend
-- amount drifts with the clock, the night<->day transition fills in gradually too.
local SKY_SHADES = {[0]=' ', [1]='\xb0', [2]='\xb1', [3]='\xb2', [4]='\xdb'}
local DITHER8 = {[0]=0/8, [1]=4/8, [2]=2/8, [3]=6/8, [4]=1/8, [5]=5/8, [6]=3/8, [7]=7/8}

local function shade_idx(frac, x)
    local i = math.floor(frac * 4 + DITHER8[x % 8])
    return i < 0 and 0 or i > 4 and 4 or i
end

-- a cell that blends bg colour `lo` toward ink colour `hi` at coverage `frac` (0..1)
local function blend_cell(lo, hi, frac, x)
    return {ch = SKY_SHADES[shade_idx(frac, x)], fg = hi, bg = lo}
end

-- overlay falling precipitation onto a row, marching with the clock. Each drop keeps
-- the sky colour already behind it, so the dithered gradient still shows through.
local function apply_precip(row, weather, t)
    local function put(x, ch, fg) row[x] = {ch = ch, fg = fg, bg = row[x].bg} end
    if weather == 1 then            -- rain
        for x = 0, W - 1 do
            if (x * 2 + math.floor(t / 6)) % 5 == 0 then put(x, '/', COLOR_LIGHTCYAN) end
        end
    elseif weather == 2 or weather == 3 then  -- snow / blizzard (denser, faster)
        local step = weather == 3 and 4 or 10
        local gap  = weather == 3 and 3 or 5
        for x = 0, W - 1 do
            local ph = (x * 3 + math.floor(t / step)) % gap
            if ph == 0 then put(x, '*', COLOR_WHITE)
            elseif ph == 1 then put(x, '\xf9', COLOR_GREY) end
        end
    elseif weather == 7 then        -- dragonfire: raining embers
        for x = 0, W - 1 do
            if (x * 2 + math.floor(t / 5)) % 4 == 0 then put(x, '*', COLOR_LIGHTRED) end
        end
    elseif weather >= 4 then        -- other exotic storms: treat as hail
        for x = 0, W - 1 do
            if (x * 3 + math.floor(t / 6)) % 4 == 0 then put(x, 'o', COLOR_WHITE) end
        end
    end
end

-- shared sun model, so the sky and the ground are lit by the same source.
local function sun_state(p)
    local h = p.hour + (clock() % TICKS_PER_HOUR) / TICKS_PER_HOUR
    local alt = math.sin((h - 6) / 12 * math.pi)  -- -1 midnight, 0 horizon, +1 noon
    local b = alt * 0.5 + 0.5                      -- daylight: 0 night, 0.5 twilight, 1 noon
    return {h = h, alt = alt, b = b < 0 and 0 or b > 1 and 1 or b}
end

-- warm hue for a sun at altitude `alt`: red on the horizon, then orange, then yellow
local function warm_hue(alt)
    return alt < 0.08 and COLOR_RED or alt < 0.25 and COLOR_BROWN or COLOR_YELLOW
end

-- how strongly the low sun's warm glow reaches column x (0..1): broad and strong near
-- the horizon, tightening and fading as the sun climbs, zero once it's well up or down.
local function sun_glow(ss, x)
    if ss.alt <= -0.3 then return 0 end
    local up = ss.alt > 0 and ss.alt or 0
    local sun_px = (ss.h - 6) / 12 * (W - 1)          -- may sit off-screen at dawn/dusk
    local gate = math.min(1, (ss.alt + 0.3) / 0.3)   -- fade out through twilight
    local warmth = math.max(0, 1 - up / 0.5)         -- gone once the sun is high
    local spread = TUNE.glow_spread_near + (1 - up) * TUNE.glow_spread_low
    local g = gate * warmth * (1 - math.abs(x - sun_px) / spread)
    return g > 0 and g or 0
end

-- the cool base sky as a dithered blend keyed off overall daylight `b`: black at
-- night, deepening to blue by day and brightening to cyan toward noon. Overcast skies
-- desaturate the same way through grey to white. All bg colours stay in 0..7.
local function sky_base_cell(b, overcast, x)
    if overcast then
        if b < 0.5 then return blend_cell(COLOR_BLACK, COLOR_GREY, b / 0.5, x) end
        return blend_cell(COLOR_GREY, COLOR_WHITE, (b - 0.5) / 0.5, x)
    end
    if b < 0.5 then return blend_cell(COLOR_BLACK, COLOR_BLUE, b / 0.5, x) end
    return blend_cell(COLOR_BLUE, COLOR_CYAN, (b - 0.5) / 0.5, x)
end

-- row 1: the sky
local function build_sky(p, weather)
    local t = clock()
    local overcast = weather ~= 0
    local ss = sun_state(p)
    local b = ss.b

    local row = {}
    for x = 0, W - 1 do row[x] = sky_base_cell(b, overcast, x) end

    -- the sun's warm glow, washing across the sky and carrying the colour through dawn
    -- and dusk. Dithered over the base so it bleeds into the blue. Hidden under cloud.
    if not overcast and ss.alt > -0.3 then
        local warm = warm_hue(ss.alt)
        local base_lo = b < 0.5 and COLOR_BLACK or COLOR_BLUE
        for x = 0, W - 1 do
            local gi = shade_idx(sun_glow(ss, x), x)
            if gi > 0 then row[x] = {ch = SKY_SHADES[gi], fg = warm, bg = base_lo} end
        end
        if ss.alt > 0 then                               -- the sun disk itself
            local col = math.floor((ss.h - 6) / 12 * (W - 1) + 0.5)
            if col >= 0 and col < W then
                local fg = ss.alt > 0.6 and COLOR_WHITE or ss.alt > 0.3 and COLOR_YELLOW or COLOR_LIGHTRED
                row[col] = {ch = '\x0f', fg = fg, bg = row[col].bg}
            end
        end
    end

    -- stars emerge as the sky darkens. A single faint glyph is held constant; each
    -- star's brightness and twinkle are conveyed purely by colour, cycling dark grey
    -- -> grey -> white, so "brighter" and "flickering" read as colour, not shape. Each
    -- star flickers on its own offset (from its hash) so they don't pulse in unison.
    -- Occasionally a star's bright peak flares a colour instead of white.
    if not overcast and b < TUNE.twilight_level then
        for x = 0, W - 1 do
            if hash(x, 7) > TUNE.star_density then
                local phase = math.floor(t / TUNE.star_twinkle) + math.floor(hash(x, 13) * 4) + x
                local fg = STAR_BRIGHT[phase % 4]
                if phase % 4 == 3 and hash(phase, 29) > TUNE.star_flare_chance then  -- rare flare
                    fg = STAR_FLARE[math.floor(hash(phase, 31) * 3) + 1]
                end
                row[x] = {ch = '\xf9', fg = fg, bg = row[x].bg}
            end
        end
    end

    -- clouds drift in front of the gradient (and the sun), preserving the sky behind
    if overcast then                          -- a solid moving cloud band
        for x = 0, W - 1 do
            local d = (x + math.floor(t / 30)) % 4
            local ch = d == 0 and '\xb2' or d == 1 and '\xb1' or '\xb0'
            row[x] = {ch = ch, fg = COLOR_DARKGREY, bg = row[x].bg}
        end
    elseif b > TUNE.twilight_level then       -- a couple of fair-weather puffs by day
        for x = 0, W - 1 do
            if (x + math.floor(t / 35)) % 11 < 2 then
                row[x] = {ch = '\xb0', fg = COLOR_WHITE, bg = row[x].bg}
            end
        end
    end

    apply_precip(row, weather, t)
    return row
end

-- per-season ground. `tones` is a short palette mottled across the row (one tone
-- picked per column) so the ground has dithered colour variation that shifts through
-- the season's early/mid/late thirds. The row is then lit by the sky in build_ground:
-- dark at night, warm under a low sun, full colour by day -- with the brightness
-- itself rendered as dithering. Winter snow uses its own tones; depth is set below.
local SEASON_GROUND = {
    [0] = {phase={  -- spring: bare thaw -> green -> lush & flowering
        [0] = {tones={COLOR_GREEN, COLOR_BROWN},      thaw=true},
        [1] = {tones={COLOR_GREEN, COLOR_LIGHTGREEN}, flowers=0.12},
        [2] = {tones={COLOR_LIGHTGREEN, COLOR_GREEN}, flowers=0.24},
    }},
    [1] = {phase={  -- summer: fresh green -> golden -> sun-dried
        [0] = {tones={COLOR_LIGHTGREEN, COLOR_GREEN}},
        [1] = {tones={COLOR_YELLOW, COLOR_LIGHTGREEN}},
        [2] = {tones={COLOR_YELLOW, COLOR_BROWN}, dry=true},
    }},
    [2] = {phase={  -- autumn: turning -> peak colour -> bare & leaf-strewn
        [0] = {tones={COLOR_GREEN, COLOR_YELLOW},            leaves=8, leaf=COLOR_YELLOW},
        [1] = {tones={COLOR_RED, COLOR_BROWN, COLOR_YELLOW}, leaves=6, leaf=COLOR_LIGHTRED},
        [2] = {tones={COLOR_BROWN, COLOR_DARKGREY},          leaves=4, leaf=COLOR_BROWN},
    }},
    [3] = {phase={[0]={}, [1]={}, [2]={}}},  -- winter: snow (tones/depth set below)
}

-- row 2: the ground, lit by the sky
local function build_ground(p, weather, band)
    local t = clock()
    local ss = sun_state(p)
    local s = SEASON_GROUND[p.season] or SEASON_GROUND[0]
    local pd = s.phase[p.season_phase]
    -- snow blankets the ground in winter, during snowfall, or whenever it's freezing
    local snow = p.season == 3 or weather == 2 or weather == 3 or band == 0
    local tones = snow and {COLOR_WHITE, COLOR_GREY} or pd.tones
    -- deep winter snow lies a touch brighter; a flurry/freeze is a thinner cover
    local snow_boost = snow and (p.season == 3 and p.season_phase or 1) * TUNE.snow_depth_step or 0

    -- Lay down the lit ground. Brightness is dithered coverage of the ground colour
    -- over black, so day -> night fades from full colour to a few dim flecks. Light =
    -- overall daylight + the low sun's glow spilling onto the ground (warmer and
    -- brighter right under a rising/setting sun) + a little moonlight floor.
    local row, light = {}, {}
    for x = 0, W - 1 do
        local glow = sun_glow(ss, x)
        local L = ss.b + glow * TUNE.sun_ground_spill + snow_boost
        L = L < TUNE.moonlight_floor and TUNE.moonlight_floor or L > 1 and 1 or L
        light[x] = L
        local color = tones[math.floor(hash(x, p.season + 2) * #tones) + 1]
        -- a subtle warm kiss only on the brightest cells right under the sun, feathered
        -- with the dither so it stays narrower and sparser than the sky's broad glow
        if glow > TUNE.ground_warm_min + DITHER8[x % 8] * TUNE.ground_warm_feather then
            color = warm_hue(ss.alt)
        end
        row[x] = {ch = SKY_SHADES[shade_idx(L, x)], fg = color, bg = COLOR_BLACK}
    end

    -- seasonal features, overlaid on the lit ground; shown only where there's enough
    -- light (you can't make out flowers or leaves in the dark).
    local function lit(x) return light[x] > TUNE.feature_light end

    if not snow and p.season == 0 then            -- spring
        if pd.thaw then                           -- early: lingering frost flecks
            for x = 0, W - 1 do
                if hash(x, 3) > 0.85 then row[x] = {ch = '\xb0', fg = COLOR_WHITE, bg = COLOR_BLACK} end
            end
        end
        if pd.flowers then                        -- more flowers as the season advances
            local petals = {COLOR_LIGHTMAGENTA, COLOR_YELLOW, COLOR_LIGHTRED}
            for x = 0, W - 1 do
                if lit(x) and hash(x, 99) > 1 - pd.flowers then
                    row[x] = {ch = '*', fg = petals[math.floor(hash(x, 5) * 3) + 1], bg = COLOR_BLACK}
                end
            end
        end
    elseif not snow and p.season == 1 and pd.dry then  -- summer late: dry brown patches
        for x = 0, W - 1 do
            if lit(x) and hash(x, 7) > 0.82 then
                row[x] = {ch = '\xb1', fg = COLOR_BROWN, bg = COLOR_BLACK}
            end
        end
    elseif not snow and p.season == 2 then        -- autumn: leaves blow past, denser later
        for x = 0, W - 1 do
            if lit(x) and (x + math.floor(t / 50)) % pd.leaves == 0 then
                row[x] = {ch = '\xf8', fg = pd.leaf, bg = COLOR_BLACK}
            end
        end
    end

    if band >= 4 then                             -- hot: heat shimmer (daytime anyway)
        for x = 0, W - 1 do
            if (x + math.floor(t / 12)) % 7 == 0 then
                row[x] = {ch = '~', fg = COLOR_RED, bg = COLOR_BLACK}
            end
        end
    end

    if weather == 1 then                          -- rain: wet splashes, dimmer at night
        for x = 0, W - 1 do
            if (x * 2 + math.floor(t / 6)) % 5 == 2 then
                row[x] = {ch = '\xf9', fg = lit(x) and COLOR_CYAN or COLOR_BLUE, bg = COLOR_BLACK}
            end
        end
    end

    return row
end

-- return the two art rows (row 1 sky, row 2 ground); each is a 0..W-1 array of cells.
-- Swap the bodies of build_sky / build_ground to design your own.
local function get_art_lines()
    local p = get_date_parts()
    local weather = get_weather()
    local band = temp_band(p, weather)
    return {build_sky(p, weather), build_ground(p, weather, band)}
end

--
-- overlay
--

local MASK_PEN = {ch=' ', fg=COLOR_WHITE, bg=COLOR_BLACK}

DateOverlay = defclass(DateOverlay, overlay.OverlayWidget)
DateOverlay.ATTRS{
    desc='Replaces the date display with a custom format and art.',
    -- top-right; drag to align over the stock date. DF stacks the date as three
    -- ~15-wide lines (e.g. "11th Sandstone" / "Mid-Autumn" / "Year 173"), so a
    -- 15x3 frame masks all three: row 0 = the compact date, rows 1-2 = the art.
    default_pos={x=-2, y=0},
    default_enabled=true,
    viewscreens='dwarfmode/Default',
    frame={w=15, h=3},
}

function DateOverlay:onRenderBody(dc)
    local w, h = self.frame_rect.width, self.frame_rect.height
    dc:fill(0, 0, w-1, h-1, MASK_PEN)  -- hide the stock date underneath
    dc:seek(0, 0):string(get_date_string(), COLOR_WHITE)

    -- Animation limiter, capped by in-game time. Regenerating the procedural art is
    -- the only real per-frame cost; drawing the cached cells is cheap and still happens
    -- every frame. So we regenerate only once CONFIG.ticks game ticks have elapsed
    -- (which naturally freezes the art when the game is paused, and skips redundant
    -- work), or never while the animation is switched off. A backwards jump (e.g. the
    -- year rolling over to tick 0) forces a refresh.
    local tick = df.global.cur_year_tick
    local elapsed = tick - (self.art_tick or 0)
    if not self.art or (CONFIG.animate and elapsed ~= 0
                        and (elapsed < 0 or elapsed >= CONFIG.ticks)) then
        self.art = get_art_lines()
        self.art_tick = tick
    end

    for i, row in ipairs(self.art) do
        local y = i  -- art starts on the line below the date
        if y >= h then break end
        for x = 0, W - 1 do
            local c = row[x]
            if c then dc:seek(x, y):string(c.ch, {fg=c.fg, bg=c.bg}) end
        end
    end
end

OVERLAY_WIDGETS = {
    date=DateOverlay,
}

--
-- command line
--

if dfhack_flags.module then
    return
end

if df.global.gamemode ~= df.game_mode.DWARF then
    qerror('timescape requires a loaded fortress')
end

-- reach the same CONFIG table the live overlay reads, regardless of how the command
-- was loaded, so toggles take effect immediately.
local cfg = reqscript('timescape').CONFIG

local function cap_str()
    return cfg.ticks > 0 and ('every '..cfg.ticks..' game ticks') or 'every tick (uncapped)'
end

local function print_help()
    print('timescape: replace DF\'s stock fort date readout with a compact custom')
    print('format plus procedurally-generated ASCII art. The display is an overlay,')
    print('enabled by default, in the top-right of the fort map; align it with')
    print('gui/overlay or by dragging in overlay edit mode.')
    print('')
    print('Commands:')
    print('  timescape              show this help')
    print('  timescape anim on|off  enable/disable the art animation (to gauge FPS cost)')
    print('  timescape ticks <n>    redraw the art at most once per <n> game ticks')
    print('                         (0 = every tick); game time: 50 ticks/hour, 1200/day')
    print('  timescape help         show this help')
    print('')
    print(('Status: animation is %s; updating %s.'):format(
        cfg.animate and 'on' or 'off', cap_str()))
end

local args = {...}
local command = args[1]
if not command or command == 'help' or command == '?' then
    print_help()
elseif command == 'anim' then
    if args[2] == 'on' or args[2] == 'off' then
        cfg.animate = args[2] == 'on'
        print('timescape animation '..(cfg.animate and 'enabled' or 'disabled'))
    else
        print('animation is '..(cfg.animate and 'on' or 'off')..'; use: timescape anim on|off')
    end
elseif command == 'ticks' then
    local n = tonumber(args[2])
    if n and n >= 0 then
        cfg.ticks = math.floor(n)
        print('timescape animation updating '..cap_str())
    else
        print('animation is updating '..cap_str()..'; use: timescape ticks <n>  (0 = every tick)')
    end
else
    dfhack.printerr('unknown command: '..command)
    print_help()
end
