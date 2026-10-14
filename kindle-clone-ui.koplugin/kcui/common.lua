local Blitbuffer = require("ffi/blitbuffer")
local CreDocument = require("document/credocument")
local DataStorage = require("datastorage")
local Event = require("ui/event")
local Font = require("ui/font")
local FontList = require("fontlist")
local LuaSettings = require("luasettings")
local Freetype = require("ffi/freetype")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local ffi = require("ffi")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local C_ = require("gettext").pgettext
local Device = require("device")
local Screen = Device.screen

local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/kcui/common%.lua$")

local REFERENCE_SCALE = math.ceil(1264 / 600 * 10000) / 10000
local REFERENCE_DPI = 300

local Units = {}

local function scale()
    return Screen:getDPI() * REFERENCE_SCALE / REFERENCE_DPI
end

function Units.ceil(units)
    return math.ceil(units * scale())
end

function Units.face(name, size)
    return Font:getFace(name, size * scale() * 10000 / Screen:scaleBySize(10000))
end

setmetatable(Units, {
    __call = function(_self, units)
        return math.floor(units * scale() + 0.5)
    end,
})

local Paint = {
    NOTCH = 9,
}

function Paint.fill(bb, x, y, w, h, color)
    if Blitbuffer.isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, color)
    end
end

function Paint.disc(bb, cx, cy, r, color)
    bb:paintCircle(cx, cy, r, color)
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_DARK_GRAY, Units.ceil(1))
end

function Paint.notch(bb, cx, edge_y, above, size, border)
    for i = 0, size do
        local half = size - i
        local y = above and edge_y + i or edge_y - i
        bb:paintRect(cx - half, y, 2 * half + 1, 1, Blitbuffer.COLOR_BLACK)
        if half > border then
            bb:paintRect(cx - half + border, y, 2 * (half - border) + 1, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local KindleFonts = {
    UI_FAMILY = "Amazon Ember",
    BOOK_FAMILY = "Bookerly",
    DIR = ROOT .. "/fonts",
    found = {},
}

local function addPluginFonts()
    FontList:getFontList()
    local mark = {}
    FontList:_readList(KindleFonts.DIR, mark)
    local cre = CreDocument:engineInit()
    for path in pairs(mark) do
        if path ~= "cache_dirty" then
            for _i, info in ipairs(FontList.fontinfo[path] or {}) do
                local names = FontList.fontnames[info.name] or {}
                FontList.fontnames[info.name] = names
                table.insert(names, info)
            end
            pcall(cre.registerFont, path)
        end
    end
    table.sort(FontList.fontlist)
end

local function styleName(path, index)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, 12, index)
    if not ok then return end
    local style = ffi.string(ftsize.face.style_name)
    ftsize:done()
    return style
end

local function findFace(family, bold, style, strict, italic)
    local wanted_style = style or (bold and "Bold" or "Regular")
    local fallback
    for _i, path in ipairs(FontList:getFontList()) do
        for _i, info in ipairs(FontList.fontinfo[path] or {}) do
            if info.name == family and (info.italic or false) == (italic or false) and info.bold == bold then
                if styleName(path, info.index) == wanted_style then
                    return path
                end
                fallback = fallback or path
            end
        end
    end
    if not strict then return fallback end
end

local function retarget(face, path)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, face.size)
    if not ok then
        logger.warn("KindleFonts: cannot load", path, ftsize)
        return
    end
    face.ftsize = ftsize
    face.realname = path
    face.is_real_bold = Font:isRealBoldFont(path)
    face.embolden_half_strength = nil
    face.hash = path .. face.size
    Font.faces[face.hash] = face
end

local function applyUIFont()
    local regular = findFace(KindleFonts.UI_FAMILY, false)
    if not regular then return end
    local bold = findFace(KindleFonts.UI_FAMILY, true)
    KindleFonts.found.ui_regular, KindleFonts.found.ui_bold = regular, bold
    KindleFonts.found.ui_medium = findFace(KindleFonts.UI_FAMILY, false, "Medium", true)
    KindleFonts.found.ui_heavy = findFace(KindleFonts.UI_FAMILY, true, "Heavy", true)
        or findFace(KindleFonts.UI_FAMILY, false, "Heavy", true)
    KindleFonts.found.ui_light = findFace(KindleFonts.UI_FAMILY, false, "Light", true)
    KindleFonts.found.ui_heavy = findFace(KindleFonts.UI_FAMILY, false, "Heavy", true)
    KindleFonts.found.ui_italic = findFace(KindleFonts.UI_FAMILY, false, "Italic", true, true)

    if bold then
        Font.bold_font_variant[regular] = bold
        Font.regular_font_variant[bold] = regular
    end
    local replacement = {
        ["NotoSans-Regular.ttf"] = regular,
        ["NotoSans-Bold.ttf"] = bold or regular,
    }

    for name, file in pairs(Font.fontmap) do
        if replacement[file] then
            Font.fontmap[name] = replacement[file]
        end
    end
    local faces = {}
    for _i, face in pairs(Font.faces) do
        if replacement[face.realname] then
            faces[face] = true
        end
    end
    for face in pairs(faces) do
        retarget(face, replacement[face.realname])
    end
    CreDocument.header_font = KindleFonts.UI_FAMILY
end

local function applyBookFont()
    local path = findFace(KindleFonts.BOOK_FAMILY, false)
    if not path then return end
    KindleFonts.found.book = path
    KindleFonts.found.book_bold = findFace(KindleFonts.BOOK_FAMILY, true)
    CreDocument.default_font = KindleFonts.BOOK_FAMILY
end

