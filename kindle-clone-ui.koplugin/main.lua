local Version = require("version")

local MINIMUM_VERSION = 202607000000
local MINIMUM_NAME = "v2026.07"

if (Version:getNormalizedCurrentVersion() or 0) < MINIMUM_VERSION then
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template
    local _ = require("gettext")
    UIManager:scheduleIn(3, function()
        UIManager:show(InfoMessage:new{
            text = T(_("Kindle Clone UI needs KOReader %1 or later, so it has not been started.\n\nThis is KOReader %2. Please update KOReader."),
                MINIMUM_NAME, Version:getShortVersion()),
        })
    end)
    return { disabled = true }
end

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local CenterContainer = require("ui/widget/container/centercontainer")
local Defaults = require("kcui/defaults")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Library = require("kcui/library")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ReadHistory = require("readhistory")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Panel = require("kcui/panel")
local Toolbar = require("kcui/toolbar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local _ = require("gettext")
local Common = require("kcui/common")
local Screen = Device.screen
local Books = Library.Books
local KindleFonts = Common.Fonts
local Navigation = Common.Navigation
local TopBar = Panel.TopBar
local U = Common.U

Defaults.apply()
KindleFonts.apply()
Common.Rotation.install()
Panel.install()
require("kcui/restyle").install()
require("kcui/selection").install()
Library.install()
require("kcui/goto").Bookmarks.install()
require("kcui/themes").install()
if G_reader_settings:isTrue("autoremove_deleted_items_from_history") then
    ReadHistory:clearMissing()
end

local function lastBook()
    for _i, item in ipairs(ReadHistory.hist) do
        if item.select_enabled and not Library.isImage(item.file) then
            return item.file
        end
    end
end

local function coverWidget(fm, file, w, h)
    local outline = U.ceil(5)
    local border = Size.border.thin
    local inner_w = w - 2 * (outline + border)
    local inner_h = h - 2 * (outline + border)

    local entry = Books.get(file) or Books.extract(fm, file)
    local bb = Books.cover(file, math.floor(inner_h * 1.5), inner_h)
    local content
    if bb then
        content = ImageWidget:new{ image = bb, image_disposable = false }
        inner_w, inner_h = bb:getWidth(), bb:getHeight()
    else
        local label = TextBoxWidget:new{
            text = entry.title or file:match("([^/]+)$"),
            face = U.face("cfont", 7),
            bold = true,
            width = inner_w - 2 * U(4),
            height = inner_h - 2 * U(4),
            height_overflow_show_ellipsis = true,
            height_adjust = true,
            alignment = "center",
        }
        label.overlap_offset = { U(4),
            math.max(U(4), math.floor(inner_h / 3 - label:getSize().h / 2)) }
        content = OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            label,
        }
    end

    return FrameContainer:new{
        bordersize = outline,
        color = Blitbuffer.COLOR_WHITE,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        FrameContainer:new{
            bordersize = border,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                content,
            },
        },
    }
end

