local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GoTo = require("kcui/goto")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ReaderAnnotation = require("apps/reader/modules/readerannotation")
local ReaderBookmark = require("apps/reader/modules/readerbookmark")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ReaderView = require("apps/reader/modules/readerview")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local Toolbar = require("kcui/toolbar")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local _ = require("gettext")
local Common = require("kcui/common")
local Screen = Device.screen
local Gray = Common.Gray
local Paint = Common.Paint
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/selection%.lua$") .. "/icons"
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local INVERT = "invert"
local LIGHTEN = "lighten"
local BLACK_COLOR = "black"
local TEXT_COLOR = "text_color"
local UNDERLINE = "underscore"
local UNDERLINE_RAISE = 3
local STYLES = {
    { drawer = LIGHTEN },
    { drawer = TEXT_COLOR, color_only = true },
    { drawer = UNDERLINE },
    { drawer = "strikeout" },
}
local LINE_STYLES = { [UNDERLINE] = true, strikeout = true }
local NOTE_MARK_SCALE = 0.5
local NOTE_MARK_ASPECT = 0.8
local NOTE_MARK_RAISE = 0.3
local TEXT_LIGHTNESS = 0.38
local TEXT_MIN_SATURATION = 0.55
local KINDLE_COLORS = {
    { _("Pink"), "pink", "#EFA9A8", true },
    { _("Orange"), "orange", "#F1BA6E" },
    { _("Yellow"), "yellow", "#FAE77C" },
    { _("Green"), "green", "#73DCB2" },
    { _("Aqua"), "aqua", "#77D6DB" },
    { _("Blue"), "blue", "#8DB4EE", true },
    { _("Purple"), "purple", "#C3A6EC", true },
    { _("Gray"), "gray" },
}
local PORTABLE_COLORS = { pink = "purple", aqua = "blue" }
local MONO_COLOR = KINDLE_COLORS[#KINDLE_COLORS][2]
local DETAILS_BUTTON = "00_details"
local ON_BAR = { ["02_highlight"] = true, ["04_add_note"] = true, ["12_search"] = true }

local Selection = {}

local function hslToRgb(h, sat, light)
    local function channel(t)
        t = t % 1
        local q = light < 0.5 and light * (1 + sat) or light + sat - light * sat
        local p = 2 * light - q
        if t < 1 / 6 then return p + (q - p) * 6 * t end
        if t < 1 / 2 then return q end
        if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
        return p
    end
    return channel(h + 1 / 3), channel(h), channel(h - 1 / 3)
end

local function rgbToHsl(r, g, b)
    local high, low = math.max(r, g, b), math.min(r, g, b)
    local light = (high + low) / 2
    if high == low then return 0, 0, light end
    local delta = high - low
    local sat = light > 0.5 and delta / (2 - high - low) or delta / (high + low)
    local h
    if high == r then
        h = (g - b) / delta + (g < b and 6 or 0)
    elseif high == g then
        h = (b - r) / delta + 2
    else
        h = (r - g) / delta + 4
    end
    return h / 6, sat, light
end

local text_colors = {}

local function colorKey(color)
    return color.r * 65536 + color.g * 256 + color.b
end

for _i, color in ipairs(KINDLE_COLORS) do
    if color[4] then
        local swatch = Blitbuffer.colorFromString(color[3])
        text_colors[colorKey(swatch)] = swatch
    end
end

local function textColor(color)
    if Blitbuffer.isColor8(color) then
        return Blitbuffer.ColorRGB32(color.a, color.a, color.a, 0xFF)
    end
    local key = colorKey(color)
    if not text_colors[key] then
        local h, sat, light = rgbToHsl(color.r / 255, color.g / 255, color.b / 255)
        if light <= TEXT_LIGHTNESS then
            text_colors[key] = color
            return color
        end
        local r, g, b = hslToRgb(h, sat > 0 and math.max(sat, TEXT_MIN_SATURATION) or 0, TEXT_LIGHTNESS)
        text_colors[key] = Blitbuffer.ColorRGB32(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), 0xFF)
    end
    return text_colors[key]
end

local function paintTextColor(bb, rect, color)
    local tint = textColor(color):invert()
    bb:invertRect(rect.x, rect.y, rect.w, rect.h)
    bb:multiplyRectRGB(rect.x, rect.y, rect.w, rect.h, tint)
    bb:invertRect(rect.x, rect.y, rect.w, rect.h)
end

local function capTop(widget, face, cap_center)
    local cap = math.floor(face.size * 0.667 + 0.5)
    return cap_center - math.floor(cap / 2) - (widget:getBaseline() - cap)
end

local function icon(name, size)
    return ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/" .. name .. ".svg",
        width = size,
        height = size,
        alpha = true,
    }
end

local function paintNoColor(bb, cx, cy, r)
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_DARK_GRAY, U.ceil(1.5))
    local thickness = U.ceil(1.5)
    local reach = math.floor(r * 0.7)
    for i = -reach, reach do
        bb:paintRect(cx + i, cy - i, thickness, thickness, Blitbuffer.COLOR_DARK_GRAY)
    end
end

local function screenBoxes(hl)
    local selected = hl.selected_text
    local boxes = selected and (selected.sboxes or selected.pboxes)
    local result = {}
    for _i, box in ipairs(boxes or {}) do
        if hl.ui.paging then
            box = hl.view:pageToScreenTransform(selected.pos0.page, box)
        end
        if box then
            table.insert(result, box)
        end
    end
    return result
end

local function annotationBoxes(hl, index)
    local item = hl.ui.annotation.annotations[index]
    local result = {}
    if not (item and item.drawer) then
        return result
    end
    for _i, box in ipairs(hl:getHighlightVisibleBoxes(index) or {}) do
        if hl.ui.paging then
            box = item.pos0 and hl.view:pageToScreenTransform(item.pos0.page, box)
        end
        if box then
            table.insert(result, box)
        end
    end
    return result
end

local function lastBox(boxes)
    local last
    for _i, box in ipairs(boxes) do
        if not last or box.y > last.y or (box.y == last.y and box.x > last.x) then
            last = box
        end
    end
    return last
end

