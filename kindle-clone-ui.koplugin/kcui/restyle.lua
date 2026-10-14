local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local PathChooser = require("ui/widget/pathchooser")
local ReaderCoptListener = require("apps/reader/modules/readercoptlistener")
local ReaderFooter = require("apps/reader/modules/readerfooter")
local ReaderStatus = require("apps/reader/modules/readerstatus")
local ReaderView = require("apps/reader/modules/readerview")
local RenderImage = require("ui/renderimage")
local ReadHistory = require("readhistory")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local Panel = require("kcui/panel")
local Themes = require("kcui/themes")
local TopBar = Panel.TopBar
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template
local Common = require("kcui/common")
local Screen = Device.screen
local Divider = Common.Divider
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/restyle%.lua$") .. "/icons"

local STATUS_PAD = 3
local STATUS_VIEW = "kcui_status_view"
local STATUS_VIEWS = { "all", "no_progress", "none" }

local function statusView()
    local saved = G_reader_settings:readSetting(STATUS_VIEW)
    return (saved == "no_progress" or saved == "none") and saved or "all"
end

local Popup = {}

local MAX_HEIGHT_RATIO = 0.95
local MIN_FONT_SIZE = 10
local BUTTON_FONT = "cfont"

local function padding()
    return U(20)
end

local function innerWidth()
    return math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9) - 2 * Size.border.window
end

function Popup.textWidth()
    return innerWidth() - 2 * padding()
end

function Popup.face()
    return U.face("cfont", 19)
end

function Popup.titleFace()
    return U.face("tfont", 19)
end

local function buttonFace()
    return U.face(BUTTON_FONT, 17)
end

local function buttonRowPadding()
    return U(14)
end

function Popup.message(text, face)
    return TextBoxWidget:new{
        text = text,
        face = face or Popup.face(),
        width = Popup.textWidth(),
        alignment = "center",
    }
end

local function isEnabled(entry)
    if entry.enabled_func then
        return entry.enabled_func()
    end
    return entry.enabled ~= false
end

local function separator(w, h)
    return LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{ w = w, h = h },
    }
end

local function buttonRow(entries, width, sep, top, cells)
    local cell_w = math.floor((width - (#entries - 1) * sep) / #entries)
    local labels, label_h = {}, 0
    for i, entry in ipairs(entries) do
        labels[i] = TextBoxWidget:new{
            text = (entry.text_func and entry.text_func()) or entry.text or "",
            face = buttonFace(),
            bold = true,
            fgcolor = isEnabled(entry) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            width = cell_w - 2 * U(8),
            alignment = "center",
        }
        label_h = math.max(label_h, labels[i]:getSize().h)
    end
    local row_h = label_h + 2 * buttonRowPadding()
    local row = HorizontalGroup:new{}
    local x = Size.border.window
    for i, label in ipairs(labels) do
        if i > 1 then
            table.insert(row, separator(sep, row_h))
            x = x + sep
        end
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = row_h },
            label,
        })
        table.insert(cells, { entry = entries[i], rect = Geom:new{ x = x, y = top, w = cell_w, h = row_h } })
        x = x + cell_w
    end
    return row, row_h
end

