local BookList = require("ui/widget/booklist")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local Common = require("kcui/common")
local T = require("ffi/util").template
local Screen = Device.screen
local Paint = Common.Paint
local U = Common.U

local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/kcui/toolbar%.lua$")
local ICONS = ROOT .. "/icons/toolbar"
local DROPDOWN_ICONS = ROOT .. "/icons"

local Box = Widget:extend{
    items = nil,
    width = nil,
    height = nil,
    item_h = nil,
    sep_h = nil,
    pad_x = nil,
    pad_y = nil,
    border = nil,
}

function Box:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Box:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
    local b = self.border
    bb:paintRect(x + b, y + b, self.width - 2 * b, self.height - 2 * b, Blitbuffer.COLOR_WHITE)
    local cy = y + b + self.pad_y
    for _i, item in ipairs(self.items) do
        if item.separator then
            local line = U.ceil(1)
            bb:paintRect(x + b, cy + math.floor((self.sep_h - line) / 2), self.width - 2 * b, line, Blitbuffer.Color8(0xBB))
            cy = cy + self.sep_h
        elseif item.small then
            if item.text_func then
                local t = item.text_func()
                if t ~= item.text then
                    item.text = t
                    item.widget:setText(t)
                end
            end
            local text = item.widget
            item.y = cy - y
            local right = x + self.width - b - self.pad_x
            local icon_w = 0
            if item.icon_widget then
                icon_w = item.icon_widget:getSize().w
                item.icon_widget:paintTo(bb, right - icon_w, cy + math.floor((item.h - item.icon_widget:getSize().h) / 2))
                icon_w = icon_w + U(6)
            end
            text:paintTo(bb, right - icon_w - text:getSize().w, cy + math.floor((item.h - text:getSize().h) / 2))
            cy = cy + item.h
        else
            if item.text_func then
                local t = item.text_func()
                if t ~= item.text then
                    item.text = t
                    item.widget:setText(t)
                end
            end
            local text = item.widget
            item.y = cy - y
            local tx = x + b + self.pad_x
            if item.checked_func then
                local box = self.check_size
                local icon = ImageWidget:new{
                    original_in_nightmode = false,
                    file = DROPDOWN_ICONS .. (item.checked_func() and "/checkbox-selected.svg" or "/checkbox-unselected.svg"),
                    width = box,
                    height = box,
                    alpha = true,
                }
                icon:paintTo(bb, tx, cy + math.floor((self.item_h - box) / 2))
                icon:free()
                tx = tx + box + U(10)
            end
            text:paintTo(bb, tx, cy + math.floor((self.item_h - text:getSize().h) / 2))
            if item.extra_widget then
                local main_top = cy + math.floor((self.item_h - text:getSize().h) / 2)
                local main_cap = math.floor(text.face.size * 0.667 + 0.5)
                local mid = main_top + text:getBaseline() - math.floor(main_cap / 2)
                local right = x + self.width - b - self.pad_x
                local icon_w = 0
                if item.extra_icon then
                    icon_w = item.extra_icon:getSize().w
                    item.extra_icon:paintTo(bb, right - icon_w, mid - math.floor(item.extra_icon:getSize().h / 2))
                    icon_w = icon_w + U(6)
                end
                local ew = item.extra_widget:getSize().w
                local extra_cap = math.floor(item.extra_widget.face.size * 0.667 + 0.5)
                item.extra_x = right - icon_w - ew - x
                item.extra_widget:paintTo(bb, right - icon_w - ew, mid - (item.extra_widget:getBaseline() - math.floor(extra_cap / 2)))
            end
            cy = cy + item.h
        end
    end
end

function Box:free()
    for _i, item in ipairs(self.items) do
        if item.widget then item.widget:free() end
        if item.icon_widget then item.icon_widget:free() end
        if item.extra_widget then item.extra_widget:free() end
        if item.extra_icon then item.extra_icon:free() end
    end
end

local Dropdown = InputContainer:extend{
    buttons = nil,
    anchor_right = nil,
    anchor_top = nil,
    notch_x = nil,
    modal = false,
}

