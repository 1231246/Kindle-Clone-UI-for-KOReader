-- Theme gettext with autonomous translations.
-- Loads i18n tables via absolute path (works on Android).

local real = require("gettext")
local Screen = require("device").screen

local THIS = debug.getinfo(1, "S").source
local ROOT = THIS:match("^@(.*)/kcui/gettext%.lua$")
if not ROOT then
    ROOT = THIS:match("^@(.*)/") or "."
end

local translations = {}
local short_translations = {}
local current_lang = "en"

local LANG_MAP = {
    en="en", en_GB="en_GB", ru="ru", uk="uk", de="de", fr="fr", es="es",
    it="it", pl="pl", pt="pt", pt_BR="pt_BR", nl="nl", cs="cs", sk="sk",
    hu="hu", ro="ro", bg="bg", tr="tr", vi="vi", ar="ar", he="he", fa="fa",
    ja="ja", ko="ko", zh_CN="zh_CN", zh_TW="zh_TW", ca="ca", eo="eo",
    eu="eu", fi="fi", ga="ga", gl="gl", hr="hr", id="id", lt="lt", lv="lv",
    nb="nb", sr="sr", sv="sv", el="el", hi="hi", ka="ka",
}

local function load_lang_file(name)
    local path = ROOT .. "/i18n/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then return data end
    return nil
end

local function detect_lang()
    local lang = "en"
    pcall(function()
        if G_reader_settings then
            lang = G_reader_settings:readSetting("language") or "en"
        end
    end)
    return LANG_MAP[lang] or lang or "en"
end

local function load_translations()
    current_lang = detect_lang()
    translations = {}
    short_translations = {}

    local data = load_lang_file(current_lang)
    if not data then
        local base = tostring(current_lang):match("^(%w+)")
        if base then data = load_lang_file(base) end
    end

    if data then
        if type(data.full) == "table" then
            translations = data.full
            short_translations = data.short or {}
        else
            translations = data
        end
    end

    -- English fallback for missing keys
    if current_lang ~= "en" then
        local en = load_lang_file("en")
        if en then
            local src = en.full or en
            for k, v in pairs(src) do
                if translations[k] == nil then
                    translations[k] = v
                end
            end
        end
    end
end

pcall(load_translations)

local _loaded_once = false
local function tr(s)
    if type(s) ~= "string" then return s end
    if not _loaded_once and G_reader_settings then
        _loaded_once = true
        pcall(load_translations)
    end
    -- По умолчанию всегда возвращаем полный перевод
    return translations[s] or s
end

-- Явная функция для короткого перевода (для тесных мест)
local function tr_short(s)
    if type(s) ~= "string" then return s end
    return short_translations[s] or translations[s] or s
end

local function ntr(singular, plural, n)
    local key = (n == 1) and singular or plural
    local t = translations[key]
    if t then return t end
    if type(real) == "table" and real.ngettext then
        return real.ngettext(singular, plural, n)
    end
    return real(key)
end

local function ptr(context, msgid)
    local t = translations[msgid]
    if t then return t end
    if type(real) == "table" and real.pgettext then
        return real.pgettext(context, msgid)
    end
    return real(msgid)
end

local M = {
    ngettext = ntr,
    pgettext = ptr,
    short = tr_short, -- Вызывается как _.short("Library")
    _lang = function() return current_lang end,
    _reload = load_translations,
}

setmetatable(M, {
    __call = function(_, s) return tr(s) end
})

return M