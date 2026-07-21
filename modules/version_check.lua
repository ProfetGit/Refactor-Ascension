--------------------------------------------------------------------------
-- Refactor: version check. Peer-to-peer over hidden addon messages. No
-- HTTP exists in this client, so the only way to hear about a newer
-- release is from another player already running it: everyone broadcasts
-- their version to guild and group channels, and receiving a higher one
-- prints a one-line chat notice. Broadcasting is unconditional (it's
-- invisible, and it's what lets OTHERS learn there's an update); the
-- versionCheck flag only gates the notice on this end.
--------------------------------------------------------------------------

do
    local VER_PREFIX = "RefactorVer"
    local myVersion = GetAddOnMetadata("Refactor", "Version") or "0"
    local UPDATE_URL = "github.com/ProfetGit/Refactor-Ascension"

    -- True when a is strictly newer than b. Compares dotted numeric
    -- segments piecewise ("1.10.0" > "1.9.2"); a missing segment counts
    -- as 0, so "1.5" == "1.5.0".
    local function VersionNewer(a, b)
        local ai, bi = a:gmatch("%d+"), b:gmatch("%d+")
        while true do
            local as, bs = ai(), bi()
            if not as and not bs then return false end
            local an, bn = tonumber(as) or 0, tonumber(bs) or 0
            if an ~= bn then return an > bn end
        end
    end

    -- One broadcast per channel per 30s: PARTY_MEMBERS_CHANGED and
    -- RAID_ROSTER_UPDATE fire in bursts (and once per member on a full
    -- raid join), and each guild/group mate only needs to hear a version
    -- once for the session anyway.
    local SEND_COOLDOWN = 30
    local lastSent = {}
    local function Broadcast(channel)
        local now = GetTime()
        if lastSent[channel] and now - lastSent[channel] < SEND_COOLDOWN then return end
        lastSent[channel] = now
        SendAddonMessage(VER_PREFIX, myVersion, channel)
    end

    local function BroadcastAll()
        if IsInGuild() then Broadcast("GUILD") end
        -- Inside a battleground the RAID channel is redirected anyway;
        -- send on the explicit channel so it works regardless.
        if UnitInBattleground("player") then
            Broadcast("BATTLEGROUND")
        elseif GetNumRaidMembers() > 0 then
            Broadcast("RAID")
        elseif GetNumPartyMembers() > 0 then
            Broadcast("PARTY")
        end
    end

    local announced -- newest remote version already reported this session

    local ver = CreateFrame("Frame")
    ver:RegisterEvent("PLAYER_ENTERING_WORLD")
    ver:RegisterEvent("PARTY_MEMBERS_CHANGED")
    ver:RegisterEvent("RAID_ROSTER_UPDATE")
    ver:RegisterEvent("CHAT_MSG_ADDON")

    -- Guild membership isn't known the instant PLAYER_ENTERING_WORLD
    -- fires (IsInGuild() can still be false), so the login broadcast waits
    -- a few seconds. OnUpdate ticker per this file's usual pattern —
    -- C_Timer isn't guaranteed on this client; detaches itself after
    -- firing so idle frames cost nothing.
    local LOGIN_DELAY = 8
    local loginWait = 0
    local function LoginTick(self, elapsed)
        loginWait = loginWait - elapsed
        if loginWait <= 0 then
            self:SetScript("OnUpdate", nil)
            BroadcastAll()
        end
    end

    ver:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
        if event == "PLAYER_ENTERING_WORLD" then
            loginWait = LOGIN_DELAY
            self:SetScript("OnUpdate", LoginTick)
        elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
            -- New group members broadcast at their own login only, which a
            -- later-formed group never heard — re-send on roster changes
            -- (the 30s cooldown eats the burst).
            BroadcastAll()
        elseif event == "CHAT_MSG_ADDON" then
            local prefix, message, _, sender = arg1, arg2, arg3, arg4
            if prefix ~= VER_PREFIX then return end
            if sender == UnitName("player") then return end -- own echo
            -- Take only a version-shaped token: the message is peer input,
            -- not trusted data.
            local remote = message and message:match("%d+[%.%d]*")
            if not remote then return end
            if not Qol("versionCheck") then return end
            if not VersionNewer(remote, myVersion) then return end
            -- Once per version per session: announce again only if an even
            -- newer one shows up.
            if announced and not VersionNewer(remote, announced) then return end
            announced = remote
            Announce("a newer version |cffffcc00v" .. remote ..
                "|r is available (you have v" .. myVersion ..
                "). Get it at |cffffcc00" .. UPDATE_URL .. "|r")
        end
    end)
end