local function flatten(buttons)
    local items = {}
    for _i, row in ipairs(buttons) do
        if #row == 0 then
            if #items > 0 and not items[#items].separator then
                table.insert(items, { separator = true })
            end
        else
            for _i, button in ipairs(row) do
                local text = button.text_func and button.text_func() or button.text
                if text then
                    table.insert(items, {
                        text = text,
                        enabled = button.enabled ~= false and (button.enabled_func == nil or button.enabled_func()),
                        callback = button.callback,
                        hold_callback = button.hold_callback,
                        checked_func = button.checked_func,
                        text_func = button.text_func,
                        small = button.small,
                        icon = button.icon,
                        extra = button.extra,
                    })
                end
            end
        end
    end
    while #items > 0 and items[#items].separator do
        table.remove(items)
    end
    return items
end

function Dropdown:init()
    local items = flatten(self.buttons)
    local face = U.face("cfont", 18)
    local pad_x = U(27)
    local max_w = 0
    local small_face = U.face("cfont", 15)
    for _i, item in ipairs(items) do
        if not item.separator then
            item.widget = TextWidget:new{
                text = item.text,
                face = item.small and small_face or face,
                fgcolor = item.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(0xAA),
            }
            if item.icon then
                item.icon_widget = ImageWidget:new{
                    original_in_nightmode = false,
                    file = item.icon,
                    width = U(11),
                    height = U(11),
                    alpha = true,
                }
            end
            local extra_w = 0
            if item.extra then
                item.extra_widget = TextWidget:new{ text = item.extra.text, face = small_face }
                extra_w = item.extra_widget:getSize().w + U(20)
                if item.extra.icon then
                    item.extra_icon = ImageWidget:new{
                        original_in_nightmode = false,
                        file = item.extra.icon,
                        width = U(11),
                        height = U(11),
                        alpha = true,
                    }
                    extra_w = extra_w + U(17)
                end
            end
            if not item.small then
                max_w = math.max(max_w, item.widget:getSize().w + extra_w)
            end
        end
    end
    local border = U(1.5)
    local check_size = U(16)
    local has_checks = false
    for _i, item in ipairs(items) do
        if item.checked_func then has_checks = true end
    end
    if has_checks then
        max_w = max_w + check_size + U(10)
    end
    local pad_y = U(6)
    local sep_h = U(14)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local count, seps, smalls = 0, 0, 0
    for _i, item in ipairs(items) do
        if item.separator then seps = seps + 1
        elseif item.small then smalls = smalls + 1
        else count = count + 1 end
    end
    local bottom = self.max_bottom or screen_h - U(20)
    local top = self.fit and math.min(self.anchor_top, U(70)) or self.anchor_top
    local available = bottom - top - 2 * (border + pad_y) - seps * sep_h
    local item_h = math.min(U(44), math.floor(available / math.max(1, count + smalls * 0.6)))
    local small_h = math.floor(item_h * 0.6)
    for _i, item in ipairs(items) do
        item.h = item.small and small_h or item_h
    end
    local width = math.min(screen_w - 2 * U(21.27), math.max(self.min_width or math.floor(screen_w * 0.4), max_w + 2 * pad_x + 2 * border))
    local height = 2 * (border + pad_y) + count * item_h + smalls * small_h + seps * sep_h
    self.box = Box:new{
        items = items,
        width = width,
        height = height,
        item_h = item_h,
        sep_h = sep_h,
        pad_x = pad_x,
        pad_y = pad_y,
        border = border,
        check_size = check_size,
    }
    self.box_x = self.anchor_left or (self.anchor_right - width)
    self.box_y = self.anchor_top
    if self.fit and self.box_y + height > bottom then
        self.box_y = math.max(top, bottom - height)
        self.notch_x = nil
    end
    self.items = items
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    self[1] = self.box
    self.ges_events = {
        TapDropdown = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldDropdown = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    if Device:hasKeys() and not self.passthrough then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function Dropdown:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

function Dropdown:paintTo(bb, x, y)
    self.box:paintTo(bb, self.box_x, self.box_y)
    if self.notch_x then
        Paint.notch(bb, self.notch_x, self.box_y + self.box.border - 1, false, U(Paint.NOTCH), self.box.border)
    end
end

function Dropdown:region()
    local notch = self.notch_x and U(Paint.NOTCH) or 0
    return Geom:new{ x = self.box_x, y = self.box_y - notch, w = self.box.width, h = self.box.height + notch }
end

function Dropdown:itemAt(pos)
    local bx, by = pos.x - self.box_x, pos.y - self.box_y
    if bx < 0 or by < 0 or bx > self.box.width or by > self.box.height then
        return nil, true
    end
    for _i, item in ipairs(self.items) do
        if not item.separator and item.y and by >= item.y and by < item.y + item.h then
            return item
        end
    end
end

function Dropdown:onTapDropdown(_ev, ges)
    local item, outside = self:itemAt(ges.pos)
    if outside and self.passthrough then
        return false
    elseif outside then
        UIManager:close(self)
    elseif item and item.extra and item.extra_x and ges.pos.x - self.box_x >= item.extra_x - U(10) then
        item.extra.callback()
    elseif item and item.enabled and item.callback then
        if self.close_first then
            UIManager:close(self)
        end
        item.callback()
        if self.keep_open then
            UIManager:setDirty(self, function()
                return "ui", self:region()
            end)
        end
    end
    return true
end

function Dropdown:onHoldDropdown(_ev, ges)
    local item, outside = self:itemAt(ges.pos)
    if outside and self.passthrough then return false end
    if item and item.enabled and item.hold_callback then
        if self.close_first then
            UIManager:close(self)
        end
        item.hold_callback()
    end
    return true
end

function Dropdown:onShow()
    UIManager:setDirty(self, function()
        return "ui", self:region()
    end)
end

function Dropdown:onCloseWidget()
    if self.on_close then self.on_close() end
    local region = self:region()
    UIManager:setDirty("all", function()
        return "ui", region
    end)
end

local Toolbar = {
    Dropdown = Dropdown,
}

FileManager.onShowPlusMenu = function(fm)
    local _title, buttons = fm:getPlusDialogButtons()
    local anchor = fm._kcui_plus_anchor
    fm._kcui_plus_anchor = nil
    fm.plus_dialog = Dropdown:new{
        buttons = buttons,
        anchor_right = anchor and anchor.right or Screen:getWidth() - U(21.27),
        anchor_top = anchor and anchor.top or U(100),
    }
    UIManager:show(fm.plus_dialog)
    return true
end

local orig_toggle = FileManager.onToggleSelectMode
FileManager.onToggleSelectMode = function(fm, ...)
    local result = orig_toggle(fm, ...)
    if fm.file_chooser then
        fm.file_chooser:updateItems(nil, true)
    end
    return result
end

local Pill = Widget:extend{
    width = nil,
    height = nil,
}

function Pill:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Pill:paintTo(bb, x, y)
    bb:paintBorder(x, y, self.width, self.height, U.ceil(1), Blitbuffer.COLOR_BLACK, math.floor(self.height / 2), true)
end

local function showFilter(fm)
    require("kcui/library").showFilters(fm)
end

local function showSort(fm)
    require("kcui/library").showOptions(fm)
end

local function allSelected(menu)
    local any = false
    for _i, item in ipairs(menu.item_table) do
        if item.is_file then
            if not item.dim then return false end
            any = true
        end
    end
    return any
end

local function toggleAll(fm, menu)
    if allSelected(menu) then
        for _i, item in ipairs(menu.item_table) do
            if item.is_file then fm.selected_files[item.path] = nil end
        end
        menu:selectAllFilesInFolder(false)
    else
        menu:selectAllFilesInFolder(true)
    end
end

local function inFolder(menu)
    return menu.item_table[1] ~= nil and menu.item_table[1].is_go_up == true
end

Toolbar.BORDER = Blitbuffer.Color8(0xDB)
Toolbar.BACK_ROW_HEIGHT = 51.5
Toolbar.BACK_ROW_CENTER = 22.2
Toolbar.BACK_ICON = 23.5

function Toolbar.border()
    return U.ceil(1)
end

function Toolbar.height(menu)
    if inFolder(menu) then
        return U(58.8)
    end
    return U(8) + U(48.5) + U(14) + U.ceil(1)
end

local function releaseParent(window)
    if window and window._kcui_search_parent then
        window._kcui_search_parent = nil
        window.getFocusableWidgetXY = nil
        window.moveFocusTo = nil
        window.onCloseDialog = nil
    end
end

local function exitSearch(menu)
    local bar = menu._kcui_search_bar
    menu._kcui_searching = nil
    menu._kcui_search_bar = nil
    releaseParent(menu.show_parent or menu)
    if bar and bar.input then
        bar.input:onCloseKeyboard()
    end
    menu:updateItems(nil, true)
end

local function runSearch(menu, text)
    if text == "" then return end
    local fm = menu.ui
    local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    exitSearch(menu)
    FileSearcher.search_path = G_reader_settings:readSetting("home_dir") or menu.path
    FileSearcher.search_string = text
    local searcher = fm.filesearcher
    searcher.case_sensitive = false
    searcher.use_patterns = false
    searcher.include_metadata = false
    searcher.include_content = false
    searcher.include_subfolders = true
    FileSearcher.search_hash = nil
    require("ui/trapper"):wrap(function()
        searcher:doSearch()
    end)
end

local function searchBar(menu, w, h, geo, on_submit, hint)
    local close_size = U(28.4)
    local close_inset = math.floor(close_size * 0.205)
    local close_x = w - geo.pad - close_size + close_inset
    local pill_x = geo.pad
    local pill_w = close_x + close_inset - U(20) - pill_x
    local pill_top = geo.center_y - math.floor(geo.pill_h / 2)
    local function place(widget, x)
        widget.overlap_offset = { x, geo.center_y - math.floor(widget:getSize().h / 2) }
        return widget
    end
    local glass = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/search.svg", width = U(17), height = U(17), alpha = true }
    local glass_x = pill_x + U(28)
    local input_x = glass_x + glass:getSize().w + U(17)
    local pill = Pill:new{ width = pill_w, height = geo.pill_h }
    pill.overlap_offset = { pill_x, pill_top }

    local bar
    local prefill = menu._kcui_search_prefill or ""
    menu._kcui_search_prefill = nil
    local input = InputText:new{
        text = prefill,
        hint = hint or _("Search KOReader"),
        face = U.face("cfont", 18),
        width = pill_x + pill_w - U(20) - input_x,
        bordersize = 0,
        padding = 0,
        margin = 0,
        scroll = false,
        focused = true,
        enter_callback = function()
            if menu._kcui_search_bar ~= bar then return end
            if on_submit then
                local text = bar.input:getText()
                exitSearch(menu)
                on_submit(text)
            else
                runSearch(menu, bar.input:getText())
            end
        end,
    }
    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        pill,
        place(glass, glass_x),
        place(input, input_x),
        place(ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/close.svg", width = close_size, height = close_size, alpha = true }, close_x),
        LineWidget:new{
            dimen = Geom:new{ w = w, h = geo.line_h },
            background = geo.line_color,
            overlap_offset = { 0, h - geo.line_h },
        },
    }
    bar = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        ges_events = {
            TapToolbar = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
        },
        layout,
    }
    bar.input = input
    local window = menu.show_parent or menu
    input.parent = window
    window._kcui_search_parent = true
    window.getFocusableWidgetXY = function() end
    window.moveFocusTo = function() end
    window.onCloseDialog = function()
        exitSearch(menu)
        return true
    end
    if input.keyboard then
        input.keyboard.active_widgets = { bar }
    end
    function bar:onTapToolbar(_ev, ges)
        local x = ges.pos.x - self.dimen.x
        if x >= close_x - U(10) then
            exitSearch(menu)
        else
            input:onShowKeyboard()
        end
        return true
    end
    UIManager:nextTick(function()
        if menu._kcui_search_bar == bar then
            input:onShowKeyboard()
        end
    end)
    return bar
