local Books = require("kcui/library").Books
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local PluginLoader = require("pluginloader")
local ReadHistory = require("readhistory")
local State = require("kcui/common").State
local Themes = require("kcui/themes")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

local Defaults = {}

local LEGACY_APPLIED = "kcui_defaults_applied"
local RESTYLED = "kcui_styles_version"
local STYLES_VERSION = 4
local FONT_RESET_VERSION = 3
local PREVIOUS_BOTTOM = 32
local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/kcui/defaults%.lua$")
local WALLPAPERS = ROOT .. "/wallpapers"

local STATUS_BAR = {
    disable_progress_bar = false,
    chapter_progress_bar = false,
    progress_bar_position = "below",
    progress_style_thin = false,
    progress_style_thick_height = 7,
    kcui_edges = true,
    progress_margin = false,
    progress_margin_width = 10,
    initial_marker = false,
    toc_markers = false,
    text_font_size = 12.5,
    text_font_bold = true,
}
local STATUS_FONT_VERSION = 2
local PREVIOUS_STATUS_FONT_SIZES = { [12] = true, [13] = true }

local STATUS_BAR_ITEMS = {
    "page_progress", "pages_left_book", "time", "pages_left", "battery", "percentage", "book_time_to_read",
    "chapter_time_to_read", "frontlight", "frontlight_warmth", "mem_usage", "wifi_status", "book_title",
    "book_chapter", "book_author", "bookmark_count", "chapter_progress", "custom_text", "page_turning_inverted",
    "dynamic_filler", "dynamic_filler2", "additional_content",
}

local SETTINGS = {
    lock_home_folder = true,
    history_datetime_short = false,
    highlight_drawing_style = "lighten",
    highlight_lighten_factor = 0.294,
    twelve_hour_clock = true,
    collate = "kcui_author",
    auto_suspend_timeout_seconds = 600,
    cre_partial_rerendering = true,
    input_lock_gsensor = true,
    device_status_battery_alarm = true,
    device_status_battery_threshold = 10,
    device_status_battery_interval_minutes = 10,
    cre_header_auto_refresh = 1,
    cre_header_title = 1,
    cre_header_author = 1,
    cre_header_clock = 0,
    cre_header_page_number = 0,
    cre_header_page_count = 0,
    cre_header_reading_percent = 0,
    cre_header_chapter_marks = 0,
    cre_header_battery = 1,
    cre_header_battery_percent = 0,
    plugins_disabled = function()
        local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
        disabled.coverbrowser = true
        if Device:hasNaturalLight() then
            disabled.autowarmth = nil
        end
        return disabled
    end,
    style_tweaks = function()
        local tweaks = G_reader_settings:readSetting("style_tweaks")
            or util.tableDeepCopy(require("ui/data/css_tweaks").DEFAULT_GLOBAL_STYLE_TWEAKS)
        tweaks.margin_body_0 = true
        return tweaks
    end,
    autowarmth_hide_nightmode_warning = true,
    autowarmth_scheduler_times = function()
        local times = G_reader_settings:readSetting("autowarmth_scheduler_times")
            or { 0.0, 5.5, 6.0, 6.5, 7.0, 13.0, 21.5, 22.0, 22.5, 23.0, 24.0 }
        for _i, i in ipairs({ 1, 2, 3, 9, 10, 11 }) do
            times[i] = nil
        end
        return times
    end,
    autowarmth_warmth = function()
        local warmth = G_reader_settings:readSetting("autowarmth_warmth")
        if type(warmth) ~= "table" then return nil end
        for i, v in ipairs(warmth) do
            if v > 100 then warmth[i] = math.max(v - 1000, 0) end
        end
        return warmth
    end,
}

local function wallpaperFolder()
    local name = Device:hasColorScreen() and "/color" or "/black-and-white"
    return ffiUtil.realpath(WALLPAPERS .. name) or WALLPAPERS .. name
end

