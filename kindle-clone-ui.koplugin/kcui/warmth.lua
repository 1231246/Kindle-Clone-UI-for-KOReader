local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local Panel = require("kcui/panel")
local Toolbar = require("kcui/toolbar")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Common = require("kcui/common")
local T = require("ffi/util").template
local Screen = Device.screen
local Divider = Common.Divider
local KindleFonts = Common.Fonts
local TopBar = Panel.TopBar
local U = Common.U

local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/kcui/warmth%.lua$")
local ICONS = ROOT .. "/icons"
local CITIES_FILE = ROOT .. "/data/cities.tsv"
local GRAY = Blitbuffer.Color8(0x40)
local TIME_DEFAULTS = { [4] = 6.5, [5] = 7, [6] = 13, [7] = 21.5, [8] = 22 }

local LEVELS = {
    { num = 6, label = _("Daytime"), times = { { 6, _("Noon") } } },
    { num = 5, label = _("Sunrise & sunset"), times = { { 5, _("Sunrise") }, { 7, _("Sunset") } } },
    { num = 4, label = _("Night"), times = { { 8, _("Starts") }, { 4, _("Ends") } } },
}

local Cities = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Cities.find(query, limit)
    limit = limit or 6
    local name, qualifier = query:match("^([^,]+),(.*)$")
    name = trim(name or query):lower()
    qualifier = qualifier and trim(qualifier):lower() or ""
    if name == "" then return {} end
    local matches, preferred = {}, {}
    local file = io.open(CITIES_FILE, "r")
    if not file then return {} end
    for line in file:lines() do
        local city, ascii, region, country, lat, lon, elev = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if city and (city:lower() == name or (ascii ~= "" and ascii:lower() == name)) then
            local entry = {
                name = city,
                region = region,
                country = country,
                latitude = tonumber(lat),
                longitude = tonumber(lon),
                altitude = tonumber(elev) or 0,
            }
            local r, c = region:lower(), country:lower()
            if qualifier ~= "" and (c == qualifier or r == qualifier or r:sub(1, #qualifier) == qualifier) then
                table.insert(preferred, entry)
            else
                table.insert(matches, entry)
            end
        end
    end
    file:close()
    local results = {}
    for _i, list in ipairs({ preferred, matches }) do
        for _i, entry in ipairs(list) do
            if #results < limit then table.insert(results, entry) end
        end
    end
    return results
end

local city_index

function Cities.release()
    city_index = nil
end

local function loadCities()
    if city_index then return city_index end
    city_index = {}
    local file = io.open(CITIES_FILE, "r")
    if not file then return city_index end
    for line in file:lines() do
        local city, ascii, region, country, lat, lon, elev = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if city then
            local entry = {
                name = city,
                region = region,
                country = country,
                latitude = tonumber(lat),
                longitude = tonumber(lon),
                altitude = tonumber(elev) or 0,
                key = city:lower(),
                ascii_key = ascii:lower(),
            }
            entry.label_key = Cities.label(entry):lower()
            table.insert(city_index, entry)
        end
    end
    file:close()
    return city_index
end

function Cities.suggest(query, limit)
    limit = limit or 5
    query = (query or ""):gsub("^%s+", ""):lower()
    if query:match("^%s*$") then return {} end
    local n = #query
    local results = {}
    for _i, entry in ipairs(loadCities()) do
        if entry.key:sub(1, n) == query or entry.ascii_key:sub(1, n) == query or entry.label_key:sub(1, n) == query then
            table.insert(results, entry)
            if #results >= limit then break end
        end
    end
    return results
end

function Cities.label(entry)
    local parts = { entry.name }
    if entry.region ~= "" and entry.region ~= entry.name then table.insert(parts, entry.region) end
    table.insert(parts, entry.country)
    return table.concat(parts, ", ")
end

local paused = { all = nil, dark = nil }

local function anchorTime(hours)
    return math.floor(hours * 3600 * 1000) * (1 / 1000)
end

local function plain(v)
    v = v or 0
    return v > 100 and math.max(v - 1000, 0) or v
end

local function timezoneOffset()
    local now = os.time()
    local here = os.date("*t", now)
    local utc = os.date("!*t", now)
    utc.isdst = here.isdst
    local offset = os.difftime(now, os.time(utc)) / 3600
    if here.isdst then
        offset = offset - 1
    end
    return offset
end

local function rebuild(aw)
    local hours, warmth = aw.current_times_h, aw.warmth
    if not (hours and warmth) then return end
    local powerd = Device:getPowerDevice()
    local scale = (Device:hasNaturalLight() and powerd.fl_warmth_max or 100) / 100
    local dark = {
        night = (warmth[4] or 0) > 100 or (warmth[8] or 0) > 100,
        twilight = (warmth[5] or 0) > 100 or (warmth[7] or 0) > 100,
        day = (warmth[6] or 0) > 100,
    }
    local function period(index)
        if index == 4 or index == 7 then return dark.twilight end
        if index == 5 or index == 6 then return dark.day end
        return dark.night
    end
    local indices = {}
    for i = 1, 11 do
        if hours[i] then table.insert(indices, i) end
    end
    local times, warmths = {}, {}
    local function add(t, v, flag)
        table.insert(times, t)
        table.insert(warmths, flag and v + 1000 or v)
    end
    for k, i1 in ipairs(indices) do
        local t1 = anchorTime(hours[i1])
        local v1 = plain(warmth[i1])
        local anchor_flag = period(i1)
        if i1 == 4 then anchor_flag = dark.night end
        add(t1, v1, anchor_flag)
        local i2 = indices[k + 1]
        if i2 then
            local flag = period(i1)
            local v2 = plain(warmth[i2])
            local diff = v2 - v1
            local span = anchorTime(hours[i2]) - t1
            if diff ~= 0 and span > 0 then
                local step_t = span / math.abs(diff)
                local dir = diff > 0 and 1 or -1
                local level = math.floor(v1 * scale + 0.5)
                for n = 1, math.abs(diff) - 1 do
                    local v = v1 + dir * n
                    local next_level = math.floor(v * scale + 0.5)
                    if next_level ~= level then
                        level = next_level
                        add(t1 + step_t * n, v, flag)
                    end
                end
            elseif i1 == 4 and flag ~= anchor_flag and span > 0 then
                add(t1 + math.min(60, span / 2), v1, flag)
            end
        end
    end
    aw.sched_times_s = times
    aw.sched_warmths = warmths
end

local function nextPoint(aw)
    local hours = aw.current_times_h
    if not hours then return end
    local now = os.date("*t")
    local now_s = now.hour * 3600 + now.min * 60 + now.sec
    local next_s, first_s
    for i = 1, 11 do
        if hours[i] then
            local t = hours[i] * 3600
            if not first_s or t < first_s then first_s = t end
            if t > now_s + 1 and (not next_s or t < next_s) then next_s = t end
        end
    end
    if not next_s then
        if not first_s then return end
        next_s = first_s + 24 * 3600
    end
    return os.time() + math.ceil(next_s - now_s)
end

local function patchSunTime()
    local SunTime = package.loaded["suntime"]
    if type(SunTime) ~= "table" or SunTime._kcui_timezone then return end
    SunTime._kcui_timezone = true
    SunTime.getTimezoneOffset = function()
        return timezoneOffset()
    end
end

local function patchClass(class)
    if class._kcui_night then return end
    class._kcui_night = true

    local orig_step = class.scheduleNextWarmthChange
    UIManager:unschedule(orig_step)
    class.scheduleNextWarmthChange = function(self, ...)
        if self._kcui_source ~= self.sched_times_s then
            rebuild(self)
            self._kcui_source = self.sched_times_s
        end
        if paused.all then
            local left = paused.all - os.time()
            if left > 0 then
                UIManager:unschedule(self.scheduleNextWarmthChange)
                UIManager:scheduleIn(left, self.scheduleNextWarmthChange, self, false)
                if (self.sched_warmth_index or 1) < 1 then
                    self.sched_warmth_index = 1
                end
                return
            end
            paused.all = nil
        end
        return orig_step(self, ...)
    end

    local orig_set = class.setWarmth
    UIManager:unschedule(orig_set)
    class.setWarmth = function(self, val, force)
        if paused.dark and os.time() >= paused.dark then
            paused.dark = nil
        end
        if paused.dark and self.control_nightmode then
            self.control_nightmode = false
            orig_set(self, val, force)
            self.control_nightmode = true
            return
        end
        return orig_set(self, val, force)
    end

    local orig_toggle = class._onToggleNightMode
    if orig_toggle then
        class._onToggleNightMode = function(self, ...)
            orig_toggle(self, ...)
            local until_ts = nextPoint(self)
            if until_ts then
                paused.dark = until_ts - 2
            end
        end
    end
end

local WarmthPage = InputContainer:extend{
    ui = nil,
    panel = nil,
}

local function clock(hours)
    if not hours then return "--:--" end
    local h = math.floor(hours) % 24
    local m = math.floor((hours - math.floor(hours)) * 60 + 0.5)
    if m == 60 then h, m = (h + 1) % 24, 0 end
    if G_reader_settings:isTrue("twelve_hour_clock") then
        local suffix = h < 12 and "AM" or "PM"
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        return string.format("%02d:%02d %s", h12, m, suffix)
    end
    return string.format("%02d:%02d", h, m)
end

function WarmthPage:plugin()
    return self.ui and self.ui.autowarmth
end

function WarmthPage:mode()
    local plugin = self:plugin()
    local activate = plugin and plugin.activate or G_reader_settings:readSetting("autowarmth_activate") or 0
    if activate == 0 then return "off" end
    if activate == 1 then return "auto" end
    return "manual"
end

function WarmthPage:setMode(mode)
    local plugin = self:plugin()
    local activate = mode == "auto" and 1 or mode == "manual" and 2 or 0
    G_reader_settings:saveSetting("autowarmth_activate", activate)
    if plugin then
        plugin.activate = activate
        plugin:scheduleMidnightUpdate()
    end
end

function WarmthPage:hasLocation()
    local location = G_reader_settings:readSetting("autowarmth_location")
    return location ~= nil and location ~= "" and location ~= "Geysir"
        and G_reader_settings:readSetting("autowarmth_latitude") ~= nil
end
function WarmthPage:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.top = TopBar.new(self.ui, function() return self end)
    self.header = Toolbar.titleHeader(w, _("Warmth schedule"), nil, function() UIManager:close(self) end)
    self.pad = U(32.5)
    self.slider_margin = self.pad
    self.title_face = U.face("cfont", 18)
    self.desc_face = U.face("cfont", 15)
    self.chevron = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/quicksettings/schedule-chevron.svg",
        width = U(8.7),
        height = U(16.5),
        alpha = true,
    }
    self.small_chevron = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/quicksettings/schedule-chevron.svg",
        width = U(6),
        height = U(11.4),
        alpha = true,
    }
    self.ges_events = {
        TapWarmth = { GestureRange:new{ ges = "tap", range = self.dimen } },
        PanWarmth = { GestureRange:new{ ges = "pan", range = self.dimen } },
        HoldWarmth = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    if self:mode() == "auto" and not self:hasLocation() then
        self:setMode("manual")
    end
    self:layout()
end

function WarmthPage:layout()
    local w = self.dimen.w
    local mode = self:mode()
    local plugin = self:plugin()
    local y = self.top.dimen.h + self.header.dimen.h + U(14)
    self.rows = {}
    local function radio(key, title)
        local row = { kind = "radio", key = key, y = y, selected = mode == key }
        row.title = TextWidget:new{ text = title, face = self.title_face, bold = true }
        row.h = row.title:getSize().h + U(14)
        table.insert(self.rows, row)
        y = y + row.h
    end
    local function setting(key, label, value)
        local row = { kind = "setting", key = key, y = y - U(7), h = U(36) }
        row.title = TextWidget:new{ text = label, face = self.title_face }
        row.value = TextWidget:new{ text = value, face = self.title_face }
        table.insert(self.rows, row)
        y = y + row.h
    end
    radio("off", _("Off"))
    radio("auto", _("Automatic (sunrise & sunset of your city)"))
    if mode == "auto" then
        local location = self:hasLocation() and G_reader_settings:readSetting("autowarmth_location") or ""
        setting("location", _("Location:"), location ~= "" and location or _("Set location"))
    end
    radio("manual", _("Manual"))
    y = y - U(7.2)
    self.top_sep_y = y
    y = y + Divider.height + 4 + U(11.5)
    self.sliders = {}
    local powerd = Device:getPowerDevice()
    local mark = U(16)
    local manual = mode == "manual"
    local times = plugin and plugin.scheduler_times or {}
    local time_face = U.face("cfont", 17)
    local word_face = U.face("cfont", 15)
    local chevron_w = U(6)
    local right = w - self.pad
    local word_col, time_col = 0, 0
    if manual then
        for _l, level in ipairs(LEVELS) do
            for _t, entry in ipairs(level.times) do
                local ww = TextWidget:new{ text = entry[2], face = word_face }
                local tw = TextWidget:new{ text = clock(times[entry[1]] or TIME_DEFAULTS[entry[1]]), face = time_face, bold = true }
                word_col = math.max(word_col, ww:getSize().w)
                time_col = math.max(time_col, tw:getSize().w)
                ww:free()
                tw:free()
            end
        end
    end
    local col_x = right - chevron_w - U(10) - time_col - U(10) - word_col
    for _i, level in ipairs(LEVELS) do
        local slider = {
            label = level.label,
            min = powerd.fl_warmth_min,
            max = powerd.fl_warmth_max,
            get = function()
                local warmth = plugin and plugin.warmth
                if not warmth then return 0 end
                local v = warmth[level.num] or 0
                return powerd:toNativeWarmth(v > 100 and math.max(v - 1000, 0) or v)
            end,
            set = function(native)
                local warmth = plugin and plugin.warmth
                if not warmth then return end
                local v = powerd:fromNativeWarmth(native)
                local night = (warmth[level.num] or 0) > 100
                local stored = night and v + 1000 or v
                warmth[level.num] = stored
                warmth[#warmth - level.num + 1] = stored
                G_reader_settings:saveSetting("autowarmth_warmth", warmth)
                plugin:scheduleMidnightUpdate()
            end,
        }
        slider.label_cy = y + U(10)
        local has_night = plugin and plugin.control_nightmode ~= false
        local extra_lines = manual and (#level.times - 1) or 0
        if has_night then extra_lines = math.max(extra_lines, 1) end
        slider.value_cy = slider.label_cy + extra_lines * U(22) + U(30.8)
        slider.track_cy = slider.value_cy + U(31.1)
        slider.minus_x = self.pad
        slider.plus_x = w - self.pad - mark
        slider.x0 = self.pad + mark + U(21.3)
        slider.x1 = slider.plus_x - U(20.7)
        slider.label_widget = TextWidget:new{
            text = slider.label,
            face = U.face(KindleFonts.found.book_bold or KindleFonts.found.book or "cfont", 19),
            bold = KindleFonts.found.book_bold == nil,
        }
        if manual then
            slider.time_widgets = {}
            local title_cap = math.floor(slider.label_widget.face.size * 0.7 + 0.5)
            local time_cap = math.floor(time_face.size * 0.7 + 0.5)
            local align = math.floor(title_cap / 2) - math.floor(time_cap / 2)
            for i, entry in ipairs(level.times) do
                local num, word = entry[1], entry[2]
                local tw = TextWidget:new{ text = clock(times[num] or TIME_DEFAULTS[num]), face = time_face, bold = true }
                local ww = TextWidget:new{ text = word, face = word_face, fgcolor = GRAY }
                local word_x = col_x
                table.insert(slider.time_widgets, {
                    num = num,
                    widget = tw,
                    word = ww,
                    cy = slider.label_cy + align + (i - 1) * U(22),
                    x = word_x,
                    time_x = word_x + word_col + U(10),
                    chevron_x = right - chevron_w,
                    w = right - word_x,
                })
            end
        end
        if has_night then
            slider.night_cy = slider.label_cy + U(24)
            slider.night_label = TextWidget:new{ text = _("Dark mode"), face = U.face("cfont", 15) }
            slider.night_get = function()
                local warmth = plugin.warmth
                return warmth and (warmth[level.num] or 0) > 100
            end
            slider.night_toggle = function()
                local warmth = plugin.warmth
                if not warmth then return end
                local v = warmth[level.num] or 0
                local stored = v > 100 and math.max(v - 1000, 0) or v + 1000
                warmth[level.num] = stored
                warmth[#warmth - level.num + 1] = stored
                G_reader_settings:saveSetting("autowarmth_warmth", warmth)
                plugin:scheduleMidnightUpdate()
            end
        end
        table.insert(self.sliders, slider)
        slider.sep_y = slider.track_cy + U(30.5)
        y = slider.sep_y + Divider.height + 4 + U(11.5)
    end
end

function WarmthPage:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    self.top:paintTo(bb, 0, 0)
    self.header:paintTo(bb, 0, self.top.dimen.h)
    self.header.dimen.y = self.top.dimen.h
    local black = Blitbuffer.COLOR_BLACK
    for _i, row in ipairs(self.rows) do
        if row.kind == "radio" then
            local d = U(14)
            local cx = self.pad
            local cy = row.y + math.floor(row.title:getSize().h / 2)
            bb:paintRoundedRect(cx, cy - math.floor(d / 2), d, d, black, math.floor(d / 2))
            local ring = U(1.12)
            bb:paintRoundedRect(cx + ring, cy - math.floor(d / 2) + ring, d - 2 * ring, d - 2 * ring, Blitbuffer.COLOR_WHITE, math.floor(d / 2) - ring)
            if row.selected then
                local dot = d - 4 * ring
                bb:paintRoundedRect(cx + 2 * ring, cy - math.floor(dot / 2), dot, dot, black, math.floor(dot / 2))
            end
            local tx = self.pad + d + U(12)
            row.title:paintTo(bb, tx, row.y)
        else
            local tx = self.pad + U(26)
            local cy = row.y + math.floor(row.h / 2)
            row.title:paintTo(bb, tx, cy - math.floor(row.title:getSize().h / 2))
            local ch = self.chevron:getSize()
            local chx = w - self.pad - ch.w
            self.chevron:paintTo(bb, chx, cy - math.floor(ch.h / 2))
            row.value:paintTo(bb, tx + row.title:getSize().w + U(8), cy - math.floor(row.value:getSize().h / 2))
        end
    end
    if self.top_sep_y then
        Divider.paint(bb, self.pad, self.top_sep_y, w - 2 * self.pad)
    end
    for _i, slider in ipairs(self.sliders) do
        Panel.paintSlider(self, bb, slider)
        for _i, t in ipairs(slider.time_widgets or {}) do
            local cap = math.floor(t.widget.face.size * 0.7 + 0.5)
            t.widget:paintTo(bb, t.time_x, t.cy - (t.widget:getBaseline() - math.floor(cap / 2)))
            local wcap = math.floor(t.word.face.size * 0.7 + 0.5)
            t.word:paintTo(bb, t.x, t.cy - (t.word:getBaseline() - math.floor(wcap / 2)))
            local ch = self.small_chevron
            ch:paintTo(bb, t.chevron_x, t.cy - math.floor(ch:getSize().h / 2))
        end
        if slider.sep_y then
            Divider.paint(bb, self.pad, slider.sep_y, w - 2 * self.pad)
        end
        if slider.night_cy then
            local box = U(16)
            local icon = ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. (slider.night_get() and "/checkbox-selected.svg" or "/checkbox-unselected.svg"),
                width = box,
                height = box,
                alpha = true,
            }
            icon:paintTo(bb, self.pad, slider.night_cy - math.floor(box / 2))
            icon:free()
            local label = slider.night_label
            local cap = math.floor(label.face.size * 0.7 + 0.5)
            label:paintTo(bb, self.pad + box + U(10), slider.night_cy - (label:getBaseline() - math.floor(cap / 2)))
        end
    end
end

function WarmthPage:refresh()
    self:layout()
    UIManager:setDirty(self, "ui")
end

function WarmthPage:askLocation()
    local plugin = self:plugin()
    if not plugin then return end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Location"),
        input = self:hasLocation() and plugin.location or "",
        input_hint = _("City name, e.g. Edmonton"),
        edited_callback = function()
            if dialog then self:showSuggestions(dialog) end
        end,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function()
                self:hideSuggestions()
                UIManager:close(dialog)
                self:locationFailed()
            end },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    self:applyLocation(dialog:getInputText(), dialog)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    if dialog.movable then
        local kb_h = dialog:isKeyboardVisible() and dialog._input_widget:getKeyboardDimen().h or 0
        local frame_h = dialog.dialog_frame:getSize().h
        local centered = math.floor((Screen:getHeight() - kb_h - frame_h) / 2)
        dialog.movable:setMovedOffset{ x = 0, y = self.rows[1].y - U(6) - centered }
        UIManager:setDirty("all", "ui")
    end
    self.field_box = nil
    UIManager:scheduleIn(0.1, function()
        local field = dialog._input_widget.dimen
        if field and field.x then
            self.field_box = { x = field.x, y = field.y + field.h, w = field.w }
        end
    end)
end

function WarmthPage:setLocation(entry)
    local plugin = self:plugin()
    plugin.location = Cities.label(entry)
    plugin.latitude = entry.latitude
    plugin.longitude = entry.longitude
    plugin.altitude = entry.altitude
    G_reader_settings:saveSetting("autowarmth_location", plugin.location)
    G_reader_settings:saveSetting("autowarmth_latitude", plugin.latitude)
    G_reader_settings:saveSetting("autowarmth_longitude", plugin.longitude)
    G_reader_settings:saveSetting("autowarmth_altitude", plugin.altitude)
    if self.pending_auto then
        self.pending_auto = nil
        self:setMode("auto")
    end
    plugin:scheduleMidnightUpdate()
    self:refresh()
end

function WarmthPage:hideSuggestions()
    if self.suggestions then
        UIManager:close(self.suggestions)
        self.suggestions = nil
    end
end
function WarmthPage:showSuggestions(dialog)
    local text = dialog:getInputText()
    local results = Cities.suggest(text, 5)
    if #results == 1 and Cities.label(results[1]):lower() == text:gsub("%s+$", ""):lower() then
        results = {}
    end
    self:hideSuggestions()
    if #results == 0 then return end
    local buttons = {}
    for _i, entry in ipairs(results) do
        table.insert(buttons, { {
            text = Cities.label(entry),
            callback = function()
                self.suggestions = nil
                dialog:setInputText(Cities.label(entry), true, false)
            end,
        } })
    end
    local frame = dialog.dialog_frame.dimen
    local box = self.field_box or { x = frame.x, y = frame.y + frame.h, w = frame.w }
    local Dropdown = Toolbar.Dropdown
    self.suggestions = Dropdown:new{
        buttons = buttons,
        anchor_left = box.x,
        anchor_top = box.y,
        max_bottom = dialog:isKeyboardVisible() and Screen:getHeight() - dialog._input_widget:getKeyboardDimen().h - U(8) or nil,
        min_width = box.w,
        close_first = true,
        passthrough = true,
        is_always_active = true,
    }
    UIManager:show(self.suggestions)
end
function WarmthPage:locationFailed()
    local pending = self.pending_auto
    self.pending_auto = nil
    if self:hasLocation() then return end
    if pending or self:mode() == "auto" then
        self:setMode("manual")
        self:refresh()
    end
end
function WarmthPage:applyLocation(text, dialog)
    local function done()
        self:hideSuggestions()
        if dialog then UIManager:close(dialog) end
    end
    if not text or text:match("^%s*$") then
        done()
        self:locationFailed()
        return
    end
    local wanted = text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local match
    for _i, entry in ipairs(Cities.suggest(wanted, 50)) do
        if Cities.label(entry):lower() == wanted then
            match = entry
            break
        end
    end
    match = match or Cities.find(text, 1)[1]
    done()
    if match then
        self:setLocation(match)
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Couldn't find \"%1\". Try the city name only, e.g. Edmonton."), text),
        })
        self:locationFailed()
    end
