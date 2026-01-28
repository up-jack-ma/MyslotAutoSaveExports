
local ADDON_NAME, MySlot = ...

-- Helper for Localization
MySlot.L = setmetatable({}, {
    __index = function(t, k)
        return k
    end
})
local L = MySlot.L

local crc32 = MySlot.crc32
local base64 = MySlot.base64

local pblua = MySlot.luapb
local _MySlot = pblua.load_proto_ast(MySlot.ast)

local MYSLOT_VER = 42

-- TWW Beta Compat code (fix and cleanup below later)
local PickupSpell = C_Spell and C_Spell.PickupSpell or _G.PickupSpell
local PickupItem = C_Item and C_Item.PickupItem or _G.PickupItem
local GetSpellInfo = C_Spell and C_Spell.GetSpellName or _G.GetSpellInfo
local GetSpellLink = C_Spell and C_Spell.GetSpellLink or _G.GetSpellLink
local PickupSpellBookItem = C_SpellBook and C_SpellBook.PickupSpellBookItem or _G.PickupSpellBookItem
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) and C_AddOns.GetAddOnMetadata or _G.GetAddOnMetadata
-- TWW Beta Compat End

local MYSLOT_LINE_SEP = IsWindowsClient() and "\r\n" or "\n"
local MYSLOT_MAX_ACTIONBAR = 180

-- {{{ SLOT TYPE
local MYSLOT_SPELL = _MySlot.Slot.SlotType.SPELL
local MYSLOT_COMPANION = _MySlot.Slot.SlotType.COMPANION
local MYSLOT_ITEM = _MySlot.Slot.SlotType.ITEM
local MYSLOT_MACRO = _MySlot.Slot.SlotType.MACRO
local MYSLOT_FLYOUT = _MySlot.Slot.SlotType.FLYOUT
local MYSLOT_EQUIPMENTSET = _MySlot.Slot.SlotType.EQUIPMENTSET
local MYSLOT_EMPTY = _MySlot.Slot.SlotType.EMPTY
local MYSLOT_SUMMONPET = _MySlot.Slot.SlotType.SUMMONPET
local MYSLOT_SUMMONMOUNT = _MySlot.Slot.SlotType.SUMMONMOUNT
local MYSLOT_NOTFOUND = "notfound"

MySlot.SLOT_TYPE = {
    ["spell"] = MYSLOT_SPELL,
    ["companion"] = MYSLOT_COMPANION,
    ["macro"] = MYSLOT_MACRO,
    ["item"] = MYSLOT_ITEM,
    ["flyout"] = MYSLOT_FLYOUT,
    ["petaction"] = MYSLOT_EMPTY,
    ["futurespell"] = MYSLOT_EMPTY,
    ["equipmentset"] = MYSLOT_EQUIPMENTSET,
    ["summonpet"] = MYSLOT_SUMMONPET,
    ["summonmount"] = MYSLOT_SUMMONMOUNT,
    [MYSLOT_NOTFOUND] = MYSLOT_EMPTY,
}
-- }}}

local MYSLOT_BIND_CUSTOM_FLAG = 0xFFFF

