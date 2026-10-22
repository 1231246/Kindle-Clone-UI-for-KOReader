local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local ReadHistory = require("readhistory")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Toolbar = require("kcui/toolbar")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")
local Common = require("kcui/common")
local T = require("ffi/util").template
local Screen = Device.screen
local Airplane = Common.Airplane
local Dates = Common.Dates
local Gray = Common.Gray
local Divider = Common.Divider
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/panel%.lua$") .. "/icons"
local PROGRESS = "kcui_reading_progress"
local POSITION = "kcui_reading_position"
local PROGRESS_BAR = "kcui_progress_bar"
local DEFAULT_PROGRESS = "page"
local TIMED_PROGRESS = "chapter_time"
local DEFAULT_POSITION = "percentage"
local CHARGING_RECHECK = 5
local PROGRESS_OPTIONS = {
    { id = "chapter_time", text = _("Time left in chapter"), timed = true },
    { id = "book_time", text = _("Time left in book"), timed = true },
    { id = "page", text = _("Page number") },
}
local POSITION_OPTIONS = {
    { id = "percentage", text = _("Percentage") },
    { id = "page", text = _("Page number") },
}

local TopBar = {}

local function textItem(face, text_func)
    local widget = TextWidget:new{ text = "", face = face, fgcolor = Blitbuffer.Color8(0x40) }
    return {
        widget = widget,
        update = function() widget:setText(text_func()) end,
    }
end

local function clock(face)
    return textItem(face, function()
        return Dates.time(os.time())
    end)
end

local BatteryIcon = Widget:extend{
    height = nil,
    capacity = 0,
    charging = false,
}

function BatteryIcon:init()
    local h = self.height
    self.width = self.width or math.floor(h * 302 / 151 + 0.5)
    self.outline = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/statusbar/Battery.png",
        width = self.width,
        height = h,
        alpha = true,
    }
    local bolt_w = math.floor(197 * self.width / 302 + 0.5)
    self.charging_icon = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/statusbar/charging-bolt.svg",
        width = bolt_w,
        height = math.max(1, math.floor(bolt_w * 60 / 212 + 0.5)),
        alpha = true,
    }
end

function BatteryIcon:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function BatteryIcon:paintTo(bb, x, y)
    y = y + (self.nudge or 0)
    local h = self.height
    self.outline:paintTo(bb, x, y)
    local k = h / 151
    local kx = self.width / 302
    if self.charging then
        local bolt = self.charging_icon:getSize()
        local inner_x = x + math.floor(19 * kx + 0.5)
        local inner_w = math.floor(235 * kx + 0.5)
        local inner_y = y + math.floor(19 * k + 0.5)
        local inner_h = math.floor(113 * k + 0.5)
        self.charging_icon:paintTo(bb, inner_x + math.floor((inner_w - bolt.w) / 2), inner_y + math.floor((inner_h - bolt.h) / 2))
        return
    end
    if self.low then
        local inner_x = x + math.floor(19 * kx + 0.5)
        local inner_w = math.floor(235 * kx + 0.5)
        local inner_y = y + math.floor(19 * k + 0.5)
        local inner_h = math.floor(113 * k + 0.5)
        local bar_w = math.max(2, math.floor(22 * kx + 0.5) - 1)
        local cx = inner_x + math.floor((inner_w - bar_w) / 2)
        local top = inner_y + math.floor(inner_h * 0.14) + 1
        local bar_h = math.floor(inner_h * 0.48)
        local dot = bar_w
        bb:paintRect(cx, top, bar_w, bar_h, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx, top + bar_h + math.floor(inner_h * 0.1) + 1, bar_w, dot, Blitbuffer.COLOR_BLACK)
        return
    end
    local inset_x = math.floor(38 * kx + 0.5)
    local inset_y = math.floor(38 * k + 0.5)
    local max_w = math.floor(197 * kx + 0.5)
    local fill_w = math.floor(max_w * math.min(100, math.max(0, self.capacity)) / 100)
    if fill_w > 0 then
        bb:paintRect(x + inset_x, y + inset_y, fill_w, h - 2 * inset_y, Blitbuffer.COLOR_BLACK)
    end
end

function BatteryIcon:free()
    self.outline:free()
    self.charging_icon:free()
end

local function localSendRunning(ui)
    local localsend = ui and (ui.localsend or ui.LocalSend)
    if not localsend then return false end
    local ok, on = pcall(localsend.isRunning, localsend)
    return ok and on == true
end

local function status(face, hide_network, color, ui, hide_localsend)
    local text = TextWidget:new{ text = "", face = face, fgcolor = color or Blitbuffer.Color8(0x40) }
    local text_h = text:getSize().h
    local wifi_size = math.floor(text_h * 0.95)
    local wifi = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/wifi-three.svg", width = wifi_size, height = wifi_size, alpha = true }
    local airplane = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/status/AirplaneMode.svg", width = wifi_size, height = wifi_size, alpha = true }
    local localsend_size = math.floor(wifi_size * 0.66)
    local localsend = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/status/LocalSend.svg", width = localsend_size, height = localsend_size, alpha = true }
    local icon = BatteryIcon:new{ height = U(14), width = U(27.4), nudge = U(0.56) }
    local widget = HorizontalGroup:new{ align = "center" }
    return {
        widget = widget,
        update = function(charging)
            local powerd = Device:getPowerDevice()
            local has_battery = Device:hasBattery()
            local capacity = has_battery and powerd:getCapacity() or 0
            if charging == nil then
                charging = powerd:isCharging()
            end
            text:setText(has_battery and capacity .. "%" or "")
            icon.capacity = capacity
            icon.charging = has_battery and charging
            icon.low = has_battery and not icon.charging and capacity <= 10
            widget:clear()
            if not hide_network and not hide_localsend and localSendRunning(ui) then
                table.insert(widget, localsend)
                table.insert(widget, HorizontalSpan:new{ width = Size.padding.large })
            end
            local network_icon = not hide_network and (Airplane.isOn() and airplane or (NetworkMgr:isWifiOn() and wifi))
            if network_icon then
                table.insert(widget, network_icon)
                table.insert(widget, HorizontalSpan:new{ width = Size.padding.large })
            end
            table.insert(widget, text)
            if has_battery then
                table.insert(widget, HorizontalSpan:new{ width = Size.padding.small })
                table.insert(widget, icon)
            end
            widget:resetLayout()
        end,
    }
end