function KindleFonts.apply()
    if KindleFonts.applied then return end
    KindleFonts.applied = true
    addPluginFonts()
    applyUIFont()
    applyBookFont()
    logger.info("KindleFonts: UI =", KindleFonts.found.ui_regular or "default",
        "| bold =", KindleFonts.found.ui_bold or "default",
        "| book =", KindleFonts.found.book or "default")
end

local Divider = {
    color = Blitbuffer.Color8(0xE1),
    height = Units(1.75),
}

function Divider.paint(bb, x, y, w)
    bb:paintRect(x, y, w, Divider.height, Divider.color)
end

local Dates = {}

function Dates.day(seconds)
    return os.date("%b ", seconds) .. tonumber(os.date("%d", seconds)) .. os.date(", %Y", seconds)
end

function Dates.time(seconds)
    return datetime.secondsToHour(seconds, G_reader_settings:isTrue("twelve_hour_clock"))
end

function Dates.history(seconds)
    if G_reader_settings:isTrue("history_datetime_short") then
        return os.date(C_("Date string", "%y-%m-%d"), seconds)
    end
    return Dates.day(seconds) .. " · " .. Dates.time(seconds)
end

function Dates.fromStamp(stamp)
    local year, month, day, hour, min, sec = (stamp or ""):match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)$")
    if not year then return end
    return os.time{ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec) }
end

function Dates.stamp(stamp)
    local seconds = Dates.fromStamp(stamp)
    return seconds and Dates.history(seconds) or stamp
end

local Airplane = {}

function Airplane.plugin(ui)
    return ui and ui.airplanemode
end

function Airplane.isOn()
    local utils = package.loaded["utils/flight_utilities"]
    if type(utils) ~= "table" or not utils.getFlightStatus then return false end
    local ok, on = pcall(utils.getFlightStatus, utils)
    return ok and on == true
end

function Airplane.toggle(ui)
    local plugin = Airplane.plugin(ui)
    if not (plugin and plugin.onToggle) then return end
    plugin:onToggle()
    UIManager:broadcastEvent(Event:new("AirplaneModeChanged"))
end

local Navigation = {}

function Navigation.home()
    if filemanagerutil.getHomeFolder then
        return filemanagerutil.getHomeFolder()
    end
    return G_reader_settings:readSetting("home_dir") or Device.home_dir or "."
end

function Navigation.toLibrary(ui, after)
    local home = Navigation.home()
    UIManager:nextTick(function()
        ui:onClose()
        ui:showFileManager(home .. "/")
        local fm = require("apps/filemanager/filemanager").instance
        if fm then
            fm.file_chooser:onGotoPage(1)
            if after then
                after(fm)
            end
        end
    end)
end

local Highlights = {}

function Highlights.colors(highlight)
    local colors = {}
    for i, color in ipairs(highlight:getHighlightColorList()) do
        if type(color) == "table" then
            table.insert(colors, color)
        else
            local named = highlight.highlight_colors and highlight.highlight_colors[i]
            if named then
                table.insert(colors, { named[1], named[2], color })
            end
        end
    end
    return colors
end

local Rotation = {}

local last_portrait

local function isPortrait(mode)
    return mode % 2 == 0
end

function Rotation.portrait()
    local current = Screen:getRotationMode()
    if isPortrait(current) then
        return current
    end
    return last_portrait or Screen.DEVICE_ROTATED_UPRIGHT
end

function Rotation.install()
    if Rotation.installed then return end
    Rotation.installed = true
    local FileManager = require("apps/filemanager/filemanager")
    local setRotationMode = FileManager.setRotationMode
    FileManager.setRotationMode = function(fm)
        local preferred = G_reader_settings:readSetting("fm_rotation_mode")
        if G_reader_settings:isTrue("lock_rotation") or (preferred and not isPortrait(preferred)) then
            return setRotationMode(fm)
        end
        local current = Screen:getRotationMode()
        if isPortrait(current) then
            last_portrait = current
        else
            fm:onSetRotationMode(last_portrait or preferred or Screen.DEVICE_ROTATED_UPRIGHT)
        end
    end
    local ReaderView = require("apps/reader/modules/readerview")
    local onReadSettings = ReaderView.onReadSettings
    ReaderView.onReadSettings = function(view, config)
        local current = Screen:getRotationMode()
        if isPortrait(current) then
            last_portrait = current
        end
        if last_portrait and G_reader_settings:nilOrFalse("lock_rotation") then
            local name = view.ui.paging and "kopt_rotation_mode" or "copt_rotation_mode"
            local saved = config:readSetting(name) or G_reader_settings:readSetting(name)
                or Screen.DEVICE_ROTATED_UPRIGHT
            if isPortrait(saved) and saved ~= last_portrait then
                config:saveSetting(name, last_portrait)
            end
        end
        return onReadSettings(view, config)
    end
end

local State = {}

local function noBackup()
    return false
end

function State.open(path)
    local settings = LuaSettings:open(path)
    settings.backup = noBackup
    return settings
end

local setup

function State.setup()
    if not setup then
        local dev = os.getenv("KCUI_HOME") and DataStorage:getDataDir() .. "/kcui-state.lua"
        setup = State.open(dev or ROOT .. "/state.lua")
    end
    return setup
end

function State.applied()
    return State.setup():readSetting("applied") or {}
end

function State.saveApplied(applied)
    State.setup():saveSetting("applied", applied):flush()
end

return {
    State = State,
    U = Units,
    Paint = Paint,
    Fonts = KindleFonts,
    Divider = Divider,
    Dates = Dates,
    Airplane = Airplane,
    Navigation = Navigation,
    Rotation = Rotation,
    Highlights = Highlights,
}
