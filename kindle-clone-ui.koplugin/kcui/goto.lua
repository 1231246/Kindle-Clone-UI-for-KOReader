local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReaderDogear = require("apps/reader/modules/readerdogear")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Toolbar = require("kcui/toolbar")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Common = require("kcui/common")
local T = require("ffi/util").template
local Screen = Device.screen
local Paint = Common.Paint
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/goto%.lua$") .. "/icons"
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK_COLOR = "black"
local NOTE_LINES = 3
local BLOCK_WIDGETS = { "header", "date", "quote", "note_label", "note_first", "note_rest" }
local MAX_BOOKMARK_ROWS = 5
local RIBBON_NOTCH = 0.27
local PASSED_ON = {
    onGesture = true,
    onKeyPress = true,
    onKeyRepeat = true,
    onKeyRelease = true,
    onSetRotationMode = true,
}

local GoTo = InputContainer:extend{
    ui = nil,
    tab = "contents",
    modal = true,
}

local function icon(name, size)
    return ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/" .. name .. ".svg",
        width = size,
        height = size,
        alpha = true,
    }
end

local function capTop(widget, face, cap_center)
    local cap = math.floor(face.size * 0.667 + 0.5)
    return cap_center - math.floor(cap / 2) - (widget:getBaseline() - cap)
end