end

function Toolbar.new(menu, w)
    if menu._kcui_search_bar then
        return menu._kcui_search_bar
    end
    local fm = menu.ui
    local in_folder = inFolder(menu)
    local h = Toolbar.height(menu)
    local pad = U(21.27)
    local gap = U(20)
    local top = U(8)
    local pill_h = U(48.5)
    local center_y = in_folder and U(28) or top + math.floor(pill_h / 2)
    local line_h = Toolbar.border()
    local line_color = Toolbar.BORDER

    local function icon(file, iw, ih)
        return ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/" .. file, width = iw, height = ih, alpha = true }
    end
    local filtered = FileChooser.show_filter.status and next(FileChooser.show_filter.status)
    local filter = icon("adjust.svg", U(24), U(24))
    local selecting = fm.selected_files ~= nil
    local plus_size = U(26.4)
    local plus = icon(selecting and "check.svg" or "Add.svg", plus_size, plus_size)
    local plus_inset = math.floor(plus_size * 0.125)
    local sort = icon("sort.svg", U(24), U(24))
    local glass = icon("search.svg", U(17), U(17))
    local search = icon("search.svg", U(19), U(19))
    local label = TextWidget:new{ text = _("Search KOReader"), face = U.face("cfont", 18) }

    local filter_x = pad
    local sort_x = w - pad - sort:getSize().w
    local spacing = U(28.5)
    local plus_x = sort_x - spacing - plus_size + plus_inset
    local search_x = plus_x + plus_inset - spacing - search:getSize().w
    local pill_x = filter_x + filter:getSize().w + spacing
    local pill_w = plus_x + plus_inset - U(20) - pill_x
    local close_x
    local close_size = U(28.4)
    if selecting then
        local close_inset = math.floor(close_size * 0.205)
        close_x = sort_x - spacing - close_size + close_inset
        plus_size = U(32.5)
        plus = icon("check.svg", plus_size, plus_size)
        plus_x = close_x + close_inset - spacing - plus_size + math.floor(plus_size * 0.167)
        plus_inset = math.floor(plus_size * 0.18)
    end

    local function place(widget, x)
        widget.overlap_offset = { x, center_y - math.floor(widget:getSize().h / 2) }
        return widget
    end
    local pill = Pill:new{ width = pill_w, height = pill_h }
    pill.overlap_offset = { pill_x, top }
    local glass_x = pill_x + U(28)
    local label_x = glass_x + glass:getSize().w + U(17)

    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        place(filter, filter_x),
        place(plus, plus_x),
        place(sort, sort_x),
        LineWidget:new{
            dimen = Geom:new{ w = w, h = line_h },
            background = line_color,
            overlap_offset = { 0, h - line_h },
        },
    }

    local middle_end = plus_x
    local done_x, all_x, all_w
    if selecting then
        local all_face = U.face("cfont", 15)
        local all_text = TextWidget:new{ text = _("Select all"), face = all_face, bold = true }
        local box = U(21.27)
        local all_row = HorizontalGroup:new{
            align = "center",
            all_text,
            HorizontalSpan:new{ width = U(6) },
            icon(allSelected(menu) and "circle-checked.svg" or "circle-empty.svg", box, box),
        }
        local done = TextWidget:new{ text = _("Done"), face = all_face, bold = true }
        done_x = plus_x + plus_inset - U(6) - done:getSize().w
        table.insert(layout, place(done, done_x))
        all_w = all_row:getSize().w
        all_x = done_x - U(24) - all_w
        table.insert(layout, place(all_row, all_x))
        table.insert(layout, place(icon("close.svg", close_size, close_size), close_x))
    elseif in_folder then
        table.insert(layout, place(search, search_x))
        middle_end = search_x
    elseif filtered then
        local name = TextWidget:new{ text = BookList.getBookStatusString(filtered), face = U.face("cfont", 18) }
        local clear = icon("close.svg", U(15), U(15))
        local chip = Pill:new{ width = name:getSize().w + clear:getSize().w + U(64), height = pill_h }
        chip.overlap_offset = { pill_x, top }
        table.insert(layout, chip)
        table.insert(layout, place(name, pill_x + U(24)))
        table.insert(layout, place(clear, pill_x + U(24) + name:getSize().w + U(16)))
    else
        table.insert(layout, pill)
        table.insert(layout, place(glass, glass_x))
        table.insert(layout, place(label, label_x))
    end

    if menu._kcui_searching then
        menu._kcui_search_bar = searchBar(menu, w, h, {
            pad = pad, spacing = spacing, plus_size = plus_size, pill_h = pill_h,
            center_y = center_y, line_h = line_h, line_color = line_color,
        })
        return menu._kcui_search_bar
    end

    local function enterSearch()
        menu._kcui_searching = true
        menu:updateItems(nil, true)
    end

    local bar
    bar = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        ges_events = {
            TapToolbar = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
        },
        layout,
    }
    function bar:onTapToolbar(_ev, ges)
        local x = ges.pos.x - self.dimen.x
        fm._kcui_plus_anchor = { right = w - pad, top = self.dimen.y + h - U(4) }
        if x < pill_x - math.floor(gap / 2) then
            showFilter(fm)
        elseif not selecting and x < middle_end - math.floor(gap / 2) then
            if filtered and not in_folder then
                FileChooser.show_filter.status = nil
                fm.file_chooser:refreshPath()
            elseif not in_folder then
                enterSearch()
            end
        elseif selecting and x < done_x - U(6) then
            if x >= all_x - U(8) and x <= all_x + all_w + U(8) then
                toggleAll(fm, menu)
            end
        elseif in_folder and not selecting and x < plus_x then
            enterSearch()
        elseif selecting and x >= close_x - U(6) and x < sort_x - math.floor(gap / 2) then
            fm:onToggleSelectMode(true)
        elseif x < sort_x - math.floor(gap / 2) then
            if selecting and next(fm.selected_files) == nil then
                fm:onToggleSelectMode(true)
            else
                fm:onShowPlusMenu()
            end
        else
            showSort(fm)
        end
        return true
    end
    return bar