local function paintNoteMarks(view, bb)
    local hl = view.ui.highlight
    local annotations = view.ui.annotation and view.ui.annotation.annotations
    if not (hl and annotations) then return end
    local seen = {}
    for _i, visible in ipairs(view.highlight.visible_boxes or {}) do
        local index = visible.index
        local item = not seen[index] and annotations[index]
        seen[index] = true
        local last = item and item.note and lastBox(annotationBoxes(hl, index))
        if last then
            local h = math.floor(last.h * NOTE_MARK_SCALE)
            local w = math.floor(h * NOTE_MARK_ASPECT)
            local mark = ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. "/note-mark.svg",
                width = w,
                height = h,
                alpha = true,
            }
            local x = math.min(last.x + last.w, Screen:getWidth() - w)
            mark:paintTo(bb, x, math.max(0, last.y - math.floor(h * NOTE_MARK_RAISE)))
            mark:free()
        end
    end
end

local function union(boxes)
    if #boxes == 0 then return end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _i, box in ipairs(boxes) do
        x0, y0 = math.min(x0, box.x), math.min(y0, box.y)
        x1, y1 = math.max(x1, box.x + box.w), math.max(y1, box.y + box.h)
    end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

local function placement(bounds, w, h, notch)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin, gap = U(10), U(14)
    local cx = bounds and bounds.x + math.floor(bounds.w / 2) or math.floor(sw / 2)
    local x = math.max(margin, math.min(sw - margin - w, cx - math.floor(w / 2)))
    local y, above
    if bounds and bounds.y - gap - notch - h >= margin then
        y, above = bounds.y - gap - notch - h, true
    elseif bounds and bounds.y + bounds.h + gap + notch + h <= sh - margin then
        y, above = bounds.y + bounds.h + gap + notch, false
    else
        y = math.floor((sh - h) / 2)
    end
    return Geom:new{ x = x, y = y, w = w, h = h }, above, math.max(x + U(16), math.min(x + w - U(16), cx))
end

function Selection.applyChanges(ui, item, changes)
    local hl = ui.highlight
    hl:writePdfAnnotation("delete", item)
    for key, value in pairs(changes) do
        item[key] = value
    end
    if ui.paging then
        hl:writePdfAnnotation("save", item)
        if item.note then
            hl:writePdfAnnotation("content", item, item.note)
        end
    end
    UIManager:setDirty(ui.dialog, "ui")
    ui:handleEvent(Event:new("AnnotationsModified", { item }))
end

local function endsVisible(hl, item)
    local selected = item or hl.selected_text
    if not (selected and selected.pos0 and selected.pos1) then return false, false end
    if hl.ui.rolling then
        local doc = hl.ui.document
        return doc:isXPointerInCurrentPage(selected.pos0), doc:isXPointerInCurrentPage(selected.pos1)
    end
    local page = hl.view.state.page
    return selected.pos0.page == page, selected.pos1.page == page
end

local function styleFor(color, drawer)
    local base = drawer == INVERT and LIGHTEN or drawer
    if color == BLACK_COLOR then
        return (base == LIGHTEN or base == TEXT_COLOR) and INVERT or base
    end
    return base
end

local function isBlack(item)
    return item and (item.drawer == INVERT or item.color == BLACK_COLOR)
end

local PREVIEW_LINES = 2

local Palette = InputContainer:extend{
    ui = nil,
    item_fn = nil,
    width = nil,
    standalone = false,
    preview = false,
    on_delete = nil,
    on_change = nil,
}

