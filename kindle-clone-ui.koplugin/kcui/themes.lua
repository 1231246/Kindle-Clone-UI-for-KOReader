local Blitbuffer = require("ffi/blitbuffer")
local Configurable = require("configurable")
local ConfirmBox = require("ui/widget/confirmbox")
local CreDocument = require("document/credocument")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")
local Common = require("kcui/common")
local T = require("ffi/util").template
local Screen = Device.screen
local Gray = Common.Gray
local KindleFonts = Common.Fonts
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/themes%.lua$") .. "/icons"
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local REFERENCE_DPI = 300
local REFERENCE_WIDTH = 1264
local SAVED = "kcui_themes"
local CUSTOM = "kcui_theme_custom"
local MAX_SAVED = 3
local COLUMNS = 2
local THEMES_TAB = 1
local FONT_TAB = 2
local LAYOUT_TAB = 3
local RESET_TAB = 4
local BODY_FONT = 16
local TITLE_FONT = 23
local INPUT_FONT = 20
local LETTER_FONT = 22
local NUMBER_FONT = 14
local SAMPLE_FONT = 41
local NAME_FONT = 16
local LABEL_X = 99
local SUFFIX_GAP = 10
local LAYOUT_COLUMNS = { 80, 544 }
local OPTION_GAP = 29
local SIZES ={ 31, 33, 35, 39, 44, 49, 55, 62, 69, 78, 87, 98, 110, 123 }
local BOLD = { 0, 0.5, 1, 1.5, 2, 3 }
local TIGHT, NORMAL, WIDE = 1, 2, 3
local NORMAL_SPACING = { [5] = 123, [7] = 117 }
local LEFT_ALIGN = "text_align_most_left"
local SMALL_SCREEN_INCHES = 6.5
local LARGE_PAGE = { margins = { 83, 140, 200 }, top = 66 }
local SMALL_PAGE = { margins = { 45, 102, 162 }, top = 45 }
local BOTTOM_MARGIN = 14
local PREVIOUS_BOTTOMS = { 16, 45 }
local WORD_SPACING = { 100, 75 }
local DEFAULT_THEME = { name = _("Small"), size = 2, spacing = NORMAL, lines = { count = 4, first = 20, pitch = 12.67, weight = 2, inset = 16 } }
local BUILT_IN = {
    { name = _("Tiny"), size = 1, bold = 2, spacing = NORMAL, lines = { count = 6, first = 16, pitch = 9.2, weight = 2, inset = 16 } },
    DEFAULT_THEME,
    { name = _("Compact"), size = 3, spacing = TIGHT, lines = { count = 5, first = 18, pitch = 10.75, weight = 2, inset = 16 } },
    { name = _("Standard"), size = 5, spacing = NORMAL, lines = { count = 3, first = 20, pitch = 18, weight = 5, inset = 14 } },
}
local TABS = { _("Themes"), _("Font"), _("Layout"), _("Reset"), _("More") }

local Themes = {}

local function R(px)
    return U(px * 600 / REFERENCE_WIDTH)
end

local function X(px)
    return math.floor(R(px) * U.fit() + 0.5)
end

local function option(px)
    return (px * Screen:getDPI() / REFERENCE_DPI - 0.5) * 1000000 / Screen:scaleBySize(1000000)
end

local function pageLayout()
    local w, h = Screen:getWidth(), Screen:getHeight()
    return math.sqrt(w * w + h * h) / Screen:getDPI() < SMALL_SCREEN_INCHES and SMALL_PAGE or LARGE_PAGE
end

local function spacings(size)
    return { 105, NORMAL_SPACING[size] or 121, 140 }
end

local function nearest(list, value)
    local best = 1
    for i, candidate in ipairs(list) do
        if math.abs(candidate - value) < math.abs(list[best] - value) then
            best = i
        end
    end
    return best
end

local function referencePixels(value)
    return Screen:scaleBySize(value) * REFERENCE_DPI / Screen:getDPI()
end

local function builtInValues(theme)
    local page = pageLayout()
    return {
        font_face = KindleFonts.found.book and KindleFonts.BOOK_FAMILY or nil,
        font_size = option(SIZES[theme.size]),
        font_base_weight = BOLD[theme.bold or 1],
        line_spacing = spacings(theme.size)[theme.spacing],
        h_page_margins = { option(page.margins[1]), option(page.margins[1]) },
        t_page_margin = option(page.top),
        b_page_margin = BOTTOM_MARGIN,
        word_spacing = { WORD_SPACING[1], WORD_SPACING[2] },
    }
end

local function valuesOf(config, font_face)
    return {
        font_face = font_face,
        font_size = config.font_size,
        font_base_weight = config.font_base_weight,
        line_spacing = config.line_spacing,
        h_page_margins = { config.h_page_margins[1], config.h_page_margins[2] },
        t_page_margin = config.t_page_margin,
        b_page_margin = config.b_page_margin,
        word_spacing = { config.word_spacing[1], config.word_spacing[2] },
    }
end

local function currentValues(ui)
    return valuesOf(ui.document.configurable, ui.font.font_face)
end

local function defaultValues(ui)
    local config = Configurable:new()
    config:loadDefaults(ui.config.options)
    return valuesOf(config, G_reader_settings:readSetting("cre_font") or ui.document.default_font)
end

local function samePixels(a, b)
    return Screen:scaleBySize(a) == Screen:scaleBySize(b)
end

