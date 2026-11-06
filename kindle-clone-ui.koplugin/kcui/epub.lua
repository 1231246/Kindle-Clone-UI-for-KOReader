local Archiver = require("ffi/archiver")
local util = require("util")

local Epub = {}

local function clean(text)
    return util.htmlEntitiesToUtf8(text):match("^%s*(.-)%s*$")
end

local function attributes(text)
    local attrs = {}
    for key, _quote, value in text:gmatch("([%w:_-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[key] = clean(value)
    end
    return attrs
end

local function metaTags(opf)
    local tags = {}
    for attrs, closed, text in opf:gmatch("<[%w_]-:?meta(%s[^>]-)(/?)>([^<]*)") do
        local tag = attributes(attrs)
        tag.text = closed == "" and clean(text) or ""
        table.insert(tags, tag)
    end
    return tags
end

local function readOpf(file)
    local archive = Archiver.Reader:new()
    if not archive:open(file) then return end
    local text
    for entry in archive:iterate() do
        if entry.mode == "file" and entry.path:lower():match("%.opf$") then
            text = archive:extractToMemory(entry.path)
            break
        end
    end
    archive:close()
    return text
end

local function calibreSeries(tags)
    local name, index
    for _i, tag in ipairs(tags) do
        if tag.name == "calibre:series" and tag.content and tag.content ~= "" then
            name = tag.content
        elseif tag.name == "calibre:series_index" then
            index = tonumber(tag.content)
        end
    end
    return name, name and index
end

local function collectionSeries(tags)
    for _i, tag in ipairs(tags) do
        if tag.property == "belongs-to-collection" and tag.id and tag.text ~= "" then
            local kind, position
            for _j, refine in ipairs(tags) do
                if refine.refines == "#" .. tag.id then
                    if refine.property == "collection-type" then
                        kind = refine.text
                    elseif refine.property == "group-position" then
                        position = tonumber(refine.text)
                    end
                end
            end
            if kind == "series" then
                return tag.text, position
            end
        end
    end
end

function Epub.series(file)
    local ext = file:match("%.([^./]+)$")
    if not (ext and ext:lower():match("^epub")) then return false end
    local ok, opf = pcall(readOpf, file)
    if not (ok and opf) then return false end
    local tags = metaTags(opf)
    local name, index = calibreSeries(tags)
    if not name then
        name, index = collectionSeries(tags)
    end
    return true, name, index
end

return Epub