local WALLPAPER_SETTINGS = {
    screensaver_type = "random_image",
    screensaver_dir = wallpaperFolder,
    screensaver_show_message = false,
}

local PREVIOUS_STYLES = {
    copt_font_size = 16,
    copt_line_spacing = 115,
    copt_h_page_margins = { 30, 30 },
    copt_t_page_margin = 30,
    copt_b_page_margin = 15,
    copt_word_spacing = { 144, 100 },
}

local BOOK_STYLES = {
    copt_word_expansion = 0,
    copt_font_gamma = 15,
    copt_font_hinting = 2,
    copt_font_kerning = 3,
    copt_visible_pages = 1,
    copt_view_mode = 0,
    copt_block_rendering_mode = 3,
    copt_render_dpi = 96,
    copt_status_line = 1,
    copt_embedded_css = 1,
    copt_embedded_fonts = 0,
    copt_smooth_scaling = 1,
    copt_nightmode_images = 0,
}

local prompting = false

local readApplied = State.applied

local function markApplied(key)
    local applied = readApplied()
    applied[key] = true
    State.saveApplied(applied)
end

local function isReflowable(file)
    local provider = DocumentRegistry:getProvider(file)
    return provider and provider.provider == "crengine"
end

local function kindleStyles()
    local styles = Themes.defaultBookStyles()
    for key, value in pairs(BOOK_STYLES) do
        styles[key] = value
    end
    return styles
end

local function saveStyles(settings, styles)
    for key, value in pairs(styles) do
        settings:saveSetting(key, type(value) == "table" and util.tableDeepCopy(value) or value)
    end
end

