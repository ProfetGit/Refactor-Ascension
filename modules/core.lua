-- Refactor: core
-- QoL flag storage (RefactorCompareDB.qol) shared by every Refactor module,
-- plus the small bootstrap bits other modules depend on: the fast-loot CVar
-- reconciler, the error-speech CVar, and the shared chat Announce() helper.
-- Must load before every other Refactor .lua module (see Refactor.toc).

local qdb -- RefactorCompareDB.qol once saved variables exist

local QOL_DEFAULTS = {
    -- Collecting an appearance soulbinds the item, so auto-collect ships
    -- OFF: silently destroying the sale value of a BoE is not an acceptable
    -- surprise default. transmogBoE additionally gates unbound items even
    -- when auto-collect is opted into.
    transmog = false,      -- auto-collect appearances from bags (bound items only)
    transmogBoE = false,   -- ...including unbound (BoE/tradeable) items
    transmogSkipConfirm = false, -- auto-accept the manual-learn confirm popup
    cursorTooltip = true,  -- anchor default tooltip beside the cursor
    hideHealthBar = true,  -- hide the unit tooltip health bar
    qualityBorder = true,  -- color tooltip border by item quality
    autoConfirmBoP = true, -- skip "will bind it to you" popups
    fastLoot = true,       -- instant loot, hidden loot window
    questAccept = false,   -- auto-accept quest offers and escort confirmations
    questTurnIn = false,   -- auto-complete quests (multi-choice rewards stay open)
    questGossip = false,   -- auto-pick quest entries from NPC gossip menus
    -- Picking a quest reward is irreversible, so this ships off and refuses
    -- to act on anything it can't fully read (see modules/quest.lua).
    questAutoReward = false, -- auto-pick the best reward choice (upgrade, else most gold)
    hideErrorText = true,  -- hide red UI error text ("Ability is not ready yet")
    muteErrorSpeech = true,-- silence "I can't do that yet" voice errors
    -- Companion to the silent-sound client patch (loose files under the
    -- game root's Sound\ folder, see CLAUDE.md): with the patch the engine
    -- always plays silence for cast-deny sounds, and while this flag is OFF
    -- the addon replays bundled copies of the originals — so the checkbox
    -- reads as a mute: ticked = silence, unticked = sounds back. Defaults
    -- to muted, the state the patch exists to provide. Without the patch
    -- the engine sound still plays and unticking doubles it.
    muteDenySounds = true, -- silence fizzle/error sounds on denied casts
    -- Social auto-declines ship off: silently refusing invites/trades is a
    -- choice the player should make, not a surprise default.
    declineInvites = false,-- decline every party invite
    declineDuels = false,  -- cancel duel requests
    declineGuilds = false, -- decline guild invites
    declineTrades = false, -- close trades from non-friend/guild/group players
    autoResBG = false,     -- accept player resurrections inside battlegrounds
    quickInvite = false,   -- Alt + Right-Click: quick invite player
    leavePartyOnDungeon = false, -- also leave party when clicking Leave Dungeon
    -- Moves items and equips a bag on your behalf when your bag slots are
    -- full; on by default per user request.
    seamlessBagUpgrade = true, -- right-click a bag: auto-swap in the smallest equipped bag
    -- Merchant automations ship off: auto-sell is irreversible for the
    -- duration of the buyback window and auto-repair spends gold, so both
    -- are explicit opt-ins. Holding Shift while opening the merchant skips
    -- them (the same "Shift = manual" convention as loot and quests).
    -- Auto-repair uses YOUR money only, never the guild bank's.
    autoRepair = false,    -- repair all gear when opening a repair merchant
    autoSellTrash = false, -- sell all poor-quality (gray) items on merchant open
    versionCheck = true,   -- chat notice when a guild/groupmate runs a newer version
}

local function ApplyFastLootCVar()
    -- Written both ways: only ever setting "1" left the engine
    -- auto-looting (shift-inverted) after the flag was unticked.
    local v = Qol("fastLoot") and "1" or "0"
    -- Recorded BEFORE the write: SetCVar fires CVAR_UPDATE synchronously,
    -- and the reconciler below must not treat our own write as external.
    if qdb then qdb.fastLootCVar = v end
    SetCVar("autoLootDefault", v)
end

-- The game's own Auto Loot option shares the autoLootDefault CVar, and
-- turning it off there must stick: fast loot can't work without engine
-- auto-loot, and previously the next /reload stomped the game setting
-- back on. The addon records every value it writes (qdb.fastLootCVar);
-- any mismatch on login or CVAR_UPDATE means the change came from outside
-- (Interface options, /console, another addon), so external OFF wins:
-- fast loot turns off with it. Never the reverse — enabling Auto Loot in
-- the game options doesn't force fast loot on (plain auto-loot with a
-- visible window is a legitimate combo); that's the /rfc checkbox's job.
local function ReconcileFastLootCVar()
    if not qdb then return end
    local current = GetCVar("autoLootDefault")
    if qdb.fastLootCVar == nil then
        -- First run since this tracking existed: adopt the flag (fresh
        -- installs and everyone upgrading), preserving the out-of-the-box
        -- behavior. Caveat: if Auto Loot was disabled in the game settings
        -- right before updating, it's stomped this one last time — after
        -- this, external changes stick.
        ApplyFastLootCVar()
        return
    end
    if current == qdb.fastLootCVar then return end
    qdb.fastLootCVar = current
    if current == "0" and qdb.fastLoot then
        qdb.fastLoot = false
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r fast auto-loot" ..
            " turned off along with the game's Auto Loot setting." ..
            " Re-enable it in /rfc -> Tweaks.")
        if RefactorUI and RefactorUI.Refresh then RefactorUI.Refresh() end
    end