-- {{{ MergeTable
-- return item count merge into target
local function MergeTable(target, source)
    if source then
        assert(type(target) == 'table' and type(source) == 'table')
        for _, b in ipairs(source) do
            assert(b < 256)
            target[#target + 1] = b
        end
        return #source
    else
        return 0
    end
end
-- }}}

-- fix unpack stackoverflow
local function StringToTable(s)
    if type(s) ~= 'string' then
        return {}
    end
    local r = {}
    for i = 1, string.len(s) do
        r[#r + 1] = string.byte(s, i)
    end
    return r
end

local function TableToString(s)
    if type(s) ~= 'table' then
        return ''
    end
    local t = {}
    for _, c in pairs(s) do
        t[#t + 1] = string.char(c)
    end
    return table.concat(t)
end

local function CreateSpellOverrideMap()
    local spellOverride = {}

    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        -- 11.0 only
        for skillLineIndex = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
            for i = 1, skillLineInfo.numSpellBookItems do
                local spellIndex = skillLineInfo.itemIndexOffset + i
                local spellType, id, spellId = C_SpellBook.GetSpellBookItemType(spellIndex, Enum.SpellBookSpellBank.Player)
                if spellId then
                    local newid = C_Spell.GetOverrideSpell(spellId)
                    if newid ~= spellId then
                        spellOverride[newid] = spellId
                    end
                elseif spellType == Enum.SpellBookItemType.Flyout then
                    local _, _, numSlots, isKnown = GetFlyoutInfo(id);
                    if isKnown and (numSlots > 0) then
                        for k = 1, numSlots do
                            local spellID, overrideSpellID = GetFlyoutSlotInfo(id, k)
                            spellOverride[overrideSpellID] = spellID
                        end
                    end
                end
            end
        end

        local isInspect = false
        for specIndex = 1, GetNumSpecGroups(isInspect) do
            for tier = 1, MAX_TALENT_TIERS do
                for column = 1, NUM_TALENT_COLUMNS do
                    local spellId = select(6, GetTalentInfo(tier, column, specIndex))
                    if spellId then
                        local newid = C_Spell.GetOverrideSpell(spellId)
                        if newid ~= spellId then
                            spellOverride[newid] = spellId
                        end
                    end
                end
            end
        end

        for pvpTalentSlot = 1, 3 do
            local slotInfo = C_SpecializationInfo.GetPvpTalentSlotInfo(pvpTalentSlot)
            if slotInfo ~= nil then
                for i, pvpTalentID in ipairs(slotInfo.availableTalentIDs) do
                    local spellId = select(6, GetPvpTalentInfoByID(pvpTalentID))
                    if spellId then
                        local newid = C_Spell.GetOverrideSpell(spellId)
                        if newid ~= spellId then
                            spellOverride[newid] = spellId
                        end
                    end
                end
            end
        end
    end

    return spellOverride
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[MyslotAutoSave]|r " .. (msg or "nil"))
end

-- {{{ GetMacroInfo
function MySlot:GetMacroInfo(macroId)
    -- {macroId ,icon high 8, icon low 8 , namelen, ..., bodylen, ...}

    local name, iconTexture, body  = GetMacroInfo(macroId)

    if not name then
        return nil
    end

    iconTexture = gsub(strupper(iconTexture or "INV_Misc_QuestionMark"), "INTERFACE\\ICONS\\", "")

    local msg = _MySlot.Macro()
    msg.id = macroId
    msg.icon = iconTexture
    msg.name = name
    msg.body = body

    return msg
end

-- }}}

-- {{{ GetActionInfo
function MySlot:GetActionInfo(slotId)
    local slotType, index, subType = GetActionInfo(slotId)
    if MySlot.SLOT_TYPE[slotType] == MYSLOT_EQUIPMENTSET then
        -- i starts from 0 https://github.com/tg123/myslot/issues/10 weird blz
        for i = 0, C_EquipmentSet.GetNumEquipmentSets() do
            if C_EquipmentSet.GetEquipmentSetInfo(i) == index then
                index = i
                break
            end
        end
    elseif not MySlot.SLOT_TYPE[slotType] then
        -- Ignore unsupported
        return nil
    elseif slotType == "macro" and subType then
        PickupAction(slotId)
        _, index = GetCursorInfo()
        PlaceAction(slotId)
    elseif slotType == "spell" and subType == "assistedcombat" then
        index = C_AssistedCombat.GetActionSpell()
    elseif not index then
        return nil
    end

    local msg = _MySlot.Slot()
    msg.id = slotId
    msg.type = MySlot.SLOT_TYPE[slotType]
    if type(index) == 'string' then
        msg.strindex = index
        msg.index = 0
    else
        msg.index = index
    end
    return msg
end

-- }}}

function MySlot:GetPetActionInfo(slotId)
    local name, _, isToken, _, _, _, spellID = GetPetActionInfo(slotId)

    local msg = _MySlot.Slot()
    msg.id = slotId
    msg.type = MYSLOT_SPELL

    if isToken then
        msg.strindex = name
        msg.index = 0
    elseif spellID then
        msg.index = spellID
    elseif not name then
        msg.index = 0
        msg.type = MYSLOT_EMPTY
    else
        return nil
    end

    return msg
end

-- {{{ GetBindingInfo
-- {{{ Serialzie Key
local function KeyToByte(key, command)
    -- {mod , key , command high 8, command low 8}
    if not key then
        return nil
    end

    local mod = nil
    local _, _, _mod, _key = string.find(key, "(.+)-(.+)")
    if _mod and _key then
        mod, key = _mod, _key
    end

    mod = mod or "NONE"

    if not MySlot.MOD_KEYS[mod] then
        -- Ignore unsupported
        return nil
    end

    local msg = _MySlot.Key()
    if MySlot.KEYS[key] then
        msg.key = MySlot.KEYS[key]
    else
        msg.key = MySlot.KEYS["KEYCODE"]
        msg.keycode = key
    end
    msg.mod = MySlot.MOD_KEYS[mod]

    return msg
end
-- }}}

function MySlot:GetBindingInfo(index)
    -- might more than 1
    local _command, _, key1, key2 = GetBinding(index)

    if not _command then
        return
    end

    local command = MySlot.BINDS[_command]

    local msg = _MySlot.Bind()

    if not command then
        msg.command = _command
        command = MYSLOT_BIND_CUSTOM_FLAG
    end

    msg.id = command

    msg.key1 = KeyToByte(key1)
    msg.key2 = KeyToByte(key2)

    if msg.key1 or msg.key2 then
        return msg
    else
        return nil
    end
end

-- }}}

local function GetTalentTreeString()
    -- maybe classic
    if GetTalentTabInfo then

        -- wlk
        if tonumber(select(3, GetTalentTabInfo(1)), 10) then
            return select(3, GetTalentTabInfo(1)) ..  "/" .. select(3, GetTalentTabInfo(2)) .. "/" .. select(3, GetTalentTabInfo(3))
        end

        -- other
        if tonumber(select(5, GetTalentTabInfo(1)), 10) then
            return select(5, GetTalentTabInfo(1)) ..  "/" .. select(5, GetTalentTabInfo(2)) .. "/" .. select(5, GetTalentTabInfo(3))
        end
    end

    -- 11.0
    if PlayerSpellsFrame_LoadUI then
        PlayerSpellsFrame_LoadUI()

        -- no talent yet
        if not PlayerSpellsFrame.TalentsFrame:GetConfigID() then
            return nil
        end

        PlayerSpellsFrame.TalentsFrame:UpdateTreeInfo()
        if PlayerSpellsFrame.TalentsFrame:GetLoadoutExportString() then
            return PlayerSpellsFrame.TalentsFrame:GetLoadoutExportString()
        end
    end

    return nil
end

function MySlot:Export(opt)
    -- ver nop nop nop crc32 crc32 crc32 crc32

    local msg = _MySlot.Charactor()

    msg.ver = MYSLOT_VER
    msg.name = UnitName("player")

    msg.macro = {}

    if not opt.ignoreMacros["ACCOUNT"] then
        for i = 1, MAX_ACCOUNT_MACROS  do
            local m = self:GetMacroInfo(i)
            if m then
                msg.macro[#msg.macro + 1] = m
            end
        end
    end

    if not opt.ignoreMacros["CHARACTOR"] then
        for i = MAX_ACCOUNT_MACROS + 1, MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS do
            local m = self:GetMacroInfo(i)
            if m then
                msg.macro[#msg.macro + 1] = m
            end
        end
    end

    msg.slot = {}
    -- TODO move to GetActionInfo
    local spellOverride = CreateSpellOverrideMap()

    for i = 1, MYSLOT_MAX_ACTIONBAR do
        if not opt.ignoreActionBars[math.ceil(i / 12)] then
            local m = self:GetActionInfo(i)
            if m then
                if m.type == 'SPELL' then
                    if spellOverride[m.index] then
                        m.index = spellOverride[m.index]
                    end
                end
                msg.slot[#msg.slot + 1] = m
            end
        end

    end

    msg.bind = {}
    if not opt.ignoreBinding then
        for i = 1, GetNumBindings() do
            local m = self:GetBindingInfo(i)
            if m then
                msg.bind[#msg.bind + 1] = m
            end
        end
    end

    msg.petslot = {}
    if not opt.ignorePetActionBar and IsPetActive() then
        for i = 1, NUM_PET_ACTION_SLOTS, 1 do
            local m = self:GetPetActionInfo(i)
            if m then
                msg.petslot[#msg.petslot + 1] = m
            end
        end
    end

    local ct = msg:Serialize()
    local t = { MYSLOT_VER, 86, 04, 22, 0, 0, 0, 0 }
    MergeTable(t, StringToTable(ct))

    -- {{{ CRC32
    -- crc
    local crc = crc32.enc(t)
    t[5] = bit.rshift(crc, 24)
    t[6] = bit.band(bit.rshift(crc, 16), 255)
    t[7] = bit.band(bit.rshift(crc, 8), 255)
    t[8] = bit.band(crc, 255)
    -- }}}

    -- {{{ OUTPUT
    local talent = GetTalentTreeString()

    local s = ""
    s = "# --------------------" .. MYSLOT_LINE_SEP .. s
    s = "# " .. L["Feedback"] .. "  farmer1992@gmail.com" .. MYSLOT_LINE_SEP .. s
    s = "# " .. MYSLOT_LINE_SEP .. s
    s = "# " .. LEVEL .. ": " .. UnitLevel("player") .. MYSLOT_LINE_SEP .. s
    if talent then
        s = "# " .. TALENTS .. ": " .. talent .. MYSLOT_LINE_SEP .. s
    end
    if GetSpecialization then
        s = "# " ..
        SPECIALIZATION ..
        ": " ..
        (GetSpecialization() and select(2, GetSpecializationInfo(GetSpecialization())) or NONE_CAPS) ..
        MYSLOT_LINE_SEP .. s
    end
    s = "# " .. CLASS .. ": " .. UnitClass("player") .. MYSLOT_LINE_SEP .. s
    s = "# " .. PLAYER .. ": " .. UnitName("player") .. MYSLOT_LINE_SEP .. s
    s = "# " .. L["Time"] .. ": " .. date() .. MYSLOT_LINE_SEP .. s

    if GetAddOnMetadata then
        s = "# Addon Version: " .. GetAddOnMetadata("Myslot", "Version") .. MYSLOT_LINE_SEP .. s
    end

    s = "# Wow Version: " .. GetBuildInfo() .. MYSLOT_LINE_SEP .. s
    s = "# Myslot (https://myslot.net " .. L["<- share your profile here"]  ..")" .. MYSLOT_LINE_SEP .. s

    local d = base64.enc(t)
    local LINE_LEN = 60
    for i = 1, d:len(), LINE_LEN do
        s = s .. d:sub(i, i + LINE_LEN - 1) .. MYSLOT_LINE_SEP
    end
    s = strtrim(s)
    s = s .. MYSLOT_LINE_SEP .. "# --------------------"
    s = s .. MYSLOT_LINE_SEP .. "# END OF MYSLOT"

    return s
    -- }}}
end

-- --- Auto Save Logic ---

local function GetBackupName()
    local characterName = UnitName("player")
    local realmName = GetRealmName()
    if not characterName or characterName == "" or not realmName or realmName == "" then
        return nil
    end

    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex then
        return nil
    end
    local _, specName = GetSpecializationInfo(specIndex)
    if not specName or specName == "" then
        specName = "None"
    end

    return characterName .. "-" .. specName .. "-" .. realmName
end

local function TryAutoBackup(triesLeft)
    -- We are interacting with Myslot's SavedVariables directly.
    -- MyslotExports is a global variable.
    if not MyslotExports then
        -- Myslot addon not loaded or SV not available.
        Print("MyslotExports not found. Is Myslot installed and enabled?")
        return
    end

    if not MyslotExports["exports"] then
        MyslotExports["exports"] = {}
    end

    local backupName = GetBackupName()
    if not backupName then
        if triesLeft and triesLeft > 0 then
            C_Timer.After(1, function()
                TryAutoBackup(triesLeft - 1)
            end)
        end
        return
    end

    -- Check if backup exists
    for _, export in pairs(MyslotExports["exports"]) do
        if export.name == backupName then
            -- Print("Backup already exists: " .. backupName)
            return
        end
    end

    -- Export
    local opt = {
        ignoreMacros = {
            ACCOUNT = false,
            CHARACTOR = false,
        },
        ignoreActionBars = {},
        ignoreBinding = false,
        ignorePetActionBar = false,
    }

    -- Initialize ignoreActionBars table
    for i = 1, 15 do
       opt.ignoreActionBars[i] = false
    end


    local exported = MySlot:Export(opt)
    if not exported then
        if triesLeft and triesLeft > 0 then
            C_Timer.After(1, function()
                TryAutoBackup(triesLeft - 1)
            end)
        end
        return
    end

    table.insert(MyslotExports["exports"], {
        name = backupName,
        value = exported
    })
    Print("自动备份成功: " .. backupName)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function()
    C_Timer.After(5, function()
        TryAutoBackup(10)
    end)
end)