local function sameNumber(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.000001
end

local function sameStyle(a, b)
    if type(a) == "table" and type(b) == "table" then
        return sameNumber(a[1], b[1]) and sameNumber(a[2], b[2])
    end
    if type(a) == "number" then
        return sameNumber(a, b)
    end
    return a == b
end

local function styleChanges()
    local current = Themes.defaultBookStyles()
    local changes = {}
    for key, value in pairs(PREVIOUS_STYLES) do
        table.insert(changes, { key = key, from = value, to = current[key] })
    end
    table.insert(changes, { key = "copt_b_page_margin", from = Themes.fromPixels(PREVIOUS_BOTTOM), to = current.copt_b_page_margin })
    for _i, change in ipairs(Themes.marginChanges()) do
        table.insert(changes, change)
    end
    return changes
end

local function replacePreviousStyles(settings)
    local replaced = {}
    for _i, change in ipairs(styleChanges()) do
        if not replaced[change.key] and sameStyle(settings:readSetting(change.key), change.from) then
            settings:saveSetting(change.key, type(change.to) == "table" and util.tableDeepCopy(change.to) or change.to)
            replaced[change.key] = true
        end
    end
end

local function moveWallpapers()
    local dir = G_reader_settings:readSetting("screensaver_dir")
    local folder = wallpaperFolder()
    if dir and dir ~= folder and (dir == ffiUtil.realpath(WALLPAPERS) or ffiUtil.dirname(dir) == ffiUtil.realpath(WALLPAPERS)) then
        G_reader_settings:saveSetting("screensaver_dir", folder)
    end
end

local function restyleFile(file, styles)
    local doc_settings = DocSettings:open(file)
    saveStyles(doc_settings, styles)
    doc_settings:saveSetting(RESTYLED, STYLES_VERSION)
    doc_settings:flush()
end

local function resetFont(settings)
    local defaults = Themes.defaultBookStyles()
    settings:saveSetting("font_face", G_reader_settings:readSetting("cre_font") or Themes.defaultFont())
    settings:saveSetting("copt_font_size", G_reader_settings:readSetting("copt_font_size") or defaults.copt_font_size)
    settings:saveSetting("copt_font_base_weight", G_reader_settings:readSetting("copt_font_base_weight") or defaults.copt_font_base_weight)
end

local function knownBooks()
    local files = {}
    for _i, item in ipairs(ReadHistory.hist) do
        files[item.file] = true
    end
    local home = G_reader_settings:readSetting("home_dir")
    if home then
        util.findFiles(home, function(path) files[path] = true end)
    end
    local books = {}
    for file in pairs(files) do
        if not file:find(".sdr/", 1, true) and DocSettings:hasSidecarFile(file) and isReflowable(file) then
            table.insert(books, file)
        end
    end
    return books
end

function Defaults.refreshBookStyles(ui)
    local doc_settings = ui.rolling and ui.doc_settings
    if not doc_settings then return end
    local restyled = tonumber(doc_settings:readSetting(RESTYLED)) or 0
    if restyled >= STYLES_VERSION then return end
    replacePreviousStyles(doc_settings)
    if restyled < FONT_RESET_VERSION then
        resetFont(doc_settings)
    end
    doc_settings:saveSetting(RESTYLED, STYLES_VERSION)
end

function Defaults.restyleBooks(styles, except)
    local count = 0
    for _i, file in ipairs(knownBooks()) do
        if file ~= except then
            restyleFile(file, styles)
            count = count + 1
        end
    end
    return count
end

function Defaults.applyBookStyles(ui, quiet)
    local styles = kindleStyles()
    saveStyles(G_reader_settings, styles)
    local font = Themes.defaultFont()
    if font then
        G_reader_settings:saveSetting("cre_font", font)
        styles.font_face = font
    end
    local count = Defaults.restyleBooks(styles)
    G_reader_settings:flush()
    logger.info("Defaults: updated page styles of", count, "books")
    local open_file = ui and ui.document and ui.document.file
    if open_file and isReflowable(open_file) then
        ui:reloadDocument(function(file) restyleFile(file, styles) end)
    end
    if quiet then return end
    UIManager:show(InfoMessage:new{
        text = T(N_("Page styles updated for 1 book.", "Page styles updated for %1 books.", count), count),
        timeout = 3,
    })
end

function Defaults.resetBook(ui)
    local file = ui.document and ui.document.file
    if not (file and isReflowable(file)) then return end
    local styles = kindleStyles()
    styles.font_face = Themes.defaultFont()
    ui:reloadDocument(function(path)
        local doc_settings = DocSettings:open(path)
        local stale = {}
        for key in pairs(doc_settings.data) do
            if key:sub(1, 5) == "copt_" or key == "font_face" then
                table.insert(stale, key)
            end
        end
        for _i, key in ipairs(stale) do
            doc_settings:delSetting(key)
        end
        saveStyles(doc_settings, styles)
        doc_settings:saveSetting(RESTYLED, STYLES_VERSION)
        doc_settings:flush()
    end)
end

function Defaults.confirmReset(ui)
    UIManager:show(ConfirmBox:new{
        text = _("Reset to Kindle-like defaults?") .. "\n\n"
            .. _("Kindle Clone UI will set everything up again as if it had just been installed: its settings, the status bar, and the page styles of every book you have opened.") .. "\n\n"
            .. _("You will be asked about your home folder and the sleep screen wallpapers again. This can't be undone."),
        ok_text = _("Reset"),
        cancel_text = _("Cancel"),
        dismissable = false,
        ok_callback = function()
            State.saveApplied({})
            G_reader_settings:delSetting("kcui_reading_progress")
            G_reader_settings:delSetting("kcui_reading_position")
            G_reader_settings:delSetting("kcui_progress_bar")
            Defaults.apply()
            Defaults.firstRun(ui)
        end,
    })
end

local function hasBooksFolder(dir)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return false end
    for name in iter, dir_obj do
        if name:lower() == "books" and lfs.attributes(dir .. "/" .. name, "mode") == "directory" then
            return true
        end
    end
    return false
end

local function chooseHomeFolder(ui, on_done)
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or "."
    local function save(path)
        G_reader_settings:saveSetting("home_dir", path)
        if ui.folder_shortcuts and ui.folder_shortcuts.updateShortcut then
            ui.folder_shortcuts:updateShortcut("home_dir", path)
        end
        if ui.file_chooser then
            ui.file_chooser:changeToPath(path)
        end
    end
    local finished = false
    local function finish()
        if finished then return end
        finished = true
        on_done()
    end
    local root = Device.home_dir and (ffiUtil.realpath(Device.home_dir) or Device.home_dir)
    local books = root and root .. "/Books"
    local other_buttons
    if root and not hasBooksFolder(root) then
        other_buttons = { {
            {
                text = _("Create a new Home folder \"Books\""),
                callback = function()
                    util.makePath(books)
                    if lfs.attributes(books, "mode") ~= "directory" then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Could not create %1"), books),
                            dismiss_callback = function() chooseHomeFolder(ui, on_done) end,
                        })
                        return
                    end
                    save(books)
                    finish()
                end,
            },
        } }
    end
    UIManager:show(ConfirmBox:new{
        text = _("Choose your home folder") .. "\n\n"
            .. _("Your Library shows the books in this folder:") .. "\n\n" .. home,
        ok_text = _("Use this folder"),
        cancel_text = _("Choose another"),
        other_buttons = other_buttons,
        other_buttons_first = true,
        dismissable = false,
        ok_callback = function()
            save(home)
            finish()
        end,
        cancel_callback = function()
            local PathChooser = require("ui/widget/pathchooser")
            local chooser = PathChooser:new{
                select_directory = true,
                select_file = false,
                show_files = false,
                path = home,
                onConfirm = save,
            }
            local close = chooser.onCloseWidget
            chooser.onCloseWidget = function(...)
                if close then close(...) end
                UIManager:nextTick(finish)
            end
            UIManager:show(chooser)
        end,
    })