local function row(items, gap)
    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = gap })
        end
        table.insert(group, item.widget)
    end
    return group
end

local function keepCurrent(bar, window, update)
    local scheduled, painted = false, false
    local tick
    local function redraw(charging)
        update(charging)
        UIManager:setDirty(window(), "ui", bar.dimen)
    end
    local function recheck()
        redraw()
    end
    local function chargingChanged(charging)
        redraw(charging)
        UIManager:unschedule(recheck)
        UIManager:scheduleIn(CHARGING_RECHECK, recheck)
    end
    local function schedule()
        scheduled = true
        UIManager:scheduleIn(60 - os.date("*t").sec, tick)
    end
    tick = function()
        scheduled = false
        if not painted then return end
        painted = false
        redraw()
        schedule()
    end
    function bar:onCharging()
        chargingChanged(true)
    end
    function bar:onNotCharging()
        chargingChanged(false)
    end
    local paintTo = bar.paintTo
    function bar:paintTo(bb, x, y)
        painted = true
        if not scheduled then
            update()
            schedule()
        end
        return paintTo(self, bb, x, y)
    end
    function bar:onResume()
        UIManager:unschedule(tick)
        painted = true
        tick()
    end
    function bar:onCloseWidget()
        UIManager:unschedule(tick)
        UIManager:unschedule(recheck)
        scheduled = false
    end
    update()
    schedule()
end

function TopBar.new(ui, window, no_chevron, hide_network, hide_localsend)
    local w = Screen:getWidth()
    local center_y = U(24.07)
    local h = U(44.78)
    local left_pad = U(21.27)
    local right_pad = U(17.91)
    local pad = Size.padding.large
    local face = U.face("cfont", 13)

    local left_items = { clock(face) }
    local right_items = { status(face, hide_network, nil, ui, hide_localsend) }
    local all_items = {}
    for _i, item in ipairs(left_items) do table.insert(all_items, item) end
    for _i, item in ipairs(right_items) do table.insert(all_items, item) end

    local left = row(left_items, pad)
    local right = row(right_items, pad)
    local chevron_w = U(63.81)
    local chevron_h = math.floor(chevron_w * 17 / 132)
    local chevron = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/statusbar/chevron.svg",
        width = chevron_w,
        height = chevron_h,
        alpha = true,
    }
    chevron.overlap_offset = { math.floor((w - chevron_w) / 2), center_y - U(7.28) - math.floor(chevron_h / 2) }

    local bar = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        chevron_area = Geom:new{ x = math.floor(w / 2) - U(120.06), y = 0, w = U(240.11), h = h },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            no_chevron and OverlapGroup:new{
                dimen = Geom:new{ w = w, h = h },
                left,
                right,
            } or OverlapGroup:new{
                dimen = Geom:new{ w = w, h = h },
                left,
                chevron,
                right,
            },
        },
    }
    bar.ges_events = {
        TapMenu = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return Geom:new{
                        x = bar.dimen.x + bar.chevron_area.x,
                        y = bar.dimen.y,
                        w = bar.chevron_area.w,
                        h = bar.chevron_area.h,
                    }
                end,
            },
        },
    }

    local function update(charging)
        for _i, item in ipairs(all_items) do
            item.update(charging)
        end
        left:resetLayout()
        right:resetLayout()
        left.overlap_offset = { left_pad, center_y - math.floor(left:getSize().h / 2) }
        right.overlap_offset = { w - right_pad - right:getSize().w, center_y - math.floor(right:getSize().h / 2) }
    end

    local function refresh()
        update()
        UIManager:setDirty(window(), "ui", bar.dimen)
    end

    function bar:onTapMenu()
        ui.menu:onShowMenu()
        return true
    end

    bar.onNetworkConnected = refresh
    bar.onNetworkDisconnected = refresh
    bar.onLocalSendChanged = refresh

    keepCurrent(bar, window, update)
    return bar
end

local ExpandedHeader = Widget:extend{
    width = nil,
    height = nil,
}

function ExpandedHeader:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local function capOffset(widget, face)
    return widget:getBaseline() - math.floor(face.size * 0.667 + 0.5)
end

function ExpandedHeader:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    self.title:paintTo(bb, x + self.left, y + self.title_cap_top - capOffset(self.title, self.title_face))
    local line_top = y + self.when_cap_top
    local tx = x + self.left
    self.when:paintTo(bb, tx, line_top - capOffset(self.when, self.when_face))
    local cap_line = math.floor(self.when_face.size * 0.667 + 0.5)
    local dot = U(4.4)
    local dot_x = tx + self.when:getSize().w + U(8.8)
    bb:paintRoundedRect(dot_x, line_top + math.floor((cap_line - dot) / 2), dot, dot, Blitbuffer.COLOR_BLACK, math.floor(dot / 2))
    self.date:paintTo(bb, dot_x + dot + U(9.5), line_top - capOffset(self.date, self.when_face))
    local battery = self.battery
    local bw = battery:getSize().w
    local bx = x + self.width - self.right - bw
    battery:paintTo(bb, bx, y + self.battery_top)
    local pw = self.pct:getSize().w
    self.pct:paintTo(bb, bx - self.pct_gap - pw, y + self.pct_cap_top - capOffset(self.pct, self.when_face))
    local network = Airplane.isOn() and self.airplane or (NetworkMgr:isWifiOn() and self.wifi)
    if network then
        local size = network:getSize()
        local cap = math.floor(self.when_face.size * 0.667 + 0.5)
        network:paintTo(bb, bx - self.pct_gap - pw - self.pct_gap - size.w, y + self.pct_cap_top + math.floor((cap - size.h) / 2))
    end
end

