local C = RefactorCompareInternal
local Print = C.Print
local CopyTable = C.CopyTable
local MergeDefaults = C.MergeDefaults
local ActiveProfile = C.ActiveProfile
local Weights = C.Weights
local CharKey = C.CharKey
local SetActiveProfile = C.SetActiveProfile
local STATS = C.STATS
local DEFAULTS = C.DEFAULTS
local DEFAULT_WEIGHTS = C.DEFAULT_WEIGHTS
local CLASS_SPEC_WEIGHTS = C.CLASS_SPEC_WEIGHTS
local NormalizeClassKey = C.NormalizeClassKey
local AutoApplyClassSpec = C.AutoApplyClassSpec
local WipeScanCache = C.WipeScanCache
local WipeInstanceScans = C.WipeInstanceScans
local scanCache = C.scanCache
local verdictCache = C.verdictCache
local HitCapMode = C.HitCapMode
local HitCapPvP = C.HitCapPvP
local HitCapType = C.HitCapType
local HitCapRating = C.HitCapRating
local HitRatingPerPct = C.HitRatingPerPct
local CurrentHitRating = C.CurrentHitRating
local HITCAP_PCT = C.HITCAP_PCT
local HITCAP_PCT_PVP = C.HITCAP_PCT_PVP
local OnLootMessage = C.OnLootMessage

--------------------------------------------------------------------------
-- Config panel — the window itself lives in RefactorUI.lua
--------------------------------------------------------------------------

function C.RefreshConfig()
    if RefactorUI and RefactorUI.Refresh then RefactorUI.Refresh() end
end

local function SaveProfileAs(name)
    RefactorCompareDB.profiles[name] = CopyTable(ActiveProfile())
    SetActiveProfile(name)
    Print("Saved profile '" .. name .. "'.")
    C.RefreshConfig()
end

-- User-facing setter for the secondary (blue) verdict profile — config
-- window and /rfc secondary. nil/false turns the feature off for this
-- character. RefreshOpenBags bumps the memo generation: every cached
-- verdict's .secondary field goes stale the moment this changes.
local function SetSecondaryProfile(name)
    if name and not RefactorCompareDB.profiles[name] then
        Print("no profile named '" .. name .. "'.")
        return
    end
    RefactorCompareDB.charSecondaryProfile[CharKey()] = name or nil
    C.RefreshOpenBags()
    C.RefreshConfig()
    if name then
        Print("secondary verdict profile set to '" .. name .. "'.")
    else
        Print("secondary verdict profile off.")
    end
end

local function DeleteProfile(name)
    if name == "Default" then
        Print("Can't delete the Default profile.")
    elseif RefactorCompareDB.profiles[name] then
        RefactorCompareDB.profiles[name] = nil
        if RefactorCompareDB.activeProfile == name then SetActiveProfile("Default") end
        -- Characters showing it as their secondary verdict lose that too.
        for k, v in pairs(RefactorCompareDB.charSecondaryProfile) do
            if v == name then RefactorCompareDB.charSecondaryProfile[k] = nil end
        end
        Print("Deleted profile '" .. name .. "'.")
        C.RefreshOpenBags()
        C.RefreshConfig()
    end
end

-- Hit-cap mode setter for the config window / slash: "off" | "melee" |
-- "ranged" | "spell" | "custom", stored per profile. Bumps the memo
-- generation so open tooltips and bag arrows re-score against the cap
-- immediately.
local function SetHitCapMode(mode)
    if mode ~= "melee" and mode ~= "ranged" and mode ~= "spell" and mode ~= "custom" then mode = "off" end
    local p = ActiveProfile()
    p.hitCap = p.hitCap or {}
    p.hitCap.mode = mode
    C.RefreshOpenBags()
    C.RefreshConfig()
    return mode
end

local function SetHitCapPvP(enabled)
    local p = ActiveProfile()
    p.hitCap = p.hitCap or {}
    p.hitCap.pvp = enabled and true or nil
    C.RefreshOpenBags()
    C.RefreshConfig()
end

-- Rating type "custom" mode targets — separate from the mode itself since
-- the player still needs to say which combat table (melee/ranged/spell)
-- their typed rating applies to.
local function SetHitCapCustomType(type_)
    if type_ ~= "melee" and type_ ~= "ranged" and type_ ~= "spell" then type_ = "melee" end
    local p = ActiveProfile()
    p.hitCap = p.hitCap or {}
    p.hitCap.customType = type_
    C.RefreshOpenBags()
    C.RefreshConfig()
