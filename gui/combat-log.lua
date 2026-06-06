-- Real-time, space-efficient combat log viewer for a single unit.

local gui = require('gui')
local json = require('json')
local widgets = require('gui.widgets')

local config = config or json.open('dfhack-config/combat-log.json')

-- the unit_report_type categories we merge into one chronological log
local CATEGORIES = {
    df.unit_report_type.Combat,
    df.unit_report_type.Hunting,
    df.unit_report_type.Sparring,
}

local function get_unit_name(unit)
    return dfhack.units.getReadableName(unit) or ('Unit '..tostring(unit.id))
end

-- the unit to open the log for: the selected unit, or the unit a selected
-- corpse belongs to
local function get_target_unit()
    local unit = dfhack.gui.getSelectedUnit(true)
    if unit then return unit end
    local item = dfhack.gui.getSelectedItem(true)
    if item and df.item_corpsest:is_instance(item) then
        return df.unit.find(item.unit_id)
    end
    return nil
end

-- collect a unit's combat/hunting/sparring reports, deduped and sorted oldest
-- first (report ids are assigned chronologically)
local function gather_reports(unit)
    local seen, reports = {}, {}
    local log = unit.reports.log
    for _,cat in ipairs(CATEGORIES) do
        for _,report_id in ipairs(log[cat]) do
            if not seen[report_id] then
                local report = df.report.find(report_id)
                if report then
                    seen[report_id] = true
                    reports[#reports+1] = report
                end
            end
        end
    end
    table.sort(reports, function(a, b) return a.id < b.id end)
    return reports
end

-- cheap per-frame change check: total number of logged reports across categories
local function count_reports(unit)
    local total = 0
    local log = unit.reports.log
    for _,cat in ipairs(CATEGORIES) do
        total = total + #log[cat]
    end
    return total
end

local TICKS_PER_YEAR = 403200

-- cur_year_tick advances by at least 1 each simulation step, giving a monotonic
-- clock we use only to expire the "new entry" highlight once the step that
-- produced the entries has passed
local function now_tick()
    return df.global.cur_year * TICKS_PER_YEAR + df.global.cur_year_tick
end

local function report_to_choice(report, highlight)
    local fg = report.color or COLOR_GREY
    if report.bright then fg = fg + 8 end
    if fg > 15 then fg = 15 end
    if fg < 0 then fg = COLOR_GREY end
    -- highlight by inverting: the entry's own color becomes the background
    local pen = highlight and {fg=COLOR_BLACK, bg=fg} or fg
    local text = report.text
    if report.repeat_count and report.repeat_count > 0 then
        text = text..(' x%d'):format(report.repeat_count + 1)
    end
    return {
        text = {{text=text, pen=pen}},
        report_id = report.id,
        full_text = text,  -- untruncated, for the hover detail strip
        fg = fg,
    }
end

local function has_valid_pos(report)
    return report and report.pos and report.pos.x >= 0
end

local function sanitize_frame(frame)
    frame = frame or {}
    frame.w = math.max(50, frame.w or 60)
    frame.h = math.max(10, frame.h or 30)
    return frame
end

local function save_frame(self)
    config.data.frame = self.frame
    config:write()
end

--------------------
-- CombatLogWindow --
--------------------

CombatLogWindow = defclass(CombatLogWindow, widgets.Window)
CombatLogWindow.ATTRS{
    frame_title='Combat log',
    frame_inset={l=1, r=0, t=1, b=1},
    resizable=true,
    resize_min={w=50, h=10},
    autoarrange_subviews=false,
}

function CombatLogWindow:init()
    self.last_count = nil
    self.on_drag_end = function() save_frame(self) end
    self.on_resize_end = function() save_frame(self) end

    -- a frame anchored only with r= fills the whole row, so the label would
    -- render left-aligned on top of the toggle; give it an explicit width so
    -- it actually sits at the right edge
    local jump_key, jump_label = 'CUSTOM_SHIFT_E', 'Jump to end'
    local jump_w = #gui.getKeyDisplay(jump_key) + 2 + #jump_label

    self:addviews{
        widgets.ToggleHotkeyLabel{
            view_id='auto_pause',
            frame={t=0, l=0},
            label='Auto-pause:',
            key='CUSTOM_SHIFT_P',
            initial_option=config.data.auto_pause or false,
            on_change=function(val)
                config.data.auto_pause = val
                config:write()
            end,
        },
        widgets.HotkeyLabel{
            frame={t=0, r=0, w=jump_w},
            label=jump_label,
            key=jump_key,
            on_activate=function() self:scroll_to_bottom(true) end,
        },
        widgets.List{
            view_id='log',
            frame={t=2, l=0, r=0, b=0},
            cursor_pen=COLOR_DARKGREY,
            on_submit=self:callback('on_line_click'),
            on_double_click=self:callback('on_line_click'),
        },
    }
end

function CombatLogWindow:setUnit(unit)
    self.unit_id = unit.id
    self.last_count = nil
    self.max_id = nil
    self.highlight_tick = nil
    self.frame_title = 'Combat log: '..get_unit_name(unit)
    self:refresh(true)
    self:scroll_to_bottom(true)
end

function CombatLogWindow:is_at_bottom()
    local list = self.subviews.log
    local max_top = math.max(1, #list.choices - list.page_size + 1)
    return list.page_top >= max_top
end

function CombatLogWindow:scroll_to_bottom(also_select)
    local list = self.subviews.log
    list.page_top = math.max(1, #list.choices - list.page_size + 1)
    if also_select then
        list:setSelected(#list.choices)
    end
end

function CombatLogWindow:refresh(force)
    local unit = self.unit_id and df.unit.find(self.unit_id)
    if not unit then return end

    local count = count_reports(unit)
    local tick = now_tick()

    -- a highlight is showing when some shown reports are newer than the cutoff;
    -- it should expire once a tick has elapsed since it was set
    local highlight_active = self.max_id ~= nil and self.highlight_after ~= nil
            and self.highlight_after < self.max_id
    local should_clear = highlight_active and self.highlight_tick
            and tick > self.highlight_tick

    if not force and count == self.last_count and not should_clear then
        return
    end

    local had_new = self.last_count ~= nil and count > self.last_count
    self.last_count = count

    local list = self.subviews.log
    local at_bottom = self:is_at_bottom()

    local reports = gather_reports(unit)
    local cur_max = #reports > 0 and reports[#reports].id or -1
    if self.max_id == nil then
        -- first build for this unit: nothing counts as new
        self.highlight_after = cur_max
    elseif cur_max > self.max_id then
        -- new entries arrived: highlight everything newer than the old max,
        -- and remember the tick so we can expire it next step
        self.highlight_after = self.max_id
        self.highlight_tick = tick
    elseif should_clear then
        -- a step elapsed without new entries: drop the highlight
        self.highlight_after = cur_max
    end
    self.max_id = cur_max

    local choices = {}
    for _,report in ipairs(reports) do
        choices[#choices+1] =
            report_to_choice(report, report.id > self.highlight_after)
    end
    list:setChoices(choices, at_bottom and #choices or list.selected)

    if at_bottom then
        self:scroll_to_bottom(false)
    end

    if had_new and self.subviews.auto_pause:getOptionValue() then
        df.global.pause_state = true
    end
end

function CombatLogWindow:on_line_click(_, choice)
    if not choice or not choice.report_id then return end
    local report = df.report.find(choice.report_id)
    if has_valid_pos(report) then
        dfhack.gui.revealInDwarfmodeMap(copyall(report.pos), true, true)
    end
end

-- show a floating tooltip with the full text of the line under the mouse, but
-- only when that line is too wide to fit (clicking is reserved for recentering)
function CombatLogWindow:update_tooltip()
    local tip = self.tooltip
    if not tip then return end
    local list = self.subviews.log
    local idx = list:getIdxUnderMouse()
    local choice = idx and list.choices[idx]
    -- usable text width is the list body minus the scrollbar column
    local avail = (list.frame_body and list.frame_body.width or 0) - 1
    if not choice or #choice.full_text <= avail then
        tip.visible = false
        return
    end
    tip.visible = true
    tip:setContent(choice.full_text, choice.fg)
end

-- runs every frame, even while the game is unpaused, so the log stays live
function CombatLogWindow:onRenderFrame(dc, rect)
    self:refresh(false)
    self:update_tooltip()
    CombatLogWindow.super.onRenderFrame(self, dc, rect)
end

---------------------
-- CombatLogTooltip --
---------------------

local TOOLTIP_W = 44  -- total width incl. border
local TOOLTIP_TEXT_W = TOOLTIP_W - 2  -- printable interior between the borders
-- solid background so the text stays readable over a busy map
local TOOLTIP_BG = dfhack.pen.parse{ch=' ', fg=COLOR_BLACK, bg=COLOR_BLACK}

-- a mouse-following popup that shows a single log line's full, wrapped text.
-- it lives at the screen level so it can float over the map near the cursor.
CombatLogTooltip = defclass(CombatLogTooltip, widgets.Panel)
CombatLogTooltip.ATTRS{
    frame_style=gui.FRAME_THIN,
    frame_background=TOOLTIP_BG,
    visible=false,
}

function CombatLogTooltip:init()
    self.frame = self.frame or {}
    self.frame.w = TOOLTIP_W
    self.frame.h = 3
    self.label = widgets.Label{frame={t=0, l=0}, text=''}
    self:addviews{self.label}
end

function CombatLogTooltip:setContent(text, pen)
    local lines = text:wrap(TOOLTIP_TEXT_W, {return_as_table=true})
    self.label.text_pen = pen or COLOR_WHITE
    self.label:setText(table.concat(lines, NEWLINE))
    self.frame.h = #lines + 2  -- + top and bottom border rows
end

function CombatLogTooltip:render(dc)
    local x, y = dfhack.screen.getMousePos()
    if not x then return end
    local sw, sh = dfhack.screen.getWindowSize()
    self.frame.l = math.max(0, math.min(x + 2, sw - self.frame.w))
    self.frame.t = math.max(0, math.min(y + 1, sh - self.frame.h))
    self:updateLayout()
    CombatLogTooltip.super.render(self, dc)
end

--------------------
-- CombatLogScreen --
--------------------

CombatLogScreen = defclass(CombatLogScreen, gui.ZScreen)
CombatLogScreen.ATTRS{
    focus_path='combat-log',
    -- let the game keep running while the log is open
    initial_pause=false,
    force_pause=false,
}

function CombatLogScreen:init(args)
    self.window = CombatLogWindow{
        frame=sanitize_frame(copyall(config.data.frame or {})),
    }
    self.tooltip = CombatLogTooltip{}
    self.window.tooltip = self.tooltip
    -- tooltip added after the window so it renders on top of it
    self:addviews{self.window, self.tooltip}
    if args.unit then
        self.window:setUnit(args.unit)
    end
end

function CombatLogScreen:setUnit(unit)
    self.window:setUnit(unit)
end

function CombatLogScreen:onDismiss()
    view = nil
end

--------------------
-- entry point      --
--------------------

if dfhack_flags.module then
    return
end

if not dfhack.isMapLoaded() then
    qerror('combat-log requires a loaded fortress or adventure map')
end

local target = get_target_unit()

if view then
    if target then
        view:setUnit(target)
    end
    view:raise()
else
    if not target then
        qerror('no unit selected; view a unit or corpse and try again')
    end
    view = CombatLogScreen{unit=target}:show()
end
