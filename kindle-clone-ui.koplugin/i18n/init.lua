-- Minimal safe localization for Kindle Clone UI
local M = {}
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

function M.load()
    local lang = "en"
    pcall(function()
        if G_reader_settings then
            lang = G_reader_settings:readSetting("language") or "en"
        end
    end)
    current_lang = LANG_MAP[lang] or lang or "en"

    local function try(name)
        local ok, data = pcall(require, "i18n." .. name)
        if ok and type(data) == "table" then return data end
        return nil
    end

    local data = try(current_lang) or try(current_lang:match("^(%w+)") or "")
    if data then
        if data.full then
            translations = data.full
            short_translations = data.short or {}
        else
            translations = data
        end
    end

    if current_lang ~= "en" then
        local en = try("en")
        if en then
            local src = en.full or en
            for k, v in pairs(src) do
                if not translations[k] then translations[k] = v end
            end
        end
    end
end

-- translate(s [, use_short])
--   use_short == false/nil  → полный перевод (по умолчанию)
--   use_short == true       → короткий перевод, если есть; иначе полный
--                             (используйте на узких экранах/кнопках)
function M.translate(s, use_short)
    if type(s) ~= "string" then return s end
    if use_short and short_translations[s] then
        return short_translations[s]
    end
    return translations[s] or s
end

function M.is_rtl()
    return current_lang == "ar" or current_lang == "he" or current_lang == "fa"
end

pcall(M.load)
return M