function TopBar.expanded(ui, window)
    local w = Screen:getWidth()
    local black = Blitbuffer.COLOR_BLACK
    local title_face = U.face("cfont", 19)
    local face = U.face("cfont", 17)
    local header = ExpandedHeader:new{
        width = w,
        title_face = title_face,
        when_face = face,
        left = U(17.4),
        right = U(17.9),
        pct_gap = U(7.7),
        title_cap_top = U(19.9),
        when_cap_top = U(47.2),
        pct_cap_top = U(18.9),
        battery_top = U(17.9),
        height = U(80),
    }
    header.title = TextWidget:new{
        text = G_reader_settings:readSetting("kcui_device_name") or "KOReader",
        face = title_face,
        bold = true,
        fgcolor = black,
    }
    header.when = TextWidget:new{ text = "", face = face, fgcolor = black }
    header.date = TextWidget:new{ text = "", face = face, fgcolor = black }
    header.pct = TextWidget:new{ text = "", face = face, fgcolor = black }
    header.battery = BatteryIcon:new{ height = U(14), width = U(27.4) }
    local network_size = U(17)
    header.wifi = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/wifi-three.svg", width = network_size, height = network_size, alpha = true }
    header.airplane = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/status/AirplaneMode.svg", width = network_size, height = network_size, alpha = true }
    local bar = InputContainer:new{
        dimen = Geom:new{ w = w, h = header.height },
        header,
    }
    local function update(charging)
        local now = os.time()
        local date = Dates.day(now)
        header.when:setText(Dates.time(now))
        header.date:setText(date)
        local powerd = Device:getPowerDevice()
        local capacity = Device:hasBattery() and powerd:getCapacity() or 0
        if charging == nil then
            charging = powerd:isCharging()
        end
        header.pct:setText(Device:hasBattery() and capacity .. "%" or "")
        header.battery.capacity = capacity
        header.battery.charging = Device:hasBattery() and charging
        header.battery.low = not header.battery.charging and capacity <= 10
    end
    keepCurrent(bar, window, update)
    return bar
end

local More = {}

function More.tracksReadingTime(ui)
    local statistics = ui and ui.statistics
    return statistics ~= nil and statistics.settings ~= nil and statistics.settings.is_enabled == true
end

function More.readingPosition()
    local saved = G_reader_settings:readSetting(POSITION)
    if saved == "none" then
        return saved
    end
    for _i, option in ipairs(POSITION_OPTIONS) do
        if option.id == saved then
            return saved
        end
    end
    return DEFAULT_POSITION
end

function More.readingProgress(ui)
    local saved = G_reader_settings:readSetting(PROGRESS)
    if saved == "none" then
        return saved
    end
    local tracking = More.tracksReadingTime(ui)
    for _i, option in ipairs(PROGRESS_OPTIONS) do
        if option.id == saved and (tracking or not option.timed) then
            return saved
        end
    end
    if tracking then
        return TIMED_PROGRESS
    end
    return More.readingPosition() == "page" and "none" or DEFAULT_PROGRESS
end

function More.progressBarShown()
    return G_reader_settings:nilOrTrue(PROGRESS_BAR)
end

function More.dropdown(area, buttons, keep_open)
    local notch = U(Common.Paint.NOTCH)
    UIManager:show(Toolbar.Dropdown:new{
        buttons = buttons,
        anchor_right = Screen:getWidth() - U(8),
        anchor_top = area.y + math.floor(area.h / 2) + U(18) + notch,
        notch_x = area.x + math.floor(area.w / 2),
        close_first = not keep_open,
        keep_open = keep_open,
    })
end

function More.showProgress(ui, area)
    local tracking = More.tracksReadingTime(ui)
    local rows = {}
    local function choice(option, current, key, other, other_key)
        return { {
            text = option.text,
            enabled = tracking or not option.timed,
            checked_func = function() return current() == option.id end,
            callback = function()
                local value = current() == option.id and "none" or option.id
                G_reader_settings:saveSetting(key, value)
                if value == "page" and other() == "page" then
                    G_reader_settings:saveSetting(other_key, "none")
                end
                UIManager:setDirty("all", "ui")
            end,
        } }
    end
    local function progress() return More.readingProgress(ui) end
    table.insert(rows, { { text = _("Bottom left"), heading = true } })
    for _i, option in ipairs(PROGRESS_OPTIONS) do
        table.insert(rows, choice(option, progress, PROGRESS, More.readingPosition, POSITION))
    end
    table.insert(rows, {})
    table.insert(rows, { { text = _("Bottom right"), heading = true } })
    for _i, option in ipairs(POSITION_OPTIONS) do
        table.insert(rows, choice(option, More.readingPosition, POSITION, progress, PROGRESS))
    end
    table.insert(rows, {})
    table.insert(rows, { {
        text = _("Progress bar"),
        checked_func = More.progressBarShown,
        callback = function()
            G_reader_settings:flipNilOrTrue(PROGRESS_BAR)
            UIManager:setDirty("all", "ui")
        end,
    } })
    More.dropdown(area, rows, true)
end

function More.resetBook(ui)
    local file = ui.document.file
    UIManager:show(ConfirmBox:new{
        text = _("Reset this book?") .. "\n\n"
            .. _("Its reading progress, bookmarks, highlights, notes and page settings will be permanently deleted, and the book will close."),
        ok_text = _("Reset"),
        ok_callback = function()
            Common.Navigation.toLibrary(ui, function(fm)
                DocSettings:open(file):purge(nil, { doc_settings = true })
                BookList.setBookInfoCacheProperty(file, "been_opened", false)
                ReadHistory:fileSettingsPurged(file)
                fm.file_chooser:refreshPath()
            end)
        end,
    })
end

function More.disableTouch()
    UIManager:show(ConfirmBox:new{
        text = _("Turn off the touchscreen?") .. "\n\n"
            .. _("Taps and swipes will be ignored, so you can only turn pages with the page turn buttons.") .. "\n\n"
            .. _("To turn the touchscreen back on, put your device to sleep and wake it up again."),
        ok_text = _("Turn off"),
        ok_callback = function() UIManager:setIgnoreTouchInput(true) end,
    })
end

function More.show(ui, panel, area)
    local function leave()
        UIManager:close(panel)
    end
    local function action(text, run)
        return { { text = text, callback = function()
            leave()
            run()
        end } }
    end
    local buttons = {
        filemanagerutil.genStatusButtonsRow(ui.doc_settings, leave),
        {},
        { ui.collections:genAddToCollectionButton(ui.document.file, leave) },
        action(_("Book information"), function() ui.bookinfo:onShowBookInfo() end),
        action(_("Book description"), function() ui.bookinfo:onShowBookDescription() end),
        action(_("Book cover"), function() ui.bookinfo:onShowBookCover() end),
        action(_("Reset book"), function() More.resetBook(ui) end),
        {},
    }
    table.insert(buttons, { { text = _("Bottom of page"), chevron = true, callback = function() More.showProgress(ui, area) end } })
    if Device:hasKeys() then
        table.insert(buttons, action(_("Turn off touchscreen"), More.disableTouch))
    end
    More.dropdown(area, buttons)
end