function Palette:init()
    local hl = self.ui.highlight
    self.mono = not Screen:isColorEnabled()
    self.face = U.face("cfont", 14)
    self.swatch_h = U(44)
    self.name_h = U(36)
    self.swatch_r = U(10)
    self.swatch_spacing = U(30)
    self.style_size = U(20)
    self.icon_face = U.face("cfont", 14)
    self.style_spacing = U(36)
    self.swatches = {}
    if self.on_delete then
        table.insert(self.swatches, { kind = "none" })
    end
    local colors = self.mono
        and { { _("Gray"), MONO_COLOR, hl:getHighlightColor(MONO_COLOR) } }
        or Common.Highlights.colors(hl)
    for _i, color in ipairs(colors) do
        table.insert(self.swatches, { kind = "color", name = color[2], label = color[1], fill = color[3] })
    end
    table.insert(self.swatches, { kind = "color", name = BLACK_COLOR, label = _("Black"), fill = BLACK })
    self.styles = {}
    for _i, style in ipairs(STYLES) do
        if not (self.mono and style.color_only) then
            table.insert(self.styles, { drawer = style.drawer })
        end
    end
    self.preview_h = 0
    if self.preview then
        self.preview_pad = U(10)
        local item = self.item_fn()
        local text_w = (self.width or self:minWidth()) - 2 * U(14)
        local face = U.face("cfont", 15)
        local probe = TextBoxWidget:new{ text = "A", face = face, width = text_w }
        local line_h = probe:getLineHeight()
        probe:free()
        self.preview_text = TextBoxWidget:new{
            text = item and item.text or "",
            face = face,
            width = text_w,
            height = PREVIEW_LINES * line_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
        self.preview_h = self.preview_text:getSize().h + 2 * self.preview_pad
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width or self:minWidth(), h = self:height() }
    if self.standalone then
        self.ges_events = {
            TapPalette = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
end

function Palette:minWidth()
    local width = #self.swatches * self.swatch_spacing + U(20)
    if self.mono then
        width = width + #self.styles * self.style_spacing + U(14)
    end
    return width
end

function Palette:height()
    return (self.preview_h or 0) + self.swatch_h + (self.mono and 0 or self.name_h)
end

function Palette:paintPreview(bb, item)
    local text = self.preview_text
    local x, y = self.dimen.x + U(14), self.dimen.y + self.preview_pad
    text:paintTo(bb, x, y)
    if not (item and item.drawer) then return end
    local hl = self.ui.highlight
    local color = item.drawer ~= INVERT and hl:getHighlightColor(item.color) or nil
    local line_h = text:getLineHeight()
    for i = 1, text:getVisLineCount() do
        local line = text.vertical_string_list[i]
        if line and line.width and line.width > 0 then
            local rect = Geom:new{ x = x, y = y + (i - 1) * line_h, w = line.width, h = line_h }
            self.ui.view:drawHighlightRect(bb, 0, 0, rect, item.drawer, color)
        end
    end
end

function Palette:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Palette:swatchCenters()
    local d = self.dimen
    local cy = d.y + self.preview_h + math.floor(self.swatch_h / 2)
    local margin = U(14) + self.swatch_r
    local first = d.x + margin
    if self.mono then
        return first, cy, self.swatch_spacing
    end
    return first, cy, (d.w - 2 * margin) / (#self.swatches - 1)
end

function Palette:visibleStyles(item)
    if not isBlack(item) then return self.styles end
    local styles = {}
    for _i, style in ipairs(self.styles) do
        if style.drawer ~= TEXT_COLOR then
            table.insert(styles, style)
        end
    end
    return styles
end

function Palette:styleRects(styles)
    local d = self.dimen
    local cy = self.mono and select(2, self:swatchCenters()) or d.y + self.preview_h + self.swatch_h + math.floor(self.name_h / 2)
    local rects = {}
    for i = 1, #styles do
        local cx = d.x + d.w - U(14) - math.floor(self.style_size / 2) - (#styles - i) * self.style_spacing
        local half = math.floor(self.style_spacing / 2)
        rects[i] = Geom:new{ x = cx - half, y = cy - half, w = self.style_spacing, h = self.style_spacing }
    end
    return rects
end

function Palette:isCurrent(swatch, item)
    if not item or swatch.kind ~= "color" then return false end
    local black = isBlack(item)
    if swatch.name == BLACK_COLOR then return black end
    return not black and swatch.name == item.color
end

function Palette:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local d = self.dimen
    if self.standalone then
        bb:paintRect(d.x, d.y, d.w, d.h, WHITE)
    end
    local item = self.item_fn()
    if self.preview then
        self:paintPreview(bb, item)
    end
    local first, cy, spacing = self:swatchCenters()
    local ring = U.ceil(1.5)
    local current
    for i, swatch in ipairs(self.swatches) do
        local cx = math.floor(first + (i - 1) * spacing + 0.5)
        if swatch.kind == "none" then
            paintNoColor(bb, cx, cy, self.swatch_r)
        else
            Paint.disc(bb, cx, cy, self.swatch_r, swatch.fill)
            if self:isCurrent(swatch, item) then
                bb:paintCircle(cx, cy, self.swatch_r + U(4), BLACK, ring)
                current = swatch
            end
        end
    end
    if not self.mono then
        local name_top = d.y + self.preview_h + self.swatch_h
        bb:paintRect(d.x + U(8), name_top, d.w - 2 * U(8), U.ceil(1), Gray.divider)
        if current then
            local label = TextWidget:new{ text = current.label, face = self.face }
            label:paintTo(bb, d.x + U(14), name_top + capTop(label, self.face, math.floor(self.name_h / 2)))
        end
    end
    local drawer = item and (item.drawer == INVERT and LIGHTEN or item.drawer)
    local fill = self:currentFill(item)
    local styles = self:visibleStyles(item)
    for i, rect in ipairs(self:styleRects(styles)) do
        local style = styles[i]
        self:paintStyleIcon(bb, rect, style.drawer, fill)
        if drawer == style.drawer then
            bb:paintBorder(rect.x + U(3), rect.y + U(3), rect.w - 2 * U(3), rect.h - 2 * U(3), ring, BLACK, U(4))
        end
    end
end

function Palette:currentFill(item)
    local hl = self.ui.highlight
    if isBlack(item) then
        return BLACK
    end
    local name = item and item.color or (self.mono and MONO_COLOR or hl.view.highlight.saved_color)
    return hl:getHighlightColor(name) or Blitbuffer.COLOR_GRAY
end

function Palette:paintStyleIcon(bb, rect, drawer, fill)
    local size = self.style_size
    local x = rect.x + math.floor((rect.w - size) / 2)
    local y = rect.y + math.floor((rect.h - size) / 2)
    local letter_color = BLACK
    if drawer == LIGHTEN then
        local inset = U(1)
        Paint.fill(bb, x + inset, y + inset, size - 2 * inset, size - 2 * inset, fill)
        if fill == BLACK then
            letter_color = WHITE
        end
    end
    local letter = TextWidget:new{ text = "A", face = self.icon_face, bold = true, fgcolor = letter_color }
    local cap = math.floor(self.icon_face.size * 0.667 + 0.5)
    local cap_top = y + math.floor((size - cap) / 2)
    letter:paintTo(bb, x + math.floor((size - letter:getSize().w) / 2), cap_top - (letter:getBaseline() - cap))
    if drawer == TEXT_COLOR then
        paintTextColor(bb, Geom:new{ x = x, y = y, w = size, h = size }, fill)
    end
    local line = U.ceil(1.5)
    if LINE_STYLES[drawer] and not self.mono then
        fill = textColor(fill)
    end
    if drawer == UNDERLINE then
        Paint.fill(bb, x + U(2), cap_top + cap + U(2), size - 2 * U(2), line, fill)
    elseif drawer == "strikeout" then
        Paint.fill(bb, x + U(1), cap_top + math.floor((cap - line) / 2) + U(1), size - 2 * U(1), line, fill)
    end
end

function Palette:apply(color, drawer)
    local item = self.item_fn()
    if not item then return end
    local changes = { color = color, drawer = styleFor(color, drawer) }
    if changes.color == item.color and changes.drawer == item.drawer then return end
    Selection.applyChanges(self.ui, item, changes)
    if color and color ~= BLACK_COLOR then
        self.ui.highlight.view.highlight.saved_color = color
        G_reader_settings:saveSetting("highlight_color", color)
    end
    if self.on_change then
        self.on_change()
    end
end

function Palette:tap(pos)
    local item = self.item_fn()
    local styles = self:visibleStyles(item)
    for i, rect in ipairs(self:styleRects(styles)) do
        if rect:contains(pos) then
            if item then
                self:apply(item.color, styles[i].drawer)
            end
            return true
        end
    end
    if pos.y < self.dimen.y + self.preview_h or pos.y >= self.dimen.y + self.preview_h + self.swatch_h then return true end
    local first, _cy, spacing = self:swatchCenters()
    local swatch = self.swatches[math.floor((pos.x - first + spacing / 2) / spacing) + 1]
    if not swatch then return true end
    if swatch.kind == "none" then
        self.on_delete()
    elseif item then
        self:apply(swatch.name, item.drawer)
    end
    return true
end

function Palette:onTapPalette(_ev, ges)
    return self:tap(ges.pos)
end

local SelectionBar = InputContainer:extend{
    hl = nil,
    pinned = false,
    modal = true,
}

function SelectionBar:init()
    local hl = self.hl
    self.ui = hl.ui
    self:remember(self.index)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.face = U.face("cfont", 16)
    self.border = U.ceil(1.5)
    self.radius = U(6)
    self.notch = U(9)
    self.bar_h = U(42)
    self.handle_dot = U(5)
    self.handle_reach = U(30)
    self.mono = not Screen:isColorEnabled()
    self.cells = {
        { text = _("Highlight"), action = "highlight" },
        { text = _("Note"), action = "note" },
        { icon = icon("search", U(18)), action = "search" },
        { icon = icon("more-filled", U(18)), action = "more" },
    }
    self.ges_events = {
        TapBar = { GestureRange:new{ ges = "tap", range = self.dimen } },
        TouchBar = { GestureRange:new{ ges = "touch", range = self.dimen } },
        HoldBar = { GestureRange:new{ ges = "hold", range = self.dimen } },
        PanBar = { GestureRange:new{ ges = "pan", range = self.dimen } },
        HoldPanBar = { GestureRange:new{ ges = "hold_pan", range = self.dimen } },
        PanReleaseBar = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        HoldReleaseBar = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        SwipeBar = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:layout()
end

function SelectionBar:remember(index)
    self.index = index
    self.entry = index and self.ui.annotation.annotations[index]
end

function SelectionBar:resync()
    local annotations = self.ui.annotation.annotations
    if self.entry and annotations[self.index] ~= self.entry then
        self.index = nil
        for i, candidate in ipairs(annotations) do
            if candidate == self.entry then
                self.index = i
                break
            end
        end
    end
    return self.index
end

function SelectionBar:item()
    return self:resync() and self.ui.annotation.annotations[self.index]
end

function SelectionBar:layout()
    local cell_pad = U(18)
    local width = 0
    for _i, cell in ipairs(self.cells) do
        if cell.text then
            cell.label = TextWidget:new{ text = cell.text, face = self.face, bold = true, fgcolor = cell.active and WHITE or BLACK }
        end
        cell.w = (cell.label or cell.icon):getSize().w + 2 * cell_pad
        width = width + cell.w
    end
    local height = self.bar_h
    if self.palette then
        width = math.max(width, self.palette:minWidth())
        height = height + self.line_gap() + self.palette:height()
    end
    if self.fragment then
        self.boxes = annotationBoxes(self.hl, self.hl.highlight_idx)
    elseif self.existing and not self.hl.selected_text then
        self.boxes = annotationBoxes(self.hl, self.index)
    else
        self.boxes = screenBoxes(self.hl)
    end
    if self.pinned then
        self.frame = Geom:new{ x = math.floor((Screen:getWidth() - width) / 2), y = U(10), w = width, h = height }
        self.above, self.notch_x = nil, nil
    else
        self.frame, self.above, self.notch_x = placement(union(self.boxes), width, height, self.notch)
    end
    if self.palette then
        self.palette.dimen.w = width
    end
    local extra = width
    for _i, cell in ipairs(self.cells) do
        extra = extra - cell.w
    end
    local x = self.frame.x
    for i, cell in ipairs(self.cells) do
        cell.w = cell.w + math.floor(extra / #self.cells) + (i == #self.cells and extra % #self.cells or 0)
        cell.x = x
        x = x + cell.w
    end
end

function SelectionBar.line_gap()
    return U.ceil(1)
end

function SelectionBar:handles()
    if not self.editing or #self.boxes == 0 then return {} end
    local first, last = self.boxes[1], self.boxes[#self.boxes]
    local show_start, show_end = true, true
    if not self.fragment and (self.pinned or self.index) then
        show_start, show_end = endsVisible(self.hl, self.existing and not self.hl.selected_text and self:item() or nil)
        if not self.pinned and not (show_start and show_end) then
            return {}
        end
    end
    local handles = {}
    if show_start then
        table.insert(handles, { side = "start", x = first.x, top = first.y - 2 * self.handle_dot, bottom = first.y + first.h, dot_y = first.y - 2 * self.handle_dot })
    end
    if show_end then
        table.insert(handles, { side = "end", x = last.x + last.w, top = last.y, bottom = last.y + last.h + 2 * self.handle_dot, dot_y = last.y + last.h + 2 * self.handle_dot })
    end
    return handles
end

function SelectionBar:marginBars()
    local bounds = self.editing and union(self.boxes)
    if not bounds then return {} end
    local width, inset = U(4), U(8)
    local item = self:item()
    local color = item and self.hl:getHighlightColor(item.color or "gray", false, true) or Blitbuffer.COLOR_GRAY
    return {
        { rect = Geom:new{ x = inset, y = bounds.y, w = width, h = bounds.h }, color = color },
        { rect = Geom:new{ x = Screen:getWidth() - inset - width, y = bounds.y, w = width, h = bounds.h }, color = color },
    }
end

function SelectionBar:region()
    local f = self.frame
    local area = Geom:new{ x = f.x, y = f.y - self.notch, w = f.w, h = f.h + 2 * self.notch }
    for _i, bar in ipairs(self:marginBars()) do
        area = area:combine(bar.rect)
    end
    for _i, handle in ipairs(self:handles()) do
        area = area:combine(Geom:new{
            x = handle.x - self.handle_reach,
            y = handle.top - self.handle_dot,
            w = 2 * self.handle_reach,
            h = handle.bottom - handle.top + 2 * self.handle_dot,
        })
    end
    return area
end

function SelectionBar:paintHandles(bb)
    if not self.editing then return end
    for _i, bar in ipairs(self:marginBars()) do
        local r = bar.rect
        Paint.fill(bb, r.x, r.y, r.w, r.h, bar.color)
    end
    local line = U.ceil(1.5)
    for _i, box in ipairs(self.boxes) do
        bb:paintRect(box.x, box.y + box.h, box.w, line, BLACK)
    end
    for _i, handle in ipairs(self:handles()) do
        bb:paintRect(handle.x - math.floor(line / 2), handle.top, line, handle.bottom - handle.top, BLACK)
        bb:paintCircle(handle.x, handle.dot_y, self.handle_dot, BLACK)
    end
end

function SelectionBar:paintCells(bb)
    local f = self.frame
    for i, cell in ipairs(self.cells) do
        if cell.active then
            bb:paintRect(cell.x + (i == 1 and self.border or 0), f.y + self.border, cell.w - (i == 1 and self.border or 0), self.bar_h - self.border, BLACK)
        elseif i > 1 and not self.cells[i - 1].active then
            bb:paintRect(cell.x, f.y + U(8), U.ceil(1), self.bar_h - 2 * U(8), Gray.divider)
        end
        local content = cell.label or cell.icon
        local size = content:getSize()
        local y = cell.label and f.y + capTop(cell.label, self.face, math.floor(self.bar_h / 2)) or f.y + math.floor((self.bar_h - size.h) / 2)
        content:paintTo(bb, cell.x + math.floor((cell.w - size.w) / 2), y)
    end
end

function SelectionBar:paintTo(bb)
    self:paintHandles(bb)
    if self.dragging then return end
    local f = self.frame
    bb:paintRoundedRect(f.x, f.y, f.w, f.h, WHITE, self.radius)
    self:paintCells(bb)
    if self.palette then
        bb:paintRect(f.x, f.y + self.bar_h, f.w, self.line_gap(), BLACK)
        self.palette:paintTo(bb, f.x, f.y + self.bar_h + self.line_gap())
    end
    bb:paintBorder(f.x, f.y, f.w, f.h, self.border, BLACK, self.radius)
    if self.above ~= nil then
        local edge = self.above and f.y + f.h - self.border or f.y + self.border - 1
        Paint.notch(bb, self.notch_x, edge, self.above, self.notch, self.border)
    end
end

function SelectionBar:refresh(previous)
    local area = self:region()
    if previous then
        area = area:combine(previous)
    end
    UIManager:setDirty(self.ui.dialog, "ui", area)
    UIManager:setDirty(self, "ui", area)
end

function SelectionBar:dismiss(clear)
    UIManager:close(self)
    if self.hl.highlight_dialog == self then
        self.hl.highlight_dialog = nil
    end
    if clear then
        self.hl:clear()
    end
end

function SelectionBar:handleAt(pos)
    for _i, handle in ipairs(self:handles()) do
        if math.abs(pos.x - handle.x) <= self.handle_reach
                and pos.y >= handle.top - self.handle_reach and pos.y <= handle.bottom + self.handle_reach then
            return handle
        end
    end
end

function SelectionBar:onTouchBar(_ev, ges)
    local handle = self.editing and not self.pinned and self:handleAt(ges.pos)
    if handle then
        local anchor_box = handle.side == "start" and self.boxes[#self.boxes] or self.boxes[1]
        local anchor = handle.side == "start"
            and Geom:new{ x = anchor_box.x + anchor_box.w - 1, y = anchor_box.y + math.floor(anchor_box.h / 2) }
            or Geom:new{ x = anchor_box.x + 1, y = anchor_box.y + math.floor(anchor_box.h / 2) }
        self.drag = handle.side
        self.hold_pos_before = self.hl.hold_pos
        self.hl.hold_pos = self.hl.view:screenToPageTransform(anchor)
        return true
    end
    self.drag = nil
end

function SelectionBar:onHoldBar(_ev, ges)
    if self:onTouchBar(_ev, ges) then
        return true
    end
    if self.frame:contains(ges.pos) then
        return true
    end
    local hl = self.hl
    self:dismiss(true)
    hl:onHold(nil, ges)
    return true
end

function SelectionBar:onPanBar(_ev, ges)
    if not self.drag then return true end
    local previous = self:region()
    self.dragging = true
    self.hl:onHoldPan(nil, ges)
    self.boxes = screenBoxes(self.hl)
    self:refresh(previous)
    return true
end

function SelectionBar:onHoldPanBar(_ev, ges)
    return self:onPanBar(_ev, ges)
end

function SelectionBar:onHoldReleaseBar(_ev, ges)
    return self:onPanReleaseBar(_ev, ges)
end

function SelectionBar:onSwipeBar(_ev, ges)
    if self.drag then
        self.dragging = true
        return self:onPanReleaseBar(_ev, { pos = ges.end_pos or ges.pos })
    end
    self:dismiss(true)
    return true
end

function SelectionBar:onPanReleaseBar(_ev, ges)
    if not self.drag and not self.dragging then return true end
    local dragged = self.dragging
    if dragged and self.drag and ges and ges.pos then
        self.hl:onHoldPan(nil, ges)
        self.boxes = screenBoxes(self.hl)
    elseif not dragged then
        self.hl.hold_pos = self.hold_pos_before
    end
    local previous = self:region()
    self.drag, self.dragging = nil, nil
    if dragged and self.index then
        self:resave()
    end
    self:layout()
    self:refresh(previous)
    return true
end

function SelectionBar:showSaved(previous)
    local hl = self.hl
    if hl.ui.paging then
        hl.view.highlight.temp = {}
    else
        hl.ui.document:clearSelection()
    end
    self:layout()
    UIManager:setDirty(hl.dialog, "ui")
    self:refresh(previous)
end

function SelectionBar:resave()
    local hl = self.hl
    local item = self:item()
    local selected = hl.selected_text
    if not (item and selected and selected.pos0 and selected.pos1) then return end
    hl.selected_text.color = item.color
    hl.selected_text.drawer = item.drawer
    hl.selected_text.note = item.note
    hl.selected_text.datetime = item.datetime
    hl:deleteHighlight(self.index)
    self:remember(hl:saveHighlight())
    self:showSaved()
end

function SelectionBar:onTapBar(_ev, ges)
    if self.entry and not self:resync() then
        self:dismiss(true)
        return true
    end
    local pos = ges.pos
    if self.dragging then
        self.drag, self.dragging = nil, nil
        self:layout()
        self:refresh()
    end
    if self.frame:contains(pos) then
        if pos.y < self.frame.y + self.bar_h then
            for _i, cell in ipairs(self.cells) do
                if pos.x >= cell.x and pos.x < cell.x + cell.w then
                    self[cell.action](self)
                    break
                end
            end
        elseif self.palette then
            self.palette:tap(pos)
        end
        return true
    end
    if self:handleAt(pos) then
        return true
    end
    for _i, box in ipairs(self.boxes) do
        if Geom:new{ x = box.x, y = box.y - U(6), w = box.w, h = box.h + U(12) }:contains(pos) then
            if not self.editing then
                self.editing = true
                self:refresh()
            end
            return true
        end
    end
    self:dismiss(true)
    return true
end

function SelectionBar:prepareNew()
    local selected = self.hl.selected_text
    if not selected then return end
    selected.drawer = LIGHTEN
    if self.mono then
        selected.color = MONO_COLOR
    end
end

function SelectionBar:highlight()
    local hl = self.hl
    if self.index then return end
    local previous = self:region()
    self:prepareNew()
    self:remember(hl:saveHighlight(true))
    local selected = hl.selected_text
    if selected and hl.ui.rolling and not selected.sboxes then
        local ok, boxes = pcall(hl.ui.document.getScreenBoxesFromPositions, hl.ui.document, selected.pos0, selected.pos1, true)
        selected.sboxes = ok and boxes or nil
    end
    self:openPalette()
    self:showSaved(previous)
end

function SelectionBar:openPalette()
    local hl = self.hl
    self.cells[1].active = true
    self.palette = Palette:new{
        ui = self.ui,
        item_fn = function() return self:item() end,
        on_delete = function()
            UIManager:show(ConfirmBox:new{
                text = _("Delete this highlight?"),
                ok_text = _("Delete"),
                ok_callback = function()
                    local index = self:resync()
                    if index then
                        hl:deleteHighlight(index)
                    end
                    self:dismiss(true)
                end,
            })
        end,
        on_change = function() self:refresh() end,
    }
end

function SelectionBar:note()
    local hl = self.hl
    if self.index then
        local index = self.index
        local item = self:item()
        self:dismiss(true)
        if item and item.note then
            Selection.showNote(hl, index)
        else
            hl:editNote(index)
        end
    else
        self:prepareNew()
        self:dismiss()
        hl:addNote()
    end
end

function SelectionBar:search()
    local item = self.existing and self:item()
    self:dismiss()
    if item then
        self.ui.search:searchText(item.text)
    else
        self.hl:onHighlightSearch()
    end
end

function SelectionBar:more()
    local hl = self.hl
    local index = self.index
    self:dismiss()
    local buttons = hl._highlight_buttons
    local filtered = {}
    for id, button in pairs(buttons) do
        if not ON_BAR[id] then
            filtered[id] = button
        end
    end
    if index then
        hl.selected_text = util.tableDeepCopy(hl.ui.annotation.annotations[index])
        filtered[DETAILS_BUTTON] = function(this, button_index)
            return {
                text = _("Details"),
                callback = function()
                    this:onClose()
                    this.ui.bookmark:showBookmarkDetails(button_index)
                end,
            }
        end
    end
    hl._highlight_buttons = filtered
    local ok, err = pcall(Selection.originalMenu, hl, index)
    hl._highlight_buttons = buttons
    if not ok then error(err) end
end

function SelectionBar:onShow()
    self:refresh()
end

function SelectionBar:onCloseWidget()
    UIManager:setDirty(nil, "ui", self:region())
end

local function portableAnnotations(annotations)
    local portable = {}
    for i, item in ipairs(annotations) do
        local drawer = item.drawer == TEXT_COLOR and LIGHTEN or nil
        local color = item.drawer and PORTABLE_COLORS[item.color]
        if drawer or color then
            local copy = {}
            for key, value in pairs(item) do
                copy[key] = value
            end
            if drawer then
                copy.drawer = drawer
                copy.kcui_drawer = item.drawer
            end
            if color then
                copy.color = color
                copy.kcui_color = item.color
            end
            item = copy
        end
        portable[i] = item
    end
    return portable
end

local function restoreAnnotations(annotations)
    for _i, item in ipairs(annotations or {}) do
        if item.kcui_drawer and item.drawer == LIGHTEN then
            item.drawer = item.kcui_drawer
        end
        if item.kcui_color and item.color == PORTABLE_COLORS[item.kcui_color] then
            item.color = item.kcui_color
        end
        item.kcui_drawer, item.kcui_color = nil, nil
    end
end

local function withPortable(annotation, fn, ...)
    local live = annotation.annotations
    annotation.annotations = portableAnnotations(live)
    local ok, result = pcall(fn, annotation, ...)
    annotation.annotations = live
    if not ok then
        error(result, 0)
    end
    return result
end

local function restoreStyle(hl, item)
    item.drawer = LIGHTEN
    item.color = Screen:isColorEnabled() and hl.view.highlight.saved_color or MONO_COLOR
end

local function finishSelectMode(hl)
    local index = hl.highlight_idx
    local item = hl.ui.annotation.annotations[index]
    hl.select_mode = false
    hl._kcui_select_bar = nil
    if item and item.is_tmp then
        item.is_tmp = nil
        restoreStyle(hl, item)
        hl.ui:handleEvent(Event:new("AnnotationsModified", { item }))
    end
    UIManager:setDirty(hl.dialog, "ui")
    return index, item
end

local SELECT_ACTIONS = {
    highlight = function(hl)
        finishSelectMode(hl)
    end,
    note = function(hl)
        local index, item = finishSelectMode(hl)
        if item and item.note then
            Selection.showNote(hl, index)
        else
            hl:editNote(index)
        end
    end,
    search = function(hl)
        local item = hl.ui.annotation.annotations[hl.highlight_idx]
        local text = item and item.text
        hl.select_mode = false
        hl._kcui_select_bar = nil
        if item and item.is_tmp then
            hl:deleteHighlight(hl.highlight_idx)
        else
            UIManager:setDirty(hl.dialog, "ui")
        end
        if text then
            hl.ui.search:searchText(text)
        end
    end,
    more = function(hl)
        hl:onTapSelectModeIcon()
    end,
}

local function upvalue(fn, wanted)
    local index = 1
    while true do
        local name, value = debug.getupvalue(fn, index)
        if not name then return end
        if name == wanted then return value end
        index = index + 1
    end
end

local function installedDictionaries()
    local counter = ReaderDictionary.getNumberOfDictionaries
    return type(counter) == "function" and upvalue(counter, "available_ifos") or {}
end

local function hasUsable(dict, dict_names)
    local disabled = dict.doc_disabled_dicts or {}
    for _i, name in ipairs(dict_names) do
        if not disabled[name] then
            return true
        end
    end
    return false
end

local function usesExternalLookup()
    return Device:canExternalDictLookup() and G_reader_settings:isTrue("external_dict_lookup")
end

local function enable(dict, ifo)
    dict.dicts_disabled[ifo.file] = nil
    G_reader_settings:saveSetting("dicts_disabled", dict.dicts_disabled)
    if dict.doc_disabled_dicts then
        dict.doc_disabled_dicts[ifo.name] = nil
    end
    dict:updateSdcvDictNamesOptions()
end

local function choose(dict, installed, on_chosen, on_cancel)
    local dialog
    local buttons = {}
    for _i, ifo in ipairs(installed) do
        table.insert(buttons, { {
            text = ifo.name,
            callback = function()
                UIManager:close(dialog)
                enable(dict, ifo)
                on_chosen()
            end,
        } })
    end
    dialog = ButtonDialog:new{
        title = _("Select a dictionary"),
        buttons = buttons,
        modal = true,
        tap_close_callback = on_cancel,
    }
    UIManager:show(dialog)
end

local function installDictionaryChooser()
    if ReaderDictionary._kcui_choose or type(ReaderDictionary.stardictLookup) ~= "function" then return end
    ReaderDictionary._kcui_choose = true

    local stardictLookup = ReaderDictionary.stardictLookup
    ReaderDictionary.stardictLookup = function(self, word, dict_names, fuzzy_search, boxes, link, dict_close_callback)
        local installed = installedDictionaries()
        if not dict_names or #installed == 0 or usesExternalLookup() or hasUsable(self, dict_names) then
            return stardictLookup(self, word, dict_names, fuzzy_search, boxes, link, dict_close_callback)
        end
        choose(self, installed, function()
            Trapper:wrap(function()
                stardictLookup(self, word, self.enabled_dict_names, fuzzy_search, boxes, link, dict_close_callback)
            end)
        end, function()
            if self.highlight then
                self.highlight:clear()
            end
            if dict_close_callback then
                dict_close_callback()
            end
        end)
    end
end

function Selection.install()
    installDictionaryChooser()
    if ReaderHighlight._kcui_selection then return end
    ReaderHighlight._kcui_selection = true

    Blitbuffer.HIGHLIGHT_COLORS[BLACK_COLOR] = Blitbuffer.HIGHLIGHT_COLORS[BLACK_COLOR] or "#000000"
    local kindle_colors = {}
    for i, color in ipairs(KINDLE_COLORS) do
        if color[3] then
            Blitbuffer.HIGHLIGHT_COLORS[color[2]] = color[3]
        end
        kindle_colors[i] = { color[1], color[2] }
    end
    ReaderHighlight.highlight_colors = kindle_colors

    local styleString = ReaderHighlight.getHighlightStyleString
    ReaderHighlight.getHighlightStyleString = function(hl, style)
        return styleString(hl, style) or style == TEXT_COLOR and _("Text color") or style
    end

    local drawHighlightRect = ReaderView.drawHighlightRect
    ReaderView.drawHighlightRect = function(view, bb, x, y, rect, drawer, color, draw_note_mark)
        if drawer == UNDERLINE then
            rect = Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h - U(UNDERLINE_RAISE) }
        end
        if LINE_STYLES[drawer] and color then
            return drawHighlightRect(view, bb, x, y, rect, drawer, textColor(color), draw_note_mark)
        end
        if drawer ~= TEXT_COLOR then
            return drawHighlightRect(view, bb, x, y, rect, drawer, color, draw_note_mark)
        end
        if Screen:isColorEnabled() and color then
            paintTextColor(bb, rect, color)
            return drawHighlightRect(view, bb, x, y, rect, nil, color, draw_note_mark)
        end
        return drawHighlightRect(view, bb, x, y, rect, LIGHTEN, nil, draw_note_mark)
    end

    local onReadSettings = ReaderAnnotation.onReadSettings
    ReaderAnnotation.onReadSettings = function(annotation, ...)
        onReadSettings(annotation, ...)
        restoreAnnotations(annotation.annotations)
    end

    local onSaveSettings = ReaderAnnotation.onSaveSettings
    ReaderAnnotation.onSaveSettings = function(annotation, ...)
        annotation:updatePageNumbers()
        return withPortable(annotation, onSaveSettings, ...)
    end

    local onExportAnnotations = ReaderAnnotation.onExportAnnotations
    ReaderAnnotation.onExportAnnotations = function(annotation, ...)
        return withPortable(annotation, onExportAnnotations, ...)
    end

    local onAnnotationsModified = ReaderHighlight.onAnnotationsModified
    ReaderHighlight.onAnnotationsModified = function(hl, ...)
        UIManager:setDirty(hl.dialog, "ui")
        if onAnnotationsModified then
            return onAnnotationsModified(hl, ...)
        end
    end

    local startSelection = ReaderHighlight.startSelection
    ReaderHighlight.startSelection = function(hl, index)
        startSelection(hl, index)
        local item = not index and hl.ui.annotation.annotations[hl.highlight_idx]
        if item and item.is_tmp then
            item.drawer = "lighten"
            item.color = "gray"
        end
    end

    local paintTo = ReaderView.paintTo
    ReaderView.paintTo = function(view, bb, x, y)
        paintTo(view, bb, x, y)
        paintNoteMarks(view, bb)
        local hl = view.ui.highlight
        if not (hl and hl.select_mode and hl.highlight_idx) then
            if hl then
                hl._kcui_select_bar = nil
            end
            return
        end
        local item = view.ui.annotation.annotations[hl.highlight_idx]
        if not item then return end
        local bar = SelectionBar:new{
            hl = hl,
            pinned = true,
            editing = true,
            fragment = true,
            index = not item.is_tmp and hl.highlight_idx or nil,
        }
        if #bar.boxes == 0 then
            hl._kcui_select_bar = nil
            return
        end
        hl._kcui_select_bar = bar
        bar:paintTo(bb)
    end

    local onTap = ReaderHighlight.onTap
    ReaderHighlight.onTap = function(hl, arg, ges)
        local bar = hl.select_mode and hl._kcui_select_bar
        if bar and ges and bar.frame:contains(ges.pos) then
            for _i, cell in ipairs(bar.cells) do
                if ges.pos.x >= cell.x and ges.pos.x < cell.x + cell.w then
                    SELECT_ACTIONS[cell.action](hl)
                    break
                end
            end
            return true
        end
        return onTap(hl, arg, ges)
    end

    local extendSelection = ReaderHighlight.extendSelection
    ReaderHighlight.extendSelection = function(hl, ...)
        local item = hl.ui.annotation.annotations[hl.highlight_idx]
        if item and item.is_tmp then
            restoreStyle(hl, item)
        end
        hl._kcui_select_bar = nil
        local result = extendSelection(hl, ...)
        local extended = hl.selected_text and hl.selected_text.is_extended
        hl._kcui_extended = not extended
        hl._kcui_extending = extended or nil
        return result
    end

    Selection.showNote = ReaderHighlight.showHighlightNoteOrDialog
    local function showBar(hl, index, pinned)
        if not hl.hold_pos then
            hl.selected_text = nil
        end
        local bar = SelectionBar:new{ hl = hl, index = index, existing = true, pinned = pinned, editing = pinned }
        bar:openPalette()
        bar:layout()
        hl.highlight_dialog = bar
        UIManager:show(bar, "[ui]")
    end
    ReaderHighlight.showHighlightNoteOrDialog = function(hl, index) showBar(hl, index) end
    ReaderHighlight.showHighlightDialog = function(hl, index) showBar(hl, index) end

    local saveHighlight = ReaderHighlight.saveHighlight
    ReaderHighlight.saveHighlight = function(hl, ...)
        local index = saveHighlight(hl, ...)
        if hl._kcui_extending then
            hl._kcui_extending = nil
            if index then
                UIManager:tickAfterNext(function() showBar(hl, index, true) end)
            end
        end
        return index
    end

    Selection.originalMenu = ReaderHighlight.onShowHighlightMenu
    ReaderHighlight.onShowHighlightMenu = function(hl, index)
        if index or not hl.selected_text then
            return Selection.originalMenu(hl, index)
        end
        if not hl.hold_pos then
            hl.selected_text = nil
            return
        end
        local pinned = hl._kcui_extended == true
        hl._kcui_extended = nil
        hl.highlight_dialog = SelectionBar:new{ hl = hl, pinned = pinned, editing = pinned }
        UIManager:show(hl.highlight_dialog, "[ui]")
    end

    local titleBarInit = TitleBar.init
    TitleBar.init = function(bar)
        local item = bar.show_parent and bar.show_parent._kcui_note_item
        if not (item and bar.info_text) then
            return titleBarInit(bar)
        end
        bar.info_text = nil
        titleBarInit(bar)
        local h_padding = bar.info_text_h_padding or bar.title_h_padding
        local v_padding = bar.with_bottom_line and Size.padding.default or 0
        local header, date = GoTo.headerWidgets(item, bar.width - 2 * h_padding)
        local lines = VerticalGroup:new{ align = "left", header }
        if date then
            table.insert(lines, VerticalSpan:new{ width = U(2) })
            table.insert(lines, date)
        end
        local block = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = bar.titlebar_height + v_padding },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = h_padding },
                lines,
            },
        }
        table.insert(bar, block)
        bar.titlebar_height = block:getSize().h + bar.bottom_v_padding
        bar.dimen.h = bar.titlebar_height
        bar._size = { w = bar.dimen.w, h = bar.titlebar_height }
    end

    local dialogHeader = ReaderBookmark._getDialogHeader
    ReaderBookmark._getDialogHeader = function(bookmark, item, full)
        local formatted = setmetatable({ datetime = Common.Dates.stamp(item.datetime) }, { __index = item })
        return dialogHeader(bookmark, formatted, full)
    end

    local setBookmarkNote = ReaderBookmark.setBookmarkNote
    ReaderBookmark.setBookmarkNote = function(bookmark, item_or_index, ...)
        local index = bookmark.bookmark_menu and bookmark:getBookmarkItemIndex(item_or_index) or item_or_index
        local item = bookmark.ui.annotation.annotations[index]
        if not item then return end
        if not item.drawer then
            return setBookmarkNote(bookmark, item_or_index, ...)
        end
        local new = InputDialog.new
        InputDialog.new = function(class, o, ...)
            if class == InputDialog and o then
                o._kcui_note_item = item
            end
            return new(class, o, ...)
        end
        local show = UIManager.show
        UIManager.show = function(manager, widget, ...)
            if getmetatable(widget) == InputDialog and not widget._kcui_palette then
                widget._kcui_palette = true
                local palette
                palette = Palette:new{
                    ui = bookmark.ui,
                    item_fn = function() return item end,
                    width = widget:getAddedWidgetAvailableWidth(),
                    standalone = true,
                    preview = true,
                    show_parent = widget,
                    on_change = function() UIManager:setDirty(widget, "ui", palette.dimen) end,
                }
                widget:addWidget(palette, false, true)
            end
            return show(manager, widget, ...)
        end
        local ok, err = pcall(setBookmarkNote, bookmark, item_or_index, ...)
        UIManager.show = show
        InputDialog.new = new
        if not ok then error(err) end
    end
end

return Selection