end

local function resolve(value)
    if type(value) == "function" then
        return value()
    end
    return value
end

local function askWallpaper(_ui, on_done)
    UIManager:show(ConfirmBox:new{
        text = _("Use Kindle wallpapers on the sleep screen?") .. "\n\n"
            .. _("(You can add or remove images in the Kindle wallpapers folder as well.)"),
        ok_text = _("Yes, update sleep\nscreen wallpaper settings"),
        cancel_text = _("No, keep my\ncurrent settings"),
        dismissable = false,
        ok_callback = function()
            for key, value in pairs(WALLPAPER_SETTINGS) do
                G_reader_settings:saveSetting(key, resolve(value))
            end
            G_reader_settings:flush()
            on_done()
        end,
        cancel_callback = on_done,
    })
end

local function applyBookStyles(ui, on_done)
    Defaults.applyBookStyles(ui, true)
    on_done()
end

local function readBookDetails(ui, on_done)
    Books.preloadHome(ui)
    on_done()
end

local function restartAfterSetup(_ui, on_done)
    on_done()
    if not Device:canRestart() then return end
    UIManager:show(InfoMessage:new{ text = _("Restarting KOReader to finish setting up…") })
    UIManager:scheduleIn(2, function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end)
end

local FIRST_RUN_STEPS = {
    { flag = "home_dir_confirmed", run = chooseHomeFolder },
    { flag = "wallpaper_asked", run = askWallpaper },
    { flag = "book_styles_asked", run = applyBookStyles },
    { flag = "book_details_read", run = readBookDetails },
    { flag = "setup_restarted", run = restartAfterSetup },
}

local function applyStatusBar()
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local footer = G_reader_settings:readSetting("footer", ReaderFooter.default_settings)
    for key, value in pairs(STATUS_BAR) do
        footer[key] = value
    end
    for _i, item in ipairs(STATUS_BAR_ITEMS) do
        footer[item] = false
    end
    footer.percentage = true
    G_reader_settings:saveSetting("footer", footer)
end

local function holdBackDisabledPlugins()
    local createPluginInstance = PluginLoader.createPluginInstance
    PluginLoader.createPluginInstance = function(loader, plugin, attr)
        local disabled = G_reader_settings:readSetting("plugins_disabled")
        if disabled and disabled[plugin.name] then
            return nil, "disabled"
        end
        return createPluginInstance(loader, plugin, attr)
    end