end

local TIME_TITLES = {
    [4] = _("Night ends"),
    [5] = _("Sunrise"),
    [6] = _("Solar noon"),
    [7] = _("Sunset"),
    [8] = _("Night starts"),
}

function WarmthPage:askTime(num)
    local plugin = self:plugin()
    if not plugin then return end
    local times = plugin.scheduler_times
    local current = times[num] or TIME_DEFAULTS[num]
    local DateTimeWidget = require("ui/widget/datetimewidget")
    UIManager:show(DateTimeWidget:new{
        title_text = TIME_TITLES[num],
        hour = math.floor(current) % 24,
        min = math.floor((current - math.floor(current)) * 60 + 0.5) % 60,
        ok_text = _("Set time"),
        callback = function(time)
            local updated = {}
            for i = 1, 11 do
                updated[i] = times[i]
            end
            updated[num] = time.hour + time.min / 60
            local edge = updated[num]
            for i = num + 1, 11 do
                if updated[i] then
                    if updated[i] <= edge then
                        updated[i] = math.min(edge + 0.5, 24)
                    end
                    edge = updated[i]
                end
            end
            edge = updated[num]
            for i = num - 1, 1, -1 do
                if updated[i] then
                    if updated[i] >= edge then
                        updated[i] = math.max(edge - 0.5, 0)
                    end
                    edge = updated[i]
                end
            end
            local previous
            for i = 1, 11 do
                if updated[i] then
                    if previous and updated[i] <= previous then
                        UIManager:show(InfoMessage:new{
                            text = _("That time doesn't leave room for the rest of the schedule. Please choose a different time."),
                        })
                        return
                    end
                    previous = updated[i]
                end
            end
            for i = 1, 11 do
                times[i] = updated[i]
            end
            G_reader_settings:saveSetting("autowarmth_scheduler_times", times)
            plugin:scheduleMidnightUpdate()
            self:refresh()
        end,
    })
