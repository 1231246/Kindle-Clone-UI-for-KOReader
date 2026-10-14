local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local DataStorage = require("datastorage")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local Toolbar = require("kcui/toolbar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local CenterContainer = require("ui/widget/container/centercontainer")
local DocumentRegistry = require("document/documentregistry")
local FileChooser = require("ui/widget/filechooser")
local ProgressWidget = require("ui/widget/progresswidget")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local sort = require("sort")
local time = require("ui/time")
local util = require("util")
local Common = require("kcui/common")
local T = ffiUtil.template
local Screen = Device.screen
local Dates = Common.Dates
local KindleFonts = Common.Fonts
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/library%.lua$") .. "/icons"
local CACHE_DIR = DataStorage:getDataDir() .. "/cache/kcui"
local READING_MARKER = CACHE_DIR .. "/reading"
local INTERRUPTED = "interrupted"
local MAX_INTERRUPTIONS = 2
local MAX_IMAGES = 48
local NOTICE_AFTER = 3
local FLUSH_EVERY = 20
local EBOOK_FORMATS = {
    epub = true, epub3 = true, mobi = true, azw = true, azw3 = true, kfx = true, prc = true, fb2 = true,
}
local IMAGE_FORMATS = {
    bmp = true, gif = true, jpeg = true, jpg = true, jxl = true, png = true, svg = true, tif = true, tiff = true,
    webp = true,
}
local MAX_IMAGE_BYTES = 32 * 1024 * 1024
local THUMB_H = 640
local DETAILS = "details"
local PRELOADED = "preloaded_home"
local VIEW = "kcui_library_view"
local GRID = "grid"
local LIST = "list"
local GRID_COLUMNS = 3
local GRID_ASPECT = 1.5
local PAGER_SCALE = 1.6
local PAGER_FONT = math.floor(13 * PAGER_SCALE + 0.5)
local PAGER_DOTS_FONT = math.floor(9 * PAGER_SCALE + 0.5)

local PAGER_DROP = 6

local function P(units)
    return U.ceil(units * PAGER_SCALE)
end
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.Color8(0x40)
local DELETED_GRAY = Blitbuffer.Color8(0x88)
local CHIP_BORDER = Blitbuffer.Color8(0xCC)

local Books = {}

local Library = {
    GRID = GRID,
    LIST = LIST,
    Books = Books,
    SORTS = {
        { id = "kcui_title", text = _("Title") },
        { id = "kcui_author", text = _("Author (surname)") },
    },
}

local Rows = {
    ROW_HEIGHT = 92,
    HISTORY_ROW_HEIGHT = 114.1,
    UP_ROW_HEIGHT = Toolbar.BACK_ROW_HEIGHT,
}

local db
local images = {}
local image_order = {}
local flush_scheduled = false
local preloading = false
local unsaved = 0
local pending = {}

local function mtime(file)
    return lfs.attributes(file, "modification")
end

local function isDocument(file)
    local ext = file:match("%.([^./]+)$")
    return ext ~= nil and not EBOOK_FORMATS[ext:lower()]
end

local function isImage(file)
    local ext = file:match("%.([^./]+)$")
    return ext ~= nil and IMAGE_FORMATS[ext:lower()] == true
end

Library.isImage = isImage

local function renderImage(file)
    local size = lfs.attributes(file, "size")
    if not size or size > MAX_IMAGE_BYTES then return end
    return RenderImage:renderImageFile(file, false)
end

local function newEntry(file)
    return { mtime = mtime(file), thumb_h = THUMB_H, trimmed = isDocument(file) or nil, image = isImage(file) or nil }
end

local function skipInterrupted()
    local marker = io.open(READING_MARKER, "r")
    if not marker then return end
    local file = marker:read("*a")
    marker:close()
    os.remove(READING_MARKER)
    if not file or file == "" then return end
    local interrupted = db:readSetting(INTERRUPTED, {})
    interrupted[file] = (interrupted[file] or 0) + 1
    if interrupted[file] >= MAX_INTERRUPTIONS then
        local entry = newEntry(file)
        db:saveSetting(file, entry)
        db:readSetting(DETAILS, {})[file] = { mtime = entry.mtime, first_author = false }
        interrupted[file] = nil
        logger.warn("Books: giving up on", file, "after repeated interruptions")
    end
    db:flush()
end

local function open()
    if not db then
        util.makePath(CACHE_DIR)
        db = Common.State.open(CACHE_DIR .. "/books.lua")
        skipInterrupted()
    end
    return db
end

local function startReading(file)
    local marker = io.open(READING_MARKER, "w")
    if marker then
        marker:write(file)
        marker:close()
    end
end

local function doneReading()
    os.remove(READING_MARKER)
end

local function blank(bb, x, y)
    local c = bb:getPixel(x, y):getColor8A()
    return c.alpha < 128 or c.a > 235
end

local function trimMargins(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local function rowBlank(y)
        for x = 0, w - 1 do
            if not blank(bb, x, y) then return false end
        end
        return true
    end
    local function colBlank(x, top, bottom)
        for y = top, bottom do
            if not blank(bb, x, y) then return false end
        end
        return true
    end
    local top, bottom = 0, h - 1
    while top < bottom and rowBlank(top) do top = top + 1 end
    while bottom > top and rowBlank(bottom) do bottom = bottom - 1 end
    local left, right = 0, w - 1
    while left < right and colBlank(left, top, bottom) do left = left + 1 end
    while right > left and colBlank(right, top, bottom) do right = right - 1 end
    if top == 0 and left == 0 and bottom == h - 1 and right == w - 1 then return bb end
    if right - left < 8 or bottom - top < 8 then return bb end
    local trimmed = Blitbuffer.new(right - left + 1, bottom - top + 1, bb:getType())
    trimmed:blitFrom(bb, 0, 0, left, top, right - left + 1, bottom - top + 1)
    bb:free()
    return trimmed
end

function Books.get(file)
    local entry = open():readSetting(file)
    if entry and entry.mtime == mtime(file) and entry.thumb_h == THUMB_H and (entry.trimmed or not isDocument(file))
            and (entry.image or not isImage(file)) then
        return entry
    end
end

local function readProps(ui, file)
    local info = ui and ui.bookinfo
    if not info then return end
    local ok, props = pcall(info.getDocProps, info, file, nil, false)
    if not (ok and props) then return end
    local authors = props.authors and props.authors:gsub("\n", ", ")
    local first_author = props.authors and props.authors:match("[^\n&;]*[^\n&;%s][^\n&;]*")
    return props.display_title or props.title, authors, first_author
end

local function scheduleFlush()
    if flush_scheduled then return end
    flush_scheduled = true
    UIManager:nextTick(function()
        flush_scheduled = false
        unsaved = 0
        open():flush()
    end)
end

local function noteProgress()
    unsaved = unsaved + 1
    if unsaved % FLUSH_EVERY == 0 then
        open():flush()
    end
    scheduleFlush()
end

function Books.details(ui, file)
    local all = open():readSetting(DETAILS, {})
    local stamp = mtime(file)
    local entry = all[file]
    if entry and entry.mtime == stamp and entry.first_author ~= nil then
        if Books.get(file) == nil then
            Books.extract(ui, file, entry)
            noteProgress()
        end
        return entry
    end
    startReading(file)
    local title, authors, first_author
    if not isImage(file) then
        title, authors, first_author = readProps(ui, file)
    end
    entry = {
        mtime = stamp,
        title = title,
        authors = authors,
        first_author = first_author or false,
    }
    doneReading()
    all[file] = entry
    if Books.get(file) == nil then
        Books.extract(ui, file, entry)
    end
    noteProgress()
    return entry
end

local function knownDetails(file)
    local entry = open():readSetting(DETAILS, {})[file]
    if entry and entry.mtime == mtime(file) and entry.first_author ~= nil then
        return entry
    end
end

function Books.ready(file)
    return knownDetails(file) ~= nil and Books.get(file) ~= nil
end

local BOOK_TYPES = {
    epub = true, epub3 = true, pdf = true, mobi = true, azw = true, azw3 = true, kfx = true, fb2 = true, fbz = true,
    djvu = true, djv = true, cbz = true, cbr = true, cbt = true, cb7 = true, docx = true, doc = true, rtf = true,
    chm = true, xps = true, pdb = true, prc = true,
}

local function isBook(path, books_only)
    if books_only then
        local suffix = path:match("%.([^./]+)$")
        return suffix ~= nil and (BOOK_TYPES[suffix:lower()] or IMAGE_FORMATS[suffix:lower()]) == true
    end
    return DocumentRegistry:hasProvider(path)
end

local function isOwnFolder(path, name)
    if name:match("%.sdr$") or name:match("%.koplugin$") then
        return true
    end
    local data_dir = ffiUtil.realpath(DataStorage:getDataDir())
    return data_dir ~= nil and ffiUtil.realpath(path) == data_dir
end

local function collectUnread(folder, recursive, found, visited)
    visited = visited or {}
    local real = ffiUtil.realpath(folder) or folder
    if visited[real] then return end
    visited[real] = true
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then return end
    for name in iter, dir_obj do
        if not util.stringStartsWith(name, ".") then
            local path = folder .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "file" and isBook(path, recursive) and not Books.ready(path) then
                table.insert(found, path)
            elseif mode == "directory" and recursive and not isOwnFolder(path, name) then
                collectUnread(path, true, found, visited)
            end
        end
    end
end

local function progressBox()
    local width = math.floor(Screen:getWidth() * 0.8)
    local inner = width - 2 * U(24)
    local box = {
        count = TextWidget:new{ text = "", face = U.face("cfont", 16), bold = true },
        name = TextWidget:new{ text = "", face = U.face("cfont", 14), max_width = inner },
        bar = ProgressWidget:new{ width = inner, height = U(10), percentage = 0 },
    }
    box.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = U.ceil(1.5),
        radius = U(8),
        padding = U(24),
        VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = _("Reading book details…"), face = U.face("cfont", 18), bold = true },
            VerticalSpan:new{ width = U(14) },
            box.count,
            VerticalSpan:new{ width = U(6) },
            box.name,
            VerticalSpan:new{ width = U(14) },
            box.bar,
        },
    }
    box.widget = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
        modal = true,
        box.frame,
    }
    return box