function GoTo:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = U(14)
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.frame = Geom:new{ x = margin, y = margin, w = sw - 2 * margin, h = sh - 2 * margin }
    self.border = U.ceil(1.5)
    self.line = U.ceil(1)
    self.pad = U(14)
    self.title_h = U(44)
    self.tab_h = U(36)
    self.row_h = U(44)
    self.scroll_w = U(14)
    self.indent = U(16)
    self.triangle = U(10)
    self.triangle_gap = U(8)
    self.row_face = U.face("cfont", 15)
    self.note_face = U.face("cfont", 14)
    self.title = TextWidget:new{ text = _("Go To"), face = U.face("cfont", 17), bold = true }
    self.title_face = self.title.face
    self.close_size = U(28.4)
    self.close_icon = icon("close", self.close_size)
    self.tab_face = U.face("cfont", 15)
    self.tabs = {
        { key = "contents", label = TextWidget:new{ text = _("Contents"), face = self.tab_face, bold = true } },
        { key = "highlights", label = TextWidget:new{ text = _("Highlights"), face = self.tab_face, bold = true } },
    }
    self.inner = Geom:new{
        x = self.frame.x + self.border,
        y = self.frame.y + self.border,
        w = self.frame.w - 2 * self.border,
        h = self.frame.h - 2 * self.border,
    }
    self.tabs_top = self.inner.y + self.title_h + self.line
    self.list_top = self.tabs_top + self.tab_h
    self.list_bottom = self.inner.y + self.inner.h
    self.fixed = {
        { text = _("Beginning"), event = "GoToBeginning" },
        { text = _("Page or Location"), event = "ShowGotoDialog", chevron = true, thick = true },
        { text = _("Cover"), kind = "cover" },
    }
    self.contents_top = self.list_top + #self.fixed * self.row_h + 2 * self.line + self.border
    self.pages = { highlights = 1 }
    self:buildContents()
    self.ges_events = {
        TapGoTo = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeGoTo = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
end

function GoTo:buildContents()
    local ui = self.ui
    ui.toc:fillToc()
    local toc = ui.toc.toc or {}
    self.toc = toc
    self.current = ui.toc:getTocIndexByPage(ui:getCurrentPage())
    self.min_depth = math.huge
    for _i, entry in ipairs(toc) do
        self.min_depth = math.min(self.min_depth, entry.depth or 1)
    end
    self.expanded = {}
    if self.current then
        local depth = toc[self.current].depth
        for index = self.current - 1, 1, -1 do
            if toc[index].depth < depth then
                self.expanded[index] = true
                depth = toc[index].depth
            end
        end
    end
    self.contents_per_page = math.max(1, math.floor((self.list_bottom - self.contents_top) / (self.row_h + self.line)))
    self:layoutContents()
    local current_row = 1
    for i, row in ipairs(self.contents) do
        if row.index == self.current then
            current_row = i
        end
    end
    self.pages.contents = math.floor((current_row - 1) / self.contents_per_page) + 1
end

function GoTo:hasChildren(index)
    local next_entry = self.toc[index + 1]
    return next_entry ~= nil and next_entry.depth > self.toc[index].depth
end

function GoTo:layoutContents()
    local rows = {}
    local hidden_below
    for index, entry in ipairs(self.toc) do
        if not (hidden_below and entry.depth > hidden_below) then
            hidden_below = nil
            local expandable = self:hasChildren(index)
            table.insert(rows, {
                kind = "entry",
                index = index,
                entry = entry,
                level = entry.depth - self.min_depth,
                expandable = expandable,
            })
            if expandable and not self.expanded[index] then
                hidden_below = entry.depth
            end
        end
    end
    table.insert(rows, { kind = "end", text = _("End") })
    self.contents = rows
    self.contents_pages = math.max(1, math.ceil(#rows / self.contents_per_page))
    if self.pages.contents then
        self.pages.contents = math.min(self.pages.contents, self.contents_pages)
    end
end

local function textWidth(text, face, bold)
    local probe = TextWidget:new{ text = text, face = face, bold = bold }
    local width = probe:getSize().w
    probe:free()
    return width
end

local function lineHeight(face)
    local probe = TextBoxWidget:new{ text = "A", face = face, width = 100 }
    local height = probe:getLineHeight()
    probe:free()
    return height
end

local function splitFirstLine(text, face, width)
    local first_paragraph_end = text:find("\n") or #text + 1
    local fitted_end
    for word_end in text:sub(1, first_paragraph_end - 1):gmatch("%S+()") do
        if textWidth(text:sub(1, word_end - 1), face) > width then
            break
        end
        fitted_end = word_end
    end
    if not fitted_end then
        return "", text
    end
    return text:sub(1, fitted_end - 1), (text:sub(fitted_end):gsub("^%s+", ""))
end

function GoTo:quoteColor(item)
    if item.drawer == "invert" then
        return BLACK
    end
    local highlight = self.ui.highlight
    local color = highlight and highlight:getHighlightColor(item.color or "gray", false, true)
    return color or Blitbuffer.COLOR_GRAY
end

function GoTo.headerWidgets(item, width)
    local chapter = item.chapter and item.chapter ~= "" and item.chapter or nil
    local pageno = item.pageref or item.pageno or item.page
    local header = TextWidget:new{
        text = chapter and T(_("Page %1 • %2"), pageno, chapter) or T(_("Page %1"), pageno),
        face = U.face("cfont", 14),
        bold = true,
        max_width = width,
    }
    local date
    if item.datetime then
        date = TextWidget:new{
            text = Common.Dates.stamp(item.datetime),
            face = U.face("cfont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = width,
        }
    end
    return header, date
end

function GoTo:noteBlock(item, width, line_h)
    local face = self.note_face
    local block = {
        item = item,
        pad_v = U(10),
        gap = U(6),
        bar_w = U(4),
        bar_gap = U(10),
        color = self:quoteColor(item),
    }
    block.header, block.date = GoTo.headerWidgets(item, width)
    block.quote = TextBoxWidget:new{
        text = item.text or "",
        face = face,
        width = width - block.bar_w - block.bar_gap,
        height = NOTE_LINES * line_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
    local height = block.pad_v + block.header:getSize().h + block.gap + block.quote:getSize().h
        + (block.date and block.date:getSize().h + U(2) or 0)
    local note = item.note and item.note:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if note ~= "" then
        block.note_label = TextWidget:new{ text = _("Note:") .. " ", face = face, bold = true }
        local label_w = block.note_label:getSize().w
        local first, rest = splitFirstLine(note, face, width - label_w)
        block.note_first = TextWidget:new{ text = first, face = face, max_width = width - label_w }
        if rest ~= "" then
            block.note_rest = TextBoxWidget:new{
                text = rest,
                face = face,
                width = width,
                height = (NOTE_LINES - 1) * line_h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
        end
        block.note_line_h = line_h
        height = height + block.gap + line_h + (block.note_rest and block.note_rest:getSize().h or 0)
    end
    block.height = height + block.pad_v + self.line
    return block
end

local LINE_STYLES = { underscore = true, strikeout = true }

function GoTo:paintQuoteStyle(bb, block, x, y)
    local item = block.item
    if not LINE_STYLES[item.drawer] then return end
    local quote = block.quote
    local color = self.ui.highlight:getHighlightColor(item.color)
    local line_h = quote:getLineHeight()
    for i = 1, quote:getVisLineCount() do
        local line = quote.vertical_string_list[i]
        if line and line.width and line.width > 0 then
            local rect = Geom:new{ x = x, y = y + (i - 1) * line_h, w = line.width, h = line_h }
            self.ui.view:drawHighlightRect(bb, 0, 0, rect, item.drawer, color)
        end
    end
end

function GoTo:paintBlock(bb, block, x, top)
    local y = top + block.pad_v
    block.header:paintTo(bb, x, y)
    y = y + block.header:getSize().h
    if block.date then
        y = y + U(2)
        block.date:paintTo(bb, x, y)
        y = y + block.date:getSize().h
    end
    y = y + block.gap
    local quote_h = block.quote:getSize().h
    if Blitbuffer.isColor8(block.color) then
        bb:paintRect(x, y, block.bar_w, quote_h, block.color)
    else
        bb:paintRectRGB32(x, y, block.bar_w, quote_h, block.color)
    end
    block.quote:paintTo(bb, x + block.bar_w + block.bar_gap, y)
    self:paintQuoteStyle(bb, block, x + block.bar_w + block.bar_gap, y)
    if block.note_label then
        y = y + quote_h + block.gap
        block.note_label:paintTo(bb, x, y)
        block.note_first:paintTo(bb, x + block.note_label:getSize().w, y)
        if block.note_rest then
            block.note_rest:paintTo(bb, x, y + block.note_line_h)
        end
    end
end

function GoTo:buildHighlights()
    local width = self.inner.w - 2 * self.pad - self.scroll_w
    local line_h = lineHeight(self.note_face)
    local annotation = self.ui.annotation
    local blocks = {}
    if annotation then
        annotation:updatePageNumbers()
    end
    for _i, item in ipairs(annotation and annotation.annotations or {}) do
        if item.drawer then
            table.insert(blocks, self:noteBlock(item, width, line_h))
        end
    end
    local area = self.list_bottom - self.list_top
    local pages, page, used = {}, {}, 0
    for _i, block in ipairs(blocks) do
        if #page > 0 and used + block.height > area then
            table.insert(pages, page)
            page, used = {}, 0
        end
        table.insert(page, block)
        used = used + block.height
    end
    if #page > 0 then
        table.insert(pages, page)
    end
    self.highlight_pages = pages
    self.empty_highlights = TextWidget:new{ text = _("No highlights yet"), face = self.row_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
end

function GoTo:highlightPages()
    if not self.highlight_pages then
        self:buildHighlights()
    end
    return self.highlight_pages
end

function GoTo:pageCount()
    if self.tab == "contents" then
        return self.contents_pages
    end
    return math.max(1, #self:highlightPages())
end

function GoTo:pageLabel(entry)
    if self.ui.rolling and entry.xpointer then
        return self.ui.bookmark:getBookmarkPageString(entry.xpointer)
    end
    return tostring(entry.page)
end

function GoTo:paintSeparator(bb, y, thick)
    if thick then
        bb:paintRect(self.inner.x, y, self.inner.w, self.border, BLACK)
        return
    end
    local inset = math.floor(self.pad / 2)
    bb:paintRect(self.inner.x + inset, y, self.inner.w - 2 * inset, self.line, BLACK)
end

function GoTo:paintLabel(bb, text, x, top, bold, max_width)
    local label = TextWidget:new{ text = text, face = self.row_face, bold = bold, max_width = max_width }
    label:paintTo(bb, x, top + capTop(label, self.row_face, math.floor(self.row_h / 2)))
    return label
end

function GoTo:paintTriangle(bb, name, x, top)
    local triangle = icon(name, self.triangle)
    triangle:paintTo(bb, x, top + math.floor((self.row_h - self.triangle) / 2))
end

function GoTo:paintScrollbar(bb, top)
    local count = self:pageCount()
    if count <= 1 then return end
    local x = self.inner.x + self.inner.w - math.floor(self.scroll_w / 2) - U(2)
    local track_top, track_h = top + U(6), self.list_bottom - top - U(12)
    bb:paintRect(x + U(1), track_top, self.line, track_h, Toolbar.BORDER)
    local thumb_h = math.max(U(12), math.floor(track_h / count))
    local thumb_y = track_top + math.floor((track_h - thumb_h) * (self.pages[self.tab] - 1) / (count - 1))
    bb:paintRect(x, thumb_y, U(3), thumb_h, BLACK)
end

function GoTo:paintContents(bb)
    local left = self.inner.x + self.pad
    local top = self.list_top
    local current_page = self.ui:getCurrentPage()
    for _i, row in ipairs(self.fixed) do
        local bold = row.kind == "cover" and not self.current and current_page <= 1
        self:paintLabel(bb, row.text, left, top, bold)
        if row.chevron then
            self:paintTriangle(bb, "panel/triangle-right", self.inner.x + self.inner.w - self.pad - self.triangle, top)
        end
        self:paintSeparator(bb, top + self.row_h, row.thick)
        row.rect = Geom:new{ x = self.inner.x, y = top, w = self.inner.w, h = self.row_h }
        top = top + self.row_h + (row.thick and self.border or self.line)
    end
    self.rows = {}
    local right = self.inner.x + self.inner.w - self.scroll_w - self.pad
    local first = (self.pages.contents - 1) * self.contents_per_page + 1
    for i = first, math.min(#self.contents, first + self.contents_per_page - 1) do
        local row = self.contents[i]
        local text_x = left
        if row.kind == "entry" then
            local entry = row.entry
            local triangle_x = left + row.level * self.indent
            text_x = triangle_x + self.triangle + self.triangle_gap
            if row.expandable then
                local open = self.expanded[row.index]
                self:paintTriangle(bb, open and "panel/triangle-down" or "panel/triangle-right", triangle_x, top)
            end
            local bold = row.index == self.current
            local page = TextWidget:new{ text = self:pageLabel(entry), face = self.row_face, bold = bold }
            page:paintTo(bb, right - page:getSize().w, top + capTop(page, self.row_face, math.floor(self.row_h / 2)))
            self:paintLabel(bb, self.ui.toc:cleanUpTocTitle(entry.title), text_x, top, bold, right - page:getSize().w - U(16) - text_x)
            row.toggle_right = text_x
        else
            self:paintLabel(bb, row.text, text_x, top)
        end
        if i < #self.contents then
            self:paintSeparator(bb, top + self.row_h)
        end
        row.rect = Geom:new{ x = self.inner.x, y = top, w = self.inner.w, h = self.row_h }
        table.insert(self.rows, row)
        top = top + self.row_h + self.line
    end
    self:paintScrollbar(bb, self.contents_top)
end

function GoTo:paintHighlights(bb)
    self.rows = {}
    local page = self:highlightPages()[self.pages.highlights]
    if not page then
        local size = self.empty_highlights:getSize()
        self.empty_highlights:paintTo(bb, self.inner.x + math.floor((self.inner.w - size.w) / 2), self.list_top + U(40))
        return
    end
    local top = self.list_top
    local x = self.inner.x + self.pad
    for _i, block in ipairs(page) do
        self:paintBlock(bb, block, x, top)
        bb:paintRect(self.inner.x, top + block.height - self.line, self.inner.w - self.scroll_w, self.line, BLACK)
        table.insert(self.rows, { kind = "highlight", rect = Geom:new{ x = self.inner.x, y = top, w = self.inner.w, h = block.height }, item = block.item })
        top = top + block.height
    end
    self:paintScrollbar(bb, self.list_top)
end

function GoTo:paintTo(bb, x, y)
    local f = self.frame
    bb:paintRect(f.x, f.y, f.w, f.h, WHITE)
    bb:paintBorder(f.x, f.y, f.w, f.h, self.border, BLACK, U(4))
    local inner = self.inner
    self.title:paintTo(bb, inner.x + self.pad, inner.y + capTop(self.title, self.title_face, math.floor(self.title_h / 2)))
    local inset = math.floor(self.close_size * 0.205)
    self.close_icon:paintTo(bb, inner.x + inner.w - self.pad - self.close_size + inset, inner.y + math.floor((self.title_h - self.close_size) / 2))
    bb:paintRect(inner.x, inner.y + self.title_h, inner.w, self.line, BLACK)
    local half = math.floor(inner.w / 2)
    for i, tab in ipairs(self.tabs) do
        local tx = inner.x + (i - 1) * half
        local tw = i == 1 and half or inner.w - half
        local size = tab.label:getSize()
        tab.label:paintTo(bb, tx + math.floor((tw - size.w) / 2), self.tabs_top + capTop(tab.label, self.tab_face, math.floor(self.tab_h / 2)))
        if tab.key ~= self.tab then
            bb:paintRect(tx, self.list_top - self.line, tw, self.line, BLACK)
        end
    end
    bb:paintRect(inner.x + half, self.tabs_top, self.line, self.tab_h, BLACK)
    if self.tab == "contents" then
        self:paintContents(bb)
    else
        self:paintHighlights(bb)
    end
end

function GoTo:refresh()
    UIManager:setDirty(self, function() return "ui", self.frame end)
end

function GoTo:jump(fn)
    UIManager:close(self)
    self.ui.link:addCurrentLocationToStack()
    fn()
end

function GoTo:activate(row, pos)
    local ui = self.ui
    if row.kind == "highlight" then
        local item = row.item
        self:jump(function() ui.bookmark:gotoBookmark(item.page, item.pos0) end)
    elseif row.kind == "cover" then
        self:jump(function() ui:handleEvent(Event:new("GotoPage", 1)) end)
    elseif row.kind == "end" then
        UIManager:close(self)
        ui:handleEvent(Event:new("GoToEnd"))
    elseif row.expandable and pos.x < row.toggle_right then
        self.expanded[row.index] = not self.expanded[row.index] or nil
        self:layoutContents()
        self:refresh()
    else
        local entry = row.entry
        self:jump(function()
            if ui.rolling and entry.xpointer then
                ui:handleEvent(Event:new("GotoXPointer", entry.xpointer, entry.xpointer))
            else
                ui:handleEvent(Event:new("GotoPage", entry.page))
            end
        end)
    end
end

function GoTo:onTapGoTo(_ev, ges)
    local pos = ges.pos
    local inner = self.inner
    if not self.frame:contains(pos) then
        UIManager:close(self)
        return true
    end
    if pos.y < inner.y + self.title_h then
        if pos.x > inner.x + inner.w - self.pad - self.close_size - U(12) then
            UIManager:close(self)
        end
        return true
    end
    if pos.y < self.list_top then
        local key = pos.x < inner.x + math.floor(inner.w / 2) and "contents" or "highlights"
        if key ~= self.tab then
            self.tab = key
            self:refresh()
        end
        return true
    end
    if self.tab == "contents" and pos.y < self.contents_top then
        for _i, row in ipairs(self.fixed) do
            if row.rect and row.rect:contains(pos) then
                if row.event then
                    UIManager:close(self)
                    self.ui:handleEvent(Event:new(row.event))
                else
                    self:activate(row, pos)
                end
                break
            end
        end
        return true
    end
    for _i, row in ipairs(self.rows or {}) do
        if row.rect:contains(pos) then
            self:activate(row, pos)
            break
        end
    end
    return true
end

function GoTo:turn(step)
    local page = math.max(1, math.min(self:pageCount(), self.pages[self.tab] + step))
    if page ~= self.pages[self.tab] then
        self.pages[self.tab] = page
        self:refresh()
    end
    return true
end

function GoTo:onSwipeGoTo(_ev, ges)
    if ges.direction == "north" or ges.direction == "west" then
        return self:turn(1)
    elseif ges.direction == "south" or ges.direction == "east" then
        return self:turn(-1)
    end
    return true
end

function GoTo:onNextPage()
    return self:turn(1)
end

function GoTo:onPrevPage()
    return self:turn(-1)
end

function GoTo:onClose()
    UIManager:close(self)
    return true
end

function GoTo:onShow()
    self:refresh()
end

function GoTo:onCloseWidget()
    self.title:free()
    self.close_icon:free()
    for _i, tab in ipairs(self.tabs) do
        tab.label:free()
    end
    for _i, page in ipairs(self.highlight_pages or {}) do
        for _j, block in ipairs(page) do
            for _k, key in ipairs(BLOCK_WIDGETS) do
                if block[key] then
                    block[key]:free()
                end
            end
        end
    end
    if self.empty_highlights then
        self.empty_highlights:free()
    end
    UIManager:setDirty(nil, function() return "ui", self.frame end)
end

function GoTo.show(ui)
    UIManager:show(GoTo:new{ ui = ui })
end

local ReturnBar = InputContainer:extend{
    ui = nil,
    origin = nil,
    page = nil,
}

function ReturnBar:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local h = U(52)
    local pad = U(21.27)
    local face = U.face("cfont", 15)
    self.dimen = Geom:new{ x = 0, y = sh - h, w = sw, h = h }
    self.back = TextWidget:new{ text = T(_("Back to page %1"), self.page), face = face, bold = true }
    self.stay = TextWidget:new{ text = _("Stay here"), face = face, bold = true }
    self.back_x = pad
    self.stay_x = sw - pad - self.stay:getSize().w
    local function area(x, widget)
        return Geom:new{ x = x - pad, y = self.dimen.y, w = widget:getSize().w + 2 * pad, h = h }
    end
    self.ges_events = {
        TapBack = { GestureRange:new{ ges = "tap", range = area(self.back_x, self.back) } },
        TapStay = { GestureRange:new{ ges = "tap", range = area(self.stay_x, self.stay) } },
    }
end

function ReturnBar:paintLink(bb, widget, x)
    local size = widget:getSize()
    local y = self.dimen.y + math.floor((self.dimen.h - size.h) / 2)
    widget:paintTo(bb, x, y)
    bb:paintRect(x, y + widget:getBaseline() + U(3), size.w, U.ceil(1), BLACK)
end

function ReturnBar:paintTo(bb)
    local d = self.dimen
    bb:paintRect(d.x, d.y, d.w, d.h, WHITE)
    bb:paintRect(d.x, d.y, d.w, U.ceil(1), BLACK)
    self:paintLink(bb, self.back, self.back_x)
    self:paintLink(bb, self.stay, self.stay_x)
end

function ReturnBar:handleEvent(event)
    if InputContainer.handleEvent(self, event) then
        return true
    end
    if not PASSED_ON[event.handler] then
        return false
    end
    local gesture = event.handler == "onGesture" and event.args[1]
    if gesture and gesture.ges == "tap" and gesture.pos and self.dimen:contains(gesture.pos) then
        return true
    end
    if not (gesture and gesture.ges == "touch") then
        UIManager:close(self)
    end
    return self.ui:handleEvent(event)
end

function ReturnBar:onTapBack()
    UIManager:close(self)
    self.ui:handleEvent(Event:new("RestoreBookLocation", self.origin))
    return true
end

function ReturnBar:onTapStay()
    UIManager:close(self)
    return true
end

function ReturnBar:onShow()
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

function ReturnBar:onCloseWidget()
    self.back:free()
    self.stay:free()
    UIManager:setDirty(nil, "ui", self.dimen)
end

local Bookmarks = InputContainer:extend{
    ui = nil,
    anchor = nil,
    on_leave = nil,
    compact = false,
    from_marker = false,
    offset = 0,
    picking = nil,
}

local function fill(ui, item)
    local color = item.color
    if not color or color == BLACK_COLOR or not Screen:isColorEnabled() then return end
    return ui.highlight:getHighlightColor(color)
end

local function markerRect()
    local w = U(19)
    return Geom:new{ x = Screen:getWidth() - U(24) - w, y = 0, w = w, h = U(28) }
end

local function paintRibbon(bb, x, y, w, h, notch, color)
    local half = w / 2
    for i = 0, h - 1 do
        local gap = math.max(0, math.floor((i - (h - notch)) * half / notch + 0.5))
        if gap == 0 then
            Paint.fill(bb, x, y + i, w, 1, color)
        else
            local side = math.floor(half) - gap
            if side > 0 then
                Paint.fill(bb, x, y + i, side, 1, color)
                Paint.fill(bb, x + w - side, y + i, side, 1, color)
            end
        end
    end
end

local function paintBookmark(bb, x, y, w, h, color)
    paintRibbon(bb, x, y, w, h, math.floor(h * RIBBON_NOTCH), color or BLACK)
end

local function paintOutline(bb, x, y, w, h)
    local line = U.ceil(1)
    local notch = math.floor(h * RIBBON_NOTCH)
    local slope = notch / (w / 2)
    local drop = math.floor(line * (slope + math.sqrt(1 + slope * slope)) + 0.5)
    paintRibbon(bb, x, y, w, h, notch, BLACK)
    paintRibbon(bb, x + line, y, w - 2 * line, h - drop, slope * (w / 2 - line), WHITE)
end

local function paintPlus(bb, cx, cy, r)
    bb:paintCircle(cx, cy, r, BLACK)
    local arm, thick = math.floor(r * 0.55), U.ceil(2.4)
    bb:paintRect(cx - arm, cy - math.floor(thick / 2), 2 * arm + 1, thick, WHITE)
    bb:paintRect(cx - math.floor(thick / 2), cy - arm, thick, 2 * arm + 1, WHITE)
end

local function paintDots(bb, cx, cy)
    local r = U(1.9)
    for i = -1, 1 do
        bb:paintCircle(cx, cy + i * U(6.5), r, BLACK)
    end
end

local function removeBookmark(ui, item)
    for index, candidate in ipairs(ui.annotation.annotations) do
        if candidate == item then
            ui.bookmark:removeItem(item, index)
            return
        end
    end
end

function Bookmarks:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.color = Screen:isColorEnabled()
    self.border = U.ceil(1.5)
    self.notch = U(Paint.NOTCH)
    self.head_h = U(64)
    self.row_h = U(61.5)
    self.width = U(264)
    self.title_face = U.face("cfont", 17)
    self.detail_face = U.face("cfont", 12)
    self.swatches = {}
    if self.color then
        for _i, color in ipairs(Common.Highlights.colors(self.ui.highlight)) do
            table.insert(self.swatches, { name = color[2], fill = color[3] })
        end
        table.insert(self.swatches, { name = BLACK_COLOR, fill = BLACK })
    end
    if self.compact and not self.color then
        self.undo = TextWidget:new{ text = _("Undo"), face = self.title_face }
        self.width = self.undo:getSize().w + 2 * U(30)
    end
    self:build()
    if self.compact then
        self.picking = self.head
    end
    self.ges_events = {
        TapBookmarks = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeBookmarks = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function Bookmarks:release()
    for _i, widget in ipairs(self.widgets or {}) do
        widget:free()
    end
    self.widgets = {}
end

function Bookmarks:entry(item, page, text_w)
    local bookmark = self.ui.bookmark
    local chapter = self.ui.toc:getTocTitleByPage(page)
    local entry = {
        item = item,
        title = TextWidget:new{
            text = T(_("Page %1"), bookmark:getBookmarkPageString(page)),
            face = self.title_face,
            max_width = text_w,
        },
    }
    table.insert(self.widgets, entry.title)
    if chapter and chapter ~= "" then
        entry.detail = TextWidget:new{ text = chapter, face = self.detail_face, max_width = text_w }
        table.insert(self.widgets, entry.detail)
    end
    return entry
end

function Bookmarks:build()
    self:release()
    local bookmark = self.ui.bookmark
    local here = bookmark:getCurrentPageNumber()
    local index = bookmark:getDogearBookmarkIndex(here)
    local current = index and self.ui.annotation.annotations[index]
    self.head = self:entry(current, here, self.width - (current and U(44) + U(52) or U(23) + U(58)))
    self.rows = {}
    for _i, item in ipairs(self.compact and {} or self.ui.annotation.annotations) do
        if not item.drawer and item ~= current then
            table.insert(self.rows, self:entry(item, item.page, self.width - U(44) - U(52)))
        end
    end
    self.visible = math.min(MAX_BOOKMARK_ROWS, #self.rows)
    self.offset = math.max(0, math.min(self.offset, #self.rows - self.visible))
    local height = self.head_h + self.visible * self.row_h + 2 * self.border
    local x = self.dimen.w - U(10) - self.width
    local y = self.anchor.y + self.anchor.h + (self.from_marker and self.notch + U(3) or -U(4))
    self.box = Geom:new{ x = x, y = y, w = self.width, h = height }
    self.notch_x = math.min(self.anchor.x + math.floor(self.anchor.w / 2), x + self.width - self.notch - U(8))
end

function Bookmarks:region()
    local top = self.from_marker and 0 or self.box.y - self.notch
    return Geom:new{ x = self.box.x, y = top, w = self.box.w, h = self.box.y + self.box.h - top }
end

function Bookmarks:swatchCenters(row_x, row_w)
    local r = U(9.5)
    local first = row_x + U(16) + r
    return first, (row_w - 2 * U(16) - 2 * r) / (#self.swatches - 1), r
end

function Bookmarks:paintSwatches(bb, x, y, h)
    if self.undo then
        local size = self.undo:getSize()
        self.undo:paintTo(bb, x + math.floor((self.box.w - size.w) / 2), y + math.floor((h - size.h) / 2))
        return
    end
    local first, spacing, r = self:swatchCenters(x, self.box.w)
    for i, swatch in ipairs(self.swatches) do
        Paint.disc(bb, math.floor(first + (i - 1) * spacing + 0.5), y + math.floor(h / 2), r, swatch.fill)
    end
end

function Bookmarks:paintText(bb, entry, x, y, h)
    local title_h = entry.title:getSize().h
    local detail_h = entry.detail and entry.detail:getSize().h or 0
    local top = y + math.floor((h - title_h - detail_h) / 2)
    entry.title:paintTo(bb, x, top)
    if entry.detail then
        entry.detail:paintTo(bb, x, top + title_h)
    end
end

function Bookmarks:paintRow(bb, entry, y, h)
    local box = self.box
    paintBookmark(bb, box.x + U(18), y + math.floor((h - U(19)) / 2), U(13), U(19), fill(self.ui, entry.item))
    self:paintText(bb, entry, box.x + U(44), y, h)
    paintDots(bb, box.x + box.w - U(34), y + math.floor(h / 2))
end

function Bookmarks:paintTo(bb)
    local box, border = self.box, self.border
    if self.compact and not self.head.item then
        local marker = markerRect()
        paintOutline(bb, marker.x, marker.y, marker.w, marker.h)
    end
    bb:paintRoundedRect(box.x, box.y, box.w, box.h, WHITE, U(4))
    bb:paintBorder(box.x, box.y, box.w, box.h, border, BLACK, U(4))
    Paint.notch(bb, self.notch_x, box.y + border - 1, false, self.notch, border)
    local y = box.y + border
    if self.picking == self.head then
        self:paintSwatches(bb, box.x, y, self.head_h)
    elseif self.head.item then
        self:paintRow(bb, self.head, y, self.head_h)
    else
        self:paintText(bb, self.head, box.x + U(23), y, self.head_h)
        paintPlus(bb, box.x + box.w - U(34), y + math.floor(self.head_h / 2), U(11))
    end
    y = y + self.head_h
    if self.visible > 0 then
        bb:paintRect(box.x, y - border, box.w, border, BLACK)
    end
    local scrolls = #self.rows > self.visible
    local line_right = box.x + box.w - (scrolls and U(22) or U(16))
    for i = 1, self.visible do
        local entry = self.rows[self.offset + i]
        if self.picking == entry then
            self:paintSwatches(bb, box.x, y, self.row_h)
        else
            self:paintRow(bb, entry, y, self.row_h)
        end
        y = y + self.row_h
        if i < self.visible then
            bb:paintRect(box.x + U(16), y - U.ceil(1), line_right - box.x - U(16), U.ceil(1), BLACK)
        end
    end
    if scrolls then
        local track_x = box.x + box.w - U(13)
        local track_y = box.y + border + self.head_h
        local track_h = self.visible * self.row_h
        bb:paintRect(track_x, track_y, U.ceil(1), track_h, BLACK)
        local thumb_h = math.max(U(12), math.floor(track_h * self.visible / #self.rows))
        local thumb_y = track_y + math.floor((track_h - thumb_h) * self.offset / (#self.rows - self.visible))
        bb:paintRect(track_x - U(1), thumb_y, U(3), thumb_h, BLACK)
    end
end

function Bookmarks:refresh(whole_screen)
    self:build()
    UIManager:setDirty(whole_screen and "all" or self, "ui", not whole_screen and self:region() or nil)
end

function Bookmarks:choose(entry, name)
    local bookmark = self.ui.bookmark
    local item = entry.item
    if not item then
        local here = bookmark:getCurrentPageNumber()
        if not bookmark:isPageBookmarked(here) then
            bookmark:toggleBookmark()
        end
        item = self.ui.annotation.annotations[bookmark:getDogearBookmarkIndex(here)]
        bookmark:setDogearVisibility(here)
    end
    if item then
        item.color = name
    end
    self.picking = nil
    if self.compact then
        UIManager:close(self)
        UIManager:setDirty("all", "ui")
    else
        self:refresh(true)
    end
end

function Bookmarks:pick(entry)
    if self.color then
        self.picking = entry
        UIManager:setDirty(self, "ui", self:region())
    elseif not entry.item then
        self:choose(entry)
    end
end

function Bookmarks:showMenu(entry, center)
    local buttons = {}
    if self.color then
        table.insert(buttons, { { text = _("Change color"), callback = function() self:pick(entry) end } })
    end
    table.insert(buttons, { { text = _("Delete"), callback = function()
        removeBookmark(self.ui, entry.item)
        self:refresh(true)
    end } })
    UIManager:show(Toolbar.Dropdown:new{
        buttons = buttons,
        anchor_right = self.box.x + self.box.w - U(8),
        anchor_top = center + U(14) + self.notch,
        notch_x = self.box.x + self.box.w - U(34),
        close_first = true,
    })
end

function Bookmarks:tapSwatch(x)
    local first, spacing = self:swatchCenters(self.box.x, self.box.w)
    return self.swatches[math.floor((x - first + spacing / 2) / spacing) + 1]
end

function Bookmarks:onTapBookmarks(_ev, ges)
    local pos, box = ges.pos, self.box
    if not box:contains(pos) then
        UIManager:close(self)
        return true
    end
    if self.undo then
        UIManager:close(self)
        if self.head.item then
            removeBookmark(self.ui, self.head.item)
            UIManager:setDirty("all", "ui")
        end
        return true
    end
    local y = box.y + self.border
    local entry, center
    if pos.y < y + self.head_h then
        entry, center = self.head, y + math.floor(self.head_h / 2)
    else
        local index = math.floor((pos.y - y - self.head_h) / self.row_h) + 1
        if index <= self.visible then
            entry, center = self.rows[self.offset + index], y + self.head_h + math.floor((index - 0.5) * self.row_h)
        end
    end
    if self.picking then
        local swatch = self.picking == entry and self:tapSwatch(pos.x)
        if swatch then
            self:choose(entry, swatch.name)
        elseif self.compact then
            UIManager:close(self)
        else
            self.picking = nil
            UIManager:setDirty(self, "ui", self:region())
        end
    elseif entry and not entry.item then
        if pos.x >= box.x + box.w - U(58) then
            self:pick(entry)
        end
    elseif entry and pos.x >= box.x + box.w - U(52) then
        self:showMenu(entry, center)
    elseif entry and entry ~= self.head then
        UIManager:close(self)
        if self.on_leave then
            self.on_leave()
        end
        local bookmark = self.ui.bookmark
        local bar = ReturnBar:new{
            ui = self.ui,
            origin = self.ui.link:getCurrentLocation(),
            page = bookmark:getBookmarkPageString(bookmark:getCurrentPageNumber()),
        }
        self.ui.link:addCurrentLocationToStack()
        bookmark:gotoBookmark(entry.item.page)
        UIManager:show(bar)
    end
    return true
end

function Bookmarks:onSwipeBookmarks(_ev, ges)
    local step = ges.direction == "north" and self.visible or ges.direction == "south" and -self.visible
    if step and #self.rows > self.visible then
        self.offset = self.offset + step
        self.picking = nil
        self:refresh()
    end
    return true
end

function Bookmarks:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

function Bookmarks:onShow()
    UIManager:setDirty(self, "ui", self:region())
    return true
end

function Bookmarks:onCloseWidget()
    self:release()
    if self.undo then
        self.undo:free()
    end
    UIManager:setDirty(nil, "ui", self:region())
end

function Bookmarks.show(ui, anchor, on_leave)
    UIManager:show(Bookmarks:new{ ui = ui, anchor = anchor, on_leave = on_leave })
end

local function onMarker(ges)
    return not (ges and ges.pos) or ges.pos.y <= markerRect().h + U(10)
end

function Bookmarks.hold(ui, ges)
    if not onMarker(ges) and ui.highlight:onHold(nil, ges) then
        return true
    end
    if not Screen:isColorEnabled() then
        if ui.bookmark:isPageBookmarked() then
            return true
        end
        ui.bookmark:toggleBookmark()
        ui.bookmark:setDogearVisibility(ui.bookmark:getCurrentPageNumber())
        UIManager:setDirty(ui.dialog, "ui")
    end
    UIManager:show(Bookmarks:new{ ui = ui, anchor = markerRect(), from_marker = true, compact = true })
    return true
end

function Bookmarks.tap(ui, ges)
    if not onMarker(ges) and ui.highlight:onTap(nil, ges) then
        return true
    end
    if not ui.bookmark:isPageBookmarked() then
        return ui.menu:onTapShowMenu()
    end
    UIManager:show(Bookmarks:new{ ui = ui, anchor = markerRect(), from_marker = true })
    return true
end

function Bookmarks.register(ui)
    local corner = { ratio_x = 7 / 8, ratio_y = 0, ratio_w = 1 / 8, ratio_h = 1 / 8 }
    ui:registerTouchZones({
        {
            id = "kcui_bookmark_tap",
            ges = "tap",
            screen_zone = corner,
            overrides = {
                "tap_top_right_corner", "readerhighlight_tap", "readerfooter_tap", "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap", "readermenu_ext_tap", "readermenu_tap", "tap_forward", "tap_backward",
            },
            handler = function(ges) return Bookmarks.tap(ui, ges) end,
        },
        {
            id = "kcui_bookmark_hold",
            ges = "hold",
            screen_zone = corner,
            overrides = { "hold_top_right_corner", "readerhighlight_hold" },
            handler = function(ges) return Bookmarks.hold(ui, ges) end,
        },
    })
end

function Bookmarks.install()
    if ReaderDogear._kcui_marker then return end
    ReaderDogear._kcui_marker = true
    ReaderDogear.paintTo = function(dogear, bb, x, y)
        local bookmark = dogear.ui.bookmark
        local index = bookmark:getDogearBookmarkIndex(bookmark:getCurrentPageNumber())
        local item = index and dogear.ui.annotation.annotations[index]
        local rect = markerRect()
        paintBookmark(bb, x + rect.x, y + rect.y, rect.w, rect.h, item and fill(dogear.ui, item))
    end
    ReaderDogear.getRefreshRegion = markerRect
end

GoTo.Bookmarks = Bookmarks

return GoTo