local function same(a, b)
    return samePixels(a.font_size, b.font_size)
        and a.line_spacing == b.line_spacing
        and (a.font_base_weight or 0) == (b.font_base_weight or 0)
        and samePixels(a.h_page_margins[1], b.h_page_margins[1])
        and samePixels(a.h_page_margins[2], b.h_page_margins[2])
        and samePixels(a.t_page_margin, b.t_page_margin)
        and samePixels(a.b_page_margin, b.b_page_margin)
        and a.word_spacing[1] == b.word_spacing[1]
        and a.word_spacing[2] == b.word_spacing[2]
        and (a.font_face == nil or b.font_face == nil or a.font_face == b.font_face)
end

local function bookStyles(values)
    return {
        copt_font_size = values.font_size,
        copt_font_base_weight = values.font_base_weight,
        copt_line_spacing = values.line_spacing,
        copt_h_page_margins = { values.h_page_margins[1], values.h_page_margins[2] },
        copt_t_page_margin = values.t_page_margin,
        copt_b_page_margin = values.b_page_margin,
        copt_sync_t_b_page_margins = 0,
        copt_word_spacing = { values.word_spacing[1], values.word_spacing[2] },
    }
end

function Themes.defaultBookStyles()
    return bookStyles(builtInValues(DEFAULT_THEME))
end

local function apply(ui, values)
    local document = ui.document
    local config = document.configurable
    if values.font_face and values.font_face ~= ui.font.font_face then
        ui.font:onSetFont(values.font_face)
    end
    config.font_size = values.font_size
    document:setFontSize(Screen:scaleBySize(values.font_size))
    config.font_base_weight = values.font_base_weight or 0
    document:setFontBaseWeight(config.font_base_weight)
    config.line_spacing = values.line_spacing
    document:setInterlineSpacePercent(values.line_spacing)
    config.word_spacing = { values.word_spacing[1], values.word_spacing[2] }
    document:setWordSpacing(config.word_spacing)
    config.h_page_margins = { values.h_page_margins[1], values.h_page_margins[2] }
    config.t_page_margin = values.t_page_margin
    config.b_page_margin = values.b_page_margin
    config.sync_t_b_page_margins = 0
    ui.typeset.sync_t_b_page_margins = false
    ui.typeset.unscaled_margins = {
        values.h_page_margins[1], values.t_page_margin, values.h_page_margins[2], values.b_page_margin,
    }
    ui:handleEvent(Event:new("SetPageMargins", ui.typeset.unscaled_margins))
end

local function saveAsDefault(ui)
    if ui.menu.saveDocumentSettingsAsDefault then
        ui.menu:saveDocumentSettingsAsDefault()
        return
    end
    for key, value in pairs(bookStyles(currentValues(ui))) do
        G_reader_settings:saveSetting(key, value)
    end
    G_reader_settings:saveSetting("cre_font", ui.font.font_face)
end

local function savedThemes()
    local saved = G_reader_settings:readSetting(SAVED) or {}
    local page = pageLayout()
    for _i, theme in ipairs(saved) do
        theme.values.t_page_margin = option(page.top)
        theme.values.b_page_margin = BOTTOM_MARGIN
        theme.values.word_spacing = { WORD_SPACING[1], WORD_SPACING[2] }
    end
    return saved
end

local function capTop(widget, face, cap_center)
    local cap = math.floor(face.size * 0.7 + 0.5)
    return cap_center - math.floor(cap / 2) - (widget:getBaseline() - cap)
end

local function frame(bb, rect, border, radius, color)
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, color or BLACK, radius)
    bb:paintRoundedRect(rect.x + border, rect.y + border, rect.w - 2 * border, rect.h - 2 * border, WHITE, math.max(0, radius - border))
end

local function icon(name, w, h, rotation)
    return ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/" .. name .. ".svg",
        width = w,
        height = h,
        rotation_angle = rotation,
        alpha = true,
    }
end

local function cre()
    return CreDocument:engineInit()
end

local Sheet = InputContainer:extend{
    ui = nil,
    tab = THEMES_TAB,
    list = nil,
    page = 1,
}