local READER_TOOLS = {
    { icon = "aa", run = function(ui) require("kcui/themes").show(ui) end },
    { icon = "contents", run = function(ui) require("kcui/goto").show(ui) end },
    {
        icon = "bookmarks",
        keep_open = true,
        run = function(ui, panel, area)
            require("kcui/goto").Bookmarks.show(ui, area, function() UIManager:close(panel) end)
        end,
    },
    { icon = "search", run = function(ui) ui:handleEvent(Event:new("ShowFulltextSearchInput")) end },
    { icon = "more", keep_open = true, run = More.show },
}

local READER_ICON = 22.81

local function readerTools(w, center_y)
    local size = U(READER_ICON)
    local spacing = U(48.52)
    local right_center = w - U(24.94)
    local tools = {}
    for i, tool in ipairs(READER_TOOLS) do
        local cx = right_center - (#READER_TOOLS - i) * spacing
        table.insert(tools, {
            run = tool.run,
            keep_open = tool.keep_open,
            area = Geom:new{
                x = cx - math.floor(spacing / 2),
                y = center_y - math.floor(spacing / 2),
                w = spacing,
                h = spacing,
            },
            widget = ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. "/reader/" .. tool.icon .. ".svg",
                width = size,
                height = size,
                alpha = true,
                overlap_offset = { cx - math.floor(size / 2), center_y - math.floor(size / 2) },
            },
        })
    end
    return tools
end

function TopBar.home(ui, window, tap_menu)
    local w = Screen:getWidth()
    local bar = TopBar.new(ui, window, not tap_menu, false, not tap_menu)
    local bar_h = bar.dimen.h
    local row_h = U(Toolbar.BACK_ROW_HEIGHT)
    local pad = U(21.27)
    local icon = U(READER_ICON)
    local group = HorizontalGroup:new{
        align = "center",
        ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. "/reader/back.svg",
            width = icon,
            height = icon,
            alpha = true,
        },
        HorizontalSpan:new{ width = U(13.6) },
    }
    local label = TextWidget:new{
        text = _("Home"),
        face = U.face("cfont", 16),
    }
    table.insert(group, label)
    local border = Toolbar.border()
    local group_x = U(21.98) - math.floor(icon / 2)
    local group_size = group:getSize()
    local group_y = bar_h + row_h - U(Toolbar.BACK_ROW_CENTER) - math.floor(group_size.h / 2)
    group.overlap_offset = { group_x, group_y }
    local label_baseline = group_y + math.floor((group_size.h - label:getSize().h) / 2) + label:getBaseline()
    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bar_h + row_h },
        bar,
        group,
    }
    if tap_menu then
        table.insert(layout, LineWidget:new{
            dimen = Geom:new{ w = w, h = border },
            background = Gray.divider,
            overlap_offset = { 0, bar_h + row_h - border },
        })
    end
    local tools = tap_menu and readerTools(w, bar_h + row_h - U(Toolbar.BACK_ROW_CENTER)) or {}
    for _i, tool in ipairs(tools) do
        table.insert(layout, tool.widget)
    end
    local header = InputContainer:new{
        dimen = Geom:new{ w = w, h = bar_h + row_h },
        home_area = Geom:new{ x = 0, y = bar_h, w = group_x + group_size.w + U(15), h = row_h },
        chevron_area = tap_menu and bar.chevron_area or nil,
        label_gap = bar_h + row_h - border - label_baseline,
        tools = tools,
        layout,
    }
    function header.goHome()
        Common.Navigation.toBrowser(ui)
    end
    function header:onCloseWidget()
        bar:onCloseWidget()
    end
    return header
end

local AutoBrightness = {}

local SERVICE = "com.lab126.powerd"
local PROPERTY = "flAuto"

local function withLipc(fn)
    local ok, lipc = pcall(require, "liblipclua")
    if not ok or not lipc then return nil end
    local handle = lipc.init("com.github.koreader.kcui")
    if not handle then return nil end
    local done, result = pcall(fn, handle)
    handle:close()
    if done then return result end
end

local function read()
    return withLipc(function(handle) return handle:get_int_property(SERVICE, PROPERTY) end)
end

function AutoBrightness.isSupported()
    return Device:isKindle() and Device:hasLightSensor() and read() ~= nil
end

function AutoBrightness.isOn()
    return read() == 1
end

function AutoBrightness.set(on)
    withLipc(function(handle) handle:set_int_property(SERVICE, PROPERTY, on and 1 or 0) end)
end

local function lightSliders(ui)
    local powerd = Device:getPowerDevice()
    local sliders = {}
    if Device:hasFrontlight() then
        table.insert(sliders, {
            label = _("Brightness"),
            auto = AutoBrightness.isSupported(),
            min = powerd.fl_min,
            max = powerd.fl_max,
            get = function() return powerd:frontlightIntensity() end,
            set = function(v)
                if v <= powerd.fl_min then
                    powerd:turnOffFrontlight()
                else
                    powerd:setIntensity(v)
                end
                powerd:updateResumeFrontlightState()
            end,
            sync = function()
                local level = powerd:frontlightIntensityHW()
                if type(level) ~= "number" or level == powerd.fl_intensity then
                    return false
                end
                powerd.fl_intensity = level
                powerd.is_fl_on = level > powerd.fl_min
                return true
            end,
        })
    end
    if Device:hasNaturalLight() then
        table.insert(sliders, {
            schedule = (ui and ui.autowarmth) and true or false,
            label = _("Warmth"),
            min = powerd.fl_warmth_min,
            max = powerd.fl_warmth_max,
            get = function() return powerd:toNativeWarmth(powerd:frontlightWarmth()) end,
            set = function(v)
                powerd:setWarmth(powerd:fromNativeWarmth(v))
                require("kcui/warmth").pauseSchedule(ui)
            end,
        })
    end
    return sliders
end

local function capTop(widget, face, cap_center)
    local cap = math.floor(face.size * 0.667 + 0.5)
    return cap_center - math.floor(cap / 2) - (widget:getBaseline() - cap)
end

local function normalize(text)
    return ((text or ""):lower():gsub("[%s%p]", ""))
end

local function firstChapter(ui)
    local book = normalize(ui.doc_props and ui.doc_props.display_title)
    for _i, entry in ipairs(ui.toc.toc or {}) do
        local key = normalize(entry.title)
        if key ~= "" and key ~= book then
            return ui.toc:cleanUpTocTitle(entry.title)
        end
    end
    return ""
end