end

function Books.preload(ui, files)
    if not files[1] then return end
    local box = #files >= NOTICE_AFTER and progressBox()
    local shown
    preloading = true
    if box then
        UIManager:show(box.widget)
    end
    local ok, err = pcall(function()
        for index, file in ipairs(files) do
            local now = time.now()
            if box and (not shown or time.to_s(now - shown) >= 0.3) then
                shown = now
                box.count:setText(T(_("%1 of %2 (%3%)"), index, #files, math.floor((index - 1) * 100 / #files)))
                box.name:setText(file:match("[^/]+$"))
                box.bar.percentage = (index - 1) / #files
                UIManager:setDirty(box.widget, "ui", box.frame.dimen)
                UIManager:forceRePaint()
            end
            local read, problem = pcall(Books.details, ui, file)
            if not read then
                logger.warn("Books: details failed for", file, problem)
            end
        end
    end)
    preloading = false
    if box then
        UIManager:close(box.widget)
    end
    open():flush()
    if not ok then
        logger.warn("Books: preload stopped early", err)
    end
end

local function within(path, folder)
    return path == folder or path:sub(1, #folder + 1) == folder .. "/"
end

function Books.tracked(path)
    local home = G_reader_settings:readSetting("home_dir")
    if not home then return true end
    home = ffiUtil.realpath(home) or home
    path = ffiUtil.realpath(path) or path
    if not within(path, home) then return false end
    local inside = path:sub(#home + 1)
    if inside:find("%.koplugin/") or inside:find("%.sdr/") then return false end
    local data_dir = ffiUtil.realpath(DataStorage:getDataDir())
    return data_dir == nil or within(home, data_dir) or not within(path, data_dir)
end

function Books.preloadHome(ui)
    local home = G_reader_settings:readSetting("home_dir")
    if not (home and ui and ui.bookinfo) or open():readSetting(PRELOADED) == home then return false end
    local found = {}
    collectUnread(home, true, found)
    logger.info("Books: preload whole home", home, "unread", #found)
    Books.preload(ui, found)
    open():saveSetting(PRELOADED, home):flush()
    return true
end

function Books.preloadFor(ui, path)
    if Common.State.applied().book_details_read and Books.preloadHome(ui) then return end
    if not Books.tracked(path) then return end
    local found = {}
    collectUnread(path, false, found)
    logger.info("Books: preload one folder", path, "unread", #found)
    Books.preload(ui, found)
end

local function coverPath(file)
    return CACHE_DIR .. "/" .. md5(file) .. ".png"
end

local function saveThumb(file, bb, image)
    local scale = math.min(1, THUMB_H / math.max(1, bb:getHeight()))
    local thumb = RenderImage:scaleBlitBuffer(bb,
        math.max(1, math.floor(bb:getWidth() * scale)), math.max(1, math.floor(bb:getHeight() * scale)), true)
    if isDocument(file) and not image then
        thumb = trimMargins(thumb)
    end
    local written = thumb:writeToFile(coverPath(file), "png")
    thumb:free()
    return written
end

function Books.extract(ui, file, details)
    local entry = newEntry(file)
    local info = ui and ui.bookinfo
    startReading(file)
    local image = isImage(file)
    if details then
        entry.title, entry.authors = details.title, details.authors
    elseif not image and Books.tracked(file) then
        entry.title, entry.authors = readProps(ui, file)
    end
    local ok_cover, bb
    if image then
        ok_cover, bb = pcall(renderImage, file)
    elseif info then
        ok_cover, bb = pcall(info.getCoverImage, info, nil, file)
    end
    if ok_cover and bb then
        local saved, written = pcall(saveThumb, file, bb, image)
        if saved and written then
            entry.cover = true
        elseif not saved then
            logger.warn("Books: thumbnail failed for", file, written)
        end
    elseif ok_cover == false then
        logger.warn("Books: cover failed for", file, bb)
    end
    doneReading()
    images[file] = nil
    open():saveSetting(file, entry)
    if not details then
        open():flush()
    end
    return entry
end

local function remember(file, key, bb)
    images[file] = images[file] or {}
    images[file][key] = bb
    table.insert(image_order, { file = file, key = key })
    while #image_order > MAX_IMAGES do
        local oldest = table.remove(image_order, 1)
        if images[oldest.file] then
            images[oldest.file][oldest.key] = nil
        end
    end
end

function Books.cover(file, w, h)
    local entry = Books.get(file)
    if not (entry and entry.cover) then return end
    local key = w .. "x" .. h
    local cached = images[file] and images[file][key]
    if cached then
        return cached
    end
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, coverPath(file))
    if not (ok and bb) then return end
    local scale = math.min(w / bb:getWidth(), h / bb:getHeight())
    local scaled = RenderImage:scaleBlitBuffer(bb,
        math.floor(bb:getWidth() * scale), math.floor(bb:getHeight() * scale), true)
    remember(file, key, scaled)
    return scaled
end

local image_folder

local function onlyImages(items)
    local count = 0
    for _i, item in ipairs(items) do
        if item.is_file then
            if not (item.path and isImage(item.path)) then return false end
            count = count + 1
        end
    end
    return count > 0
end

local function noteFolder(path, items)
    if image_folder and image_folder.path == path then return end
    image_folder = onlyImages(items) and { path = path, view = GRID } or nil
end

function Library.view(path)
    if path and image_folder and image_folder.path == path then
        return image_folder.view
    end
    return G_reader_settings:readSetting(VIEW) == GRID and GRID or LIST
end

function Library.setView(view, path)
    if path and image_folder and image_folder.path == path then
        image_folder.view = view
        return
    end
    G_reader_settings:saveSetting(VIEW, view)
end

function Library.isGrid(menu)
    return menu.name == "filemanager" and Library.view(menu.path) == GRID
end

local function titleKey(title)
    local key = title:lower():gsub("^%s+", "")
    key = key:gsub("^the%s+", "")
    key = key:gsub("^an?%s+", "")
    return key
end

local function toSet(words)
    local set = {}
    for _i, word in ipairs(words) do
        set[word] = true
        set[word .. "."] = true
    end
    return set
end

local PREFIXES = toSet{ "mr", "mrs", "ms", "dr", "prof", "sir", "dame", "rev" }
local SUFFIXES = toSet{ "jr", "sr", "junior", "senior", "i", "ii", "iii", "iv", "phd", "ph.d", "md", "m.d", "esq" }
local COPYWORDS = toSet{
    "agency", "corporation", "company", "co", "council", "committee", "inc", "institute", "national", "society",
    "club", "team", "software", "games", "entertainment", "media", "studios", "press", "publishing", "staff",
    "anonymous", "various",
}
local PARTICLES = toSet{
    "da", "das", "de", "del", "della", "den", "der", "di", "do", "dos", "du", "la", "le", "st", "ten", "ter",
    "van", "von", "bin", "ibn",
}

local function surnameFirst(author)
    local name = author:gsub("%b()", ""):gsub("%b[]", ""):match("^%s*(.-)%s*$")
    if name:find(",") then
        local head, tail = name:match("^(.*),%s*(%S+)$")
        if not (tail and SUFFIXES[tail:lower()]) then return name end
        if head:find(",") then return head .. " " .. tail end
        name = head .. " " .. tail
    end
    local tokens, lower = {}, {}
    for word in name:gmatch("%S+") do
        table.insert(tokens, word)
        lower[#tokens] = word:lower()
        if COPYWORDS[lower[#tokens]] then return name end
    end
    if #tokens < 2 then return tokens[1] end
    local first, last = 1, #tokens
    while first < last and PREFIXES[lower[first]] do first = first + 1 end
    while last > first and SUFFIXES[lower[last]] do last = last - 1 end
    local start = last
    while start - 1 > first and PARTICLES[lower[start - 1]] do start = start - 1 end
    local key = table.concat(tokens, " ", start, last)
    if start > first then key = key .. ", " .. table.concat(tokens, " ", first, start - 1) end
    if last < #tokens then key = key .. " " .. table.concat(tokens, " ", last + 1) end
    return key
end

local function authorKey(author)
    local key = author and surnameFirst(author)
    return key and key:lower() or nil
end

local function setKeys(item, details)
    item.kcui_title = titleKey(details.title or item.text:gsub("%.[^.]+$", ""))
    item.kcui_author = authorKey(details.first_author)
end

local function readPending()
    if not pending[1] then return end
    local batch = pending
    pending = {}
    local files, seen = {}, {}
    for _i, entry in ipairs(batch) do
        if not seen[entry.file] then
            seen[entry.file] = true
            table.insert(files, entry.file)
        end
    end
    Books.preload(batch[1].ui, files)
    for _i, entry in ipairs(batch) do
        setKeys(entry.item, knownDetails(entry.file) or {})
    end
end

local function attachKeys(item, ui)
    local file = item.path or item.file
    local details
    if file and ui and ui.bookinfo and Books.tracked(file) then
        details = knownDetails(file)
        if not (details and Books.get(file)) then
            if not pending[1] then
                UIManager:nextTick(readPending)
            end
            table.insert(pending, { item = item, ui = ui, file = file })
        end
    end
    setKeys(item, details or {})
end

local function byKey(key)
    return function(cache)
        local natsort
        natsort, cache = sort.natsort_cmp(cache)
        local reverse = G_reader_settings:isTrue("reverse_collate")
        return function(a, b)
            if pending[1] then
                readPending()
            end
            local ka, kb = a[key], b[key]
            if ka == nil or kb == nil then
                if ka ~= kb then
                    return (kb == nil) ~= reverse
                end
            elseif ka ~= kb then
                return natsort(ka, kb)
            end
            return natsort(a.kcui_title or "", b.kcui_title or "")
        end, cache
    end
end

local folder_matches
local hasMatchingBookIn

local function scanForMatch(chooser, folder, show_dir)
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then return false end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and (FileChooser.show_hidden or not util.stringStartsWith(name, ".")) then
            local path = folder .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "file" and not util.stringStartsWith(name, "._") and chooser:show_file(name, path) then
                return true
            end
            if mode == "directory" and show_dir(chooser, name) and hasMatchingBookIn(chooser, path, show_dir) then
                return true
            end
        end
    end
    return false
end

local function hasMatchingBook(chooser, folder, show_dir)
    if not folder_matches then
        folder_matches = {}
        UIManager:nextTick(function() folder_matches = nil end)
    end
    local key = ffiUtil.realpath(folder) or folder
    if folder_matches[key] == nil then
        folder_matches[key] = false
        folder_matches[key] = scanForMatch(chooser, folder, show_dir)
    end
    return folder_matches[key]
end

hasMatchingBookIn = hasMatchingBook

local function installPreload()
    local genItemTableFromPath = FileChooser.genItemTableFromPath
    FileChooser.genItemTableFromPath = function(chooser, path)
        if chooser.name == "filemanager" and chooser.ui and chooser.ui.bookinfo and not preloading then
            Books.preloadFor(chooser.ui, path)
        end
        local items = genItemTableFromPath(chooser, path)
        if chooser.name == "filemanager" then
            noteFolder(path, items)
        end
        return items
    end
end

local function installFolderFilter()
    local getPathList = FileChooser.getPathList
    if not getPathList then return end
    FileChooser.getPathList = function(chooser, path, collate, dirs, files)
        if not (chooser.name == "filemanager" and FileChooser.show_filter.status) then
            return getPathList(chooser, path, collate, dirs, files)
        end
        local own, outer = rawget(chooser, "show_dir"), chooser._kcui_show_dir
        local show_dir = outer or chooser.show_dir
        chooser._kcui_show_dir = show_dir
        chooser.show_dir = function(self, name)
            return show_dir(self, name) and hasMatchingBook(self, path .. "/" .. name, show_dir)
        end
        local ok, err = pcall(getPathList, chooser, path, collate, dirs, files)
        chooser.show_dir = own
        chooser._kcui_show_dir = outer
        if not ok then error(err, 0) end
    end
end

function Library.install()
    if BookList.collates.kcui_title then return end
    installFolderFilter()
    installPreload()
    for order, entry in ipairs(Library.SORTS) do
        BookList.collates[entry.id] = {
            text = entry.text:lower(),
            menu_order = 200 + order,
            can_collate_mixed = false,
            item_func = attachKeys,
            init_sort_func = byKey(entry.id),
        }
    end
end

local function pagerHeight()
    local probe = TextWidget:new{ text = "0", face = U.face("cfont", PAGER_FONT) }
    local h = probe:getSize().h
    probe:free()
    return h + P(8)
end

local function isDeleted(entry)
    local file = entry.file
    return entry.dim and file ~= nil and lfs.attributes(file, "mode") ~= "file"
end

local function rowGeometry(h)
    local margin = math.floor(h * 0.06)
    local cover_h = math.min(h - 2 * margin, math.floor(U(150) / 0.72))
    local cover_w = math.floor(cover_h * 0.72)
    return cover_h, cover_w, U(21.27) + cover_w + math.floor(cover_h * 0.15)
end

local function isSelected(entry)
    return entry.dim and not isDeleted(entry)
end

local function readState(file)
    if isImage(file) then return end
    local info = BookList.getBookInfo(file)
    if not info.been_opened then return end
    if info.status == "complete" then return 100 end
    if info.percent_finished then return math.floor(info.percent_finished * 100) end
end

local function tag(text)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_BLACK,
        bordersize = 0,
        radius = U(0.8),
        padding = 0,
        padding_left = U(6.4),
        padding_right = U(6.4),
        padding_top = 0,
        padding_bottom = 0,
        TextWidget:new{
            text = text,
            face = U.face(KindleFonts.found.ui_heavy or "cfont", 14),
            bold = KindleFonts.found.ui_heavy == nil,
            fgcolor = Blitbuffer.COLOR_WHITE,
        },
    }
end

local function barWidth(file, text_w, title_face)
    local probe = TextWidget:new{ text = "abcdef", face = title_face, bold = true }
    local min_w = probe:getSize().w
    probe:free()
    local max_w = math.floor(text_w * 0.5)
    local pages = BookList.getBookInfo(file).pages
    if not pages or pages <= 0 then return max_w end
    local t = math.max(0, math.min(1, pages / 1000))
    return math.floor(min_w + (max_w - min_w) * t)
end

local function fileType(file)
    local ext = file:match("%.([^./]+)$")
    if ext and not EBOOK_FORMATS[ext:lower()] then
        return ext:upper()
    end
end

local ProgressBar = Widget:extend{
    width = nil,
    height = nil,
    percentage = 0,
}

function ProgressBar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ProgressBar:paintTo(bb, x, y)
    local radius = math.floor(self.height / 2)
    bb:paintRoundedRect(x, y, self.width, self.height, Blitbuffer.Color8(0xDD), radius)
    local fill = math.floor(self.width * self.percentage)
    if fill > 0 then
        bb:paintRoundedRect(x, y, math.max(fill, self.height), self.height, GRAY, radius)
    end
end

local Tile = Widget:extend{
    width = nil,
    height = nil,
    name = nil,
    font_size = 7,
}

function Tile:init()
    local w = self.width
    local function rel(px) return math.floor(w * px / 292 + 0.5) end
    self.stroke = math.max(U.ceil(1), rel(4))
    self.stack_gap = math.max(U.ceil(1), rel(5))
    self.border = Size.border.thin
    self.frame_y = 2 * (self.stroke + self.stack_gap)
    local frame_h = self.height - self.frame_y
    self.header_h = math.floor(frame_h * 0.3)
    local icon_h = math.max(U(10), math.floor(frame_h * 0.1))
    self.icon = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. (self.has_books and "/collections.svg" or "/folder-open.svg"),
        width = icon_h,
        height = icon_h,
        alpha = true,
    }
    self.inset = math.max(U(3), rel(11))
    if self.name then
        self.label = TextBoxWidget:new{
            text = self.name,
            face = U.face("cfont", self.font_size),
            bold = true,
            bgcolor = Blitbuffer.Color8(0xCC),
            width = w - 2 * self.inset,
            height = math.floor(frame_h * 0.45),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
end

function Tile:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Tile:paintTo(bb, x, y)
    local w, h = self.width, self.height
    local stack = Blitbuffer.Color8(0x66)
    local outer = math.floor(w * 0.03)
    local inner = math.floor(w * 0.015)
    bb:paintRect(x + outer, y, w - 2 * outer, self.stroke, stack)
    bb:paintRect(x + inner, y + self.stroke + self.stack_gap, w - 2 * inner, self.stroke, stack)
    local fy = y + self.frame_y
    local fh = h - self.frame_y
    local b = self.border
    bb:paintRect(x, fy, w, fh, Blitbuffer.Color8(0x88))
    bb:paintRect(x + b, fy + b, w - 2 * b, fh - 2 * b, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + b, fy + self.header_h, w - 2 * b, fh - self.header_h - b, Blitbuffer.Color8(0xCC))
    local icon_size = self.icon:getSize()
    self.icon:paintTo(bb, x + self.inset, fy + math.floor((self.header_h - icon_size.h) / 2))
    if self.label then
        self.label:paintTo(bb, x + self.inset, fy + self.header_h + math.floor(self.inset / 2))
    end
end

function Tile:free()
    self.icon:free()
    if self.label then self.label:free() end
end

local function folderMandatory(menu, entry)
    if entry.is_go_up or entry._kcui_counted then return entry.mandatory end
    if entry.mandatory and not entry.folder then return entry.mandatory end
    local path = entry.path or entry.folder
    local fm = require("apps/filemanager/filemanager").instance
    local fc = (menu.ui and menu.ui.file_chooser) or (fm and fm.file_chooser)
    if not fc or not path then return end
    local ok, dirs, files = pcall(fc.getList, fc, path)
    if not ok or not dirs then return end
    entry.mandatory = #dirs .. " \u{F114} " .. #files .. " \u{F016}"
    entry._kcui_counted = true
    return entry.mandatory
end

local function placeholder(title, w, h, bg)
    local border = Size.border.thin
    local inner_w, inner_h = w - 2 * border, h - 2 * border
    local label = TextBoxWidget:new{
        bgcolor = bg,
        text = title,
        face = U.face("cfont", math.max(7, math.min(14, math.floor(7 * w / U(53))))),
        bold = true,
        width = inner_w - 2 * U(4),
        height = inner_h - 2 * U(4),
        height_overflow_show_ellipsis = true,
        height_adjust = true,
        alignment = "center",
    }
    label.overlap_offset = { U(4),
        math.max(U(4), math.floor(inner_h / 3 - label:getSize().h / 2)) }
    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.Color8(0xBB),
        padding = 0,
        OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            label,
        },
    }
end

local function bookTitle(entry, cached)
    local title = cached and cached.title or entry.text:gsub("%.[^.]+$", "")
    local file = entry.file or entry.path
    local ext = file and isDocument(file) and file:match("%.([^./]+)$")
    if ext and title:sub(-#ext - 1):lower() ~= "." .. ext:lower() then
        return title .. "." .. ext
    end
    return title
end

local function coverImage(file, w, h)
    local border = isDocument(file) and Size.border.thin or 0
    local bb = Books.cover(file, w - 2 * border, h - 2 * border)
    if not bb then return end
    local image = ImageWidget:new{ image = bb, image_disposable = false }
    if border == 0 then return image end
    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.Color8(0xBB),
        padding = 0,
        image,
    }
end

local function fileIcon(w, h)
    local border = Size.border.thin
    local size = math.floor(math.min(w, h) * 0.4)
    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.Color8(0xBB),
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border },
            ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. "/document.svg",
                width = size,
                height = size,
                alpha = true,
            },
        },
    }
end

local Row = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
    show_parent = nil,
}