end

-- Player-typed target rating for "custom" mode — bypasses the built-in
-- %→rating table entirely, so talent/racial flat-% hit (never counted by
-- the fixed melee/ranged/spell % constants) can be folded in by hand.
local function SetHitCapCustomRating(rating)
    rating = tonumber(rating)
    local p = ActiveProfile()
    p.hitCap = p.hitCap or {}
    p.hitCap.customRating = (rating and rating > 0) and rating or nil
    C.RefreshOpenBags()
    C.RefreshConfig()
end

RefactorCompareShared.SaveProfileAs = SaveProfileAs
RefactorCompareShared.DeleteProfile = DeleteProfile
RefactorCompareShared.SetSecondaryProfile = SetSecondaryProfile
RefactorCompareShared.SetHitCapMode = SetHitCapMode
RefactorCompareShared.GetHitCapMode = function()
    return HitCapMode(ActiveProfile())
end
RefactorCompareShared.SetHitCapPvP = SetHitCapPvP
RefactorCompareShared.GetHitCapPvP = function()
    return HitCapPvP(ActiveProfile())
end
RefactorCompareShared.SetHitCapCustomType = SetHitCapCustomType
RefactorCompareShared.GetHitCapCustomType = function()
    return HitCapType(ActiveProfile())
end
RefactorCompareShared.SetHitCapCustomRating = SetHitCapCustomRating
RefactorCompareShared.GetHitCapCustomRating = function()
    local p = ActiveProfile()
    return p.hitCap and p.hitCap.customRating
end
-- Live readout for the config window: current hit rating, the cap rating, and
-- the target %. cap is nil when the rating→% ratio isn't derivable yet (no hit
-- worn and none cached) — the UI shows "—" then.
RefactorCompareShared.HitCapInfo = function()
    local p = ActiveProfile()
    local mode = HitCapMode(p)
    if mode == "off" then return { mode = "off" } end
    if mode == "custom" then
        -- No fixed %/PvE-PvP pair to report here — the player typed the
        -- rating directly, so just the current/cap rating readout applies.
        local type_ = HitCapType(p)
        return { mode = mode, current = CurrentHitRating(type_), cap = HitCapRating(p) }
    end
    local pvp = HitCapPvP(p)
    local cap = HitCapRating(p)
    local ratio = HitRatingPerPct(mode)
    local activePct = pvp and HITCAP_PCT_PVP[mode] or HITCAP_PCT[mode]
    local refPct = pvp and HITCAP_PCT[mode] or HITCAP_PCT_PVP[mode]
    local refCap = ratio and (refPct * ratio) or nil
    return { mode = mode, pvp = pvp, current = CurrentHitRating(mode),
        cap = cap, pct = activePct,
        refCap = refCap, refPct = refPct }
end
-- Raw saved pick (name or nil) for the config window's dropdown display;
-- unlike SecondaryProfile() this reports the setting even while it names
-- the active profile or a deleted one.
RefactorCompareShared.SecondaryProfileName = function()
    return RefactorCompareDB.charSecondaryProfile[CharKey()]
end

-- Renames a hand-made profile in place and points every character's
-- remembered pick (last-active, auto-applied, deliberate choice) at the
-- new name, so alts don't lose it. Two names refuse: Default anchors the
-- fallback path, and class-spec profiles are found BY NAME by
-- auto-selection and the spec picker — renaming one would only make it
-- regenerate from defaults under the old name.
RefactorCompareShared.RenameProfile = function(old, new)
    new = new and new:match("^%s*(.-)%s*$") or ""
    if new == "" or new == old or not RefactorCompareDB.profiles[old] then return end
    if old == "Default" then
        Print("Can't rename the Default profile.")
        return
    end
    local classPart, specPart = old:match("^(.-) %- (.+)$")
    local specList = classPart and CLASS_SPEC_WEIGHTS[NormalizeClassKey(classPart)]
    if specList then
        local wanted = specPart:lower():gsub(" ", "_")
        for _, specEntry in ipairs(specList) do
            if specEntry.name:lower() == wanted then
                Print("'" .. old .. "' is a class-spec profile — auto-selection finds "
                    .. "it by this exact name. Use 'Save as' to make a copy you can "
                    .. "name freely.")
                return
            end
        end
    end
    if RefactorCompareDB.profiles[new] then
        Print("A profile named '" .. new .. "' already exists.")
        return
    end
    RefactorCompareDB.profiles[new] = RefactorCompareDB.profiles[old]
    RefactorCompareDB.profiles[old] = nil
    if RefactorCompareDB.activeProfile == old then RefactorCompareDB.activeProfile = new end
    for _, map in ipairs({ RefactorCompareDB.charProfiles, RefactorCompareDB.charAutoProfile, RefactorCompareDB.charManualProfile,
        RefactorCompareDB.charSecondaryProfile }) do
        for k, v in pairs(map) do
            if v == old then map[k] = new end
        end
    end
    Print("Renamed profile '" .. old .. "' to '" .. new .. "'.")
    C.RefreshConfig()