local function chapterTitle(ui, page)
    local toc = ui.toc
    if not toc then return "" end
    local title = toc:getTocTitleByPage(page)
    local key = normalize(title)
    if key == "" or key == normalize(ui.doc_props and ui.doc_props.display_title) then
        return firstChapter(ui)
    end
    return title
end

local function readingFooter(ui)
    local w, h = Screen:getWidth(), Screen:getHeight()
    local footer = { height = U(147.5), line = U.ceil(1) }
    footer.y = h - footer.height
    local page = ui:getCurrentPage()
    local total = ui.document:getPageCount()
    footer.chapter_face = U.face("cfont", 19)
    footer.info_face = U.face("cfont", 15)
    footer.chapter = TextWidget:new{
        text = chapterTitle(ui, page),
        face = footer.chapter_face,
        max_width = w - 2 * U(21.27),
    }
    footer.info = TextWidget:new{
        text = T(_("Page %1 of %2 | %3%"), page, total, math.floor(page / total * 100)),
        face = footer.info_face,
    }
    local button_w, button_h, icon = U(74), U(29), U(17)
    local specs = {
        { "/panel/page-flip.svg", "ShowSkimtoDialog" },
        { "/grid.svg", "ShowPageBrowser" },
        { "/toolbar/menu.svg", "ShowBookMap" },
    }
    local left = math.floor((w - #specs * button_w) / 2)
    footer.border = U.ceil(1.5)
    footer.buttons = {}
    for i, spec in ipairs(specs) do
        table.insert(footer.buttons, {
            event = spec[2],
            icon = ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. spec[1],
                width = icon,
                height = icon,
                alpha = true,
            },
            rect = Geom:new{ x = left + (i - 1) * button_w, y = footer.y + U(103), w = button_w, h = button_h },
        })
    end
    return footer
end

local function paintFooter(bb, footer, w)
    bb:paintRect(0, footer.y, w, footer.height, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, footer.y, w, footer.line, Blitbuffer.COLOR_BLACK)
    local chapter, info = footer.chapter, footer.info
    chapter:paintTo(bb, math.floor((w - chapter:getSize().w) / 2), footer.y + capTop(chapter, footer.chapter_face, U(34)))
    info:paintTo(bb, math.floor((w - info:getSize().w) / 2), footer.y + capTop(info, footer.info_face, U(66)))
    for i, button in ipairs(footer.buttons) do
        local r = button.rect
        local x = i == 1 and r.x or r.x - footer.border
        local bw = i == 1 and r.w or r.w + footer.border
        bb:paintBorder(x, r.y, bw, r.h, footer.border, Blitbuffer.COLOR_BLACK)
        local size = button.icon:getSize()
        button.icon:paintTo(bb, r.x + math.floor((r.w - size.w) / 2), r.y + math.floor((r.h - size.h) / 2))
    end
end

local Panel = InputContainer:extend{
    ui = nil,
    kind = "quick",
    on_settings = nil,
    modal = false,
}

function Panel:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    if self.kind == "quick" then
        local in_book = self.ui and self.ui.document ~= nil
        self.top = (in_book and TopBar.home or TopBar.expanded)(self.ui, function() return self end)
    else
        self.top = TopBar.home(self.ui, function() return self end, true)
    end
    local top_h = self.top.dimen.h
    if self.kind == "quick" then
        local w = self.dimen.w
        local collections = self.ui and self.ui.collections
        local half = math.floor(U(199.4) * (1 + U.fit()) / 2)
        local shift = top_h - U(80)
        local row1_top, row1_label = U(94) + shift, U(157) + shift
        local row2_top, row2_label = U(201.6) + shift, U(265) + shift
        local cx = math.floor(w / 2)
        local localsend_tile
        local localsend = self.ui and (self.ui.localsend or self.ui.LocalSend)
        if localsend then
            local function running()
                local ok, on = pcall(localsend.isRunning, localsend)
                return ok and on
            end
            localsend_tile = {
                icon = function() return running() and "LocalSend-On.svg" or "LocalSend-Off.svg" end,
                label = function() return running() and _("On") or _("Off") end,
                toggle = true,
                run = function()
                    localsend:onToggleLocalSend()
                    for _i, delay in ipairs({ 1, 3 }) do
                        UIManager:scheduleIn(delay, function()
                            UIManager:broadcastEvent(Event:new("LocalSendChanged"))
                            if not UIManager:isWidgetShown(self) then return end
                            self:buildActions()
                            UIManager:setDirty(self, function()
                                return "ui", Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.panel_h }
                            end)
                        end)
                    end
                end,
            }
        end
        local bluetooth_tile
        local bluetooth = self.ui and (self.ui.bluetooth or self.ui.Bluetooth)
        if bluetooth then
            local connected
            local function refreshBluetooth()
                local ok, on = pcall(bluetooth.isBluetoothOn, bluetooth)
                connected = nil
                if not (ok and on) then return end
                pcall(function()
                    if bluetooth:isMTKDevice() then
                        for _i, dev in ipairs(bluetooth:getPairedDevices()) do
                            if dev.connected then
                                connected = dev.name
                                break
                            end
                        end
                    else
                        local mac, name = bluetooth:getSavedDeviceMAC()
                        if mac and bluetooth:executeCommandWithTimeout("bluetoothctl info " .. mac, 2):match("Connected:%s*yes") then
                            connected = name or mac
                        end
                    end
                end)
            end
            refreshBluetooth()
            bluetooth_tile = {
                icon = function() return bluetooth.is_bluetooth_on and "Bluetooth-On.svg" or "Bluetooth-Off.svg" end,
                label = function()
                    if not bluetooth.is_bluetooth_on then return _("Off") end
                    return connected or _("On")
                end,
                toggle = true,
                run = function()
                    local switch = bluetooth.is_bluetooth_on and bluetooth.onBluetoothOff or bluetooth.onBluetoothOn
                    if switch then
                        switch(bluetooth)
                    end
                    refreshBluetooth()
                end,
            }
        end
        local dark_mode = {
            icon = function() return G_reader_settings:isTrue("night_mode") and "Darkmode-On.svg" or "Darkmode-Off.svg" end,
            label = _("Dark Mode"),
            toggle = true,
            run = function() UIManager:broadcastEvent(require("ui/event"):new("ToggleNightMode")) end,
        }
        local collections_action = {
            icon = "Collections.svg",
            label = _("Collections"),
            run = function() if collections then collections:onShowCollList() end end,
        }
        local settings = {
            icon = "Settings-Off.svg",
            label = _("All Settings"),
            run = function() if self.on_settings then self.on_settings() end end,
        }
        local actions = {}
        if localsend_tile then table.insert(actions, localsend_tile) end
        if bluetooth_tile then table.insert(actions, bluetooth_tile) end
        local rows
        if #actions == 2 then
            for _i, tile in ipairs({ dark_mode, collections_action, settings }) do table.insert(actions, tile) end
            rows = { 3, 2 }
        else
            for _i, tile in ipairs({ collections_action, dark_mode, settings }) do table.insert(actions, tile) end
            rows = { #actions }
        end
        local index = 0
        for r, count in ipairs(rows) do
            local top, label_top = r == 1 and row1_top or row2_top, r == 1 and row1_label or row2_label
            local left, right = cx - half, cx + half
            if count == 2 then
                left, right = cx - math.floor(half / 2), cx + math.floor(half / 2)
            end
            local spacing = (right - left) / (count - 1)
            for i = 1, count do
                index = index + 1
                local action = actions[index]
                action.cx = left + math.floor(spacing * (i - 1) + 0.5)
                action.top, action.label_top = top, label_top
                action.max_w = math.min(U(170), math.floor(spacing) - U(8))
            end
        end
        self.actions = actions
        self.action_size = U(47.3)
        self.action_face = U.face("cfont", 17)
        self:buildActions()
        self.divider_y = (#rows == 1 and U(308.3) - (row2_top - row1_top) or U(308.3)) + shift
        self.sliders = lightSliders(self.ui)
        local cy = self.divider_y + U(30.3)
        local margin = U(32.5)
        local mark = U(16)
        self.slider_margin = margin
        for _i, slider in ipairs(self.sliders) do
            slider.label_cy = cy
            slider.value_cy = cy + U(29.5)
            slider.track_cy = slider.value_cy + U(29.9)
            slider.minus_x = margin
            slider.plus_x = w - margin - mark
            slider.x0 = margin + mark + U(21.3)
            slider.x1 = slider.plus_x - U(20.7)
            slider.label_widget = TextWidget:new{ text = slider.label, face = U.face("cfont", 17) }
            if slider.auto then
                slider.auto_on = AutoBrightness.isOn()
                slider.auto_widget = TextWidget:new{ text = _("Auto Brightness"), face = U.face("cfont", 17) }
                slider.auto_box = U(23.26)
                slider.auto_box_x = w - U(29.05) - slider.auto_box
                slider.auto_text_right = slider.auto_box_x - U(13.15)
            end
            if slider.schedule then
                local on = (G_reader_settings:readSetting("autowarmth_activate") or 0) ~= 0
                slider.schedule_widget = TextWidget:new{
                    text = on and _("Schedule: on") or _("Schedule: off"),
                    face = U.face("cfont", 17),
                }
                slider.schedule_chevron = ImageWidget:new{
                    original_in_nightmode = false,
                    file = ICONS .. "/quicksettings/schedule-chevron.svg",
                    width = U(8.3),
                    height = U(15.7),
                    alpha = true,
                }
                slider.schedule_right = w - U(72)
                slider.chevron_x = w - U(38.3) - slider.schedule_chevron:getSize().w
            end
            cy = slider.track_cy + U(60.2)
        end
        local last = self.sliders[#self.sliders]
        self.chevron_cy = (last and last.track_cy or self.divider_y) + U(61)
        self.chevron_w = U(53.7)
        self.chevron = ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. "/statusbar/chevron-up.svg",
            width = self.chevron_w,
            height = math.floor(self.chevron_w * 23 / 111),
            alpha = true,
        }
        self.bottom_line = U(4.4)
        self.panel_h = self.chevron_cy + U(24.6) + self.bottom_line
    else
        local pad = U(21.27)
        local gap = self.top.label_gap + U(6)
        local face = U.face("cfont", 16)
        local cap = math.floor(face.size * 0.667 + 0.5)
        self.title = TextWidget:new{
            text = self.ui.doc_props and self.ui.doc_props.display_title or "",
            face = face,
            bold = true,
            max_width = w - 2 * pad,
        }
        self.title_x = pad
        self.title_y = top_h + gap - (self.title:getBaseline() - cap)
        self.bottom_line = U.ceil(1)
        self.panel_h = top_h + 2 * gap + cap + self.bottom_line
        if self.ui and self.ui.document then
            self.footer = readingFooter(self.ui)
        end
    end
    self.ges_events = {
        TapPanel = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipePanel = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        PanPanel = { GestureRange:new{ ges = "pan", range = self.dimen } },
        HoldPanel = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function Panel:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

local function capMiddle(widget, face, cy)
    local cap = math.floor(face.size * 0.7 + 0.5)
    return cy - (widget:getBaseline() - math.floor(cap / 2))
end

function Panel:paintSlider(bb, slider)
    local black = Blitbuffer.COLOR_BLACK
    local value = slider.get()
    local range = math.max(1, slider.max - slider.min)
    local frac = math.max(0, math.min(1, (value - slider.min) / range))
    local d = U(33)
    local knob_x = slider.x0 + math.floor(d / 2) + math.floor(frac * (slider.x1 - slider.x0 - d))
    local label = slider.label_widget
    label:paintTo(bb, self.slider_margin, capMiddle(label, label.face, slider.label_cy))
    if slider.auto_widget then
        local aw = slider.auto_widget
        aw:paintTo(bb, slider.auto_text_right - aw:getSize().w, capMiddle(aw, aw.face, slider.label_cy))
        local box = ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. (slider.auto_on and "/panel/checkbox-on.svg" or "/panel/checkbox-off.svg"),
            width = slider.auto_box,
            height = slider.auto_box,
            alpha = true,
        }
        box:paintTo(bb, slider.auto_box_x, slider.label_cy - math.floor(slider.auto_box / 2))
        box:free()
    end
    if slider.schedule_widget then
        local sw = slider.schedule_widget
        sw:paintTo(bb, slider.schedule_right - sw:getSize().w, capMiddle(sw, sw.face, slider.label_cy))
        local ch = slider.schedule_chevron
        ch:paintTo(bb, slider.chevron_x, slider.label_cy - U(1.2) - math.floor(ch:getSize().h / 2))
    end
    local mark = U(16)
    local stroke = U(1.9)
    local ty = slider.track_cy
    bb:paintRect(slider.minus_x, ty - math.floor(stroke / 2), mark, stroke, black)
    bb:paintRect(slider.plus_x, ty - math.floor(stroke / 2), mark, stroke, black)
    bb:paintRect(slider.plus_x + math.floor((mark - stroke) / 2), ty - math.floor(mark / 2), stroke, mark, black)
    local thin = U(1.7)
    bb:paintRect(slider.x0, ty - math.floor(thin / 2), slider.x1 - slider.x0, thin, black)
    local thick = U(6.7)
    if knob_x > slider.x0 then
        bb:paintRoundedRect(slider.x0, ty - math.floor(thick / 2), knob_x - slider.x0, thick, black, math.floor(thick / 2))
    end
    local border = U(1.12)
    bb:paintRoundedRect(knob_x - math.floor(d / 2), ty - math.floor(d / 2), d, d, black, math.floor(d / 2))
    bb:paintRoundedRect(knob_x - math.floor(d / 2) + border, ty - math.floor(d / 2) + border, d - 2 * border, d - 2 * border, Blitbuffer.COLOR_WHITE, math.floor(d / 2) - border)
    local face = U.face("cfont", 13)
    local text = TextWidget:new{ text = tostring(value), face = face }
    text:paintTo(bb, knob_x - math.floor(text:getSize().w / 2), capMiddle(text, face, slider.value_cy))
    text:free()
end

function Panel:sliderAt(pos)
    for _i, slider in ipairs(self.sliders or {}) do
        if math.abs(pos.y - slider.track_cy) <= U(28) then
            return slider
        end
    end
end

function Panel:sliderRegion(slider)
    local top = slider.label_cy - U(20)
    return Geom:new{ x = 0, y = top, w = self.dimen.w, h = slider.track_cy + U(30) - top }
end

function Panel:setSlider(slider, value)
    value = math.max(slider.min, math.min(slider.max, value))
    local manual = slider.auto_on
    if manual then
        slider.auto_on = false
        AutoBrightness.set(false)
    end
    if value ~= slider.get() then
        slider.set(value)
    end
    UIManager:setDirty(self, function()
        return manual and "ui" or "fast", Panel.sliderRegion(self, slider)
    end)
end

function Panel:followAutoBrightness()
    if not UIManager:isWidgetShown(self) then return end
    for _i, slider in ipairs(self.sliders or {}) do
        if slider.auto_on and slider.sync and slider.sync() then
            UIManager:setDirty(self, function()
                return "ui", Panel.sliderRegion(self, slider)
            end)
        end
    end
    self.follow_auto = self.follow_auto or function() self:followAutoBrightness() end
    UIManager:scheduleIn(2, self.follow_auto)
end

function Panel:adjustSlider(slider, x, jump)
    local value
    if x < slider.x0 - U(6) then
        value = jump and slider.min or slider.get() - 1
    elseif x > slider.x1 + U(6) then
        value = jump and slider.max or slider.get() + 1
    elseif jump then
        return false
    else
        value = Panel.valueAt(self, slider, x)
    end
    Panel.setSlider(self, slider, value)
    return true
end
function Panel:valueAt(slider, x)
    local d = U(33)
    local frac = (x - slider.x0 - math.floor(d / 2)) / math.max(1, slider.x1 - slider.x0 - d)
    frac = math.max(0, math.min(1, frac))
    return math.floor(slider.min + frac * (slider.max - slider.min) + 0.5)
end

function Panel:onPanPanel(_ev, ges)
    local slider = self:sliderAt(ges.start_pos or ges.pos)
    if slider then
        self:setSlider(slider, self:valueAt(slider, ges.pos.x))
    end
    return true
end

function Panel:buildActions()
    for _i, action in ipairs(self.actions) do
        local icon = type(action.icon) == "function" and action.icon() or action.icon
        local label = type(action.label) == "function" and action.label() or action.label
        if action.image then action.image:free() end
        for _i, line in ipairs(action.lines or {}) do line:free() end
        action.image = ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. "/quicksettings/" .. icon,
            width = self.action_size,
            height = self.action_size,
            alpha = true,
        }
        local max_w = action.max_w or U(170)
        local face = self.action_face
        local function width(text)
            local widget = TextWidget:new{ text = text, face = face }
            local tw = widget:getSize().w
            widget:free()
            return tw
        end
        local first, rest = label, nil
        if width(label) > max_w then
            local words = {}
            for word in label:gmatch("%S+") do table.insert(words, word) end
            local n = 1
            while n < #words and width(table.concat(words, " ", 1, n + 1)) <= max_w do
                n = n + 1
            end
            if n < #words then
                first, rest = table.concat(words, " ", 1, n), table.concat(words, " ", n + 1)
            end
        end
        action.lines = { TextWidget:new{ text = first, face = self.action_face, max_width = max_w } }
        if rest then
            table.insert(action.lines, TextWidget:new{ text = rest, face = self.action_face, max_width = max_w })
        end
        action.line_h = math.floor(self.action_face.size * 1.3 + 0.5)
        action.x = action.cx - U(80)
        action.w = U(160)
        action.bottom = action.label_top + action.lines[1]:getSize().h + (#action.lines - 1) * action.line_h
    end
end

function Panel:paintTo(bb, x, y)
    local w = self.dimen.w
    bb:paintRect(0, 0, w, self.panel_h, Blitbuffer.COLOR_WHITE)
    self.top:paintTo(bb, 0, 0)
    if self.kind == "quick" then
        Divider.paint(bb, 0, self.divider_y, w)
        for _i, slider in ipairs(self.sliders) do
            self:paintSlider(bb, slider)
        end
        self.chevron:paintTo(bb, math.floor((w - self.chevron:getSize().w) / 2), self.chevron_cy - math.floor(self.chevron:getSize().h / 2))
        for _i, action in ipairs(self.actions) do
            action.image:paintTo(bb, action.cx - math.floor(self.action_size / 2), action.top)
            for i, line in ipairs(action.lines) do
                local offset = line:getBaseline() - math.floor(self.action_face.size * 0.667 + 0.5)
                line:paintTo(bb, action.cx - math.floor(line:getSize().w / 2), action.label_top + (i - 1) * action.line_h - offset)
            end
        end
    else
        self.title:paintTo(bb, self.title_x, self.title_y)
    end
    bb:paintRect(0, self.panel_h - self.bottom_line, w, self.bottom_line, Blitbuffer.COLOR_BLACK)
    if self.footer then
        paintFooter(bb, self.footer, w)
    end
end

function Panel:dirtyRegions(fn)
    fn(Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.panel_h })
    if self.footer then
        fn(Geom:new{ x = 0, y = self.footer.y, w = self.dimen.w, h = self.footer.height })
    end
end

function Panel:toggleAutoBrightness(slider)
    slider.auto_on = not slider.auto_on
    AutoBrightness.set(slider.auto_on)
    local function repaint()
        if not UIManager:isWidgetShown(self) then return end
        UIManager:setDirty(self, function()
            return "ui", Geom:new{ x = 0, y = slider.label_cy - U(20), w = self.dimen.w, h = slider.track_cy + U(30) - slider.label_cy + U(20) }
        end)
    end
    repaint()
    UIManager:scheduleIn(1.5, repaint)
end
function Panel:onHoldPanel(_ev, ges)
    local slider = self:sliderAt(ges.pos)
    return slider ~= nil and self:adjustSlider(slider, ges.pos.x, true)
end
function Panel:onTapPanel(_ev, ges)
    local pos = ges.pos
    if self.footer and pos.y >= self.footer.y then
        for _i, button in ipairs(self.footer.buttons) do
            if button.rect:contains(pos) then
                UIManager:close(self)
                self.ui:handleEvent(Event:new(button.event))
                break
            end
        end
        return true
    end
    if pos.y > self.panel_h then
        UIManager:close(self)
        return true
    end
    for _i, tool in ipairs(self.top.tools or {}) do
        if tool.area:contains(pos) then
            if tool.run then
                if not tool.keep_open then
                    UIManager:close(self)
                end
                tool.run(self.ui, self, tool.area)
            end
            return true
        end
    end
    if self.top.home_area and self.top.home_area:contains(pos) then
        UIManager:close(self)
        self.top.goHome()
        return true
    end
    for _i, sl in ipairs(self.sliders or {}) do
        if sl.schedule_widget and math.abs(pos.y - sl.label_cy) <= U(20)
                and pos.x >= sl.schedule_right - sl.schedule_widget:getSize().w - U(10) then
            UIManager:close(self)
            UIManager:show(require("kcui/warmth"):new{ ui = self.ui })
            return true
        end
    end
    for _i, sl in ipairs(self.sliders or {}) do
        if sl.auto_widget and math.abs(pos.y - sl.label_cy) <= U(20)
                and pos.x >= sl.auto_text_right - sl.auto_widget:getSize().w - U(10) then
            self:toggleAutoBrightness(sl)
            return true
        end
    end
    local slider = self:sliderAt(pos)
    if slider then
        self:adjustSlider(slider, pos.x)
        return true
    end
    if self.kind == "quick" and math.abs(pos.y - self.chevron_cy) <= U(25) then
        UIManager:close(self)
        return true
    end
    if self.kind == "quick" then
        for _i, action in ipairs(self.actions) do
            if pos.x >= action.x and pos.x < action.x + action.w
                    and pos.y >= action.top - U(8) and pos.y <= action.bottom + U(8) then
                if action.toggle then
                    action.run()
                    if not UIManager:isWidgetShown(self) then return true end
                    self:buildActions()
                    UIManager:setDirty(self, function()
                        return "ui", Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.panel_h }
                    end)
                else
                    UIManager:close(self)
                    action.run()
                end
                break
            end
        end
        return true
    end
    if self.top.chevron_area:contains(pos) then
        UIManager:close(self)
        Panel.showQuick(self.ui)
    end
    return true
