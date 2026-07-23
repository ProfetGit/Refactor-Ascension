-- Refactor: error text/sound
-- Hides the red UI error text ("Ability is not ready yet" etc.) and mutes
-- the cast-deny fizzle sounds (companion to the silent client patch, see
-- CLAUDE.md).

-- Cast-deny fizzles (on not-ready spam and on not-enough-resource — the
-- engine plays the spell school's fizzle for both) come from sound files —
-- the Lua API has no per-sound mute on this client, so they're silenced by
-- the client patch (silent loose files in the game root's Sound\ folder).
-- While muteDenySounds is off, the addon replays a bundled original on the
-- matching error events, giving an in-game mute toggle: patch installed +
-- flag on = silence, flag off = sound back, instantly, no restart. The
-- error text carries no spell school, so the replay is always the holy
-- variant rather than varying by school like the engine did.
local DENY_LINES = {}
local function AddDeny(s)
    if type(s) == "string" then DENY_LINES[s] = true end
end
AddDeny(SPELL_FAILED_NOT_READY)         -- "Ability is not ready yet"
AddDeny(SPELL_FAILED_SPELL_IN_PROGRESS) -- "Another action is in progress"
AddDeny(ERR_SPELL_COOLDOWN)             -- "Spell is not ready yet."
AddDeny(ERR_ABILITY_COOLDOWN)           -- "Ability is not ready yet."
AddDeny(ERR_ITEM_COOLDOWN)              -- "Item is not ready yet."
AddDeny(ERR_OUT_OF_MANA)                -- "Not enough mana"
AddDeny(ERR_OUT_OF_RAGE)                -- "Not enough rage"
AddDeny(ERR_OUT_OF_ENERGY)              -- "Not enough energy"
AddDeny(ERR_OUT_OF_FOCUS)               -- "Not enough focus"
AddDeny(ERR_OUT_OF_RUNIC_POWER)         -- "Not enough runic power"
AddDeny(ERR_OUT_OF_RUNES)               -- "Not enough runes"
AddDeny(ERR_OUT_OF_HEALTH)              -- "Not enough health"
AddDeny(SPELL_FAILED_NO_POWER)          -- "Not enough power"

-- PlaySoundFile has no volume/channel control on this client (no channel
-- arg support, no per-sound volume param), so the replay would otherwise
-- always play at full Master volume no matter what the SFX slider says.
-- Approximated by shipping the same clip pre-attenuated at four gain tiers
-- and picking the closest one to the live Sound_SFXVolume cvar.
local DENY_SOUND_TIERS = {
    { 0.3, "Interface\\AddOns\\Refactor\\sounds\\FizzleHolyA_20.wav" },
    { 0.5, "Interface\\AddOns\\Refactor\\sounds\\FizzleHolyA_40.wav" },
    { 0.7, "Interface\\AddOns\\Refactor\\sounds\\FizzleHolyA_60.wav" },
    { 0.9, "Interface\\AddOns\\Refactor\\sounds\\FizzleHolyA_80.wav" },
}
local DENY_SOUND_FULL = "Interface\\AddOns\\Refactor\\sounds\\FizzleHolyA.wav"

local function DenySoundForVolume(vol)
    for _, tier in ipairs(DENY_SOUND_TIERS) do
        if vol <= tier[1] then return tier[2] end
    end
    return DENY_SOUND_FULL
end

-- UIErrorsFrame owns UI_ERROR_MESSAGE; take the event over so the flag is
-- read per message and toggling needs no /reload. Yellow UI_INFO_MESSAGE
-- lines (quest progress etc.) stay with the default frame.
UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")

local errText = CreateFrame("Frame")
errText:RegisterEvent("UI_ERROR_MESSAGE")
errText:SetScript("OnEvent", function(self, event, message)
    if message and DENY_LINES[message] and not Qol("muteDenySounds")
        and PlaySoundFile
        and GetCVar("Sound_EnableSFX") == "1" then
        local vol = tonumber(GetCVar("Sound_SFXVolume")) or 1
        if vol > 0 then
            PlaySoundFile(DenySoundForVolume(vol), "SFX")
        end
    end
    if Qol("hideErrorText") then return end
    -- Same color/hold values the default UI uses for error lines.
    UIErrorsFrame:AddMessage(message, 1.0, 0.1, 0.1, 1.0)
end)