end

function WarmthPage:onTapWarmth(_ev, ges)
    local pos = ges.pos
    local header_top = self.top.dimen.h
    if pos.y >= header_top and pos.y < header_top + self.header.dimen.h then
        UIManager:close(self)
        return true
    end
    for _i, row in ipairs(self.rows) do
        if pos.y >= row.y - U(4) and pos.y < row.y + row.h then
            if row.kind == "radio" then
                if row.key == "auto" and not self:hasLocation() then
                    self.pending_auto = true
                    self:askLocation()
                elseif self:mode() ~= row.key then
                    self:setMode(row.key)
                    self:refresh()
                end
            elseif row.key == "location" then
                self:askLocation()
            else
                self:askTime(row.key)
            end
            return true
        end
    end
    for _i, sl in ipairs(self.sliders) do
        if sl.night_cy and math.abs(pos.y - sl.night_cy) <= U(16)
                and pos.x <= self.pad + U(26) + sl.night_label:getSize().w + U(10) then
            sl.night_toggle()
            self:refresh()
            return true
        end
    end
    for _i, sl in ipairs(self.sliders) do
        for _i, t in ipairs(sl.time_widgets or {}) do
            if math.abs(pos.y - t.cy) <= U(11) and pos.x >= t.x - U(8) and pos.x <= t.x + t.w + U(8) then
                self:askTime(t.num)
                return true
            end
        end
    end
    local slider = Panel.sliderAt(self, pos)
    if slider then
        Panel.adjustSlider(self, slider, pos.x)
    end
    return true