end

function Panel:onSwipePanel(_ev, ges)
    local opening = self.opening
    self.opening = nil
    if opening and opening.x == ges.pos.x and opening.y == ges.pos.y then
        return true
    end
    if ges.direction == "north" then
        UIManager:close(self)
    elseif ges.direction == "south" and self.kind == "reader" then
        UIManager:close(self)
        Panel.showQuick(self.ui)
    end
    return true
end

function Panel:onShow()
    self:dirtyRegions(function(region)
        UIManager:setDirty(self, function() return "ui", region end)
    end)
    for _i, slider in ipairs(self.sliders or {}) do
        if slider.auto then
            self:followAutoBrightness()
        end
    end
end

function Panel:onResume()
    self.top:handleEvent(Event:new("Resume"))
end

function Panel:onCloseWidget()
    if self.follow_auto then
        UIManager:unschedule(self.follow_auto)
    end
    if self.top.onCloseWidget then
        self.top:onCloseWidget()
    end
    self:dirtyRegions(function(region)
        UIManager:setDirty("all", function() return "ui", region end)
    end)
end

function Panel.showQuick(ui)
    UIManager:show(Panel:new{
        ui = ui,
        kind = "quick",
        on_settings = function()
            ui.menu:onShowMenu()
        end,
    })
end