function Row:init()
    local entry = self.entry
    self.file = entry.file or entry.path or entry.folder
    local is_book = entry.file ~= nil or entry.is_file
    local is_shortcut = not is_book and entry.folder ~= nil
    local book_style = is_book or is_shortcut
    local deleted = isDeleted(entry)
    local selected = entry.dim and not deleted
    local w, h = self.dimen.w, self.dimen.h
    local pad = U(21.27)
    local right_pad = U(21.27)
    local cover_h, cover_w, text_x = rowGeometry(h)
    local more_size = entry.is_go_up and 0 or U(25)
    local more_x = w - right_pad - (entry.is_go_up and 0 or U(37.5))
    local dots_left = more_x + math.floor(more_size * 10 / 24)
    local dots_gap = w - right_pad - (more_x + math.ceil(more_size * 14 / 24))
    local check = U(21.27)
    local check_x = dots_left - U(24.6) - check
    local text_right = (more_size > 0 and selected) and check_x or dots_left
    local text_w = more_size > 0 and text_right - dots_gap - text_x or more_x - text_x
    local bg = selected and Blitbuffer.Color8(0xF0) or Blitbuffer.COLOR_WHITE
    local gap = Size.padding.small

    local cover, title, authors, percent, kind, count
    if is_book then
        local cached = Books.get(self.file)
        self.needs_extract = not deleted and cached == nil
        title = deleted and entry.text or bookTitle(entry, cached)
        authors = deleted and _("Deleted") or cached and cached.authors
        kind = fileType(self.file)
        local image = not deleted and cached and coverImage(self.file, cover_w, cover_h)
        if deleted then
            cover = LineWidget:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                background = Blitbuffer.Color8(0xEE),
            }
        elseif image then
            cover = image
        elseif cached and Books.tracked(self.file) then
            cover = placeholder(title, cover_w, cover_h, bg)
        else
            cover = fileIcon(cover_w, cover_h)
        end
        percent = readState(self.file)
    else
        title = entry.is_go_up and ".." or (entry.name or entry.text):gsub("/$", "")
        if self.menu._kcui_tab == "collections" and entry.name then
            local ReadCollection = require("readcollection")
            local n = 0
            for _i in pairs(ReadCollection.coll[entry.name] or {}) do n = n + 1 end
            title = entry.text
            entry.mandatory = "0 \u{F114} " .. n .. " \u{F016}"
            entry._kcui_counted = true
        end
        folderMandatory(self.menu, entry)
        if is_shortcut then
            authors = entry.folder:gsub("/+$", ""):match("([^/]+)$") or entry.folder
            if authors == title then
                authors = nil
            end
        end
        local tile_h = h - 2 * math.floor(h * 0.08)
        local tile_w = math.min(cover_w, math.floor(tile_h * 0.65))
        if entry.is_go_up then
            local icon = math.floor(tile_w * 0.8)
            cover = ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/folder.svg", width = icon, height = icon, alpha = true }
        else
            count = entry.mandatory
            cover = Tile:new{
                name = title, width = tile_w, height = tile_h,
                has_books = (tonumber((entry.mandatory or ""):match("(%d+) \u{F016}")) or 0) > 0 }
        end
    end

    local face = U.face("cfont", 13)
    local function line(text, line_face)
        return TextWidget:new{ text = text, face = line_face or face, fgcolor = GRAY, max_width = text_w }
    end
    local below = {}
    if authors and authors ~= "" then table.insert(below, line(authors, U.face("cfont", 14))) end
    if percent and percent >= 100 then
        table.insert(below, tag(_("Read")))
    elseif percent then
        local label = TextWidget:new{ text = T(_("%1% Read"), percent), face = U.face("cfont", 13), fgcolor = GRAY }
        local bar_h = U.ceil(5)
        table.insert(below, HorizontalGroup:new{
            align = "center",
            ProgressBar:new{
                width = math.min(barWidth(self.file, text_w, U.face("cfont", 15)), text_w - label:getSize().w - 5 * gap),
                height = bar_h,
                percentage = percent / 100,
            },
            HorizontalSpan:new{ width = 5 * gap },
            label,
        })
    end
    if kind then table.insert(below, line(kind)) end
    if is_book and self.menu._kcui_tab == "history" and entry.time then
        table.insert(below, line(Dates.history(entry.time)))
    end
    if count and count ~= "" then
        local dirs = tonumber(count:match("(%d+) \u{F114}")) or 0
        local files = tonumber(count:match("(%d+) \u{F016}")) or 0
        local digit_h = math.floor(face.size * 0.68 + 0.5)
        local group = HorizontalGroup:new{ align = "center" }
        local function add(n, icon, glyph)
            local icon_h = math.floor(digit_h * 24 / glyph + 0.5)
            if #group > 0 then table.insert(group, HorizontalSpan:new{ width = U(8) }) end
            table.insert(group, line(tostring(n)))
            table.insert(group, HorizontalSpan:new{ width = U(2) })
            table.insert(group, ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. "/count/" .. icon .. ".svg",
                width = icon_h,
                height = icon_h,
                alpha = true,
            })
        end
        if dirs > 0 then add(dirs, "folder", 15.5) end
        if files > 0 then add(files, "file", 15) end
        if #group > 0 then table.insert(below, group) end
    end

    local below_h = 0
    for _i, widget in ipairs(below) do
        below_h = below_h + gap + widget:getSize().h
    end
    local title_face = book_style and U.face("cfont", 15)
        or U.face(KindleFonts.found.book_bold or KindleFonts.found.book or "cfont", 18)
    local line_h = math.floor((1 + 0.3) * title_face.size + 0.5)
    local max_lines = 2
    local lines = math.max(1, math.min(max_lines, math.floor(((book_style and cover_h or h) - below_h) / line_h)))
    local text = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            bgcolor = bg,
            text = title,
            face = title_face,
            fgcolor = deleted and DELETED_GRAY or nil,
            bold = book_style or KindleFonts.found.book_bold == nil,
            width = text_w,
            height = lines * line_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        },
    }
    for _i, widget in ipairs(below) do
        table.insert(text, VerticalSpan:new{ width = gap })
        table.insert(text, widget)
    end

    local cover_size = cover:getSize()
    cover.overlap_offset = { pad, math.floor((h - cover_size.h) / 2) }
    text.overlap_offset = { text_x, math.floor((h - text:getSize().h) / 2) }

    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        cover,
        text,
    }
    if selected then
        table.insert(self[1], 1, LineWidget:new{
            dimen = Geom:new{ w = w, h = h },
            background = bg,
            overlap_offset = { 0, 0 },
        })
    end
    if more_size > 0 then
        local center_y = math.floor(h / 2)
        table.insert(self[1], ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. "/more-filled.svg",
            width = more_size,
            height = more_size,
            alpha = true,
            overlap_offset = { more_x, center_y - math.floor(more_size / 2) },
        })
        self.more_x = more_x - U(10)
        if selected then
            table.insert(self[1], ImageWidget:new{
                original_in_nightmode = false,
                file = ICONS .. "/selected.svg",
                width = check,
                height = check,
                alpha = true,
                overlap_offset = { check_x, center_y - math.floor(check / 2) },
            })
        end
    end
    local line = U.ceil(1)
    local full = selected or self.next_selected
    if not self.last or full then
        table.insert(self[1], LineWidget:new{
            dimen = Geom:new{ w = full and w or w - pad - right_pad, h = line },
            background = Blitbuffer.COLOR_BLACK,
            overlap_offset = { full and 0 or pad, h - line },
        })
    end
    if selected and self.first then
        table.insert(self[1], LineWidget:new{
            dimen = Geom:new{ w = w, h = line },
            background = Blitbuffer.COLOR_BLACK,
            overlap_offset = { 0, 0 },
        })
    end

    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