end

function Toolbar.present(fn, anchor, skip)
    local captured
    local orig_show = UIManager.show
    UIManager.show = function(um, widget, ...)
        if not captured and getmetatable(widget) == ButtonDialog then
            captured = widget
            return
        end
        return orig_show(um, widget, ...)
    end
    local ok, err = pcall(fn)
    UIManager.show = orig_show
    if not ok then error(err) end
    if not captured then return end
    captured.onCloseWidget = function() end
    local dropdown
    local function run(action)
        if not anchor.fit then
            return function() Toolbar.present(action, anchor, skip) end
        end
        return function()
            action()
            UIManager:close(dropdown)
        end
    end
    local buttons = {}
    for _i, row in ipairs(captured.buttons or {}) do
        local new_row = {}
        for _i, button in ipairs(row) do
            if skip and skip(button) then goto continue end
            local copy = {}
            for k, v in pairs(button) do copy[k] = v end
            if button.callback then
                copy.callback = run(button.callback)
            end
            if button.hold_callback then
                copy.hold_callback = run(button.hold_callback)
            end
            table.insert(new_row, copy)
            ::continue::
        end
        if #new_row > 0 or #row == 0 then
            table.insert(buttons, new_row)
        end
    end
    dropdown = Dropdown:new{
        buttons = buttons,
        anchor_left = anchor.left,
        anchor_right = anchor.right,
        anchor_top = anchor.top,
        notch_x = anchor.notch_x,
        fit = anchor.fit,
        close_first = not anchor.fit,
    }
    UIManager:show(dropdown)