function Popup.build(widget, body, rows)
    local pad = padding()
    local width = innerWidth()
    local sep = Size.line.medium
    local body_h = body:getSize().h
    local group = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = pad },
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = body_h },
            body,
        },
        VerticalSpan:new{ width = pad },
    }
    local y = Size.border.window + 2 * pad + body_h
    widget.popup_cells = {}
    for _i, entries in ipairs(rows) do
        if #entries > 0 then
            table.insert(group, separator(width, sep))
            local row, row_h = buttonRow(entries, width, sep, y + sep, widget.popup_cells)
            table.insert(group, row)
            y = y + sep + row_h
        end
    end
    widget.popup_frame = FrameContainer:new{
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
    widget.movable = MovableContainer:new{
        widget.popup_frame,
        unmovable = widget.unmovable,
    }
    widget[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        widget.movable,
    }
    if Device:isTouchDevice() then
        widget.ges_events.TapPopup = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    if widget.dismissable and Device:hasKeys() then
        widget.key_events.Close = { { Device.input.group.Back } }
    end
end

function Popup.onTap(widget, ges)
    local frame = widget.popup_frame.dimen
    if not frame or not frame:contains(ges.pos) then
        if widget.dismissable then
            widget:onClose()
        end
        return true
    end
    for _i, cell in ipairs(widget.popup_cells) do
        local rect = cell.rect
        local hit = Geom:new{ x = frame.x + rect.x, y = frame.y + rect.y, w = rect.w, h = rect.h }
        if hit:contains(ges.pos) then
            if isEnabled(cell.entry) then
                cell.entry.callback()
            end
            break
        end
    end
    return true
end

local function tooTall(widget)
    return widget.popup_frame:getSize().h > MAX_HEIGHT_RATIO * Screen:getHeight()
end

local function smallerFace(face)
    local size = face.orig_size
    while size > MIN_FONT_SIZE do
        size = size - 1
        local smaller = Font:getFace(face.orig_font, size)
        if smaller.size < face.size then
            return smaller
        end
    end
end

local function confirmBoxInit(self)
    local face = self.face or Popup.face()
    self.text_widget_width = Popup.textWidth()
    self.text_group = VerticalGroup:new{
        align = "center",
        Popup.message(self.text, face),
    }
    if self._added_widgets then
        table.insert(self.text_group, VerticalSpan:new{ width = Size.padding.large })
        for _i, added in ipairs(self._added_widgets) do
            table.insert(self.text_group, added)
        end
    end
    local function closeUnlessKept()
        if not self.keep_dialog_open then
            UIManager:close(self)
        end
    end
    local main = {
        {
            text = self.cancel_text,
            callback = function()
                self.cancel_callback()
                UIManager:close(self)
            end,
        },
    }
    if not self.no_ok_button then
        table.insert(main, {
            text = self.ok_text,
            callback = function()
                self.ok_callback()
                closeUnlessKept()
            end,
        })
    end
    local rows = { main }
    for i, buttons_row in ipairs(self.other_buttons or {}) do
        local entries = {}
        for _i, button in ipairs(buttons_row) do
            table.insert(entries, {
                text = button.text,
                callback = function()
                    if button.callback then
                        button.callback()
                    end
                    closeUnlessKept()
                end,
            })
        end
        table.insert(rows, self.other_buttons_first and i or #rows + 1, entries)
    end
    Popup.build(self, self.text_group, rows)
    if tooTall(self) then
        local smaller = smallerFace(face)
        if smaller then
            self.face = smaller
            if self._added_widgets then
                self:_preserveAddedWidgets()
            end
            self:free()
            self:init()
        end
    end
end

local function multiConfirmBoxInit(self)
    local function choice(text, text_func, enabled, callback)
        return {
            text = text,
            text_func = text_func,
            enabled = enabled,
            callback = function()
                callback()
                UIManager:close(self)
            end,
        }
    end
    Popup.build(self, Popup.message(self.text, self.face), {
        {
            choice(self.cancel_text, nil, true, self.cancel_callback),
            choice(self.choice1_text, self.choice1_text_func, self.choice1_enabled, self.choice1_callback),
            choice(self.choice2_text, self.choice2_text_func, self.choice2_enabled, self.choice2_callback),
        },
    })
end

local function defaultButtonLabelHeight()
    local probe = TextWidget:new{
        text = "Ag",
        face = Font:getFace(Button.text_font_face, Button.text_font_size),
        bold = Button.text_font_bold,
    }
    local height = probe:getSize().h
    probe:free()
    return height
end

function Popup.tallButtonHeight()
    local probe = TextWidget:new{ text = "Ag", face = buttonFace(), bold = true }
    local height = probe:getSize().h
    probe:free()
    return height + 2 * (buttonRowPadding() - Size.padding.buttontable)
end

local function styleButtonTable(buttons)
    local face, height = buttonFace(), defaultButtonLabelHeight()
    for _i, row in ipairs(buttons) do
        for _i, entry in ipairs(row) do
            if (entry.text or entry.text_func) and not entry.menu_style and not entry.font_face and not entry.font_size then
                entry.font_face = BUTTON_FONT
                entry.font_size = face.orig_size
                entry.height = entry.height or height
            end
        end
    end
end

local function onTapPopup(self, _ev, ges)
    return Popup.onTap(self, ges)
end

local function installPopups()
    if ConfirmBox._kcui_popup then return end
    ConfirmBox._kcui_popup = true

    ConfirmBox.face = nil
    ConfirmBox.init = confirmBoxInit
    ConfirmBox.onTapPopup = onTapPopup

    MultiConfirmBox.face = nil
    MultiConfirmBox.init = multiConfirmBoxInit
    MultiConfirmBox.onTapPopup = onTapPopup

    local buttonTableInit = ButtonTable.init
    ButtonTable.init = function(self)
        styleButtonTable(self.buttons)
        buttonTableInit(self)
    end

    ButtonDialog.title_align = "center"
    ButtonDialog.info_face = Popup.face()
    ButtonDialog.title_face = Popup.titleFace()

    local titleBarInit = TitleBar.init
    TitleBar.init = function(self)
        if not self.fullscreen then
            self.align = "center"
            self.title_face = self.title_face or Popup.titleFace()
            self.bottom_line_color = self.bottom_line_color or Blitbuffer.COLOR_GRAY
        end
        titleBarInit(self)
    end

    InfoMessage.show_icon = false
    InfoMessage.alignment = "center"
    local infoInit = InfoMessage.init
    InfoMessage.init = function(self)
        if self.image and rawget(self, "show_icon") == nil then
            self.show_icon = true
        end
        if not self.show_icon then
            if not self.face and not self.monospace_font then
                self.face = Popup.face()
            end
            self.width = self.width or Popup.textWidth()
        end
        infoInit(self)
        if not self.show_icon then
            self.movable[1].padding = padding()
        end
    end
end

local function hiddenByLock(path)
    return path ~= "/"
        and G_reader_settings:isTrue("lock_home_folder")
        and path == G_reader_settings:readSetting("home_dir")
end

local function installPathChooser()
    if PathChooser._kcui_go_up then return end
    PathChooser._kcui_go_up = true
    local genItemTable = PathChooser.genItemTable
    PathChooser.genItemTable = function(self, dirs, files, path)
        local item_table = genItemTable(self, dirs, files, path)
        if path and hiddenByLock(path) then
            table.insert(item_table, self.show_current_dir_for_hold and 2 or 1, {
                text = BD.mirroredUILayout() and BD.ltr("../ ⬆") or "⬆ ../",
                path = path .. "/..",
                is_go_up = true,
            })
        end
        return item_table
    end
    PathChooser.onFolderUp = function(self)
        self:changeToPath(string.format("%s/..", self.path), self.path)
    end
end

local pending_history_hold

local function removeFromHistory(menu, item)
    local manager = menu._manager
    if menu.file_dialog then
        UIManager:close(menu.file_dialog)
    end
    local filtered = manager.search_string or manager.selected_collections or manager.filter ~= "all"
    ReadHistory:removeItem(item, not filtered and item.idx or nil)
    manager:updateItemTable()
end

local function showChoice(manager_class, context, post_delete_callback)
    local file = context.item.file
    UIManager:show(MultiConfirmBox:new{
        text = _("Delete file permanently or remove from history?") .. "\n\n" .. BD.filepath(filemanagerutil.abbreviate(file)),
        choice1_text = _("Delete file"),
        choice1_callback = function()
            if manager_class:deleteFile(file, true) and post_delete_callback then
                post_delete_callback()
            end
        end,
        choice2_text = _("Remove\nfrom history"),
        choice2_callback = function() removeFromHistory(context.menu, context.item) end,
    })
end

local function installHistoryDelete()
    if FileManagerHistory._kcui_delete then return end
    FileManagerHistory._kcui_delete = true

    local onMenuHold = FileManagerHistory.onMenuHold
    FileManagerHistory.onMenuHold = function(menu, item)
        local result = onMenuHold(menu, item)
        local dialog = menu.file_dialog
        if dialog then
            local context = { menu = menu, item = item }
            pending_history_hold = context
            local close = dialog.onCloseWidget
            dialog.onCloseWidget = function(...)
                if pending_history_hold == context then
                    pending_history_hold = nil
                end
                if close then
                    return close(...)
                end
            end
        end
        return result
    end

    local showDeleteFileDialog = FileManager.showDeleteFileDialog
    FileManager.showDeleteFileDialog = function(manager_class, filepath, post_delete_callback, pre_delete_callback)
        local context = pending_history_hold
        if context and context.item.file == filepath and context.menu._manager.booklist_menu == context.menu then
            return showChoice(manager_class, context, post_delete_callback)
        end
        return showDeleteFileDialog(manager_class, filepath, post_delete_callback, pre_delete_callback)
    end
end

local END_OF_BOOK_DIALOG = "end_document"

local end_of_book_status

local function installEndOfBook()
    if ReaderStatus._kcui_end_of_book then return end
    ReaderStatus._kcui_end_of_book = true

    local onEndOfBook = ReaderStatus.onEndOfBook
    ReaderStatus.onEndOfBook = function(self, ...)
        end_of_book_status = self
        local result = onEndOfBook(self, ...)
        end_of_book_status = nil
        return result
    end

    local init = ButtonDialog.init
    ButtonDialog.init = function(self)
        if self.name == END_OF_BOOK_DIALOG and end_of_book_status and not self._kcui_customized then
            local reader_status = end_of_book_status
            self._kcui_customized = true
            self.buttons[1][1] = {
                text = _("View cover"),
                callback = function()
                    UIManager:close(self)
                    reader_status.ui.bookinfo:onShowBookCover()
                end,
            }
            table.insert(self.buttons, {
                {
                    text = _("Mark as finished & return to library"),
                    height = Popup.tallButtonHeight(),
                    callback = function()
                        UIManager:close(self)
                        reader_status:markBook(true)
                        UIManager:nextTick(function()
                            reader_status:openFileBrowser()
                        end)
                    end,
                },
            })
        end
        init(self)
    end
end

local TITLES = {
    ["appbar.filebrowser"] = _("Library"),
    ["appbar.navigation"] = _("Navigation"),
    ["appbar.typeset"] = _("Typeset"),
    ["appbar.settings"] = _("Config"),
    ["appbar.tools"] = _("Tools"),
    ["appbar.search"] = _("Exploration"),
    ["appbar.menu"] = _("Navigate"),
}

local KINDLE_ICONS = {
    ["appbar.filebrowser"] = "series",
    ["appbar.settings"] = "edit",
    ["appbar.tools"] = "manage-apps",
    ["appbar.search"] = "info-filled",
    ["appbar.menu"] = "list",
}

local function restyleTabs(menu)
    local bar = menu.bar
    if not (bar and bar.icon_widgets and menu.tab_item_table) then return end
    local face = U.face("cfont", 11)
    for k, button in ipairs(bar.icon_widgets) do
        local tab = menu.tab_item_table[k]
        local title = tab and TITLES[tab.icon]
        if title then
            local w, h = button.dimen.w, button.dimen.h
            local size = math.floor(button.image:getSize().h * 0.62 + 0.5)
            button.image:free()
            local kindle = KINDLE_ICONS[tab.icon]
            if kindle then
                button.image = ImageWidget:new{
                    original_in_nightmode = false,
                    file = ICONS .. "/" .. kindle .. ".svg",
                    width = size,
                    height = size,
                    alpha = true,
                }
            else
                button.image = IconWidget:new{ icon = tab.icon, width = size, height = size }
            end
            local label = TextWidget:new{ text = title, face = face, bold = true, max_width = w }
            local extra = U(5)
            button[1] = CenterContainer:new{
                dimen = Geom:new{ w = w, h = h + extra },
                VerticalGroup:new{
                    align = "center",
                    VerticalSpan:new{ width = extra },
                    button.image,
                    VerticalSpan:new{ width = U(2) },
                    label,
                },
            }
            button.dimen = Geom:new{ x = button.dimen.x, y = button.dimen.y, w = w, h = h + extra }
            button:initGesListener()
            bar._kcui_extra = extra
        end
    end
    local extra = bar._kcui_extra
    if extra then
        for _i, sep in ipairs(bar.icon_seps or {}) do
            sep.dimen.h = sep.dimen.h + extra
        end
        bar.height = bar.height + extra
        bar.dimen.h = bar.height
        bar.bar_icon_group:resetLayout()
    end
end

local function packTabs(menu)
    local bar = menu.bar
    if not (bar and bar.bar_icon_group and bar.icon_widgets and #bar.icon_widgets > 1) then return end
    local stretch
    for _i, widget in ipairs(bar.bar_icon_group) do
        if widget.width and not widget.dimen and widget ~= bar.icon_widgets[#bar.icon_widgets] and not widget.icon then
            if widget.width > (stretch and stretch.width or 0) then stretch = widget end
        end
    end
    if not stretch or stretch.width <= 0 then return end
    local shift = stretch.width
    stretch.width = 0
    bar.bar_icon_group:resetLayout()
    local last = bar.icon_widgets[#bar.icon_widgets]
    local orig_callback = last.callback
    last.callback = function()
        orig_callback()
        local mirrored = require("ui/bidi").mirroredUILayout()
        for _i, segment in ipairs(bar.bar_sep.empty_segments or {}) do
            segment.s = segment.s + (mirrored and shift or -shift)
            segment.e = segment.e + (mirrored and shift or -shift)
        end
    end
    local edge
    for i, widget in ipairs(bar.bar_icon_group) do
        if widget == last then
            edge = bar.bar_icon_group[i + 1]
            break
        end
    end
    if edge and edge.dimen and edge.style then
        if bar._kcui_extra then
            edge.dimen.h = edge.dimen.h + bar._kcui_extra
            bar.bar_icon_group:resetLayout()
        end
        for k, button in ipairs(bar.icon_widgets) do
            local callback = button.callback
            button.callback = function()
                callback()
                edge.style = k == #bar.icon_widgets and "solid" or "none"
            end
        end
    end
    local close_size = U(28.4)
    local inset = math.floor(close_size * 0.205)
    local close = InputContainer:new{
        dimen = Geom:new{ w = close_size, h = close_size },
        ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. "/close.svg",
            width = close_size,
            height = close_size,
            alpha = true,
        },
    }
    close.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = function()
            return Geom:new{ x = close.dimen.x - U(12), y = close.dimen.y - U(12), w = close_size + U(24), h = close_size + U(24) }
        end } },
    }
    function close:onTapClose()
        menu:closeMenu()
        return true
    end
    local used = bar.bar_icon_group:getSize().w
    local gap = bar.width - used - close_size - U(21.27) + inset
    if gap > 0 then
        table.insert(bar.bar_icon_group, HorizontalSpan:new{ width = gap })
        table.insert(bar.bar_icon_group, close)
        bar.bar_icon_group:resetLayout()
    end
    local current = bar.icon_widgets[menu.cur_tab]
    if current then current.callback() end
end

local function buildHeader(menu)
    local bar = TopBar.new(nil, function() return menu.show_parent end, true, true)
    bar.ges_events = {}
    local group = VerticalGroup:new{
        bar,
        VerticalSpan:new{ width = 2 },
        LineWidget:new{
            background = Divider.color,
            dimen = Geom:new{ w = Screen:getWidth(), h = Divider.height },
        },
    }
    local header = Widget:new{ group = group }
    function header:getSize()
        local size = self.group:getSize()
        local lift = menu.bordersize or 0
        return Geom:new{ w = size.w, h = size.h - lift }
    end
    function header:paintTo(bb, x, y)
        local top = y - (menu.bordersize or 0)
        self.group:paintTo(bb, x, top)
        local tabs = menu.bar
        local selected = tabs and tabs.icon_widgets and tabs.icon_widgets[menu.cur_tab]
        if not selected then return end
        local offset = 0
        for _i, widget in ipairs(tabs.bar_icon_group) do
            if widget == selected then break end
            offset = offset + widget:getSize().w
        end
        local sep = tabs.icon_seps and tabs.icon_seps[1]
        local sep_w = sep and sep.dimen.w or 0
        local left = math.max(0, offset - sep_w)
        local right = offset + selected:getSize().w + sep_w
        local line_h = Divider.height
        local line_y = top + bar:getSize().h + 2
        bb:paintRect(x + left, line_y, right - left, line_h, Blitbuffer.COLOR_BLACK)
    end
    function header:handleEvent(event)
        return self.group:handleEvent(event)
    end
    return header
end

local function installMainMenu()
    local TouchMenu = require("ui/widget/touchmenu")
    if TouchMenu._kcui_main then return end
    TouchMenu._kcui_main = true
    local orig_init = TouchMenu.init
    TouchMenu.init = function(menu, ...)
        if menu.tab_item_table then
            local tabs = {}
            for i, tab in ipairs(menu.tab_item_table) do
                if tab.icon == "appbar.filebrowser" and tab.callback then
                    if menu.last_index and menu.last_index > i then
                        menu.last_index = menu.last_index - 1
                    end
                else
                    table.insert(tabs, tab)
                end
            end
            if #tabs < #menu.tab_item_table then
                menu.tab_item_table = tabs
                if menu.last_index and menu.last_index > #tabs then
                    menu.last_index = #tabs
                end
            end
        end
        menu._kcui_header = buildHeader(menu)
        orig_init(menu, ...)
        if menu.not_shown then
            menu._kcui_header.group[1]:onCloseWidget()
        end
        restyleTabs(menu)
        packTabs(menu)
        if menu.device_info and menu.device_info[1] == menu.time_info then
            table.remove(menu.device_info, 1)
            menu.device_info:resetLayout()
        end
    end
    local orig_update = TouchMenu.updateItems
    local item_face = U.face("smallinfofont", 20)
    TouchMenu.updateItems = function(menu, ...)
        orig_update(menu, ...)
        if not TouchMenu._kcui_item_face then
            for _i, widget in ipairs(menu.item_group) do
                if widget.item and widget.menu == menu then
                    local class = getmetatable(widget)
                    if class and class.face then
                        class.face = item_face
                        TouchMenu._kcui_item_face = true
                        orig_update(menu, ...)
                    end
                    break
                end
            end
        end
        local group = menu.item_group
        if menu._kcui_header and group[1] ~= menu._kcui_header then
            table.insert(group, 1, menu._kcui_header)
        end
        group:resetLayout()
        menu.dimen.h = group:getSize().h + menu.bordersize * 2 + menu.padding
    end
end

local Restyle = {}

local BAND_HEIGHT = 1.9
local BAND_GAP = 4.75
local BAND_COLOR = Blitbuffer.Color8(0xBB)

local ProgressBand = Widget:extend{
    bar = nil,
}

function ProgressBand:getSize()
    if (self.bar:getSize().h or 0) == 0 then
        return Geom:new{ w = Screen:getWidth(), h = 0 }
    end
    self.bar.height = U(BAND_HEIGHT)
    return Geom:new{ w = Screen:getWidth(), h = self.bar.height + U(BAND_GAP) }
end

function ProgressBand:paintTo(bb, x, y)
    local size = self:getSize()
    if size.h == 0 then return end
    self.bar.width = size.w
    if statusView() == "none" then
        self.changed = Geom:new{ x = x, y = y, w = 0, h = self.bar:getSize().h }
        self.fill = nil
        return
    end
    self.bar:paintTo(bb, x, y)
    local fill = math.ceil(size.w * math.max(0, math.min(1, self.bar.percentage or 0)))
    local before = self.fill or fill
    self.fill = fill
    self.changed = Geom:new{ x = x + math.min(before, fill), y = y, w = math.abs(fill - before), h = self.bar:getSize().h }
    if self.changed.w > 0 then
        self.pending = self.pending and self.pending:combine(self.changed) or self.changed:copy()
    end
end

local StatusRow = Widget:extend{
    footer = nil,
}

function StatusRow:getSize()
    return Geom:new{ w = Screen:getWidth(), h = self.footer.height }
end

function StatusRow:progressText()
    local footer = self.footer
    local ui = footer.ui
    local choice = Panel.readingProgress(ui)
    if choice == "page" then
        return footer.pageno and footer.pages and T(_("Page %1 of %2"), footer.pageno, footer.pages) or ""
    end
    local left, label
    if choice == "book_time" then
        left, label = ui.document:getTotalPagesLeft(footer.pageno), _("%1 left in book")
    elseif choice == "chapter_time" then
        left = ui.toc:getChapterPagesLeft(footer.pageno, true) or ui.document:getTotalPagesLeft(footer.pageno)
        label = _("%1 left in chapter")
    end
    local per_page = left and ui.statistics.avg_time
    if not per_page or per_page ~= per_page then
        return ""
    end
    local minutes = math.max(1, math.floor(left * per_page / 60 + 0.5))
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    local parts = {}
    if hours > 0 then
        table.insert(parts, T(N_("1 hr", "%1 hrs", hours), hours))
    end
    if minutes > 0 then
        table.insert(parts, T(N_("1 min", "%1 mins", minutes), minutes))
    end
    return T(label, table.concat(parts, " "))
end

function StatusRow:itemsText()
    local footer = self.footer
    local texts = {}
    for i = 1, #footer.mode_index do
        local name = footer.mode_index[i]
        local generate = footer.textGeneratorMap[name]
        if footer.settings[name] and generate and not name:find("^dynamic_filler") then
            local text = generate(footer)
            if text and name == "percentage" then
                text = text:gsub("^%D*", "")
            end
            if text and text ~= "" then
                table.insert(texts, text)
            end
        end
    end
    return table.concat(texts, footer:genSeparator())
end

function StatusRow:face()
    local footer = self.footer
    local settings = footer.settings
    if settings.text_font_face == footer.default_settings.text_font_face then
        local found = Common.Fonts.found
        local path = settings.text_font_bold and found.ui_heavy or found.ui_regular
        if path then
            return Font:getFace(path, settings.text_font_size), false
        end
    end
    return footer.footer_text_face, settings.text_font_bold
end

local function charStart(text, index)
    while index > 1 and index <= #text and text:byte(index) >= 0x80 and text:byte(index) < 0xC0 do
        index = index - 1
    end
    return index
end

local function charEnd(text, index)
    while index < #text and text:byte(index + 1) >= 0x80 and text:byte(index + 1) < 0xC0 do
        index = index + 1
    end
    return index
end

function StatusRow:track(key, text, x, w, y, measure)
    self.drawn = self.drawn or {}
    local old = self.drawn[key]
    self.drawn[key] = { text = text, x = x, w = w }
    if old and old.text == text and old.x == x then return end
    local from, to = x, x + w
    if old then
        from, to = math.min(old.x, x), math.max(old.x + old.w, x + w)
        if old.x == x and old.w == w and #old.text == #text then
            local first, last = 1, #text
            while first <= last and text:byte(first) == old.text:byte(first) do first = first + 1 end
            while last >= first and text:byte(last) == old.text:byte(last) do last = last - 1 end
            first, last = charStart(text, first), charEnd(text, last)
            from = x + measure(text:sub(1, first - 1)) - STATUS_PAD
            to = x + measure(text:sub(1, last)) + STATUS_PAD
        end
    end
    if to > from then
        self.pending = self.pending or {}
        table.insert(self.pending, Geom:new{ x = from, y = y, w = to - from, h = self:getSize().h })
    end
end

function StatusRow:paintTo(bb, x, y)
    local size = self:getSize()
    local face, bold = self:face()
    local margin = Themes.narrowMargin()
    local max_width = math.floor(size.w / 2) - margin
    self.top = y
    local function measure(text)
        if text == "" then return 0 end
        local widget = TextWidget:new{ text = text, face = face, bold = bold }
        local w = widget:getSize().w
        widget:free()
        return w
    end
    local function draw(key, text, right)
        if text == "" then
            self:track(key, text, right and x + size.w - margin or x + margin, 0, y, measure)
            return
        end
        local widget = TextWidget:new{ text = text, face = face, bold = bold, max_width = max_width }
        local text_size = widget:getSize()
        local text_x = right and x + size.w - margin - text_size.w or x + margin
        widget:paintTo(bb, text_x, y + math.floor((size.h - text_size.h) / 2))
        widget:free()
        self:track(key, text, text_x, text_size.w, y, measure)
    end
    local shown = statusView()
    local visible = self.footer.pageno and shown ~= "none"
    draw("progress", visible and shown == "all" and self:progressText() or "", false)
    draw("items", visible and self:itemsText() or "", true)
end

local function findItem(items, text)
    for i, item in ipairs(items or {}) do
        if item.text == text then
            return item, i
        end
    end
end

local function addEdgesStyle(footer, menu_items)
    local progress = findItem(menu_items.status_bar and menu_items.status_bar.sub_item_table, _("Progress bar"))
    local settings = footer.settings
    local margins = T(_("Margins: %1"), settings.progress_margin and _("same as book margins") or settings.progress_margin_width)
    for _i, item in ipairs(progress and progress.sub_item_table or {}) do
        if item.text_func and item.text_func() == margins then
            item.enabled_func = function()
                return not settings.disable_progress_bar and not settings.kcui_edges
            end
        end
    end
    for _i, item in ipairs(progress and progress.sub_item_table or {}) do
        local styles = item.sub_item_table
        local thick = findItem(styles, _("Thick"))
        local thin, thin_index = findItem(styles, _("Thin"))
        if thick and thin and not findItem(styles, _("Medium")) then
            local styleName = item.text_func
            item.text_func = function()
                return settings.kcui_edges and _("Thickness and height: edges") or styleName()
            end
            thick.checked_func = function()
                return not settings.progress_style_thin and not settings.kcui_edges
            end
            for _j, style in ipairs({ thick, thin }) do
                local choose = style.callback
                style.callback = function(...)
                    settings.kcui_edges = nil
                    return choose(...)
                end
            end
            thin.separator = nil
            table.insert(styles, thin_index + 1, {
                text = _("Edges"),
                radio = true,
                separator = true,
                checked_func = function()
                    return settings.kcui_edges == true
                end,
                callback = function()
                    settings.kcui_edges = true
                    settings.progress_style_thin = nil
                    if settings.progress_bar_position == "alongside" then
                        settings.progress_bar_position = "below"
                    end
                    footer.progress_bar:updateStyle(true, settings.progress_style_thick_height)
                    footer:setTocMarkers()
                    footer:refreshFooter(true, true)
                end,
            })
            return
        end
    end
end

local function installStatusBar()
    if ReaderFooter._kcui_band then return end
    ReaderFooter._kcui_band = true
    local addToMainMenu = ReaderFooter.addToMainMenu
    ReaderFooter.addToMainMenu = function(footer, menu_items)
        addToMainMenu(footer, menu_items)
        addEdgesStyle(footer, menu_items)
    end
    local genProgressBarPositionMenuItems = ReaderFooter.genProgressBarPositionMenuItems
    ReaderFooter.genProgressBarPositionMenuItems = function(footer, value)
        local item = genProgressBarPositionMenuItems(footer, value)
        if value == "alongside" then
            item.enabled_func = function()
                return not footer.settings.kcui_edges
            end
        end
        return item
    end
    local updateFooterContainer = ReaderFooter.updateFooterContainer
    ReaderFooter.updateFooterContainer = function(footer)
        updateFooterContainer(footer)
        footer._kcui_band = nil
        footer._kcui_row = nil
        if footer.settings.kcui_edges then
            local bar = footer.progress_bar
            bar.bgcolor = BAND_COLOR
            bar.fillcolor = Blitbuffer.COLOR_BLACK
            bar.bordersize = 0
            bar.margin_h = 0
            bar.margin_v = 0
            bar.radius = 0
            bar._orig_bordersize = 0
            bar._orig_margin_v = 0
        end
        local frame = footer.vertical_frame
        for i, widget in ipairs(frame) do
            if footer.settings.kcui_edges and widget == footer.footer_container
                    and footer.settings.progress_bar_position ~= "alongside" then
                footer._kcui_row = StatusRow:new{ footer = footer }
                frame[i] = footer._kcui_row
            end
            if footer.settings.kcui_edges and widget == footer.progress_bar then
                footer._kcui_band = ProgressBand:new{ bar = footer.progress_bar }
                frame[i] = footer._kcui_band
                if i == #frame then
                    footer.footer_content = FrameContainer:new{
                        frame,
                        background = Blitbuffer.COLOR_WHITE,
                        bordersize = 0,
                        padding = 0,
                    }
                    footer.footer_positioner[1] = footer.footer_content
                end
            end
        end
    end
end

local function tapStatusBar(ui, ges)
    local footer = ui.view.footer
    if not (footer and footer.settings.kcui_edges and ui.view.footer_visible) then
        return footer ~= nil and footer:TapFooter(ges)
    end
    local current = statusView()
    for i, name in ipairs(STATUS_VIEWS) do
        if name == current then
            G_reader_settings:saveSetting(STATUS_VIEW, STATUS_VIEWS[i % #STATUS_VIEWS + 1])
        end
    end
    UIManager:setDirty(ui.dialog, "ui")
    return true
end

function Restyle.registerStatusTap(ui)
    local zones = {}
    for id, setting in pairs({ kcui_status_tap = "DTAP_ZONE_CONFIG", kcui_status_tap_ext = "DTAP_ZONE_CONFIG_EXT" }) do
        local zone = G_defaults:readSetting(setting)
        table.insert(zones, {
            id = id,
            ges = "tap",
            screen_zone = { ratio_x = zone.x, ratio_y = zone.y, ratio_w = zone.w, ratio_h = zone.h },
            overrides = {
                "tap_left_bottom_corner", "tap_right_bottom_corner", "readerconfigmenu_ext_tap", "readerconfigmenu_tap",
                "readerfooter_tap", "tap_forward", "tap_backward",
            },
            handler = function(ges) return tapStatusBar(ui, ges) end,
        })
    end
    ui:registerTouchZones(zones)
end

function Restyle.rebuildOpenPopups()
    for _i, window in ipairs(UIManager._window_stack) do
        local widget = window.widget
        if widget.ok_callback and widget.cancel_callback and widget.text and not widget.popup_frame then
            widget:free()
            widget:init()
            UIManager:setDirty("all", "ui")
        end
    end
end

function Restyle.refreshStatusBar(ui)
    local footer = ui.view and ui.view.footer
    if not (footer and footer.vertical_frame) then return end
    footer.footer_text_face = Font:getFace(footer.settings.text_font_face, footer.settings.text_font_size)
    footer.progress_bar.initial_pos_marker = footer.settings.initial_marker
    footer.progress_bar:updateStyle(not footer.settings.progress_style_thin)
    footer:updateFooterContainer()
    footer:resetLayout(true)
end

local function coverPage(view)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local cover = view._kcui_cover
    if cover and cover.w == sw and cover.h == sh then
        return cover.image
    end
    if cover and cover.image then
        cover.image:free()
    end
    cover = { w = sw, h = sh, image = false }
    view._kcui_cover = cover
    local ok, image = pcall(function()
        local document = view.ui.document
        local has_pages = document:getPageCount() > 1
        local text = has_pages and document:getTextFromXPointers(document:getPageXPointer(1), document:getPageXPointer(2))
        local found = has_pages and not (text and text:find("%S")) and document:getCoverPageImage()
        if found then
            local scale = math.min(sw / found:getWidth(), sh / found:getHeight())
            return RenderImage:scaleBlitBuffer(found, math.max(1, math.floor(found:getWidth() * scale)),
                math.max(1, math.floor(found:getHeight() * scale)), true)
        end
    end)
    cover.image = ok and image or false
    return cover.image
end

local HEADER_BAR = "kcui_header_progress_bar"

local function hideHeaderBar(view, bb, x, y)
    if G_reader_settings:isTrue(HEADER_BAR) then return end
    local header_h = view.ui.document:getHeaderHeight()
    if header_h > 0 then
        bb:paintRect(x, y + header_h - 3, Screen:getWidth(), 7, Blitbuffer.COLOR_WHITE)
    end
end

local function installHeaderBar()
    if ReaderCoptListener._kcui_header_bar then return end
    ReaderCoptListener._kcui_header_bar = true
    local getAltStatusBarMenu = ReaderCoptListener.getAltStatusBarMenu
    ReaderCoptListener.getAltStatusBarMenu = function(listener)
        local menu = getAltStatusBarMenu(listener)
        local _item, index = findItem(menu.sub_item_table, _("Chapter marks"))
        table.insert(menu.sub_item_table, (index or #menu.sub_item_table) + 1, {
            text = _("Progress bar"),
            checked_func = function()
                return G_reader_settings:isTrue(HEADER_BAR)
            end,
            callback = function()
                G_reader_settings:flipNilOrFalse(HEADER_BAR)
                UIManager:setDirty(listener.view.dialog, "ui")
            end,
        })
        return menu
    end
end

local function installQuietBar()
    if ReaderView._kcui_quiet_bar then return end
    ReaderView._kcui_quiet_bar = true
    local turning
    local setDirty = UIManager.setDirty
    UIManager.setDirty = function(manager, widget, refreshtype, region, dither)
        local view = turning
        local band = view and view.footer and view.footer._kcui_band
        local row = view and view.footer and view.footer._kcui_row
        if not (band and band.changed and row and row.top and widget == view.dialog
                and refreshtype == "partial" and region == nil) then
            return setDirty(manager, widget, refreshtype, region, dither)
        end
        setDirty(manager, widget, "partial", Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = row.top }, dither)
        manager:tickAfterNext(function()
            local regions = row.pending or {}
            row.pending = nil
            table.insert(regions, band.pending)
            band.pending = nil
            for _i, changed in ipairs(regions) do
                setDirty(manager, nil, "ui", changed)
            end
        end)
    end
    local recalculate = ReaderView.recalculate
    ReaderView.recalculate = function(view)
        local page = view.state.page
        local quiet = view.ui.rolling and view.view_mode == "page" and view.footer_visible
            and view.footer.settings.kcui_edges and view.footer.settings.progress_bar_position == "below"
            and page ~= 1 and view._kcui_turned_from ~= 1
            and not G_reader_settings:isTrue("avoid_flashing_ui")
            and not BD.mirroredUILayout() and not view.footer.settings.invert_progress_direction
        view._kcui_turned_from = page
        turning = quiet and view or nil
        local ok, err = pcall(recalculate, view)
        turning = nil
        if not ok then error(err, 0) end
    end
end

local function installCoverPage()
    if ReaderView._kcui_cover_page then return end
    ReaderView._kcui_cover_page = true
    local paintTo = ReaderView.paintTo
    ReaderView.paintTo = function(view, bb, x, y)
        paintTo(view, bb, x, y)
        local ui = view.ui
        if ui.rolling and view.view_mode == "page" then
            hideHeaderBar(view, bb, x, y)
        end
        if not (ui.rolling and view.view_mode == "page" and view.state.page == 1 and ui.document:getVisiblePageCount() == 1) then
            return
        end
        local image = coverPage(view)
        if image then
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            bb:paintRect(x, y, sw, sh, Blitbuffer.COLOR_WHITE)
            local blit = Screen.night_mode and bb.invertblitFrom or bb.blitFrom
            blit(bb, image, x + math.floor((sw - image:getWidth()) / 2), y + math.floor((sh - image:getHeight()) / 2), 0, 0, image:getWidth(), image:getHeight())
        end
    end
    local onCloseWidget = ReaderView.onCloseWidget
    ReaderView.onCloseWidget = function(view)
        if view._kcui_cover and view._kcui_cover.image then
            view._kcui_cover.image:free()
        end
        view._kcui_cover = nil
        return onCloseWidget(view)
    end
end

function Restyle.install()
    installStatusBar()
    installHeaderBar()
    installQuietBar()
    installCoverPage()
    installMainMenu()
    installPopups()
    installPathChooser()
    installHistoryDelete()
    installEndOfBook()
end

return Restyle
