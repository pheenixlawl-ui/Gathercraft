local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Translations
--   Texts are written in English in the code; L["English text"] gives the
--   text in the chosen language (Options > Language), English if missing.
--   Each language file (Locales/xxXX.lua) fills ns.Locales.xxXX.
--   ns.LText(fontString, "English text") also remembers the text, so a
--   language change can redo every label without a reload.
---------------------------------------------------------------------------
ns.Locales = ns.Locales or {}

ns.LANGUAGES = {
    { code = "auto", name = "Auto (game language)" },
    { code = "enUS", name = "English" },
    { code = "deDE", name = "Deutsch" },
    { code = "frFR", name = "Français" },
    { code = "esES", name = "Español" },
    { code = "ptBR", name = "Português" },
    { code = "itIT", name = "Italiano" },
    -- these need the game's own fonts: only offered in a client of that language
    { code = "ruRU", name = "Русский", ownFont = true },
    { code = "koKR", name = "한국어", ownFont = true },
    { code = "zhCN", name = "简体中文", ownFont = true },
    { code = "zhTW", name = "繁體中文", ownFont = true },
}

local ALIASES = { enGB = "enUS", esMX = "esES" }

local function GameLanguage()
    local loc = GetLocale and GetLocale() or "enUS"
    return ALIASES[loc] or loc
end

-- the languages this client can show
function ns.UsableLanguages()
    local out, game = {}, GameLanguage()
    for _, lang in ipairs(ns.LANGUAGES) do
        if not lang.ownFont or lang.code == game then out[#out + 1] = lang end
    end
    return out
end

-- the language in use: the saved choice, else the game's
function ns.Language()
    local choice = ns.db and ns.db.language
    if choice and choice ~= "auto" then
        for _, lang in ipairs(ns.LANGUAGES) do
            -- a language this client has no letters for: stay with the game's
            if lang.code == choice and lang.ownFont and choice ~= GameLanguage() then return GameLanguage() end
        end
        return choice
    end
    return GameLanguage()
end

local current, dict
local function Dict()
    local lang = ns.Language()
    if lang ~= current then
        current, dict = lang, ns.Locales[lang]
    end
    return dict
end

ns.L = setmetatable({}, {
    __index = function(_, key)
        local d = Dict()
        return (d and d[key]) or key
    end,
})

-- Labels that are set once: remembered with their English text
local registered = setmetatable({}, { __mode = "k" })
function ns.LText(obj, key, ...)
    if not obj then return end
    registered[obj] = { key, select("#", ...) > 0 and { ... } or nil }
    local text = ns.L[key]
    if select("#", ...) > 0 then text = text:format(...) end
    obj:SetText(text)
end

-- redo every remembered label (after the saved choice is known, or a change)
function ns.ApplyLanguage()
    current = nil
    for obj, entry in pairs(registered) do
        local text = ns.L[entry[1]]
        if entry[2] then text = text:format(unpack(entry[2])) end
        obj:SetText(text)
    end
    for _, fn in ipairs(ns.languageListeners or {}) do pcall(fn) end
end
ns.languageListeners = ns.languageListeners or {}

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON_NAME then return end
    self:UnregisterEvent("ADDON_LOADED")
    -- Core.lua has set ns.db by now (it registered first)
    C_Timer.After(0, function()
        if ns.db and ns.db.language and ns.db.language ~= "auto" and ns.db.language ~= GameLanguage() then
            ns.ApplyLanguage()
        end
    end)
end)