end

-- Opens/closes the RefactorUI window (RefactorUI.lua, loaded after this
-- file). The guard only matters if that file failed to load.
local function ToggleConfig()
    if RefactorUI and RefactorUI.Toggle then
        RefactorUI.Toggle()
    else
        Print("config window failed to load — check RefactorUI.lua.")
    end
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_REFACTORCOMPARE1 = "/rfc"
SLASH_REFACTORCOMPARE2 = "/refactorcompare"
SLASH_REFACTORCOMPARE3 = "/refactor"
SlashCmdList.REFACTORCOMPARE = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "" then
        ToggleConfig()
    elseif cmd == "toggle" then
        RefactorCompareDB.enabled = not RefactorCompareDB.enabled
        C.RefreshOpenBags()
        Print("gear compare " .. (RefactorCompareDB.enabled and "|cff00ff00enabled|r" or "|cffff4040disabled|r") .. ".")
    elseif cmd == "alert" then
        RefactorCompareDB.lootAlert = not RefactorCompareDB.lootAlert
        Print("loot alerts " .. (RefactorCompareDB.lootAlert and "on" or "off") .. ".")
    elseif cmd == "bagicons" then
        RefactorCompareDB.bagIcons = not RefactorCompareDB.bagIcons
        C.RefreshOpenBags()
        Print("bag upgrade icons " .. (RefactorCompareDB.bagIcons and "on" or "off") .. ".")
    elseif cmd == "auto" then
        -- Forget this character's manual profile choice and hand control
        -- back to class/spec auto-selection. Armor types are deliberately
        -- untouched: nothing auto-selects them any more, so there is no
        -- automation to hand back to (see 02_classspec.lua).
        RefactorCompareDB.charManualProfile[CharKey()] = nil
        AutoApplyClassSpec()
        C.RefreshOpenBags()
        C.RefreshConfig()
        Print("profile auto-selection re-enabled (now: '" .. RefactorCompareDB.activeProfile .. "').")
    elseif cmd == "debug" then
        RefactorCompareDB.debug = not RefactorCompareDB.debug
        Print("debug " .. (RefactorCompareDB.debug and "on — hover an item to see red-line detection" or "off") .. ".")
    elseif cmd == "quality" then
        local q = tonumber(rest)
        if q then
            RefactorCompareDB.minQuality = math.max(0, math.min(5, math.floor(q)))
            C.RefreshOpenBags()
            C.RefreshConfig()
            Print("minimum quality set to " .. RefactorCompareDB.minQuality .. ".")
        else
            Print("usage: /rfc quality <0-5>")
        end
    elseif cmd == "weight" then
        -- Last token is the value, everything before it is the stat name
        -- (custom stat names can contain spaces).
        local name, value = rest:match("^(.-)%s+([%d%.%-]+)$")
        value = tonumber(value)
        if not name or name == "" or not value then
            Print("usage: /rfc weight <stat> <value>")
            return
        end
        local lname = name:lower()
        for _, s in ipairs(STATS) do
            if s.key:lower() == lname or s.label:lower() == lname then
                Weights()[s.key] = value
                C.RefreshOpenBags()
                C.RefreshConfig()
                Print(s.label .. " weight set to " .. value .. ".")
                return
            end
        end
        ActiveProfile().customWeights[lname] = value
        -- Verdicts move with the weight: refresh (and bump the memo
        -- generation) like the standard-stat branch above does — without
        -- this the verdict/equipped memos keep serving old-weight scores.
        C.RefreshOpenBags()
        C.RefreshConfig()
        Print("custom stat '" .. lname .. "' weight set to " .. value .. ".")
    elseif cmd == "secondary" then
        local name = rest:match("^%s*(.-)%s*$")
        if name == "" then
            local cur = RefactorCompareDB.charSecondaryProfile[CharKey()]
            Print(cur and ("secondary verdict profile: '" .. cur .. "'.")
                or "no secondary verdict profile set. /rfc secondary <name> to set one.")
        elseif name:lower() == "off" or name:lower() == "none" then
            SetSecondaryProfile(nil)
        else
            SetSecondaryProfile(name)
        end
    elseif cmd == "hitcap" then
        local mode = rest:match("^%s*(%S*)"):lower()
        if mode == "pvp" then
            local p = ActiveProfile()
            SetHitCapPvP(not HitCapPvP(p))
            local pvp = HitCapPvP(ActiveProfile())
            Print("hit cap target: " .. (pvp and "PvP (never miss a player)"
                or "PvE (never miss a raid boss)") .. ".")
        elseif mode == "off" or mode == "melee" or mode == "ranged" or mode == "spell" then
            SetHitCapMode(mode)
            if mode == "off" then
                Print("hit cap off for profile '" .. RefactorCompareDB.activeProfile .. "'.")
            else
                local info = RefactorCompareShared.HitCapInfo()
                local target = info.pvp and "PvP" or "PvE"
                Print("hit cap set to " .. mode .. " " .. target .. " (" .. (info.pct or "?") .. "%) for profile '"
                    .. RefactorCompareDB.activeProfile .. "'"
                    .. (info.cap and (": " .. info.current .. "/" .. math.floor(info.cap + 0.5) .. " rating")
                        or " (cap unknown until you have some hit)") .. ".")
            end
        else
            Print("usage: /rfc hitcap <off|melee|ranged|spell|pvp>")
        end
    elseif cmd == "profile" then
        local sub, name = rest:match("^(%S*)%s*(.-)$")
        local subl = sub:lower()
        if subl == "list" then
            local names = {}
            for n in pairs(RefactorCompareDB.profiles) do tinsert(names, n) end
            table.sort(names)
            Print("profiles: " .. table.concat(names, ", ")
                .. " (active: " .. RefactorCompareDB.activeProfile .. ")")
        elseif subl == "save" and name ~= "" then
            SaveProfileAs(name)
        elseif subl == "delete" and name ~= "" then
            if RefactorCompareDB.profiles[name] then
                DeleteProfile(name)
            else
                Print("no profile named '" .. name .. "'.")
            end
        elseif sub ~= "" and name == "" then
            if RefactorCompareDB.profiles[sub] then
                SetActiveProfile(sub)
                C.RefreshOpenBags()
                C.RefreshConfig()
                Print("switched to profile '" .. sub .. "'.")
            else
                Print("no profile named '" .. sub .. "'. /rfc profile save " .. sub .. " to create it.")
            end
        else
            Print("usage: /rfc profile <name> | save <name> | delete <name> | list")
        end
    else
        Print("commands: /rfc (config), toggle, alert, bagicons, auto, debug, quality <n>, weight <stat> <n>, hitcap <off|melee|ranged|spell|pvp>, profile ..., secondary <name|off>")
    end
