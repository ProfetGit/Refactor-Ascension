-- Refactor: social automation
-- Auto-decline party invites, duels, guild invites and stranger trades;
-- auto-accept player resurrections in battlegrounds; Alt + Right-Click
-- quick invite; leave party when clicking Leave Dungeon. Hold Shift as a
-- request arrives to handle it manually.

local function IsFriend(name)
    if not name then return false end
    for i = 1, GetNumFriends() do
        if GetFriendInfo(i) == name then return true end
    end
    return false
end

local social = CreateFrame("Frame")
social:RegisterEvent("PARTY_INVITE_REQUEST")
social:RegisterEvent("DUEL_REQUESTED")
social:RegisterEvent("GUILD_INVITE_REQUEST")
social:RegisterEvent("TRADE_SHOW")
social:RegisterEvent("RESURRECT_REQUEST")

-- Every auto-handled request gets one chat line (Announce, core.lua) so the
-- player still knows it happened — the popups are hidden the same frame
-- they'd appear.
social:SetScript("OnEvent", function(self, event, arg1, arg2)
    if IsShiftKeyDown() then return end -- manual override for every request

    if event == "PARTY_INVITE_REQUEST" then
        if not Qol("declineInvites") then return end
        DeclineGroup()
        StaticPopup_Hide("PARTY_INVITE")
        Announce("declined group invite from " .. (arg1 or "someone"))
    elseif event == "DUEL_REQUESTED" then
        if not Qol("declineDuels") then return end
        CancelDuel()
        StaticPopup_Hide("DUEL_REQUESTED")
        Announce("declined duel from " .. (arg1 or "someone"))
    elseif event == "GUILD_INVITE_REQUEST" then
        -- arg1 = inviter, arg2 = guild name.
        if not Qol("declineGuilds") then return end
        DeclineGuild()
        StaticPopup_Hide("GUILD_INVITE")
        Announce("declined invite to <" .. (arg2 or "?") .. "> from " .. (arg1 or "someone"))
    elseif event == "TRADE_SHOW" then
        if not Qol("declineTrades") then return end
        -- "NPC" is the trade partner while the window is open. Friends,
        -- guildmates and groupmates trade freely; only strangers are blocked.
        local partner = UnitName("NPC")
        if IsFriend(partner) or UnitIsInMyGuild("NPC")
            or UnitInParty("NPC") or UnitInRaid("NPC") then return end
        CloseTrade()
        Announce("closed trade with " .. (partner or "someone"))
    elseif event == "RESURRECT_REQUEST" then
        -- arg1 = who's offering. Battlegrounds only — accepting a dungeon
        -- combat-res is a timing decision that stays with the player.
        if not Qol("autoResBG") then return end
        local _, instanceType = IsInInstance()
        if instanceType ~= "pvp" then return end
        AcceptResurrect()
        StaticPopup_Hide("RESURRECT")
        StaticPopup_Hide("RESURRECT_NO_SICKNESS")
        StaticPopup_Hide("RESURRECT_NO_TIMER")
        Announce("accepted resurrection from " .. (arg1 or "someone"))
    end
end)

--------------------------------------------------------------------------
-- Social: Alt + Right-Click a player to quickly invite them
--------------------------------------------------------------------------

-- Post-hook, NOT a global replacement: swapping the UnitPopup_ShowMenu
-- global put addon code in the path of every unit right-click menu, and
-- on 3.3.5 dropdown taint blocks protected menu actions (Set Focus etc.)
-- — same lesson as the UseContainerItem hooks elsewhere in this addon.
-- The menu can't be preempted from a post-hook, so it's closed right
-- after opening instead; the one-frame flicker is the taint-free price.
hooksecurefunc("UnitPopup_ShowMenu", function(dropdownFrame, which, unit, name)
    if not Qol("quickInvite") or not IsAltKeyDown() then return end
    local targetName = name
    if unit then
        if not UnitIsPlayer(unit) then return end
        targetName = UnitName(unit)
    end
    if targetName and targetName ~= UnitName("player") then
        CloseDropDownMenus()
        InviteUnit(targetName)
    end
end)

-- World clicks: the binding system calls the TurnOrActionStart C command
-- directly, so a hooksecurefunc on the Lua global never fires from a real
-- right-click — WorldFrame's mouse script is the only path that does.
WorldFrame:HookScript("OnMouseDown", function(_, button)
    if button ~= "RightButton" then return end
    if Qol("quickInvite") and IsAltKeyDown() and UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        local name = UnitName("mouseover")
        if name and name ~= UnitName("player") then
            InviteUnit(name)
        end
    end
end)

--------------------------------------------------------------------------
-- Dungeons: leave party when clicking the Leave Dungeon button
--------------------------------------------------------------------------

if LFDLeaveFrameLeaveButton then
    LFDLeaveFrameLeaveButton:HookScript("OnClick", function()
        if Qol("leavePartyOnDungeon") then
            LeaveParty()
        end
    end)
end