local function showActions(widget, cx, cy)
    Toolbar.present(function() widget.menu:onMenuHold(widget.entry) end, {
        right = Screen:getWidth() - U(8),
        top = cy + U(14) + U(Common.Paint.NOTCH),
        notch_x = cx,
        fit = true,
    })
end

function Row:showActions()
    local more_x = self.more_x or self.dimen.w - U(40)
    showActions(self, self.dimen.x + more_x + math.floor((self.dimen.w - more_x) / 2), self.dimen.y + math.floor(self.dimen.h / 2))
end

function Row:onTapSelect(_ev, ges)
    if self.more_x and ges and ges.pos.x - self.dimen.x >= self.more_x then
        self:showActions()
        return true
    end
    self.menu:onMenuSelect(self.entry)
    return true
end

function Row:onHoldSelect()
    self:showActions()
    return true
end

local ribbons = {}

local function ribbon(text)
    local size = U(65)
    local key = text .. size
    if ribbons[key] then
        return ribbons[key]
    end
    local inner = U(31)
    local face = U.face(KindleFonts.found.ui_heavy or "cfont", 12)
    local label = TextWidget:new{
        text = text,
        face = face,
        bold = KindleFonts.found.ui_heavy == nil,
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    local label_size = label:getSize()
    local lw, lh = label_size.w, label_size.h
    local cap_center = label:getBaseline() - face.size * 0.667 / 2
    local source = Blitbuffer.new(lw, lh, Blitbuffer.TYPE_BB8)
    source:fill(Blitbuffer.COLOR_BLACK)
    label:paintTo(source, 0, 0)
    label:free()
    local function ink(px, py)
        if px < 0 or py < 0 or px >= lw or py >= lh then return 0 end
        return source:getPixel(px, py):getColor8().a
    end
    local function sample(sx, sy)
        local x0, y0 = math.floor(sx - 0.5), math.floor(sy - 0.5)
        local fx, fy = sx - 0.5 - x0, sy - 0.5 - y0
        local top = ink(x0, y0) * (1 - fx) + ink(x0 + 1, y0) * fx
        local bottom = ink(x0, y0 + 1) * (1 - fx) + ink(x0 + 1, y0 + 1) * fx
        return math.floor(top * (1 - fy) + bottom * fy + 0.5)
    end
    local band = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8A)
    local diagonal = math.sqrt(2)
    local middle = (inner + size) / 2
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local px, py = x + 0.5, y + 0.5
            local distance = size - px + py
            local depth = math.min(distance - inner, size - distance) / diagonal
            if depth > -0.5 then
                local along = (px - (size - py)) / diagonal
                local across = (distance - middle) / diagonal
                local gray = sample(along + lw / 2, across + cap_center)
                band:setPixel(x, y, Blitbuffer.Color8A(gray, math.floor(math.min(1, depth + 0.5) * 255)))
            end
        end
    end
    source:free()
    ribbons[key] = band
    return band