end

local function homeHeight()
    return U(8) + U(48.5) + U(14) + U.ceil(1)
end

function Toolbar.heightFor(menu)
    if menu.name == "filemanager" then
        return Toolbar.height(menu)
    end
    if menu._kcui_tab == "history" then
        return homeHeight()
    end
    return 0
end

function Toolbar.history(menu, w)
    if menu._kcui_search_bar then
        return menu._kcui_search_bar
    end
    local manager = menu._manager
    local h = homeHeight()
    local pad = U(21.27)
    local top = U(8)
    local pill_h = U(48.5)
    local center_y = top + math.floor(pill_h / 2)
    local line_h = U.ceil(1)
    local line_color = Blitbuffer.Color8(0xDB)
    local geo = {
        pad = pad, spacing = U(28.5), plus_size = U(26.4), pill_h = pill_h,
        center_y = center_y, line_h = line_h, line_color = line_color,
    }
    local function submit(text)
        if text == "" then return end
        manager.case_sensitive = false
        manager.search_string = text:lower()
        manager:updateItemTable()
    end
    if menu._kcui_searching then
        menu._kcui_search_bar = searchBar(menu, w, h, geo, submit, _("Search History"))
        return menu._kcui_search_bar
    end
    local function place(widget, x)
        widget.overlap_offset = { x, center_y - math.floor(widget:getSize().h / 2) }
        return widget
    end
    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LineWidget:new{
            dimen = Geom:new{ w = w, h = line_h },
            background = line_color,
            overlap_offset = { 0, h - line_h },
        },
    }
    local query = manager.search_string
    local close_size = U(28.4)
    local close_inset = math.floor(close_size * 0.205)
    local close_x = w - pad - close_size + close_inset
    local filter = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/adjust.svg", width = U(24), height = U(24), alpha = true }
    local filter_right = pad + filter:getSize().w
    table.insert(layout, place(filter, pad))
    if query then
        local pill_x = filter_right + U(28.5)
        local pill_w = close_x + close_inset - U(20) - pill_x
        local pill = Pill:new{ width = pill_w, height = pill_h }
        pill.overlap_offset = { pill_x, top }
        local glass = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/search.svg", width = U(17), height = U(17), alpha = true }
        local glass_x = pill_x + U(28)
        local text_x = glass_x + glass:getSize().w + U(17)
        table.insert(layout, pill)
        table.insert(layout, place(glass, glass_x))
        table.insert(layout, place(TextWidget:new{
            text = query,
            face = U.face("cfont", 18),
            max_width = pill_x + pill_w - U(20) - text_x,
        }, text_x))
        table.insert(layout, place(ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/close.svg", width = close_size, height = close_size, alpha = true }, close_x))
    else
        local search = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/search.svg", width = U(21.8), height = U(21.8), alpha = true }
        table.insert(layout, place(search, w - pad - search:getSize().w))
    end
    local bar
    bar = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        ges_events = {
            TapHistoryBar = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
        },
        layout,
    }
    function bar:onTapHistoryBar(_ev, ges)
        local x = ges.pos.x - self.dimen.x
        if x < filter_right + U(14) then
            Toolbar.present(function() manager:showHistDialog() end,
                { left = pad, top = self.dimen.y + h - U(4) },
                function(button) return button.text == _("Search in filename and book metadata") end)
        elseif query and x >= close_x - U(10) then
            manager.search_string = nil
            manager:updateItemTable()
        elseif query or x >= w - pad - U(40) then
            menu._kcui_searching = true
            menu._kcui_search_prefill = query
            menu:updateItems(nil, true)
        end
        return true
    end
    return bar
end

function Toolbar.build(menu, w)
    if menu.name == "filemanager" then
        return Toolbar.new(menu, w)
    end
    return Toolbar.history(menu, w)
end

function Toolbar.titleHeader(w, title, count, on_back, on_plus, on_more)
    local h = U(Toolbar.BACK_ROW_HEIGHT)
    local pad = U(21.27)
    local icon = U(Toolbar.BACK_ICON)
    local gap = U(27.2)
    local plus_size = U(26.4)
    local plus_inset = math.floor(plus_size * 0.125)
    local more_size = U(30)
    local more_inset = math.floor(more_size * 0.165)
    local more_x = w - pad - more_size + more_inset
    local plus_right = on_more and (more_x + more_inset - U(28.5)) or (w - pad)
    local plus_x = plus_right - plus_size + plus_inset
    local label = TextWidget:new{
        text = count and count > 0 and T(_.ngettext("(%1 item)", "(%1 items)", count), count) or "",
        face = U.face("cfont", 15),
        fgcolor = Blitbuffer.Color8(0x40),
    }
    local name = TextWidget:new{
        text = title,
        face = U.face("cfont", 18),
        bold = true,
        max_width = plus_x - pad - icon - gap - U(9.5) - label:getSize().w - U(20),
    }
    local group = HorizontalGroup:new{
        align = "center",
        ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/../arrow-left.svg", width = icon, height = icon, alpha = true },
        HorizontalSpan:new{ width = gap },
        name,
    }
    if count and count > 0 then
        table.insert(group, HorizontalSpan:new{ width = U(9.5) })
        table.insert(group, label)
    end
    local center_y = h - U(Toolbar.BACK_ROW_CENTER)
    group.overlap_offset = { pad - math.floor(icon * 3 / 24), center_y - math.floor(group:getSize().h / 2) }
    local border = Toolbar.border()
    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        group,
        LineWidget:new{
            dimen = Geom:new{ w = w, h = border },
            background = Toolbar.BORDER,
            overlap_offset = { 0, h - border },
        },
    }
    if on_plus then
        local plus = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/Add.svg", width = plus_size, height = plus_size, alpha = true }
        plus.overlap_offset = { plus_x, center_y - math.floor(plus_size / 2) }
        table.insert(layout, plus)
    end
    if on_more then
        local more = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/menu.svg", width = more_size, height = more_size, alpha = true }
        more.overlap_offset = { more_x, center_y - math.floor(more_size / 2) }
        table.insert(layout, more)
    end
    local bar
    bar = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        ges_events = {
            TapHeader = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
        },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            layout,
        },
    }
    function bar:onTapHeader(_ev, ges)
        local x = ges.pos.x - self.dimen.x
        local anchor = { right = w - pad, top = self.dimen.y + h - U(4) }
        if on_more and x >= more_x - U(10) then
            on_more(anchor)
        elseif on_plus and x >= plus_x - U(14) then
            on_plus()
        else
            on_back()
        end
        return true
    end
    return bar