end

--------------------------------------------------------------------------
-- Init & events
--------------------------------------------------------------------------

-- UNIT_INVENTORY_CHANGED and BAG_UPDATE fire in bursts (one equip raises
-- several of each). Wiping the scan cache and re-evaluating every open
-- bag once PER EVENT was the addon's biggest frame-time spike — with a
-- Bagnon wall of 100+ slots, each event cost 100+ hidden-tooltip renders.
-- Instead: mark what went stale, flush once shortly after the burst ends.
-- (Smart equip keeps its own immediate event frame — it must react the
-- moment the engine's swap settles, and it does no scanning of its own.)
local refreshFrame = CreateFrame("Frame")
refreshFrame:Hide()
local refreshElapsed = 0
local invDirty = false -- equipped gear changed: every instance scan is suspect
local dirtyBags = {}   -- [bagID] = true: that bag's instance scans are stale
local REFRESH_DEBOUNCE = 0.15

-- Cache-key prefixes per bag id, built once at load. Bag ids are the fixed
-- 0..NUM_BAG_SLOTS range (the BAG_UPDATE handler below rejects anything
-- else), so the sweep never has to build a prefix string at flush time.
-- scanCache keys look like "b:<bag>:<slot>:<link>"; verdictCache keys drop
-- the marker and are just "<bag>:<slot>:<link>".
local SCAN_BAG_PREFIX, VERDICT_BAG_PREFIX = {}, {}
for b = 0, (NUM_BAG_SLOTS or 4) do
    SCAN_BAG_PREFIX[b] = "b:" .. b .. ":"
    VERDICT_BAG_PREFIX[b] = b .. ":"
end

-- Scratch lists reused across flushes, so a sweep allocates nothing at all.
local scanPrefixes, verdictPrefixes = {}, {}
local strfind = string.find

refreshFrame:SetScript("OnUpdate", function(self, elapsed)
    refreshElapsed = refreshElapsed + elapsed
    if refreshElapsed < REFRESH_DEBOUNCE then return end
    self:Hide()

    if invDirty then
        -- Equipping can rescale items; drop all live scans so the refresh
        -- compares against what's actually worn now. Every entry carrying an
        -- `expires` stamp IS an instance scan, so this also clears the whole
        -- expiry backlog — no separate sweep needed on this branch.
        WipeInstanceScans()
        invDirty = false
        for k in pairs(dirtyBags) do dirtyBags[k] = nil end
        C.RefreshOpenBags()
        return
    end

    -- Bag-only change: a same-link different-instance copy can land in a
    -- slot whose scan is still cached, so drop just those bags' scans —
    -- folded into the same pass as the expiry sweep for quest-reward "q:"
    -- and loot-window "ls:" keys, which no event ever deletes.
    --
    -- One walk of scanCache instead of one per dirty bag, and the prefix
    -- test is plain strfind rather than k:sub(1, #prefix) == prefix: sub()
    -- built a throwaway substring for every key on every flush, which with a
    -- few hundred cached scans and a bag-update burst was the biggest single
    -- source of garbage in this file.
    local now = GetTime()
    local n = 0
    for bagID in pairs(dirtyBags) do
        local sp = SCAN_BAG_PREFIX[bagID]
        if sp then
            n = n + 1
            scanPrefixes[n] = sp
            verdictPrefixes[n] = VERDICT_BAG_PREFIX[bagID]
        end
    end

    for k, v in pairs(scanCache) do
        local drop = v.expires and v.expires < now
        if not drop then
            for i = 1, n do
                if strfind(k, scanPrefixes[i], 1, true) == 1 then
                    drop = true
                    break
                end
            end
        end
        if drop then scanCache[k] = nil end
    end

    -- Bag-only: equipped gear and weights are unchanged, so the
    -- equipped-score memos and every untouched bag's verdicts are still
    -- exact. Drop only the dirty bags' verdict entries and redraw — clean
    -- slots answer from the warm memos instead of re-running the whole scan
    -- pipeline (a one-slot loot into a 100-slot bag wall used to recompute
    -- all 100).
    for k in pairs(verdictCache) do
        for i = 1, n do
            if strfind(k, verdictPrefixes[i], 1, true) == 1 then
                verdictCache[k] = nil
                break
            end
        end
    end

    for i = 1, n do
        scanPrefixes[i] = nil
        verdictPrefixes[i] = nil
    end
    for k in pairs(dirtyBags) do dirtyBags[k] = nil end
    C.RedrawBags()
end)

local function QueueRefresh()
    refreshElapsed = 0 -- true debounce: the burst's last event restarts the clock
    refreshFrame:Show()
end

-- Expiry backstop for instance scans with no owning event.
--
-- The flush above only runs when a bag or equip event queues it, so the
-- expiry sweep rode entirely on the player touching their inventory. Keys
-- from sources that raise no bag event — merchant ("m:"/"bb:"), quest
-- rewards ("q:"), the loot window ("ls:") — accumulated for as long as the
-- player browsed without looting or equipping anything. They were correct
-- (each carries an `expires` stamp, so nothing stale was ever served) but
-- nothing reclaimed them.
--
-- A 5s ticker that only runs while the table is non-empty, self-stopping
-- when it empties, so an idle session pays nothing. Deliberately slow: this
-- reclaims memory, it does not affect correctness, and the flush still does
-- the bulk of the work whenever the player actually plays.
local sweepFrame = CreateFrame("Frame")
sweepFrame:Hide()
local sweepElapsed = 0
local SWEEP_INTERVAL = 5

sweepFrame:SetScript("OnUpdate", function(self, elapsed)
    sweepElapsed = sweepElapsed + elapsed
    if sweepElapsed < SWEEP_INTERVAL then return end
    sweepElapsed = 0
    local now = GetTime()
    local remaining = 0
    for k, v in pairs(scanCache) do
        if v.expires then
            if v.expires < now then
                scanCache[k] = nil
            else
                remaining = remaining + 1
            end
        end
    end
    -- Only expiring ("instance") entries need watching; "h:" base scans are
    -- static and capped separately by H_SCAN_CAP.
    if remaining == 0 then self:Hide() end
end)

C.QueueScanSweep = function()
    sweepElapsed = 0
    sweepFrame:Show()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        -- Bagnon/DragonUI/AdiBags/ElvUI can load before or after this
        -- addon; try the hooks on every load until they stick (no-op once
        -- hooked or if absent).
        C.TryHookBagnon()
        C.TryHookDragonUI()
        C.TryHookAdiBags()
        C.TryHookElvUI()
        if arg1 ~= "Refactor" then return end
        local firstRun = type(RefactorCompareDB) ~= "table"
        if firstRun then RefactorCompareDB = {} end
        if firstRun then
            Print("gear compare loaded — weights are auto-picked from your class and spec, type |cffffff00/rfc|r to fine-tune.")
        end
        MergeDefaults(RefactorCompareDB, DEFAULTS)
        for _, profile in pairs(RefactorCompareDB.profiles) do
            if type(profile.weights) ~= "table" then profile.weights = {} end
            if type(profile.customWeights) ~= "table" then profile.customWeights = {} end
            MergeDefaults(profile.weights, DEFAULT_WEIGHTS)
        end
        -- Recall this character's own last profile choice rather than
        -- inheriting whatever the last-played alt left active. Falls
        -- through to whatever's already active (or Default) the first
        -- time a character is seen, and records it so it sticks from
        -- here on.
        local remembered = RefactorCompareDB.charProfiles[CharKey()]
        if remembered and RefactorCompareDB.profiles[remembered] then
            RefactorCompareDB.activeProfile = remembered
        end
    elseif event == "CHAT_MSG_LOOT" then
        OnLootMessage(arg1)
    elseif event == "START_LOOT_ROLL" then
        -- FrameXML's own handler opened the roll frame before this one
        -- runs (it registered first); mark the icon if it's an upgrade.
        C.StartRollUpdates()
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        C.UpdateMerchantArrows()
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then
            invDirty = true
            QueueRefresh()
        end
    elseif event == "BAG_UPDATE" then
        -- Player bags only; bank (-1, 5+) has no arrows or live scans.
        if type(arg1) == "number" and arg1 >= 0 and arg1 <= NUM_BAG_SLOTS then
            dirtyBags[arg1] = true
            QueueRefresh()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- Scaled item stats change with level; cached scans are stale.
        WipeScanCache()
        C.RefreshOpenBags()
        -- Spec unlocks at level 10 — re-detect in case the placeholder
        -- default (the class's first spec) needs correcting now.
        AutoApplyClassSpec()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_TALENT_UPDATE"
        or event == "ASCENSION_KNOWN_ENTRIES_UPDATED"
        or event == "ASCENSION_KNOWN_ENTRIES_CHANGED" then
        local before = RefactorCompareDB and RefactorCompareDB.activeProfile
        AutoApplyClassSpec()
        if RefactorCompareDB and RefactorCompareDB.activeProfile ~= before then C.RefreshOpenBags() end
    end
end)
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
-- Ascension custom events: fire when Character Advancement entries
-- (CoA talents/abilities) change — the CA system doesn't reliably raise
-- PLAYER_TALENT_UPDATE. Unknown event names are a harmless no-op on
-- clients that lack them.
pcall(eventFrame.RegisterEvent, eventFrame, "ASCENSION_KNOWN_ENTRIES_UPDATED")
pcall(eventFrame.RegisterEvent, eventFrame, "ASCENSION_KNOWN_ENTRIES_CHANGED")