end

local Cell = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
    show_parent = nil,
}

function Cell:init()
    local entry = self.entry
    self.file = entry.file or entry.path or entry.folder
    local w, h = self.dimen.w, self.dimen.h
    local box_h = math.min(h, math.floor(w * GRID_ASPECT))
    if entry.is_file then
        local cached = Books.get(self.file)
        self.needs_extract = cached == nil
        local image = cached and coverImage(self.file, w, h)
        if image then
            self.cover = image
        elseif cached and Books.tracked(self.file) then
            self.cover = placeholder(bookTitle(entry, cached), w, box_h, Blitbuffer.COLOR_WHITE)
        else
            self.cover = fileIcon(w, box_h)
        end
        self.read = (readState(self.file) or 0) >= 100
    else
        local count = folderMandatory(self.menu, entry)
        local tile_w = math.floor(w * 0.86)
        self.cover = Tile:new{
            name = entry.text:gsub("/$", ""),
            width = tile_w,
            height = math.min(h, math.floor(tile_w / 0.65)),
            font_size = 12,
            has_books = (tonumber((count or ""):match("(%d+) \u{F016}")) or 0) > 0,
        }
    end
    self.selected = isSelected(entry)
    if self.selected then
        local check = U(21.27)
        self.check = ImageWidget:new{
            original_in_nightmode = false,
            file = ICONS .. "/selected.svg",
            width = check,
            height = check,
            alpha = true,
        }
    end
    self.more = U(40)
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Cell:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Cell:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if not self.cover then return end
    local size = self.cover:getSize()
    local cx = x + math.floor((self.dimen.w - size.w) / 2)
    local cy = y + self.dimen.h - size.h
    self.cover:paintTo(bb, cx, cy)
    if self.read then
        local band = ribbon(_("Read"))
        local side = band:getWidth()
        bb:alphablitFrom(band, cx + size.w - side, cy, 0, 0, side, side)
    end
    local radius, ring = U(2.4), U.ceil(1)
    local dot_x = cx + size.w - U(11) - radius
    for i = 0, 2 do
        local dot_y = cy + size.h - U(12) - i * U(9) - radius
        bb:paintRoundedRect(dot_x - ring, dot_y - ring, 2 * (radius + ring), 2 * (radius + ring), Blitbuffer.COLOR_BLACK, radius + ring)
        bb:paintRoundedRect(dot_x, dot_y, 2 * radius, 2 * radius, Blitbuffer.COLOR_WHITE, radius)
    end
    if self.check then
        local inset = U(6)
        self.check:paintTo(bb, cx + inset, cy + size.h - inset - self.check:getSize().h)
    end