function Panel.install()
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    if FileManagerMenu._kcui_panel then return end
    FileManagerMenu._kcui_panel = true
    local orig_fm_show = FileManagerMenu.onShowMenu
    FileManagerMenu.onShowMenu = function(menu, tab_index, do_not_show)
        if do_not_show or menu._kcui_bypass then
            return orig_fm_show(menu, tab_index, do_not_show)
        end
        UIManager:show(Panel:new{
            ui = menu.ui,
            kind = "quick",
            on_settings = function()
                menu._kcui_bypass = true
                orig_fm_show(menu, tab_index)
                menu._kcui_bypass = nil
            end,
        })
        return true
    end

    local ReaderMenu = require("apps/reader/modules/readermenu")
    ReaderMenu.onSwipeShowMenu = function(menu, ges)
        if ges.direction == "south" then
            Panel.showQuick(menu.ui)
            menu.ui:handleEvent(Event:new("HandledAsSwipe"))
            return true
        end
    end
    ReaderMenu.onTapShowMenu = function(menu, ges)
        UIManager:show(Panel:new{ ui = menu.ui, kind = "reader", opening = ges and ges.start_pos })
        return true
    end

    local ReaderConfig = require("apps/reader/modules/readerconfig")
    local onSwipeConfig = ReaderConfig.onSwipeShowConfigMenu
    ReaderConfig.onSwipeShowConfigMenu = function(config, ges)
        if config.ui.rolling and config.activation_menu ~= "tap" and ges.direction == "north" then
            config.ui.menu:onTapShowMenu(ges)
            return true
        end
        return onSwipeConfig(config, ges)
    end
end

Panel.TopBar = TopBar
Panel.readingProgress = More.readingProgress
Panel.readingPosition = More.readingPosition
Panel.progressBarShown = More.progressBarShown

return Panel