local function bottomBar(fm, active, menu)
    local w = Screen:getWidth()
    local cover_h = U.ceil(66)
    local cover_w = math.floor(cover_h * 2 / 3)
    local h = cover_h + Size.padding.default + U(10)
    local line_y = math.floor(cover_h * 0.4)
    local left_pad = U(21.27)
    local right_pad = U(21.27)
    local left_slot = math.floor((w - cover_w) / 2) - left_pad
    local right_slot = math.floor((w - cover_w) / 2) - right_pad
    local face = U.face("cfont", 18)

    local library = TextWidget:new{ text = _("Library"), face = face, bold = active ~= "history" }
    local history = TextWidget:new{ text = _("History"), face = face, bold = active == "history" }
    local label_h = library:getSize().h
    local line_h = U.ceil(2)
    local line_outline = U.ceil(5)
    local below_line = line_y + line_h
    local label_y = below_line + math.floor((h - below_line - label_h) / 2) - U(2.5)
    library.overlap_offset = { left_pad + math.floor((left_slot - library:getSize().w) / 2), label_y }
    history.overlap_offset = { w - right_pad - right_slot + math.floor((right_slot - history:getSize().w) / 2), label_y }

    local tab = active == "history" and history or library
    local tab_w = tab:getSize().w
    local underline_w = math.floor(tab_w * 0.7)
    local underline_y = label_y + tab:getBaseline()
        + math.floor((label_h - tab:getBaseline()) * 0.75) + U.ceil(2)

    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LineWidget:new{
            dimen = Geom:new{ w = w, h = line_h + 2 * line_outline },
            background = Blitbuffer.COLOR_WHITE,
            overlap_offset = { 0, line_y - line_outline },
        },
        LineWidget:new{
            dimen = Geom:new{ w = w, h = line_h },
            background = Blitbuffer.COLOR_BLACK,
            overlap_offset = { 0, line_y },
        },
        library,
        history,
        LineWidget:new{
            dimen = Geom:new{ w = underline_w, h = line_h },
            background = Blitbuffer.COLOR_BLACK,
            overlap_offset = { tab.overlap_offset[1] + math.floor((tab_w - underline_w) / 2), underline_y },
        },
    }

    local book = lastBook()
    local cover_tap_w = 0
    if book then
        local book_h = U.ceil(72)
        local cover = coverWidget(fm, book, math.floor(book_h * 2 / 3), book_h)
        local size = cover:getSize()
        cover.overlap_offset = { math.floor((w - size.w) / 2), math.floor((cover_h - size.h) / 2) + U(4) }
        table.insert(layout, cover)
        cover_tap_w = size.w
    end

    local bar
    bar = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        ges_events = {
            TapBottomBar = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
        },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            layout,
        },
    }
    function bar:onTapBottomBar(_ev, ges)
        local x = ges.pos.x - self.dimen.x
        local reader = fm.document ~= nil
        if book and math.abs(x - w / 2) <= cover_tap_w / 2 + Size.padding.large then
            if active ~= "library" then menu.close_callback() end
            if not (reader and book == fm.document.file) then
                filemanagerutil.openFile(fm, book)
            end
        elseif reader then
            menu.close_callback()
            Navigation.toLibrary(fm, x >= w / 2 and function(home_fm) home_fm.history:onShowHist() end or nil)
        elseif x < w / 2 then
            if active ~= "library" then
                menu.close_callback()
            elseif fm.file_chooser.path ~= filemanagerutil.getHomeFolder() then
                fm.file_chooser:changeToPath(filemanagerutil.getHomeFolder())
            else
                fm.file_chooser:onGotoPage(1)
            end
        else
            if active ~= "library" and active ~= "history" then
                menu.close_callback()
                fm.history:onShowHist()
            elseif active == "library" then
                fm.history:onShowHist()
            else
                menu:onGotoPage(1)
            end
        end
        return true
    end
    return bar
end