end

function Cell:onTapSelect(_ev, ges)
    local pos = ges and ges.pos
    if pos and pos.x >= self.dimen.x + self.dimen.w - self.more and pos.y >= self.dimen.y + self.dimen.h - self.more then
        self:showActions()
        return true
    end
    self.menu:onMenuSelect(self.entry)
    return true
end

function Cell:showActions()
    local half = math.floor(self.more / 2)
    showActions(self, self.dimen.x + self.dimen.w - half, self.dimen.y + self.dimen.h - half)
end

function Cell:onHoldSelect()
    self:showActions()
    return true
end

function Cell:free()
    if self.cover and self.cover.free then self.cover:free() end
    if self.check then self.check:free() end
end

local function gridGeometry(w, list_h)
    local pad, gap, top = U(21.27), U(15), U(19)
    local cell_w = math.floor((w - 2 * pad - (GRID_COLUMNS - 1) * gap) / GRID_COLUMNS)
    local rows = math.max(1, math.floor((list_h - top + gap) / (math.floor(cell_w * GRID_ASPECT) + gap) + 0.5))
    return {
        pad = pad,
        gap = gap,
        top = top,
        rows = rows,
        cell_w = cell_w,
        cell_h = math.floor((list_h - top) / rows) - gap,
    }
end

local function scheduleExtraction(menu)
    if menu._kcui_extract then
        UIManager:unschedule(menu._kcui_extract)
        menu._kcui_extract = nil
    end
    local file
    for _i, row in ipairs(menu._kcui_rows or {}) do
        if row.needs_extract then
            file = row.file
            break
        end
    end
    if not file then return end
    menu._kcui_extract = function()
        menu._kcui_extract = nil
        if not UIManager:isWidgetShown(menu.show_parent or menu) then return end
        if Books.get(file) == nil then
            Books.extract(menu.ui, file)
        end
        menu:updateItems(nil, true)
    end
    UIManager:scheduleIn(0.1, menu._kcui_extract)
end

local PageNumber = InputContainer:extend{
    page = nil,
    current = false,
    menu = nil,
}