end

function WarmthPage:onHoldWarmth(_ev, ges)
    local slider = Panel.sliderAt(self, ges.pos)
    return slider ~= nil and Panel.adjustSlider(self, slider, ges.pos.x, true)
end

function WarmthPage:onPanWarmth(_ev, ges)
    local slider = Panel.sliderAt(self, ges.start_pos or ges.pos)
    if slider then
        Panel.setSlider(self, slider, Panel.valueAt(self, slider, ges.pos.x))
    end
    return true
end

function WarmthPage:onShow()
    UIManager:setDirty(self, "ui")
end

function WarmthPage:onResume()
    self.top:handleEvent(Event:new("Resume"))
end

function WarmthPage:onCloseWidget()
    Cities.release()
    if self.top.onCloseWidget then self.top:onCloseWidget() end
    UIManager:setDirty("all", "ui")
end

function WarmthPage.installSchedule(ui)
    local aw = ui and ui.autowarmth
    if not aw then return end
    local class = getmetatable(aw)
    if not class or not class.scheduleNextWarmthChange then return end
    patchSunTime()
    patchClass(class)
    if aw.activate and aw.activate ~= 0 then
        aw:scheduleMidnightUpdate()
    end
end

function WarmthPage.pauseSchedule(ui)
    local aw = ui and ui.autowarmth
    if not aw or not aw.activate or aw.activate == 0 then return end
    local until_ts = nextPoint(aw)
    if not until_ts then return end
    paused.all = until_ts
    UIManager:unschedule(aw.scheduleNextWarmthChange)
    UIManager:scheduleIn(math.max(until_ts - os.time(), 1), aw.scheduleNextWarmthChange, aw, false)
end

return WarmthPage