end

function Defaults.firstRun(ui)
    if prompting then return end
    prompting = true
    local asked = false
    local applied = readApplied()
    logger.info("Defaults: first run check, home", tostring(applied.home_dir_confirmed), "wallpaper",
        tostring(applied.wallpaper_asked), "styles", tostring(applied.book_styles_asked), "details",
        tostring(applied.book_details_read), "restarted", tostring(applied.setup_restarted))
    local function step(index)
        local current = FIRST_RUN_STEPS[index]
        if not current then
            prompting = false
            if asked and ui.file_chooser then
                ui.file_chooser:refreshPath()
            end
            return
        end
        if readApplied()[current.flag] then
            return step(index + 1)
        end
        asked = true
        current.run(ui, function()
            markApplied(current.flag)
            UIManager:nextTick(function() step(index + 1) end)
        end)
    end
    step(1)
end

function Defaults.apply()
    local applied = readApplied()
    if G_reader_settings:has("kcui_clock_defaulted") then
        applied.twelve_hour_clock = true
        G_reader_settings:delSetting("kcui_clock_defaulted")
    end
    if not G_reader_settings:has("home_dir") then
        G_reader_settings:saveSetting("home_dir", Device.home_dir)
    end
    local newly_applied = {}
    for key, value in pairs(SETTINGS) do
        if not applied[key] then
            value = resolve(value)
            if value ~= nil then
                G_reader_settings:saveSetting(key, value)
            end
            applied[key] = true
            newly_applied[key] = true
        end
    end
    if newly_applied.plugins_disabled then
        holdBackDisabledPlugins()
    end
    if newly_applied.history_datetime_short then
        require("readhistory"):updateDateTimeString()
    end
    local dev_home = os.getenv("KCUI_HOME")
    if dev_home then
        G_reader_settings:saveSetting("home_dir", dev_home)
    end
    G_reader_settings:delSetting("kcui_airplane_mode")
    G_reader_settings:delSetting("kcui_airplane_mode_restore")
    G_reader_settings:delSetting("kcui_status_view")
    moveWallpapers()
    if not applied.warmth_location_cleared then
        local location = G_reader_settings:readSetting("autowarmth_location")
        if location == nil or location == "Geysir" then
            G_reader_settings:saveSetting("autowarmth_location", "")
            G_reader_settings:delSetting("autowarmth_latitude")
            G_reader_settings:delSetting("autowarmth_longitude")
            G_reader_settings:delSetting("autowarmth_altitude")
            if G_reader_settings:readSetting("autowarmth_activate") == 1 then
                G_reader_settings:saveSetting("autowarmth_activate", 2)
            end
        end
        applied.warmth_location_cleared = true
    end
    if not applied.status_bar_defaults then
        applyStatusBar()
        applied.status_bar_defaults = true
    end
    if (tonumber(applied.status_font_version) or 0) < STATUS_FONT_VERSION then
        local footer = G_reader_settings:readSetting("footer")
        if footer and PREVIOUS_STATUS_FONT_SIZES[footer.text_font_size] then
            footer.text_font_size = STATUS_BAR.text_font_size
            G_reader_settings:saveSetting("footer", footer)
        end
        applied.status_font_version = STATUS_FONT_VERSION
    end
    if (tonumber(applied.styles_version) or 0) < STYLES_VERSION then
        replacePreviousStyles(G_reader_settings)
        Themes.forgetCustom()
        applied.styles_version = STYLES_VERSION
    end
    State.saveApplied(applied)
    G_reader_settings:delSetting(LEGACY_APPLIED)
    G_reader_settings:flush()
    if dev_home then
        local function autosave()
            G_reader_settings:flush()
            UIManager:scheduleIn(5, autosave)
        end
        UIManager:scheduleIn(5, autosave)
    end
end

return Defaults