end

local fastLootCVarWatcher = CreateFrame("Frame")
fastLootCVarWatcher:RegisterEvent("CVAR_UPDATE")
fastLootCVarWatcher:SetScript("OnEvent", ReconcileFastLootCVar)

local function InitQol()
    if qdb or type(RefactorCompareDB) ~= "table" then return end
    if type(RefactorCompareDB.qol) ~= "table" then RefactorCompareDB.qol = {} end
    qdb = RefactorCompareDB.qol
    for k, v in pairs(QOL_DEFAULTS) do
        if qdb[k] == nil then qdb[k] = v end
    end
    -- One-time migration: auto-collect used to default ON, and collecting
    -- soulbinds the item — players lost sellable BoEs to a default they
    -- never chose. Force it off once for saves from those versions; turning
    -- it back on is an explicit choice in /rfc -> Tweaks from now on.
    if not RefactorCompareDB.migratedTransmogOff then
        RefactorCompareDB.migratedTransmogOff = true
        if qdb.transmog then
            qdb.transmog = false
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r auto transmog" ..
                " collection is now OFF by default: collecting an appearance" ..
                " soulbinds the item, which destroys BoE sale value. Re-enable" ..
                " it in /rfc -> Tweaks (bound items only, unless you also allow" ..
                " tradeable items).")
        end
    end
    ReconcileFastLootCVar()
end

-- Qol is a genuine Lua global (not a file-local upvalue): every other
-- Refactor module calls it directly as Qol("key"), the same bare call-site
-- syntax the original monolithic Refactor.lua used internally. This file
-- loads first (see Refactor.toc), so the global is always assigned before
-- any other module's runtime code can call it.
function Qol(key)
    if qdb and qdb[key] ~= nil then return qdb[key] end
    return QOL_DEFAULTS[key]
end

-- Voice errors ("I can't do that yet") are played by the sound engine, not
-- the UI, so there's nothing to intercept per-message — the only switch is
-- the Sound_EnableErrorSpeech CVar. Written at login and whenever the
-- checkbox changes (a CVar is client-wide, so it must track the flag).
local function ApplyErrorSpeech()
    SetCVar("Sound_EnableErrorSpeech", Qol("muteErrorSpeech") and 0 or 1)
end

-- Every auto-handled request across the QoL modules (social.lua,
-- version_check.lua) prints one chat line via this — a plain global so any
-- module can call it without a Shared table round trip.
function Announce(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r " .. msg)
end

-- Shared with RefactorUI.lua (the config window).
RefactorQoL = {
    Get = Qol,
    Set = function(key, value)
        InitQol()
        if qdb then qdb[key] = value and true or false end
        if key == "muteErrorSpeech" then ApplyErrorSpeech() end
        if key == "fastLoot" then ApplyFastLootCVar() end
    end,
    -- Restores every QoL flag to its shipped default. Position saves
    -- (minimap button, CC alert) live outside qol and are untouched.
    ResetDefaults = function()
        InitQol()
        if not qdb then return end
        for k in pairs(qdb) do qdb[k] = nil end
        for k, v in pairs(QOL_DEFAULTS) do qdb[k] = v end
        ApplyErrorSpeech()
        ApplyFastLootCVar()
    end,
    -- Flips every QoL flag off in one click, so the player can then opt
    -- back into individual tweaks one at a time (the Pawn-style workflow
    -- this button exists for) instead of hunting down each one to disable.
    DisableAll = function()
        InitQol()
        if not qdb then return end
        for k in pairs(QOL_DEFAULTS) do qdb[k] = false end
        ApplyErrorSpeech()
        ApplyFastLootCVar()
    end,
}

-- Bootstraps everything above once saved variables exist: this file loads
-- before RefactorCompare.lua creates RefactorCompareDB, so QoL init happens
-- at PLAYER_ENTERING_WORLD, not install time.
local core = CreateFrame("Frame")
core:RegisterEvent("PLAYER_ENTERING_WORLD")
core:SetScript("OnEvent", function()
    InitQol() -- saved variables (and RefactorCompare's init) are done by now
    ApplyErrorSpeech()
    -- The friends list is empty client-side until the server sends it;
    -- request it now so social.lua's trade-window whitelist can check it.
    ShowFriends()
end)