local function inHome(path, home)
    return path == home or path:sub(1, #home + 1) == home .. "/"
end

local function isMainUI(ui)
    return ui ~= nil and (ui == require("apps/filemanager/filemanager").instance
        or ui == require("apps/reader/readerui").instance)
end

local function tabFor(menu)
    if menu.name == "filemanager" then
        return "library"
    end
    local fm = require("apps/filemanager/filemanager").instance
    if menu.name == "history" and menu.ui == fm then
        return "history"
    end
    if menu.name == "filesearcher" and fm and menu.ui == fm then
        return "search"
    end
    if fm and fm.folder_shortcuts and menu._manager == fm.folder_shortcuts and not menu.select_callback then
        return "shortcuts"
    end
    if menu.name == "collections" and isMainUI(menu.ui) then
        return "collection"
    end
    local manager = menu._manager
    if manager and manager.ui and isMainUI(manager.ui) and manager == manager.ui.collections
            and menu.name ~= "collections" and manager.selected_collections == nil
            and menu.onMenuChoice == manager.onCollListChoice then
        return "collections"
    end
end

local function decorate(menu, active, orig_init)
    local fm = require("apps/filemanager/filemanager").instance
    local ui = menu.ui or (menu._manager and menu._manager.ui) or fm
    Library.attach(menu)
    menu._kcui_tab = active
    menu.no_title = true
    menu.show_path = true
    local home = G_reader_settings:readSetting("home_dir")
    if active == "library" and home and G_reader_settings:isTrue("lock_home_folder")
            and not inHome(menu.path, home) then
        menu.path = home
    end
    local top = TopBar.new(ui, function() return menu.show_parent or menu end)
    local bar = bottomBar(ui, active, menu)
    local header
    if active == "search" then
        local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        header = Toolbar.results(menu, Screen:getWidth(), FileSearcher.search_string)
    elseif active == "shortcuts" then
        local count = 0
        for _i, shortcut in pairs(menu._manager.folder_shortcuts) do
            if shortcut.text then count = count + 1 end
            for _i in pairs(shortcut.providers or {}) do count = count + 1 end
        end
        header = Toolbar.titleHeader(Screen:getWidth(), _("Folder shortcuts"), count,
            function() menu.close_callback() end,
            function() menu._manager:addShortcut() end)
    elseif active == "collections" then
        local ReadCollection = require("readcollection")
        local count = 0
        for _i in pairs(ReadCollection.coll) do count = count + 1 end
        header = Toolbar.titleHeader(Screen:getWidth(), _("Collections"), count,
            function() menu.close_callback(true) end,
            function() menu._manager:addCollection() end,
            function(anchor)
                Toolbar.present(function() menu._manager:showCollListDialog() end, anchor)
            end)
    elseif active == "collection" then
        local ReadCollection = require("readcollection")
        local name = menu.path or ReadCollection.default_collection_name
        local count = 0
        for _i in pairs(ReadCollection.coll[name] or {}) do count = count + 1 end
        local title = menu._manager:getCollectionTitle(name)
        header = Toolbar.titleHeader(Screen:getWidth(), title, count,
            function() menu.close_callback() end,
            nil,
            function(anchor)
                Toolbar.present(function() menu._manager:showCollDialog() end, anchor)
            end)
    end
    local header_h = header and header.dimen.h or 0
    menu.height = Screen:getHeight() - top.dimen.h - header_h - bar.dimen.h
    orig_init(menu)
    if header then
        menu[1] = VerticalGroup:new{ align = "left", top, header, menu[1], bar }
    else
        menu[1] = VerticalGroup:new{ align = "left", top, menu[1], bar }
    end
    menu.dimen.h = menu.dimen.h + top.dimen.h + header_h + bar.dimen.h
end

local orig_booklist_init = BookList.init
BookList.init = function(menu)
    local active = tabFor(menu)
    if not active or menu.height then
        return orig_booklist_init(menu)
    end
    decorate(menu, active, orig_booklist_init)
end

local Menu = require("ui/widget/menu")
local orig_menu_init = Menu.init
Menu.init = function(menu)
    local active = not menu.height and tabFor(menu)
    if active ~= "shortcuts" and active ~= "collections" then
        return orig_menu_init(menu)
    end
    decorate(menu, active, orig_menu_init)
end

local KindleCloneUI = WidgetContainer:extend{
    name = "kindlecloneui",
    is_doc_only = false,
}

function KindleCloneUI:init()
    logger.info("KindleCloneUI: init")
    require("kcui/restyle").rebuildOpenPopups()
    self.ui.menu:registerToMainMenu(self)
    local ui = self.ui
    if ui.document then
        Defaults.refreshBookStyles(ui)
        require("kcui/goto").Bookmarks.register(ui)
        require("kcui/themes").register(ui)
        require("kcui/restyle").refreshStatusBar(ui)
        require("kcui/restyle").registerStatusTap(ui)
    end
    UIManager:nextTick(function()
        require("kcui/warmth").installSchedule(ui)
        Defaults.firstRun(ui)
    end)
end

function KindleCloneUI:addToMainMenu(menu_items)
    menu_items.kcui_book_styles = {
        text = _("Reset to Kindle-like defaults"),
        sorting_hint = "device",
        callback = function()
            Defaults.confirmReset(self.ui)
        end,
    }
    menu_items.menu_activate = nil
end

return KindleCloneUI