function PageNumber:init()
    self.text = TextWidget:new{
        text = self.label or tostring(self.page),
        face = U.face("cfont", PAGER_FONT),
        bold = true,
        fgcolor = not self.current and Blitbuffer.Color8(0xBB) or nil,
    }
    local size = self.text:getSize()
    local w = math.max(self.slot_w or 0, size.w) + 2 * P(3)
    self.text_x = math.floor((w - size.w) / 2)
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = size.h }
    if self.dots then
        self.dots_widget = TextWidget:new{
            text = "…",
            face = U.face("cfont", PAGER_DOTS_FONT),
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    self.ges_events = {
        TapPage = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function PageNumber:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function PageNumber:paintTo(bb, x, y)
    y = y + U(PAGER_DROP)
    self.dimen.x, self.dimen.y = x, y
    self.text:paintTo(bb, x + self.text_x, y)
    if self.dots then
        local left, right
        if self.dots == "after" then
            local n = self.neighbor
            left = x - n.dimen.w + n.text_x + n.text:getSize().w
            right = x + self.dimen.w + self.arrow_inset
        else
            local n = self.neighbor
            left = x - self.arrow_inset
            right = x + self.dimen.w + n.text_x
        end
        local dots_y = y + self.neighbor.text:getBaseline() - self.dots_widget:getBaseline()
        self.dots_widget:paintTo(bb, math.floor((left + right - self.dots_widget:getSize().w) / 2), dots_y)
    end
end

function PageNumber:onTapPage()
    if self.page and not self.current then
        self.menu:onGotoPage(self.page)
    end
    return true
end

function PageNumber:free()
    self.text:free()
    if self.dots_widget then self.dots_widget:free() end
end

local PageArrow = InputContainer:extend{
    icon = nil,
    enabled = true,
    action = nil,
    row_h = nil,
}

function PageArrow:init()
    self.size = P(15)
    self.icon_widget = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/pager/" .. self.icon .. (self.enabled and "" or "-off") .. ".svg",
        width = self.size,
        height = self.size,
        alpha = true,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.size, h = self.row_h }
    self.ges_events = {
        TapArrow = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function PageArrow:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function PageArrow:paintTo(bb, x, y)
    y = y + U(PAGER_DROP)
    self.dimen.x, self.dimen.y = x, y
    self.icon_widget:paintTo(bb, x, y + math.floor((self.row_h - self.size) / 2))
end

function PageArrow:onTapArrow()
    if self.enabled then self.action() end
    return true
end

function PageArrow:free()
    self.icon_widget:free()
end

local function updateArrows(menu)
    local probe = TextWidget:new{ text = "0", face = U.face("cfont", PAGER_FONT) }
    local row_h = probe:getSize().h
    probe:free()
    menu.page_info_spacer.width = P(12)
    local paged = #menu.item_table > 0 and menu.page_num > 1
    local back = paged and menu.page > 1
    local forward = paged and menu.page < menu.page_num
    local arrows = {
        [1] = { "chevron-double-left", back, function() menu:onFirstPage() end },
        [3] = { "chevron-left", back, function() menu:onPrevPage() end },
        [7] = { "chevron-right", forward, function() menu:onNextPage() end },
        [9] = { "chevron-double-right", forward, function() menu:onLastPage() end },
    }
    for slot, arrow in pairs(arrows) do
        if paged then
            menu.page_info[slot] = PageArrow:new{
                icon = arrow[1], enabled = arrow[2], action = arrow[3], row_h = row_h,
            }
        else
            menu.page_info[slot] = HorizontalSpan:new{ width = 0 }
        end
    end
end

local function updatePageNumbers(menu)
    local slot = 5
    if #menu.item_table == 0 then
        menu.page_info[slot] = menu.page_info_text
    elseif menu.page_num <= 1 then
        menu.page_info[slot] = HorizontalSpan:new{ width = 0 }
    else
        local first = math.max(1, menu.page - 2)
        local last = math.min(menu.page_num, first + 4)
        first = math.max(1, last - 4)
        local numbers = HorizontalGroup:new{ align = "center" }
        local widest = TextWidget:new{
            text = string.rep("0", math.max(3, #tostring(menu.page_num))),
            face = U.face("cfont", PAGER_FONT),
            bold = true,
        }
        local slot_w = widest:getSize().w
        widest:free()
        local dots = TextWidget:new{ text = "…", face = U.face("cfont", PAGER_FONT) }
        local dots_w = dots:getSize().w
        dots:free()
        local spaced = TextWidget:new{ text = "0 0", face = U.face("cfont", PAGER_FONT) }
        local tight = TextWidget:new{ text = "00", face = U.face("cfont", PAGER_FONT) }
        local space_w = spaced:getSize().w - tight:getSize().w
        spaced:free()
        tight:free()
        local pad = P(3)
        local arrow_inset = math.floor(P(15) * 6 / 24)
        local reserve_w = math.max(0, dots_w + 2 * space_w - arrow_inset - 3 * pad)
        local before, after = first > 1, last < menu.page_num
        local items = {}
        for page = first, last do
            table.insert(items, PageNumber:new{ page = page, current = page == menu.page, menu = menu, slot_w = slot_w })
        end
        table.insert(numbers, PageNumber:new{
            page = before and first - 1 or nil, label = "", menu = menu, slot_w = reserve_w,
            dots = before and "before" or nil, neighbor = items[1], arrow_inset = arrow_inset,
        })
        for _i, item in ipairs(items) do
            table.insert(numbers, item)
        end
        table.insert(numbers, PageNumber:new{
            page = after and last + 1 or nil, label = "", menu = menu, slot_w = reserve_w,
            dots = after and "after" or nil, neighbor = items[#items],
            arrow_inset = arrow_inset,
        })
        menu.page_info[slot] = numbers
    end
    menu.page_info[4] = HorizontalSpan:new{ width = 0 }
    menu.page_info[6] = HorizontalSpan:new{ width = 0 }
    menu.page_info.align = "top"
    menu.page_info[10] = VerticalSpan:new{ width = pagerHeight() }
    menu.page_info:resetLayout()
end

local UpRow = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
    text_x = nil,
}

function UpRow:init()
    local w, h = self.dimen.w, self.dimen.h
    local pad = U(21.27)
    local icon = U(Toolbar.BACK_ICON)
    local count = #self.menu.item_table - 1
    local path = (self.menu.path or ""):gsub("/+$", "")
    local label = TextWidget:new{
        text = count > 0 and T(_.ngettext("(%1 item)", "(%1 items)", count), count) or "",
        face = U.face("cfont", 15),
        fgcolor = GRAY,
    }
    local arrow_x = pad - math.floor(icon * 3 / 24)
    local gap = self.text_x - arrow_x - icon
    local home = (G_reader_settings:readSetting("home_dir") or ""):gsub("/+$", "")
    local name = TextWidget:new{
        text = path == home and _("Library") or path:match("([^/]+)$") or path,
        face = U.face("cfont", 18),
        bold = true,
        max_width = w - 2 * pad - icon - gap - U(9.5) - label:getSize().w,
    }
    local group = HorizontalGroup:new{
        align = "center",
        ImageWidget:new{ original_in_nightmode = false, file = ICONS .. "/arrow-left.svg", width = icon, height = icon, alpha = true },
        HorizontalSpan:new{ width = gap },
        name,
    }
    if count > 0 then
        table.insert(group, HorizontalSpan:new{ width = U(9.5) })
        table.insert(group, label)
    end
    group.overlap_offset = { arrow_x, h - U(Toolbar.BACK_ROW_CENTER) - math.floor(group:getSize().h / 2) }
    local border = Toolbar.border()
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        group,
        LineWidget:new{
            dimen = Geom:new{ w = w, h = border },
            background = Toolbar.BORDER,
            overlap_offset = { 0, h - border },
        },
    }
    self.ges_events = {
        TapUp = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function UpRow:onTapUp()
    self.menu:onMenuSelect(self.entry)
    return true
end

local function hasUp(menu)
    local first = menu.item_table[1]
    return first ~= nil and first.is_go_up == true
end

local function getPageNumber(menu, item_number)
    local skip = hasUp(menu) and 1 or 0
    local count = #menu.item_table - skip
    if count <= 0 then return 1 end
    local index = math.max(1, math.min(item_number - skip, count))
    return math.ceil(index / menu.perpage)
end

local function keepSearchBar(menu)
    local bar = menu._kcui_search_bar
    if not bar then return end
    for i, widget in ipairs(menu.item_group) do
        if widget == bar then
            table.remove(menu.item_group, i)
            return
        end
    end
end

local function updateItems(menu, select_number, no_recalculate_dimen)
    local old_dimen = menu.dimen and menu.dimen:copy()
    menu.layout = {}
    keepSearchBar(menu)
    menu.item_group:clear()
    menu.page_info:resetLayout()
    menu.return_button:resetLayout()
    menu.content_group:resetLayout()
    menu:_recalculateDimen(no_recalculate_dimen)

    local skip = hasUp(menu) and 1 or 0
    local header_h = skip == 1 and U(Rows.UP_ROW_HEIGHT) or 0
    local toolbar_h = Toolbar.heightFor(menu)
    local row_dimen = menu.item_dimen:copy()
    row_dimen.h = math.floor((menu.available_height - header_h - toolbar_h) / menu.perpage)
    if skip == 1 then
        local up = UpRow:new{
            entry = menu.item_table[1],
            menu = menu,
            dimen = Geom:new{ x = 0, y = 0, w = row_dimen.w, h = header_h },
            text_x = select(3, rowGeometry(row_dimen.h)),
        }
        table.insert(menu.item_group, up)
        table.insert(menu.layout, { up })
    end
    if toolbar_h > 0 then
        table.insert(menu.item_group, Toolbar.build(menu, row_dimen.w))
    end
    local offset = (menu.page - 1) * menu.perpage + skip
    local grid = Library.isGrid(menu)
        and gridGeometry(row_dimen.w, menu.available_height - header_h - toolbar_h)
    local lines = {}
    menu._kcui_rows = {}
    if grid then
        table.insert(menu.item_group, VerticalSpan:new{ width = grid.top })
    end
    for i = 1, menu.perpage do
        local index = offset + i
        local item = menu.item_table[index]
        if item == nil then break end
        item.idx = index
        if index == menu.itemnumber then
            select_number = i
        end
        local row
        if grid then
            row = Cell:new{
                entry = item,
                menu = menu,
                dimen = Geom:new{ x = 0, y = 0, w = grid.cell_w, h = grid.cell_h },
                show_parent = menu.show_parent,
            }
            if i % GRID_COLUMNS == 1 then
                table.insert(lines, HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = grid.pad } })
                table.insert(menu.item_group, lines[#lines])
                table.insert(menu.item_group, VerticalSpan:new{ width = grid.gap })
                table.insert(menu.layout, {})
            else
                table.insert(lines[#lines], HorizontalSpan:new{ width = grid.gap })
            end
            table.insert(lines[#lines], row)
            table.insert(menu.layout[#menu.layout], row)
        else
            row = Row:new{
                entry = item,
                menu = menu,
                dimen = row_dimen:copy(),
                show_parent = menu.show_parent,
                last = i == menu.perpage or menu.item_table[index + 1] == nil,
                first = i == 1,
                next_selected = i < menu.perpage and menu.item_table[index + 1] ~= nil and isSelected(menu.item_table[index + 1]),
            }
            table.insert(menu.item_group, row)
            table.insert(menu.layout, { row })
        end
        table.insert(menu._kcui_rows, row)
    end
    for _i, group in ipairs(lines) do
        table.insert(group, HorizontalSpan:new{ width = row_dimen.w - group:getSize().w })
        group:resetLayout()
    end

    menu:updatePageInfo(select_number)
    if menu.page_return_arrow then
        menu.page_return_arrow:hide()
    end
    updateArrows(menu)
    updatePageNumbers(menu)
    menu:mergeTitleBarIntoLayout()
    if menu.path_items and menu.path then
        menu.path_items[menu.path] = (menu.page - 1) * menu.perpage + skip + 1
    end
    UIManager:setDirty(menu.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(menu.dimen) or menu.dimen
    end)
    scheduleExtraction(menu)
end

local function recalculateDimen(menu, no_recalculate_dimen)
    local top_height = (menu.title_bar and not menu.no_title) and menu.title_bar:getHeight() or 0
    local available = menu.inner_dimen.h - top_height - pagerHeight()
    local list_h = available - (hasUp(menu) and U(Rows.UP_ROW_HEIGHT) or 0) - Toolbar.heightFor(menu)
    local row_h = menu._kcui_tab == "history" and Rows.HISTORY_ROW_HEIGHT or Rows.ROW_HEIGHT
    local perpage = Library.isGrid(menu) and gridGeometry(menu.inner_dimen.w, list_h).rows * GRID_COLUMNS
        or math.max(1, math.floor(list_h / U(row_h) + 0.5))
    if menu.perpage ~= perpage then
        menu.perpage = perpage
        no_recalculate_dimen = false
    end
    if no_recalculate_dimen then return end
    menu.available_height = available
    menu.item_dimen = Geom:new{
        x = 0, y = 0,
        w = menu.inner_dimen.w,
        h = math.floor(menu.available_height / menu.perpage),
    }
    menu.page_num = menu:getPageNumber(#menu.item_table)
    if menu.page > menu.page_num then
        menu.page = menu.page_num
    end
end

function Library.attach(menu)
    menu._recalculateDimen = recalculateDimen
    menu.updateItems = updateItems
    menu.getPageNumber = getPageNumber
end

local Sheet = InputContainer:extend{
    fm = nil,
}

local STATUSES = { "new", "reading", "abandoned", "complete" }

local function filterSections(fm)
    local current = FileChooser.show_filter.status
    local function chip(status)
        return {
            text = BookList.getBookStatusString(status or "all"),
            selected = (current == nil and status == nil) or (current ~= nil and status ~= nil and current[status] == true),
            action = function()
                FileChooser.show_filter.status = status and { [status] = true } or nil
                fm.file_chooser:refreshPath()
            end,
        }
    end
    local chips = { chip(nil) }
    for _i, status in ipairs(STATUSES) do
        table.insert(chips, chip(status))
    end
    return { { title = _("Filters"), row_sizes = { 1, 2, 2 }, rows = { chips } } }
end

local function sortSections(fm)
    local collate = G_reader_settings:readSetting("collate")
    local reverse = G_reader_settings:isTrue("reverse_collate")
    local path = fm.file_chooser.path
    local view = Library.view(path)
    local sorts = {}
    for _i, entry in ipairs(Library.SORTS) do
        table.insert(sorts, {
            text = entry.text,
            selected = collate == entry.id,
            action = function() fm:onSetSortBy(entry.id) end,
        })
    end
    local function direction(text, descending)
        return {
            text = text,
            selected = reverse == descending,
            action = function() fm:onSetReverseSorting(descending) end,
        }
    end
    local function layout(text, icon, id)
        return {
            text = text,
            icon = icon,
            selected = view == id,
            action = function()
                Library.setView(id, path)
                fm.file_chooser:refreshPath()
            end,
        }
    end
    return {
        {
            title = _("Sort by"),
            rows = { sorts, { direction(_("Ascending"), false), direction(_("Descending"), true) } },
        },
        {
            title = _("View options"),
            rows = { { layout(_("Grid"), "grid", Library.GRID), layout(_("List"), "list", Library.LIST) } },
        },
    }
end

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.chevron = ImageWidget:new{
        original_in_nightmode = false,
        file = ICONS .. "/statusbar/chevron.svg",
        width = U(63.81),
        height = math.floor(U(63.81) * 17 / 132),
        alpha = true,
    }
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
end

function Sheet:build()
    self:release()
    self.widgets, self.chips, self.rules, self.headings = {}, {}, {}, {}
    local w = self.dimen.w
    local inset = U(45)
    local chip_h, chip_gap, chip_pad = U(41), U(8), U(17)
    local icon_size, icon_gap = U(20), U(15)
    local face = U.face("cfont", 15)
    local heading_face = U.face("cfont", 17)
    local function keep(widget)
        table.insert(self.widgets, widget)
        return widget
    end
    local y = U(3)
    for index, section in ipairs(self.sections(self.fm)) do
        local heading = keep(TextWidget:new{ text = section.title, face = heading_face, bold = true })
        local center = y + (index == 1 and U(61) or U(49))
        table.insert(self.headings, { widget = heading, x = inset, y = center - math.floor(heading:getSize().h / 2) })
        local rule = center + U(24)
        table.insert(self.rules, { x = U(17.5), y = rule, w = w - 2 * U(17.5), h = U(2), color = BLACK })
        y = rule + U(2) + U(13)
        for row_index, row in ipairs(section.rows) do
            if row_index > 1 then
                table.insert(self.rules, { x = inset, y = y + U(7.5), w = w - 2 * inset, h = U.ceil(1), color = Toolbar.BORDER })
                y = y + U(22.5)
            end
            local x = inset
            local placed = 0
            local breaks, total = {}, 0
            for _i, size in ipairs(section.row_sizes or {}) do
                total = total + size
                breaks[total] = true
            end
            for _i, chip in ipairs(row) do
                chip.label = keep(TextWidget:new{ text = chip.text, face = face, fgcolor = chip.selected and WHITE or BLACK })
                local content = chip.label:getSize().w
                if chip.icon then
                    chip.image = keep(ImageWidget:new{
                        original_in_nightmode = false,
                        file = ICONS .. "/" .. chip.icon .. ".svg",
                        width = icon_size,
                        height = icon_size,
                        invert = chip.selected,
                    })
                    content = content + icon_size + icon_gap
                end
                local chip_w = content + 2 * chip_pad
                if x > inset and (x + chip_w > w - inset or breaks[placed]) then
                    x = inset
                    y = y + chip_h + chip_gap
                end
                chip.rect = Geom:new{ x = x, y = y, w = chip_w, h = chip_h }
                chip.label_x = x + chip_w - chip_pad - chip.label:getSize().w
                table.insert(self.chips, chip)
                placed = placed + 1
                x = x + chip_w + chip_gap
            end
            y = y + chip_h
        end
    end
    self.height = y + U(15)
    self.top = self.dimen.h - self.height
end

function Sheet:region()
    return Geom:new{ x = 0, y = self.top, w = self.dimen.w, h = self.height }
end

function Sheet:paintTo(bb, x, y)
    local top = y + self.top
    bb:paintRect(x, top, self.dimen.w, self.height, WHITE)
    bb:paintRect(x, top, self.dimen.w, U(3), BLACK)
    local chevron = self.chevron:getSize()
    self.chevron:paintTo(bb, x + math.floor((self.dimen.w - chevron.w) / 2), top + U(21) - math.floor(chevron.h / 2))
    for _i, rule in ipairs(self.rules) do
        bb:paintRect(x + rule.x, top + rule.y, rule.w, rule.h, rule.color)
    end
    for _i, heading in ipairs(self.headings) do
        heading.widget:paintTo(bb, x + heading.x, top + heading.y)
    end
    for _i, chip in ipairs(self.chips) do
        local r = chip.rect
        local radius = math.floor(r.h / 2)
        if chip.selected then
            bb:paintRoundedRect(x + r.x, top + r.y, r.w, r.h, BLACK, radius)
        else
            bb:paintBorder(x + r.x, top + r.y, r.w, r.h, U.ceil(1), CHIP_BORDER, radius, true)
        end
        if chip.image then
            chip.image:paintTo(bb, x + r.x + U(17), top + r.y + math.floor((r.h - chip.image:getSize().h) / 2))
        end
        chip.label:paintTo(bb, x + chip.label_x, top + r.y + math.floor((r.h - chip.label:getSize().h) / 2))
    end
end

function Sheet:dismiss()
    UIManager:close(self)
    return true
end

function Sheet:onTapSheet(_ev, ges)
    local pos = ges.pos
    if pos.y < self.top + U(42) then
        return self:dismiss()
    end
    for _i, chip in ipairs(self.chips) do
        local r = chip.rect
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= self.top + r.y and pos.y < self.top + r.y + r.h then
            if not chip.selected then
                chip.action()
                self:build()
                UIManager:setDirty(self, "ui", self:region())
            end
            break
        end
    end
    return true
end

function Sheet:onAnyKeyPressed()
    return self:dismiss()
end

function Sheet:onSwipeSheet(_ev, ges)
    if ges.direction == "south" then
        return self:dismiss()
    end
    return true
end

function Sheet:onShow()
    UIManager:setDirty(self, "ui", self:region())
    return true
end

function Sheet:onCloseWidget()
    self:release()
    self.chevron:free()
    UIManager:setDirty(nil, "ui", self:region())
end

function Library.showOptions(fm)
    UIManager:show(Sheet:new{ fm = fm, sections = sortSections })
end

function Library.showFilters(fm)
    UIManager:show(Sheet:new{ fm = fm, sections = filterSections })
end

return Library