end

function Toolbar.results(menu, w, query)
    local fm = menu.ui
    local h = U(8) + U(48.5) + U(14) + U.ceil(1)
    local pad = U(21.27)
    local spacing = U(28.5)
    local top = U(8)
    local pill_h = U(48.5)
    local center_y = top + math.floor(pill_h / 2)
    local close_size = U(28.4)
    local close_inset = math.floor(close_size * 0.205)
    local close_x = w - pad - close_size + close_inset
    local pill_x = pad
    local pill_w = close_x + close_inset - U(20) - pill_x
    local function place(widget, x)
        widget.overlap_offset = { x, center_y - math.floor(widget:getSize().h / 2) }
        return widget
    end
    local glass = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/search.svg", width = U(17), height = U(17), alpha = true }
    local glass_x = pill_x + U(28)
    local text_x = glass_x + glass:getSize().w + U(17)
    local pill = Pill:new{ width = pill_w, height = pill_h }
    pill.overlap_offset = { pill_x, top }
    local text = TextWidget:new{
        text = query or "",
        face = U.face("cfont", 18),
        max_width = pill_x + pill_w - U(20) - text_x,
    }
    local layout = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        pill,
        place(glass, glass_x),
        place(text, text_x),
        place(ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/close.svg", width = close_size, height = close_size, alpha = true }, close_x),
        LineWidget:new{
            dimen = Geom:new{ w = w, h = U.ceil(1) },
            background = Blitbuffer.Color8(0xDB),
            overlap_offset = { 0, h - U.ceil(1) },
        },
    }
    local bar
    bar = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        ges_events = {
            TapResults = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
        },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            layout,
        },
    }
    function bar:onTapResults(_ev, ges)
        local x = ges.pos.x - self.dimen.x
        menu.close_callback()
        if x < close_x - U(10) then
            local fc = fm.file_chooser
            fc._kcui_searching = true
            fc._kcui_search_prefill = query
            fc:updateItems(nil, true)
        end
        return true
    end
    return bar
end

return Toolbar