function Sheet:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.height = math.min(R(1008), sh)
    self.top = sh - self.height
    self.face = U.face("cfont", BODY_FONT)
    self.italic = U.face(KindleFonts.found.ui_italic or "cfont", BODY_FONT)
    self.letter_face = U.face("cfont", LETTER_FONT)
    self.number_face = U.face("cfont", NUMBER_FONT)
    self.check = icon("themes/check", R(48), R(36))
    self.chevron = icon("themes/chevron", R(20), R(30))
    self.back = icon("themes/chevron", R(20), R(30), 180)
    self.avatar = icon("themes/person", R(40), R(38))
    self.trash = icon("delete", R(44), R(44))
    self.letter = TextWidget:new{ text = "A", face = self.letter_face }
    self.dim_letter = TextWidget:new{ text = "A", face = self.letter_face, fgcolor = Gray.inactive }
    self.fixed = { self.check, self.chevron, self.back, self.avatar, self.trash, self.letter, self.dim_letter }
    self:build()
    self.ges_events = {
        TapSheet = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function Sheet:release()
    for _i, widget in ipairs(self.widgets or {}) do
        widget:free()
    end
    self.widgets = {}
end

function Sheet:text(text, bold, face, color)
    local widget = TextWidget:new{ text = text, face = face or self.face, bold = bold, fgcolor = color }
    table.insert(self.widgets, widget)
    return widget
end

function Sheet:themeEntries()
    local current = currentValues(self.ui)
    local entries = { { kind = "custom", name = _("Custom"), values = G_reader_settings:readSetting(CUSTOM) } }
    for _i, theme in ipairs(BUILT_IN) do
        table.insert(entries, { kind = "built_in", name = theme.name, lines = theme.lines, values = builtInValues(theme) })
    end
    for _i, saved in ipairs(savedThemes()) do
        table.insert(entries, { kind = "saved", name = saved.name, values = saved.values })
    end
    local defaults = defaultValues(self.ui)
    local selected, default
    for i = 2, #entries do
        selected = selected or same(entries[i].values, current) and entries[i]
        default = default or same(entries[i].values, defaults) and entries[i]
    end
    selected = selected or entries[1]
    if default then
        default.is_default = true
    end
    if selected == entries[1] then
        G_reader_settings:saveSetting(CUSTOM, current)
        entries[1].values = current
    end
    return entries, selected
end

function Sheet:buildThemes()
    local sw = self.dimen.w
    local column_w = math.min(R(566), math.floor((sw - R(82) - R(50)) / COLUMNS))
    self.entries, self.selected = self:themeEntries()
    for i, entry in ipairs(self.entries) do
        local column, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        local current = entry == self.selected
        entry.disabled = entry.kind == "custom" and not current
        entry.x = R(82) + column * column_w
        entry.y = self.top + R(181) + row * R(149)
        entry.rect = Geom:new{ x = entry.x - R(20), y = entry.y - R(20), w = column_w, h = R(118) }
        local label_w = column_w - R(125)
        entry.label = self:text(entry.name, current, nil, entry.disabled and Gray.inactive or nil)
        if entry.is_default then
            entry.suffix = self:text(_("- default"), false, self.italic)
            label_w = label_w - entry.suffix:getSize().w - R(SUFFIX_GAP)
        end
        entry.label:setMaxWidth(label_w)
        if current then
            entry.note = self:text(_("Current Theme"), false, self.italic)
        end
    end
    self.save_rect = Geom:new{ x = R(63), y = self.dimen.h - R(243), w = sw - 2 * R(63), h = R(95) }
    self.save_color = self.selected.is_default and Gray.inactive or BLACK
    self.save_label = self:text(self.selected.kind == "custom" and _("Save Current Settings") or _("Set Theme as Default"),
        false, nil, self.save_color)
    self.manage_label = self:text(_("Manage Themes"))
    self.manage_rect = Geom:new{ x = 0, y = self.dimen.h - R(111), w = sw, h = R(111) }
end

function Sheet:slider(label, label_center, center, count, level, segment_w, pitch)
    return {
        label = self:text(label),
        label_center = label_center,
        center = center,
        count = count,
        level = level,
        segment_w = X(segment_w),
        pitch = X(pitch),
        x = X(465),
        minus = Geom:new{ x = X(390), y = center - R(2), w = R(33), h = R(4) },
        plus = Geom:new{ x = X(1172) - R(33), y = center - R(17), w = R(33), h = R(33) },
    }
end

function Sheet:buildFont()
    local ui = self.ui
    local config = ui.document.configurable
    local face = ui.font.font_face or ""
    local file = cre().getFontFaceFilenameAndFaceIndex(face)
    self.family_label = self:text(_("Font Family"))
    self.family_sample = self:text("Aa", false, U.face(file or "cfont", SAMPLE_FONT))
    self.family_name = self:text(face, false, U.face(file or "cfont", NAME_FONT))
    self.family_name:setMaxWidth(self.dimen.w - R(319) - self.family_label:getSize().w - self.family_sample:getSize().w)
    self.family_rect = Geom:new{ x = 0, y = self.top + R(111), w = self.dimen.w, h = R(165) }
    local size = self:slider(_("Size"), self.top + R(527), self.top + R(528), #SIZES, nearest(SIZES, referencePixels(config.font_size)), 37, 46)
    size.number = self:text(tostring(size.level), false, self.number_face)
    size.set = function(level)
        local values = currentValues(ui)
        local spacing = nearest(spacings(size.level), values.line_spacing)
        values.font_size = option(SIZES[level])
        values.line_spacing = spacings(level)[spacing]
        apply(ui, values)
    end
    local bold = self:slider(_("Bold"), self.top + R(361), self.top + R(361), #BOLD - 1, nearest(BOLD, config.font_base_weight or 0) - 1, 119, 128)
    bold.set = function(level)
        local values = currentValues(ui)
        values.font_base_weight = BOLD[level + 1]
        apply(ui, values)
    end
    self.sliders = { bold, size }
end

local function rule(count, first, pitch, x, w)
    local lines = {}
    for i = 0, count - 1 do
        local span = type(x) == "table" and x[i + 1] or { x, w }
        table.insert(lines, { x = span[1], y = first + i * pitch, w = span[2] })
    end
    return lines
end

local function columns(count, first, pitch)
    local lines = rule(count, first, pitch, 17, 37)
    for _i, line in ipairs(rule(count, first, pitch, 65, 37)) do
        table.insert(lines, line)
    end
    return lines
end

function Sheet:orient(landscape, pages)
    local ui = self.ui
    local config = ui.document.configurable
    local mode = landscape and Screen.DEVICE_ROTATED_CLOCKWISE or Common.Rotation.portrait()
    UIManager:close(self)
    if (Screen:getRotationMode() % 2 == 1) ~= landscape then
        config.rotation_mode = mode
        ui:handleEvent(Event:new("SetRotationMode", mode))
    end
    if config.visible_pages ~= pages then
        ui:handleEvent(Event:new("SetVisiblePages", pages))
    end
    UIManager:nextTick(function()
        Themes.show(ui, LAYOUT_TAB)
    end)
end

function Sheet:buildLayout()
    local ui = self.ui
    local config = ui.document.configurable
    local landscape = Screen:getRotationMode() % 2 == 1
    local paired = config.visible_pages == 2
    local size = nearest(SIZES, referencePixels(config.font_size))
    local page_margins = pageLayout().margins
    local margin = nearest(page_margins, referencePixels(config.h_page_margins[1]))
    local spacing = nearest(spacings(size), config.line_spacing)
    local left = ui.styletweak ~= nil and ui.styletweak:isTweakEnabled(LEFT_ALIGN)
    local function set(change)
        return function()
            local values = currentValues(ui)
            change(values)
            apply(ui, values)
            self:refresh()
        end
    end
    local function margins(level)
        return set(function(values)
            values.h_page_margins = { option(page_margins[level]), option(page_margins[level]) }
        end)
    end
    local function spaced(level)
        return set(function(values)
            values.line_spacing = spacings(size)[level]
        end)
    end
    local function aligned(to_left)
        return function()
            if ui.styletweak then
                ui.styletweak:onToggleStyleTweak({ LEFT_ALIGN, to_left }, nil, true)
            end
            self:refresh()
        end
    end
    local wide, tall = { 140, 79 }, { 88, 118 }
    local flat = { 119, 88 }
    self.groups = {
        { title = _("Orientation"), column = 1, center = 166, top = 226, options = {
            { size = tall, lines = rule(6, 20, 16.2, 17, 56), selected = not landscape,
                action = function() self:orient(false, 1) end },
            { size = flat, lines = rule(5, 18, 12.5, 19, 82), selected = landscape and not paired,
                action = function() self:orient(true, 1) end },
            { size = flat, lines = columns(5, 18, 12.5), selected = landscape and paired,
                action = function() self:orient(true, 2) end },
        } },
        { title = _("Margins"), column = 2, center = 186, top = 246, options = {
            { size = wide, lines = rule(5, 18, 10.75, 10, 120), selected = margin == 1, action = margins(1) },
            { size = wide, lines = rule(5, 18, 10.75, 22, 97), selected = margin == 2, action = margins(2) },
            { size = wide, lines = rule(5, 18, 10.75, 39, 64), selected = margin == 3, action = margins(3) },
        } },
        { title = _("Alignment"), column = 1, center = 404, top = 464, options = {
            { size = wide, lines = rule(4, 23, 11, 22, 96), selected = not left, action = aligned(false) },
            { size = wide, lines = rule(4, 23, 11, { { 22, 96 }, { 22, 89 }, { 22, 79 }, { 22, 96 } }), selected = left,
                action = aligned(true) },
        } },
        { title = _("Spacing"), column = 2, center = 404, top = 464, options = {
            { size = wide, lines = rule(4, 23, 11, 22, 96), selected = spacing == TIGHT, action = spaced(TIGHT) },
            { size = wide, lines = rule(4, 18, 14.33, 22, 96), selected = spacing == NORMAL, action = spaced(NORMAL) },
            { size = wide, lines = rule(3, 22, 18.5, 22, 96), selected = spacing == WIDE, action = spaced(WIDE) },
        } },
    }
    local lefts = { R(LAYOUT_COLUMNS[1]), R(LAYOUT_COLUMNS[2]) }
    for _i, group in ipairs(self.groups) do
        if group.column == 2 then
            local width = -R(OPTION_GAP)
            for _j, choice in ipairs(group.options) do
                width = width + R(choice.size[1]) + R(OPTION_GAP)
            end
            lefts[2] = math.min(lefts[2], self.dimen.w - lefts[1] - width)
        end
    end
    for _i, group in ipairs(self.groups) do
        group.label = self:text(group.title)
        group.left = lefts[group.column]
        local x = group.left
        for _j, choice in ipairs(group.options) do
            choice.rect = Geom:new{ x = x, y = self.top + R(group.top), w = R(choice.size[1]), h = R(choice.size[2]) }
            x = x + choice.rect.w + R(OPTION_GAP)
        end
    end
end

function Sheet:buildList()
    local list = self.list
    local sw = self.dimen.w
    local row_h = R(112)
    local first_y = self.top + R(111)
    list.per_page = math.max(1, math.floor((self.dimen.h - first_y) / row_h))
    list.pages = math.max(1, math.ceil(#list.items / list.per_page))
    self.page = math.max(1, math.min(self.page, list.pages))
    list.title_label = self:text(list.title, true)
    list.empty_label = list.empty and self:text(list.empty)
    list.rows = {}
    local first = (self.page - 1) * list.per_page
    for i = 1, list.per_page do
        local item = list.items[first + i]
        if not item then break end
        table.insert(list.rows, {
            item = item,
            label = self:text(item.text, item.current, item.face),
            rect = Geom:new{ x = 0, y = first_y + (i - 1) * row_h, w = sw, h = row_h },
        })
    end
end

function Sheet:build()
    self:release()
    local x = R(44)
    self.tabs = {}
    for i, label in ipairs(TABS) do
        local regular = TextWidget:new{ text = label, face = self.face }
        local width = regular:getSize().w + 2 * R(19)
        regular:free()
        table.insert(self.tabs, { label = self:text(label, i == self.tab), x = x, w = width })
        x = x + width + R(44)
    end
    if self.list then
        self:buildList()
    elseif self.tab == THEMES_TAB then
        self:buildThemes()
    elseif self.tab == FONT_TAB then
        self:buildFont()
    else
        self:buildLayout()
    end
end

function Sheet:region()
    return Geom:new{ x = 0, y = self.top, w = self.dimen.w, h = self.height }
end

function Sheet:paintIcon(bb, entry)
    local x, y, size = entry.x, entry.y, R(78)
    frame(bb, Geom:new{ x = x, y = y, w = size, h = size }, R(4), R(10), entry.disabled and Gray.inactive or nil)
    if entry == self.selected then
        bb:paintRect(x - R(1), y - R(1), R(34), R(32), WHITE)
        self.check:paintTo(bb, x - R(17), y - R(17))
    end
    if entry.kind == "custom" then
        local letter_widget = entry.disabled and self.dim_letter or self.letter
        local letter = letter_widget:getSize()
        letter_widget:paintTo(bb, x + math.floor((size - letter.w) / 2), capTop(letter_widget, self.letter_face, y + R(39)))
    elseif entry.kind == "saved" then
        local avatar = self.avatar:getSize()
        self.avatar:paintTo(bb, x + math.floor((size - avatar.w) / 2), y + math.floor((size - avatar.h) / 2))
    else
        local lines = entry.lines
        for i = 0, lines.count - 1 do
            bb:paintRect(x + R(lines.inset), y + R(lines.first + i * lines.pitch), size - 2 * R(lines.inset), math.max(1, R(lines.weight)), BLACK)
        end
    end
end

function Sheet:paintThemes(bb)
    local sw, sh = self.dimen.w, self.dimen.h
    for _i, entry in ipairs(self.entries) do
        self:paintIcon(bb, entry)
        local label_x = entry.x + R(LABEL_X)
        local center = entry.y + R(38)
        local label_center = entry.note and center - R(21.5) or center
        entry.label:paintTo(bb, label_x, capTop(entry.label, self.face, label_center))
        if entry.suffix then
            entry.suffix:paintTo(bb, label_x + entry.label:getSize().w + R(SUFFIX_GAP), capTop(entry.suffix, self.italic, label_center))
        end
        if entry.note then
            entry.note:paintTo(bb, label_x, capTop(entry.note, self.italic, center + R(21.5)))
        end
    end
    local button = self.save_rect
    bb:paintBorder(button.x, button.y, button.w, button.h, R(2), self.save_color)
    local save = self.save_label:getSize()
    self.save_label:paintTo(bb, button.x + math.floor((button.w - save.w) / 2),
        capTop(self.save_label, self.face, button.y + math.floor(button.h / 2)))
    bb:paintRect(R(63), sh - R(115), sw - 2 * R(63), R(4), BLACK)
    self.manage_label:paintTo(bb, R(63), capTop(self.manage_label, self.face, sh - R(56)))
    local chevron = self.chevron:getSize()
    self.chevron:paintTo(bb, sw - R(113), sh - R(58) - math.floor(chevron.h / 2))
end

function Sheet:paintSlider(bb, slider)
    slider.label:paintTo(bb, R(61), capTop(slider.label, self.face, slider.label_center))
    bb:paintRect(slider.minus.x, slider.minus.y, slider.minus.w, slider.minus.h, BLACK)
    local plus = slider.plus
    bb:paintRect(plus.x, slider.center - R(2), plus.w, R(4), BLACK)
    bb:paintRect(plus.x + math.floor((plus.w - R(4)) / 2), plus.y, R(4), plus.h, BLACK)
    local top, height = slider.center - R(7), R(15)
    for i = 1, slider.count do
        local x = slider.x + (i - 1) * slider.pitch
        if i <= slider.level then
            bb:paintRect(x, top, slider.segment_w, height, BLACK)
        else
            bb:paintBorder(x, top, slider.segment_w, height, R(2), BLACK)
        end
    end
    if slider.number then
        local size = slider.number:getSize()
        local x = slider.x + (slider.level - 1) * slider.pitch + math.floor((slider.segment_w - size.w) / 2)
        slider.number:paintTo(bb, x, capTop(slider.number, self.number_face, slider.center - R(25)))
    end
end

function Sheet:paintFont(bb)
    local sw, top = self.dimen.w, self.top
    self.family_label:paintTo(bb, R(63), capTop(self.family_label, self.face, top + R(205)))
    local chevron = self.chevron:getSize()
    local right = sw - R(100)
    self.chevron:paintTo(bb, right, top + R(202) - math.floor(chevron.h / 2))
    local name = self.family_name:getSize()
    local name_x = right - R(54) - name.w
    self.family_name:paintTo(bb, name_x, top + R(218) - self.family_name:getBaseline())
    bb:paintRect(name_x - R(41), top + R(206), R(32), R(3), BLACK)
    local sample = self.family_sample:getSize()
    self.family_sample:paintTo(bb, name_x - R(62) - sample.w, top + R(239) - self.family_sample:getBaseline())
    bb:paintRect(R(63), top + R(276), sw - 2 * R(63), R(2), BLACK)
    bb:paintRect(R(63), top + R(443), sw - 2 * R(63), R(2), BLACK)
    for _i, slider in ipairs(self.sliders) do
        self:paintSlider(bb, slider)
    end
end

function Sheet:paintLayout(bb)
    for _i, group in ipairs(self.groups) do
        group.label:paintTo(bb, group.left, capTop(group.label, self.face, self.top + R(group.center)))
        for _j, choice in ipairs(group.options) do
            local rect = choice.rect
            if choice.selected then
                frame(bb, rect, R(5), R(10))
            else
                frame(bb, rect, R(2), R(8))
            end
            for _k, line in ipairs(choice.lines) do
                bb:paintRect(rect.x + R(line.x), rect.y + R(line.y), R(line.w), math.max(1, R(2)), BLACK)
            end
        end
    end
end

function Sheet:paintList(bb)
    local list = self.list
    local sw = self.dimen.w
    if #list.items == 0 and list.empty_label then
        list.empty_label:paintTo(bb, R(63), capTop(list.empty_label, self.face, self.top + R(171)))
        return
    end
    for _i, row in ipairs(list.rows) do
        local center = row.rect.y + math.floor(row.rect.h / 2)
        row.label:paintTo(bb, R(63), capTop(row.label, row.item.face or self.face, center))
        if list.delete then
            local trash = self.trash:getSize()
            self.trash:paintTo(bb, sw - R(63) - trash.w, center - math.floor(trash.h / 2))
        elseif row.item.current then
            local check = self.check:getSize()
            self.check:paintTo(bb, sw - R(63) - check.w, center - math.floor(check.h / 2))
        end
        bb:paintRect(R(63), row.rect.y + row.rect.h - R(2), sw - 2 * R(63), R(2), BLACK)
    end
    if list.pages > 1 then
        local track_y = self.top + R(125)
        local track_h = self.dimen.h - R(14) - track_y
        local thumb_h = math.floor(track_h / list.pages)
        local x = sw - R(30)
        bb:paintRect(x, track_y, R(8), track_h, Gray.inactive)
        bb:paintRect(x, track_y + math.floor((self.page - 1) * (track_h - thumb_h) / (list.pages - 1)), R(8), thumb_h, BLACK)
    end
end

function Sheet:paintTo(bb)
    local sw = self.dimen.w
    local top = self.top
    bb:paintRect(0, top, sw, self.height, WHITE)
    bb:paintRect(0, top, sw, R(5), BLACK)
    if self.list then
        local back = self.back:getSize()
        self.back:paintTo(bb, R(63), top + R(55) - math.floor(back.h / 2))
        self.list.title_label:paintTo(bb, R(63) + back.w + R(30), capTop(self.list.title_label, self.face, top + R(55)))
    else
        for i, tab in ipairs(self.tabs) do
            local size = tab.label:getSize()
            tab.label:paintTo(bb, tab.x + math.floor((tab.w - size.w) / 2), capTop(tab.label, self.face, top + R(56)))
            if i == self.tab then
                bb:paintRect(tab.x, top + R(97), tab.w, R(10), BLACK)
            end
        end
    end
    bb:paintRect(0, top + R(107), sw, R(4), BLACK)
    if self.list then
        self:paintList(bb)
    elseif self.tab == THEMES_TAB then
        self:paintThemes(bb)
    elseif self.tab == FONT_TAB then
        self:paintFont(bb)
    else
        self:paintLayout(bb)
    end
end

function Sheet:refresh()
    self:build()
    UIManager:setDirty(self, "ui", self:region())
end

function Sheet:openList(list)
    self.list = list
    self.page = 1
    self:refresh()
end

function Sheet:closeList()
    self.list = nil
    self:refresh()
end

function Sheet:manageThemes()
    local items = {}
    for index, saved in ipairs(savedThemes()) do
        table.insert(items, { text = saved.name, index = index })
    end
    self:openList{
        title = _("Manage Themes"),
        empty = _("No saved themes yet"),
        delete = true,
        items = items,
        on_delete = function(item)
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete the theme \"%1\"?"), item.text),
                ok_text = _("Delete"),
                ok_callback = function()
                    local saved = savedThemes()
                    table.remove(saved, item.index)
                    G_reader_settings:saveSetting(SAVED, saved)
                    self:manageThemes()
                end,
            })
        end,
    }
end

function Sheet:chooseFont()
    local ui = self.ui
    local items = {}
    for _i, face in ipairs(cre().getFontFaces()) do
        local file = cre().getFontFaceFilenameAndFaceIndex(face)
        table.insert(items, {
            text = face,
            current = face == ui.font.font_face,
            face = file and U.face(file, BODY_FONT) or nil,
        })
    end
    self:openList{
        title = _("Font Family"),
        items = items,
        on_tap = function(item)
            local values = currentValues(ui)
            values.font_face = item.text
            apply(ui, values)
            self:closeList()
        end,
    }
end

function Sheet:choose(entry)
    if entry == self.selected or entry.disabled or not entry.values then return end
    apply(self.ui, entry.values)
    self:refresh()
end

function Sheet:setDefault()
    if self.selected.is_default then return end
    local ui = self.ui
    saveAsDefault(ui)
    local styles = bookStyles(currentValues(ui))
    styles.font_face = ui.font.font_face
    require("kcui/defaults").restyleBooks(styles, ui.document.file)
    self:refresh()
end

function Sheet:askName()
    if #savedThemes() >= MAX_SAVED then
        UIManager:show(InfoMessage:new{
            text = T(_("You can keep up to %1 saved themes. Delete one in Manage Themes first."), MAX_SAVED),
        })
        return
    end
    local ui = self.ui
    UIManager:close(self)
    Themes.askName(ui)
end

function Sheet:tapList(pos)
    local list = self.list
    if pos.y < self.top + R(111) then
        self:closeList()
        return
    end
    for _i, row in ipairs(list.rows) do
        if row.rect:contains(pos) then
            if list.on_delete then
                if pos.x >= self.dimen.w - R(160) then
                    list.on_delete(row.item)
                end
            elseif list.on_tap then
                list.on_tap(row.item)
            end
            return
        end
    end
end

local function viewModePanel(options)
    for index, panel in ipairs(options or {}) do
        for _i, setting in ipairs(panel.options or {}) do
            if setting.name == "view_mode" then
                return index
            end
        end
    end
end

function Sheet:confirmReset()
    local ui = self.ui
    UIManager:show(ConfirmBox:new{
        text = _("Reset styles for this book?"),
        ok_text = _("Yes"),
        cancel_text = _("No"),
        ok_callback = function()
            UIManager:close(self)
            require("kcui/defaults").resetBook(ui)
        end,
    })
end

function Sheet:tapTabs(pos)
    for i, tab in ipairs(self.tabs) do
        if pos.x >= tab.x - R(22) and pos.x < tab.x + tab.w + R(22) then
            if i <= LAYOUT_TAB then
                if i ~= self.tab then
                    self.tab = i
                    self:refresh()
                end
            elseif i == RESET_TAB then
                self:confirmReset()
            else
                local ui = self.ui
                UIManager:close(self)
                ui.config.last_panel_index = viewModePanel(ui.config.options) or ui.config.last_panel_index
                ui:handleEvent(Event:new("ShowConfigMenu"))
            end
            return
        end
    end
end

function Sheet:tapThemes(pos)
    if self.save_rect:contains(pos) then
        if self.selected.kind == "custom" then
            self:askName()
        else
            self:setDefault()
        end
    elseif self.manage_rect:contains(pos) then
        self:manageThemes()
    else
        for _i, entry in ipairs(self.entries) do
            if entry.rect:contains(pos) then
                self:choose(entry)
                return
            end
        end
    end
end

function Sheet:tapFont(pos)
    if self.family_rect:contains(pos) then
        self:chooseFont()
        return
    end
    local reach = R(30)
    for _i, slider in ipairs(self.sliders) do
        if math.abs(pos.y - slider.center) <= R(60) then
            local level
            if pos.x >= slider.minus.x - reach and pos.x <= slider.minus.x + slider.minus.w + reach then
                level = slider.level - 1
            elseif pos.x >= slider.plus.x - reach and pos.x <= slider.plus.x + slider.plus.w + reach then
                level = slider.level + 1
            elseif pos.x >= slider.x and pos.x < slider.x + slider.count * slider.pitch then
                level = math.floor((pos.x - slider.x) / slider.pitch) + 1
            end
            if level then
                level = math.max(slider.number and 1 or 0, math.min(slider.count, level))
                if level ~= slider.level then
                    slider.set(level)
                    self:refresh()
                end
            end
            return
        end
    end
end

function Sheet:tapLayout(pos)
    local reach = R(12)
    for _i, group in ipairs(self.groups) do
        for _j, choice in ipairs(group.options) do
            local rect = choice.rect
            if pos.x >= rect.x - reach and pos.x < rect.x + rect.w + reach
                    and pos.y >= rect.y - reach and pos.y < rect.y + rect.h + reach then
                if not choice.selected then
                    choice.action()
                end
                return
            end
        end
    end
end

function Sheet:onTapSheet(_ev, ges)
    local pos = ges.pos
    if pos.y < self.top then
        UIManager:close(self)
    elseif self.list then
        self:tapList(pos)
    elseif pos.y < self.top + R(111) then
        self:tapTabs(pos)
    elseif self.tab == THEMES_TAB then
        self:tapThemes(pos)
    elseif self.tab == FONT_TAB then
        self:tapFont(pos)
    else
        self:tapLayout(pos)
    end
    return true
end

function Sheet:onSwipeSheet(_ev, ges)
    local list = self.list
    if list and (ges.direction == "north" or ges.direction == "west") and self.page < list.pages then
        self.page = self.page + 1
        self:refresh()
    elseif list and (ges.direction == "south" or ges.direction == "east") and self.page > 1 then
        self.page = self.page - 1
        self:refresh()
    elseif ges.direction == "south" then
        UIManager:close(self)
    end
    return true
end

function Sheet:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

function Sheet:onShow()
    UIManager:setDirty(self, "ui", self:region())
    return true
end

function Sheet:onCloseWidget()
    self:release()
    for _i, widget in ipairs(self.fixed) do
        widget:free()
    end
    UIManager:setDirty(nil, "ui", self:region())
end

local NameSheet = InputContainer:extend{
    ui = nil,
}

function NameSheet:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.face = U.face("cfont", BODY_FONT)
    self.title_face = U.face("cfont", TITLE_FONT)
    self.box = Geom:new{ x = R(59), w = sw - R(59) - R(76), h = R(111) }
    self.input = InputText:new{
        text = T(_("Theme %1"), #savedThemes() + 1),
        face = U.face("cfont", INPUT_FONT),
        width = self.box.w - 2 * R(52),
        bordersize = 0,
        padding = 0,
        margin = 0,
        scroll = false,
        focused = true,
        parent = self,
        enter_callback = function() self:save() end,
    }
    self[1] = self.input
    if self.input.keyboard then
        self.input.keyboard.active_widgets = { self }
    end
    local keyboard = self.input:getKeyboardDimen()
    self.height = R(604)
    self.top = math.max(0, sh - (keyboard and keyboard.h or 0) - self.height)
    self.box.y = self.top + R(133)
    self.title = TextWidget:new{ text = _("Save Current Settings"), face = self.title_face }
    self.note = TextWidget:new{
        text = _("Save your settings (Font, Layout, and More) to a new theme"),
        face = self.face,
        max_width = sw - 2 * R(59),
    }
    local button_w, button_h, gap = R(255), R(95), R(30)
    local right = self.box.x + self.box.w
    self.buttons = {
        { label = TextWidget:new{ text = _("Cancel"), face = self.face }, action = function() self:finish() end,
            rect = Geom:new{ x = right - 2 * button_w - gap, y = self.top + R(479), w = button_w, h = button_h } },
        { label = TextWidget:new{ text = _("Save"), face = self.face }, action = function() self:save() end,
            rect = Geom:new{ x = right - button_w, y = self.top + R(479), w = button_w, h = button_h } },
    }
    self.ges_events = {
        TapName = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function NameSheet:getFocusableWidgetXY() end

function NameSheet:moveFocusTo() end

function NameSheet:onCloseDialog()
    self:finish()
    return true
end

function NameSheet:region()
    return Geom:new{ x = 0, y = self.top, w = self.dimen.w, h = self.height }
end

function NameSheet:paintTo(bb)
    local sw, top = self.dimen.w, self.top
    bb:paintRect(0, top, sw, self.height, WHITE)
    bb:paintRect(0, top, sw, R(4), BLACK)
    bb:paintRect(0, top + self.height - R(5), sw, R(5), BLACK)
    self.title:paintTo(bb, R(59), capTop(self.title, self.title_face, top + R(54)))
    self.note:paintTo(bb, R(59), capTop(self.note, self.face, top + R(105)))
    local box = self.box
    bb:paintBorder(box.x, box.y, box.w, box.h, R(4), BLACK)
    local input = self.input:getSize()
    self.input:paintTo(bb, box.x + R(52), box.y + math.floor((box.h - input.h) / 2))
    for _i, button in ipairs(self.buttons) do
        local rect = button.rect
        bb:paintBorder(rect.x, rect.y, rect.w, rect.h, R(2), BLACK)
        local size = button.label:getSize()
        button.label:paintTo(bb, rect.x + math.floor((rect.w - size.w) / 2),
            capTop(button.label, self.face, rect.y + math.floor(rect.h / 2)))
    end
end

function NameSheet:finish()
    local ui = self.ui
    self.input:onCloseKeyboard()
    UIManager:close(self)
    Themes.show(ui)
end

function NameSheet:save()
    local name = util.trim(self.input:getText() or "")
    if name == "" then return end
    local saved = savedThemes()
    table.insert(saved, { name = name, values = currentValues(self.ui) })
    G_reader_settings:saveSetting(SAVED, saved)
    self:finish()
end

function NameSheet:onTapName(_ev, ges)
    for _i, button in ipairs(self.buttons) do
        if button.rect:contains(ges.pos) then
            button.action()
            return true
        end
    end
    if ges.pos.y < self.top then
        self:finish()
    end
    return true
end

function NameSheet:onShow()
    UIManager:setDirty(self, "ui", self:region())
    UIManager:nextTick(function()
        if UIManager:isWidgetShown(self) then
            self.input:onShowKeyboard()
        end
    end)
    return true
end

function NameSheet:onCloseWidget()
    self.title:free()
    self.note:free()
    for _i, button in ipairs(self.buttons) do
        button.label:free()
    end
    UIManager:setDirty(nil, "ui", self:region())
end

Themes.fromPixels = option

function Themes.defaultFont()
    return KindleFonts.found.book and KindleFonts.BOOK_FAMILY or nil
end

function Themes.narrowMargin()
    return Screen:scaleBySize(option(pageLayout().margins[1]))
end

function Themes.marginChanges()
    local to = pageLayout()
    local changes = {
        { key = "copt_t_page_margin", from = option(LARGE_PAGE.top), to = option(to.top) },
    }
    for _i, bottom in ipairs(PREVIOUS_BOTTOMS) do
        table.insert(changes, { key = "copt_b_page_margin", from = option(bottom), to = BOTTOM_MARGIN })
    end
    for level, margin in ipairs(LARGE_PAGE.margins) do
        table.insert(changes, {
            key = "copt_h_page_margins",
            from = { option(margin), option(margin) },
            to = { option(to.margins[level]), option(to.margins[level]) },
        })
    end
    return changes
end

function Themes.forgetCustom()
    G_reader_settings:delSetting(CUSTOM)
end

function Themes.askName(ui)
    UIManager:show(NameSheet:new{ ui = ui })
end

function Themes.show(ui, tab)
    if not (ui.rolling and ui.document.configurable.font_size) then
        ui:handleEvent(Event:new("ShowConfigMenu"))
        return
    end
    UIManager:show(Sheet:new{ ui = ui, tab = tab })
end

function Themes.register(ui)
    if not ui.rolling then return end
    local zones = {}
    for _i, gesture in ipairs({ "pinch", "spread" }) do
        table.insert(zones, {
            id = "kcui_themes_" .. gesture,
            ges = gesture,
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { gesture .. "_gesture" },
            handler = function()
                Themes.show(ui, FONT_TAB)
                return true
            end,
        })
    end
    ui:registerTouchZones(zones)
end

return Themes
