-- if you notice any bugs, please open an issue on github or dm okleah on discord
local addonName, PL = ...

-- =========================================================================
-- 1. Libraries & SavedVariables
-- =========================================================================
local AceAddon = LibStub("AceAddon-3.0")
local AceDB = LibStub("AceDB-3.0")
local AceConsole = LibStub("AceConsole-3.0")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local LSM = LibStub("LibSharedMedia-3.0")
local AceSerializer = LibStub("AceSerializer-3.0", true) -- optional

local PrettyLoot = AceAddon:NewAddon("PrettyLoot", "AceConsole-3.0", "AceEvent-3.0")
PL = PrettyLoot

-- deep copy helper
local function DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do copy[k] = DeepCopy(v) end
    return copy
end

-- =========================================================================
-- 2. Defaults
-- =========================================================================
local defaults = {
    profile = {
        locked = true,
        x = 0,
        y = 200,

        -- display defaults
        iconSize = 16,
        textSize = 14,
        rowHeight = 22,
        maxItems = 6,
        rowSpacing = 2,
        fontKey = "Expressway", -- falls back to FRIZQT__ via GetFont if missing

        -- durations (all default to 5s)
        holdDuration = 5,
        durationCoins = 5,
        durationItems = 5,
        durationCurrency = 5,
        durationRep = 5,
        durationHighlight = 5,

        trackCurrencies = true,
        trackReputation = true,

        blacklist = "",
        highlight = "",

        playSoundOnHighlight = false,
        highlightSound = "",

        -- highlight visual style
        highlightStyle = "popout", -- "popout", "pulse", "background"
        highlightBackgroundColour = { r = 0.4, g = 0.2, b = 0.7, a = 0.25 },

        -- layout tuning
        iconGapWithIcon = 6,
        iconGapNoIcon = 2,
        indicatorVerticalOffset = 0,
    }
}

-- =========================================================================
-- 3. Constants & helpers
-- =========================================================================
local SLIDE_SPEED = 300
local SLIDE_DISTANCE_MAX = 140
local FADE_SPEED = 2

local FLUSH_DELAY = 0.08 -- batching delay (seconds)
local soundCooldown = 0 -- no throttle; play highlight sound every time
local lastSoundTime = 0

local MAX_CONCURRENT_ANIMS = 3
local activeAnimations = 0

local activeLines = {}
local framePool = {}

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local DEFAULT_QUALITY = 1

local qualityColors = {
    [0] = "|cff9d9d9d",
    [1] = "|cffffffff",
    [2] = "|cff1eff00",
    [3] = "|cff0070dd",
    [4] = "|cffa335ee",
    [5] = "|cffff8000",
    [6] = "|cffe6cc80",
}

local repColors = {
    [1] = "|cffcc2222",
    [2] = "|cffff0000",
    [3] = "|cffee6622",
    [4] = "|cffe8e800",
    [5] = "|cff00ff00",
    [6] = "|cff00ff88",
    [7] = "|cff00ffcc",
    [8] = "|cff00ffff",
}

local anchor, highlight, highlightText, highlightHeader
local currencySnapshot = {}
local reputationSnapshot = {}

PL.plusWidth = nil

-- parsed data
local parsedBlacklist = {}
local parsedBlacklistPatterns = {}
local parsedHighlight = {}
local parsedHighlightPatterns = {}

-- temporary storage for new profile input
PL._newProfileName = ""

local function GetHoldDuration() return PL.db.profile.holdDuration or 5 end
local function GetRowHeight() return PL.db.profile.rowHeight or 22 end
local function GetFont()
    return LSM:Fetch("font", PL.db.profile.fontKey) or "Fonts\\FRIZQT__.TTF"
end
local function Trim(s) if not s then return "" end return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function StripColors(s) if not s then return "" end return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function EscapeExceptAsterisk(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%+%-%?\\])", "%%%1"))
end

local function WildcardToPattern(s)
    if not s then return nil end
    local orig = s
    local lower = string.lower(s)
    local escaped = EscapeExceptAsterisk(lower)
    escaped = escaped:gsub("%*", ".*")
    local leftAnchor = true
    local rightAnchor = true
    if orig:sub(1,1) == "*" then leftAnchor = false end
    if orig:sub(-1) == "*" then rightAnchor = false end
    if leftAnchor then escaped = "^" .. escaped end
    if rightAnchor then escaped = escaped .. "$" end
    return escaped
end

local function ParseListIntoTables(text, outLookup, outPatterns)
    outLookup = outLookup or {}
    outPatterns = outPatterns or {}
    if not text or text == "" then return outLookup, outPatterns end
    local norm = text:gsub(",", "\n")
    for line in string.gmatch(norm, "[^\r\n]+") do
        local item = Trim(line)
        if item ~= "" then
            if string.find(item, "%*") then
                local ok, pat = pcall(WildcardToPattern, item)
                if ok and pat then
                    table.insert(outPatterns, pat)
                else
                    outLookup[string.lower(item)] = true
                end
            else
                outLookup[string.lower(item)] = true
            end
        end
    end
    return outLookup, outPatterns
end

local function UpdateParsedLists()
    parsedBlacklist = {}
    parsedBlacklistPatterns = {}
    parsedHighlight = {}
    parsedHighlightPatterns = {}
    ParseListIntoTables(PL.db.profile.blacklist or "", parsedBlacklist, parsedBlacklistPatterns)
    ParseListIntoTables(PL.db.profile.highlight or "", parsedHighlight, parsedHighlightPatterns)
end

local function MatchList(listLookup, listPatterns, displayName)
    if not displayName then return false end
    local lowerName = string.lower(displayName)
    if listLookup[lowerName] then return true end
    for _, pat in ipairs(listPatterns) do
        local ok, res = pcall(string.find, lowerName, pat)
        if ok and res then return true end
    end
    return false
end

local function IsBlacklisted(itemKey, displayName)
    if itemKey ~= nil then
        local keyStr = tostring(itemKey)
        if parsedBlacklist[keyStr] then return true end
        if type(itemKey) == "string" and parsedBlacklist[string.lower(itemKey)] then return true end
    end
    if displayName then
        local stripped = StripColors(displayName)
        if MatchList(parsedBlacklist, parsedBlacklistPatterns, stripped) then return true end
    end
    return false
end

local function IsHighlighted(itemKey, displayName)
    if itemKey ~= nil then
        local keyStr = tostring(itemKey)
        if parsedHighlight[keyStr] then return true end
        if type(itemKey) == "string" and parsedHighlight[string.lower(itemKey)] then return true end
    end
    if displayName then
        local stripped = StripColors(displayName)
        if MatchList(parsedHighlight, parsedHighlightPatterns, stripped) then return true end
    end
    return false
end

-- =========================================================================
-- Priority: Money(1) > Reputation(2) > Currency(3) > Item(4)
-- =========================================================================
local function getPriority(line)
    if line.isMoney then return 1 end
    if line.isReputation then return 2 end
    if line.isCurrency then return 3 end
    return 4
end

local function InsertLineByPriority(newLine)
    local newP = getPriority(newLine)
    local inserted = false
    for i, v in ipairs(activeLines) do
        local p = getPriority(v)
        if p > newP then
            table.insert(activeLines, i, newLine)
            inserted = true
            break
        end
    end
    if not inserted then table.insert(activeLines, newLine) end
end

-- =========================================================================
-- Duration helpers
-- =========================================================================
local function GetBaseDurationForLine(line)
    if line.isMoney then
        return PL.db.profile.durationCoins or GetHoldDuration()
    elseif line.isReputation then
        return PL.db.profile.durationRep or GetHoldDuration()
    elseif line.isCurrency then
        return PL.db.profile.durationCurrency or GetHoldDuration()
    else
        return PL.db.profile.durationItems or GetHoldDuration()
    end
end

local function GetHighlightDuration()
    return PL.db.profile.durationHighlight or GetHoldDuration()
end

-- forward declaration
local function RemoveLine(line) end

-- =========================================================================
-- Preview helpers
-- =========================================================================
local function ClearPreviewLines()
    local i = 1
    while i <= #activeLines do
        local line = activeLines[i]
        if line.isPreview then
            RemoveLine(line)
        else
            i = i + 1
        end
    end
end

-- =========================================================================
-- Frame factory & highlight animations
-- =========================================================================
local function ComputePlusWidth()
    if not anchor then return 36 end
    local temp = anchor:CreateFontString(nil, "OVERLAY")
    temp:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
    local samples = { "|cff00ff00+|r", "|cffff0000-|r", "|cff89cff0CUR|r", "|cffffa500REP|r" }
    local maxW = 0
    for _, s in ipairs(samples) do
        temp:SetText(s)
        local w = temp:GetStringWidth()
        if w > maxW then maxW = w end
    end
    temp:SetText("")
    temp:Hide()
    return math.ceil(maxW + 4)
end

local function UpdateHighlightSize()
    local width = 300
    local headerHeight = 25
    local contentHeight = (GetRowHeight() + PL.db.profile.rowSpacing) * PL.db.profile.maxItems
    local totalHeight = headerHeight + contentHeight
    anchor:SetSize(width, totalHeight)
    highlight:SetSize(width, contentHeight)
    highlightHeader:SetSize(width, headerHeight)
end

local function RecalculateQueue()
    local yOffset = 0
    local rowHeight = GetRowHeight()
    for _, line in ipairs(activeLines) do
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", highlight, "TOPLEFT", line.slideX or 0, yOffset)
        line.anchorRef = highlight
        line.anchorPoint = "TOPLEFT"
        line.anchorYOffset = yOffset
        yOffset = yOffset - rowHeight - PL.db.profile.rowSpacing
    end
    UpdateHighlightSize()
end

local function StopHighlightVisual(line)
    if line._sparkleAnim and line._sparklePlaying then
        pcall(function() line._sparkleAnim:Stop() end)
    end
    if line._pulseAnim and line._pulsePlaying then
        pcall(function() line._pulseAnim:Stop() end)
    end
    if line._bgTex then
        line._bgTex:Hide()
    end
end

local function StartHighlightVisual(line)
    local style = PL.db.profile.highlightStyle or "popout"

    if style == "background" then
        if not line._bgTex then
            local bg = line:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(line)
            line._bgTex = bg
        end
        local c = PL.db.profile.highlightBackgroundColour or { r = 0.4, g = 0.2, b = 0.7, a = 0.25 }
        line._bgTex:SetColorTexture(c.r or 0.4, c.g or 0.2, c.b or 0.7, c.a or 0.25)
        line._bgTex:Show()
        return
    end

    if style == "popout" then
        if not line._sparkleAnim then
            local sparkle = line:CreateTexture(nil, "OVERLAY")
            sparkle:SetTexture("Interface\\Cooldown\\star4")
            sparkle:SetBlendMode("ADD")
            sparkle:SetPoint("CENTER", line, "CENTER", 0, 0)
            sparkle:SetSize(GetRowHeight(), GetRowHeight())
            sparkle:SetAlpha(0)
            line._sparkle = sparkle

            local ag = line:CreateAnimationGroup()
            ag:SetLooping("REPEAT")

            local fadeIn = ag:CreateAnimation("Alpha")
            fadeIn:SetFromAlpha(0)
            fadeIn:SetToAlpha(0.8)
            fadeIn:SetDuration(0.25)
            fadeIn:SetOrder(1)

            local fadeOut = ag:CreateAnimation("Alpha")
            fadeOut:SetFromAlpha(0.8)
            fadeOut:SetToAlpha(0)
            fadeOut:SetDuration(0.5)
            fadeOut:SetOrder(2)

            local scale = ag:CreateAnimation("Scale")
            scale:SetScale(1.3, 1.3)
            scale:SetOrigin("CENTER", 0, 0)
            scale:SetDuration(0.75)
            scale:SetOrder(1)

            ag:SetScript("OnPlay", function()
                sparkle:Show()
                line._sparklePlaying = true
                activeAnimations = activeAnimations + 1
            end)
            ag:SetScript("OnStop", function()
                sparkle:Hide()
                line._sparklePlaying = nil
                if activeAnimations > 0 then
                    activeAnimations = activeAnimations - 1
                end
            end)

            line._sparkleAnim = ag
        end

        if not line._sparklePlaying and activeAnimations < MAX_CONCURRENT_ANIMS then
            pcall(function() line._sparkleAnim:Play() end)
        end
        return
    end

    if style == "pulse" then
        if not line._pulseAnim then
            local ag = line:CreateAnimationGroup()
            ag:SetLooping("REPEAT")

            local scaleUp = ag:CreateAnimation("Scale")
            scaleUp:SetScale(1.05, 1.05)
            scaleUp:SetOrigin("CENTER", 0, 0)
            scaleUp:SetDuration(0.25)
            scaleUp:SetOrder(1)

            local scaleDown = ag:CreateAnimation("Scale")
            scaleDown:SetScale(1/1.05, 1/1.05)
            scaleDown:SetOrigin("CENTER", 0, 0)
            scaleDown:SetDuration(0.25)
            scaleDown:SetOrder(2)

            ag:SetScript("OnPlay", function()
                line._pulsePlaying = true
                activeAnimations = activeAnimations + 1
            end)
            ag:SetScript("OnStop", function()
                line:SetScale(1)
                line._pulsePlaying = nil
                if activeAnimations > 0 then
                    activeAnimations = activeAnimations - 1
                end
            end)

            line._pulseAnim = ag
        end

        if not line._pulsePlaying and activeAnimations < MAX_CONCURRENT_ANIMS then
            pcall(function() line._pulseAnim:Play() end)
        end
        return
    end
end

function RemoveLine(line)
    StopHighlightVisual(line)
    line:Hide()
    line.itemKey = nil
    line.itemLink = nil
    line.slideX = 0
    line.isPreview = nil
    for i, v in ipairs(activeLines) do if v == line then table.remove(activeLines, i) break end end
    table.insert(framePool, line)
    RecalculateQueue()
end

local function GetLine()
    local line = table.remove(framePool)
    if not line then
        line = CreateFrame("Frame", nil, UIParent)
        line:SetSize(300, GetRowHeight())
        line:SetClipsChildren(true)
        line.slideX = 0

        line.plus = line:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        line.plus:SetPoint("LEFT", line, "LEFT", 0, PL.db.profile.indicatorVerticalOffset or 0)
        line.plus:SetText("|cff00ff00+|r")
        line.plus:SetParent(line)
        line.plus:SetJustifyH("RIGHT")

        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(PL.db.profile.iconSize, PL.db.profile.iconSize)
        line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        line.icon:SetParent(line)

        line.iconBorder = line:CreateTexture(nil, "BORDER")
        line.iconBorder:SetPoint("TOPLEFT", line.icon, "TOPLEFT", -1, 1)
        line.iconBorder:SetPoint("BOTTOMRIGHT", line.icon, "BOTTOMRIGHT", 1, -1)
        line.iconBorder:SetColorTexture(0,0,0,1)
        line.iconBorder:SetParent(line)

        line.text = line:CreateFontString(nil, "OVERLAY", nil)
        line.text:SetParent(line)
        line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
        line.text:SetJustifyH("LEFT")
        line.text:ClearAllPoints()
        line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)

        line:SetScript("OnUpdate", function(self, elapsed)
            if self.timer and self.timer > 0 then
                self.timer = self.timer - elapsed
                if self.slideX ~= 0 or self:GetAlpha() < 1 then
                    self.slideX = 0
                    self:SetAlpha(1)
                    self:SetPoint("TOPLEFT", self.anchorRef, self.anchorPoint, self.slideX, self.anchorYOffset)
                end
            else
                if self.highlighted then
                    self.highlighted = nil
                    StopHighlightVisual(self)
                end

                self.slideX = self.slideX + (elapsed * SLIDE_SPEED)
                if self.slideX > SLIDE_DISTANCE_MAX then self.slideX = SLIDE_DISTANCE_MAX end
                self:SetPoint("TOPLEFT", self.anchorRef, self.anchorPoint, self.slideX, self.anchorYOffset)

                local newAlpha = self:GetAlpha() - (elapsed * FADE_SPEED)
                if newAlpha > 0 then
                    self:SetAlpha(newAlpha)
                else
                    RemoveLine(self)
                end
            end
        end)
    end

    if not PL.plusWidth then PL.plusWidth = ComputePlusWidth() end
    line.plus:SetWidth(PL.plusWidth)

    line:SetAlpha(1)
    line:SetHeight(GetRowHeight())
    line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
    line.icon:SetSize(PL.db.profile.iconSize, PL.db.profile.iconSize)
    line.isPreview = nil
    line.itemLink = nil
    line:Show()
    return line
end

-- =========================================================================
-- Profession quality helpers
-- =========================================================================
local function BuildProfessionQualityIcon(itemLink)
    if not itemLink then return "" end
    if not C_TradeSkillUI or not C_TradeSkillUI.GetItemReagentQualityByItemInfo then
        return ""
    end

    local quality = C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemLink)
    if not quality or quality <= 0 or quality > 5 then
        return ""
    end

    if quality == 1 then
        return " |A:Professions-ChatIcon-Quality-Tier1:16:16|a"
    elseif quality == 2 then
        return " |A:Professions-ChatIcon-Quality-Tier2:16:16|a"
    elseif quality == 3 then
        return " |A:Professions-ChatIcon-Quality-Tier3:16:16|a"
    elseif quality == 4 then
        return " |A:Professions-ChatIcon-Quality-Tier4:16:16|a"
    elseif quality == 5 then
        return " |A:Professions-ChatIcon-Quality-Tier5:16:16|a"
    end

    return ""
end

local function ColorizeItemNameWithProfessionIcon(itemLink, fallbackName)
    if not itemLink and not fallbackName then
        return "|cffffffffUnknown Item|r"
    end

    local itemName = fallbackName or "Unknown Item"
    local quality = DEFAULT_QUALITY

    if itemLink and C_Item and C_Item.GetItemInfo then
        local name, _, linkQuality = C_Item.GetItemInfo(itemLink)
        if name then itemName = name end
        if linkQuality and linkQuality >= 0 and linkQuality <= 6 then
            quality = linkQuality
        end
    end

    local colorCode = qualityColors[quality] or qualityColors[1]
    local profIcon = BuildProfessionQualityIcon(itemLink)

    return string.format("%s%s|r%s", colorCode, itemName, profIcon or "")
end

-- =========================================================================
-- Add/Update Loot (uses InsertLineByPriority for insertion)
-- =========================================================================
local function AddOrUpdateLoot(key, iconPath, textHtml, quantity, isMoney, isCurrency, isLoss, isPreview, itemLink)
    local displayName = StripColors(textHtml)
    if not isPreview and IsBlacklisted(key, displayName) then return end

    local line
    for _, l in ipairs(activeLines) do
        if l.itemKey == key and ((l.isPreview and isPreview) or (not l.isPreview and not isPreview)) then
            if l.timer and l.timer <= 0 then
                -- already sliding/fading; let a new line be created
            else
                line = l
                break
            end
        end
    end

    if line then
        if isCurrency or line.isCurrency or line.isReputation then
            local signedQuantity = isLoss and -quantity or quantity
            line.currentCount = (line.currentCount or 0) + signedQuantity
        else
            line.currentCount = (line.currentCount or 0) + quantity
        end

        if isMoney then
            line.isMoney = true
            local color = line.currentCount >= 0 and "|cff00ff00" or "|cffff0000"
            local text = GetCoinTextureString(math.abs(line.currentCount))
            line.plus:SetText(color..(line.currentCount >= 0 and "+" or "-").."|r")
            line.text:SetText("|cffffffff"..text.."|r")
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, 0)
        elseif line.isReputation or isCurrency then
            line.isMoney = nil
            if line.currentCount == 0 then RemoveLine(line); return end
            local displayQuantity = math.abs(line.currentCount)
            local sign = line.currentCount >= 0 and "+" or "-"
            if line.isReputation then
                line.plus:SetText("|cffffa500REP|r")
                line.text:SetText(string.format("%s |cffffffff%s%d|r", line.baseName or textHtml, sign, displayQuantity))
            else
                line.plus:SetText("|cff89cff0CUR|r")
                line.text:SetText(string.format("%s |cffffffff%s%d|r", line.baseName or textHtml, sign, displayQuantity))
            end
        else
    -- Regular items: keep profession icon on updates too
    line.isMoney = nil

    local prettyName = ColorizeItemNameWithProfessionIcon(line.itemLink, StripColors(line.baseName or textHtml))
    local itemText   = string.format("%s x%d", prettyName, line.currentCount or quantity or 1)

    line.text:SetText(itemText)
    line.plus:SetText("|cff00ff00+|r")
end

        local baseDur = GetBaseDurationForLine(line)
        if line.highlighted then
            line.timer = GetHighlightDuration()
        else
            line.timer = baseDur
        end

        RecalculateQueue()
    else
        line = GetLine()
        line.itemKey = key
        line.itemLink = itemLink
        line.isPreview = isPreview and true or nil
        if isCurrency then
            line.currentCount = isLoss and -quantity or quantity
        else
            line.currentCount = quantity
        end
        line.baseName = textHtml
        line.slideX = 0
        line.isCurrency = isCurrency
        line.isReputation = type(key) == "string" and key:match("^REPUTATION_") ~= nil
        line.isMoney = isMoney and true or nil
        line.timer = GetBaseDurationForLine(line)

        if isMoney then
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            line.text:SetText("|cffffffff"..GetCoinTextureString(math.abs(line.currentCount)).."|r")
            line.plus:SetText(line.currentCount >= 0 and "|cff00ff00+|r" or "|cffff0000-|r")
            line.timer = PL.db.profile.durationCoins or GetHoldDuration()
        elseif line.isReputation then
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            local displayQuantity = math.abs(line.currentCount)
            local sign = line.currentCount >= 0 and "+" or "-"
            line.plus:SetText("|cffffa500REP|r")
            line.text:SetText(string.format("%s |cffffffff%s%d|r", textHtml, sign, displayQuantity))
            line.timer = PL.db.profile.durationRep or GetHoldDuration()
        elseif isCurrency then
            line.icon:Show()
            line.iconBorder:Show()
            line.icon:SetTexture(iconPath or DEFAULT_ICON)
            line.icon:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapWithIcon or 6, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            local displayQuantity = math.abs(line.currentCount)
            local sign = line.currentCount >= 0 and "+" or "-"
            line.plus:SetText("|cff89cff0CUR|r")
            line.text:SetText(string.format("%s |cffffffff%s%d|r", textHtml, sign, displayQuantity))
            line.timer = PL.db.profile.durationCurrency or GetHoldDuration()
        else
            -- Items: use full itemLink for profession quality where applicable
            line.icon:Show()
            line.iconBorder:Show()
            line.icon:SetTexture(iconPath or DEFAULT_ICON)
            line.icon:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapWithIcon or 6, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")

            local prettyName = ColorizeItemNameWithProfessionIcon(itemLink or line.itemLink, StripColors(textHtml))
            local itemText = string.format("%s x%d", prettyName, quantity)

            line.text:SetText(itemText)
            line.plus:SetText("|cff00ff00+|r")
            line.timer = PL.db.profile.durationItems or GetHoldDuration()
        end

        local isHighlightEntry = IsHighlighted(key, displayName) or key == "PREVIEW_HIGHLIGHT_ITEM"
        if isHighlightEntry then
            line.highlighted = true
            line.timer = GetHighlightDuration()
            StartHighlightVisual(line)
            if PL.db.profile.playSoundOnHighlight and not isPreview then
                local now = GetTime()
                local soundKey = PL.db.profile.highlightSound
                local sound = soundKey and soundKey ~= "" and LSM:Fetch("sound", soundKey)
                pcall(function()
                    if type(sound) == "number" then
                        if PlaySound then PlaySound(sound) end
                    else
                        if PlaySoundFile and type(sound) == "string" then PlaySoundFile(sound, "Master") end
                    end
                end)
                lastSoundTime = now
            end
        else
            line.highlighted = nil
        end

        InsertLineByPriority(line)

        if #activeLines > PL.db.profile.maxItems then RemoveLine(activeLines[1]) end
        RecalculateQueue()
    end
end

-- =========================================================================
-- Throttled queue
-- =========================================================================
local eventQueue = {}
local flushTimerActive = false

local function FlushEventQueue()
    flushTimerActive = false
    if #eventQueue == 0 then return end

    local merged = {}
    for _, ev in ipairs(eventQueue) do
        local key = ev.key
        if not merged[key] then
            merged[key] = {
                key = key,
                icon = ev.icon,
                text = ev.text,
                signed = ev.signed or 0,
                qty = ev.qty or 0,
                isMoney = ev.isMoney,
                isCurrency = ev.isCurrency,
                isReputation = ev.isReputation,
                itemLink = ev.itemLink,
            }
        else
            merged[key].signed = (merged[key].signed or 0) + (ev.signed or 0)
            merged[key].qty = (merged[key].qty or 0) + (ev.qty or 0)
            -- keep first itemLink; all events are same item
        end
    end

    eventQueue = {}

    for _, m in pairs(merged) do
        if m.isMoney then
            if (m.signed or 0) ~= 0 then
                AddOrUpdateLoot("MONEY", nil, GetCoinTextureString(math.abs(m.signed)), math.abs(m.signed), true, false, false, false, nil)
            end
        elseif m.isCurrency or m.isReputation then
            local signed = m.signed or 0
            if signed == 0 then
                if (m.qty or 0) > 0 then
                    AddOrUpdateLoot(m.key, m.icon, m.text, m.qty, false, m.isCurrency, false, false, m.itemLink)
                end
            else
                AddOrUpdateLoot(m.key, m.icon, m.text, math.abs(signed), false, m.isCurrency, signed < 0, false, m.itemLink)
            end
        else
            if (m.qty or 0) > 0 then
                AddOrUpdateLoot(m.key, m.icon, m.text, m.qty, false, false, false, false, m.itemLink)
            end
        end
    end
end

local function QueueEvent(ev)
    table.insert(eventQueue, ev)
    if not flushTimerActive then
        flushTimerActive = true
        C_Timer.After(FLUSH_DELAY, FlushEventQueue)
    end
end

-- =========================================================================
-- Currency & reputation snapshot/change
-- =========================================================================
local function SnapshotCurrencies()
    if not PL.db.profile.trackCurrencies then return end
    currencySnapshot = {}
    if not C_CurrencyInfo then return end

    local currencies = C_CurrencyInfo.GetCurrencyListSize() or 0
    local changed = true
    while changed do
        changed = false
        for i = 1, currencies do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and info.isHeader and not info.isHeaderExpanded then
                C_CurrencyInfo.ExpandCurrencyList(i, true)
                changed = true
            end
        end
        if changed then currencies = C_CurrencyInfo.GetCurrencyListSize() or currencies end
    end

    for i = 1, currencies do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and info.currencyID and not info.isHeader then
            local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(info.currencyID)
            if currencyInfo then currencySnapshot[info.currencyID] = currencyInfo.quantity or 0
            else currencySnapshot[info.currencyID] = 0 end
        end
    end

    PL.plusWidth = ComputePlusWidth()
    UpdateParsedLists()
end

local function CheckCurrencyChanges(currencyID, totalAmount)
    if not PL.db.profile.trackCurrencies then return end
    if not currencyID then return end

    if not totalAmount and C_CurrencyInfo then
        local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(currencyID)
        if not currencyInfo then return end
        totalAmount = currencyInfo.quantity or 0
    end

    local previousAmount = currencySnapshot[currencyID]
    if previousAmount == nil then currencySnapshot[currencyID] = totalAmount; return end

    local difference = totalAmount - previousAmount
    currencySnapshot[currencyID] = totalAmount
    if difference == 0 then return end

    local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(currencyID)
    if not currencyInfo or not currencyInfo.name then return end

    local nameColor = "|cffffffff"
    if currencyInfo.quality then
        local qualityColor = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[currencyInfo.quality]
        if qualityColor then nameColor = qualityColor.hex or nameColor end
    end

    local displayText = nameColor .. currencyInfo.name .. "|r"
    local iconPath = currencyInfo.iconFileID or DEFAULT_ICON

    QueueEvent({
        key = "CURRENCY_" .. currencyID,
        icon = iconPath,
        text = displayText,
        signed = difference,
        qty = math.abs(difference),
        isCurrency = true,
    })
end

local function SnapshotReputation()
    if not PL.db.profile.trackReputation then return end
    reputationSnapshot = {}
    if not C_Reputation then return end
    local numFactions = C_Reputation.GetNumFactions() or 0
    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.factionID then
            reputationSnapshot[factionData.factionID] = {
                standing = factionData.reaction or factionData.standing or 4,
                currentValue = factionData.standing or factionData.currentReaction or factionData.currentValue or 0,
                isParagon = C_Reputation.IsFactionParagon and C_Reputation.IsFactionParagon(factionData.factionID),
            }
        end
    end
    UpdateParsedLists()
end

local function CheckReputationChanges()
    if not PL.db.profile.trackReputation then return end
    if not C_Reputation then return end

    local numFactions = C_Reputation.GetNumFactions() or 0
    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.factionID then
            local oldData = reputationSnapshot[factionData.factionID]
            if oldData then
                local newStanding = factionData.reaction or factionData.standing or 4
                local newValue = factionData.standing or factionData.currentReaction or factionData.currentValue or 0
                if oldData.currentValue ~= newValue or oldData.standing ~= newStanding then
                    local change = newValue - oldData.currentValue
                    if oldData.standing ~= newStanding then
                        local oldMax = select(2, C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(factionData.factionID) or nil) or 0
                        change = (oldMax - oldData.currentValue) + newValue
                    end
                    if change ~= 0 then
                        local isLoss = change < 0
                        local factionName = factionData.name or "Unknown Faction"
                        local standingColor = repColors[newStanding] or repColors[4]
                        local displayText = standingColor .. factionName .. "|r"
                        QueueEvent({
                            key = "REPUTATION_" .. factionData.factionID,
                            icon = nil,
                            text = displayText,
                            signed = change,
                            qty = math.abs(change),
                            isReputation = true,
                        })
                        reputationSnapshot[factionData.factionID].standing = newStanding
                        reputationSnapshot[factionData.factionID].currentValue = newValue
                    end
                end
            end
        end
    end
end

-- =========================================================================
-- Profile helpers: create/delete/apply character profile by default
-- =========================================================================
local function CopyProfileValuesTo(targetProfileTable, sourceProfileTable)
    for k, _ in pairs(defaults.profile) do
        targetProfileTable[k] = DeepCopy(sourceProfileTable[k])
    end
end

function PrettyLoot:ApplyCharacterProfileDefault()
    local db = self.db
    local currentProfileData = DeepCopy(db.profile)
    local charProfileName = (UnitName("player") or "character") .. "-" .. (GetRealmName() or "realm")
    if db:GetCurrentProfile() ~= charProfileName then
        db:SetProfile(charProfileName)
        CopyProfileValuesTo(db.profile, currentProfileData)
    end
    UpdateParsedLists()
end

function PrettyLoot:CreateProfile(newName)
    local db = self.db
    if not newName or Trim(newName) == "" then DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: profile name required"); return end
    local oldProfileData = DeepCopy(db.profile)
    local exists = false
    for _, n in ipairs(db:GetProfiles()) do if n == newName then exists = true ; break end end
    if exists then
        db:SetProfile(newName)
        UpdateParsedLists()
        return
    end
    db:SetProfile(newName)
    CopyProfileValuesTo(db.profile, oldProfileData)
    UpdateParsedLists()
end

function PrettyLoot:DeleteProfile(profileName)
    if not profileName or profileName == self.db:GetCurrentProfile() then DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: cannot delete current profile"); return end
    if profileName == "Default" then DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: cannot delete Default profile"); return end
    local ok, err = pcall(function() PL.db:DeleteProfile(profileName) end)
    if not ok then
        if PL.db and PL.db.global and PL.db.global.profiles then
            PL.db.global.profiles[profileName] = nil
        end
    end
end

-- =========================================================================
-- Import / Export helpers
-- =========================================================================
local function SerializeProfileTable(tbl)
    if AceSerializer then
        local ok, s = pcall(function() return AceSerializer:Serialize(tbl) end)
        if ok and s then return s end
    end
    local lines = {}
    for k, _ in pairs(defaults.profile) do
        local v = tbl[k]
        if type(v) == "table" then
            lines[#lines+1] = k .. "=%TABLE%"
        else
            local val = tostring(v):gsub("\n","\\n")
            lines[#lines+1] = k .. "=" .. val
        end
    end
    return table.concat(lines, "\n")
end

local function DeserializeProfileString(s)
    if not s or s == "" then return nil end
    if AceSerializer then
        local ok, obj = pcall(function() return AceSerializer:Deserialize(s) end)
        if ok and obj then return obj end
    end
    local t = {}
    for line in s:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then
            v = v:gsub("\\n", "\n")
            if v == "true" then t[k] = true
            elseif v == "false" then t[k] = false
            elseif tonumber(v) and tostring(tonumber(v)) == v then t[k] = tonumber(v)
            else t[k] = v end
        end
    end
    return t
end

local function removeOkayButtons(frame)
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if child and child.GetObjectType and child:GetObjectType() == "Button" then
            local text
            if child.GetText then
                local ok, t = pcall(function() return child:GetText() end)
                if ok then
                    text = t
                end
            end

            if text and (text == "Okay" or text == "OK" or text == "OkayButton") then
                child:Hide()
            else
                local name = child.GetName and child:GetName()
                if name and (name:find("Okay", 1, true) or name:find("OK", 1, true)) then
                    child:Hide()
                end
            end
        end
    end
end

local exportFrame = nil
local function OpenExportDialog()
    if exportFrame and exportFrame:IsShown() then
        exportFrame:Raise()
        return
    end

    local WIDTH, HEIGHT = 320, 190
    local PAD = 14
    local innerWidth = WIDTH - PAD * 2
    local editHeight = 88

    local f = CreateFrame("Frame", "PrettyLootExportDialog", UIParent, "DialogBoxFrame")
    f:SetParent(UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel((UIParent:GetFrameLevel() or 0) + 2000)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetMovable(true)
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("PrettyLoot — Export Profile")

    local instr = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instr:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -36)
    instr:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -36)
    instr:SetJustifyH("LEFT")
    instr:SetText("Profile data. Press Ctrl+C to copy.")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -54)
    scroll:SetSize(innerWidth - 22, editHeight)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(innerWidth - 22 - 8)
    edit:SetHeight(editHeight - 8)
    edit:SetAutoFocus(true)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetTextInsets(4, 4, 4, 4)
    scroll:SetScrollChild(edit)

    local profileCopy = DeepCopy(PL.db.profile)
    local s = SerializeProfileTable(profileCopy)
    edit:SetText(s)
    edit:SetFocus()
    edit:HighlightText()

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(100, 24)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 12)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    removeOkayButtons(f)

    exportFrame = f
    f:Show()
    f:Raise()
end

local importFrame = nil
local function OpenImportDialog()
    if importFrame and importFrame:IsShown() then
        importFrame:Raise()
        return
    end

    local WIDTH, HEIGHT = 320, 190
    local PAD = 14
    local innerWidth = WIDTH - PAD * 2
    local editHeight = 88

    local f = CreateFrame("Frame", "PrettyLootImportDialog", UIParent, "DialogBoxFrame")
    f:SetParent(UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel((UIParent:GetFrameLevel() or 0) + 2000)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetMovable(true)
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("PrettyLoot — Import Profile")

    local instr = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instr:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -36)
    instr:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -36)
    instr:SetJustifyH("LEFT")
    instr:SetText("Paste profile data here, then click Import to apply it.")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -54)
    scroll:SetSize(innerWidth - 22, editHeight)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(innerWidth - 22 - 8)
    edit:SetHeight(editHeight - 8)
    edit:SetAutoFocus(true)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetTextInsets(4, 4, 4, 4)
    scroll:SetScrollChild(edit)

    local btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImport:SetSize(100, 24)
    btnImport:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 12)
    btnImport:SetText("Import")
    btnImport:SetScript("OnClick", function()
        local txt = edit:GetText()
        if not txt or txt == "" then
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: paste profile data first")
            return
        end
        local t = DeserializeProfileString(txt)
        if not t then
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: import failed (invalid data)")
            return
        end
        for k, _ in pairs(defaults.profile) do
            if t[k] ~= nil then
                PL.db.profile[k] = DeepCopy(t[k])
            end
        end
        UpdateParsedLists()
        DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: profile data imported into current profile")
        f:Hide()
    end)

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(100, 24)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 12)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    removeOkayButtons(f)

    importFrame = f
    f:Show()
    f:Raise()
end

-- =========================================================================
-- Options
-- =========================================================================
function PrettyLoot:SetupOptions()
    local function GetProfileList()
        local t = {}
        for _, name in ipairs(self.db:GetProfiles()) do t[name] = name end
        return t
    end

    local highlightStyles = {
        popout = "Pop-out",
        pulse = "Pulse",
        background = "Background colour",
    }

    local options = {
        name = "PrettyLoot",
        handler = self,
        type = "group",
        childGroups = "tree",
        args = {
            lock = {
                type = "toggle",
                name = "Lock Window",
                order = 1,
                get = function() return self.db.profile.locked end,
                set = function(info, value)
                    self.db.profile.locked = value
                    if value then
                        highlight:Hide(); highlightHeader:Hide(); highlightText:Hide()
                    else
                        highlight:Show(); highlightHeader:Show(); highlightText:Show(); UpdateHighlightSize()
                    end
                end,
            },
            preview = {
                type = "execute",
                name = "Preview Loot",
                order = 2,
                desc = "Show a demo set of loot notifications demonstrating priority ordering.",
                func = function()
                    ClearPreviewLines()

                    AddOrUpdateLoot("PREVIEW_MONEY", nil, GetCoinTextureString(12345), 12345, true, false, false, true, nil)
                    AddOrUpdateLoot("PREVIEW_REP", nil, "|cffffa500Preview Reputation|r", 50, false, false, false, true, nil)
                    AddOrUpdateLoot("PREVIEW_CURRENCY", "Interface\\Icons\\INV_Misc_Coin_01", "|cffffffffPreview Currency|r", 12, false, true, false, true, nil)
                    AddOrUpdateLoot("PREVIEW_ITEM", "Interface\\Icons\\INV_Misc_Herb_16", "|cffffffffPreview Item|r", 3, false, false, false, true, nil)

                    local highlightName = "|cff00ff00Highlighted Preview Item|r"
                    AddOrUpdateLoot("PREVIEW_HIGHLIGHT_ITEM", "Interface\\Icons\\INV_Misc_Rune_01", highlightName, 1, false, false, false, true, nil)
                end,
            },
            resetPos = {
                type = "execute",
                name = "Reset Position",
                order = 3,
                func = function()
                    self.db.profile.x = 0; self.db.profile.y = 200; self:ApplySavedPosition()
                end,
            },

            general = {
                type = "group",
                name = "General",
                order = 10,
                args = {
                    trackingHeader = { type = "header", name = "Tracking Options", order = 1 },
                    trackCurrencies = {
                        type = "toggle",
                        name = "Track Currencies",
                        order = 2,
                        get = function() return self.db.profile.trackCurrencies end,
                        set = function(info, value) self.db.profile.trackCurrencies = value if value then SnapshotCurrencies() end end,
                    },
                    trackReputation = {
                        type = "toggle",
                        name = "Track Reputation",
                        order = 3,
                        get = function() return self.db.profile.trackReputation end,
                        set = function(info, value) self.db.profile.trackReputation = value if value then SnapshotReputation() end end,
                    },

                    durationsHeader = { type = "header", name = "Duration Settings", order = 10 },
                    durationCoins = { type = "range", name = "Duration: Coins", min = 1, max = 60, step = 1, order = 11, get = function() return self.db.profile.durationCoins end, set = function(info, v) self.db.profile.durationCoins = v end },
                    durationItems = { type = "range", name = "Duration: Items", min = 1, max = 60, step = 1, order = 12, get = function() return self.db.profile.durationItems end, set = function(info, v) self.db.profile.durationItems = v end },
                    durationCurrency = { type = "range", name = "Duration: Currency", min = 1, max = 60, step = 1, order = 13, get = function() return self.db.profile.durationCurrency end, set = function(info, v) self.db.profile.durationCurrency = v end },
                    durationRep = { type = "range", name = "Duration: Rep", min = 1, max = 60, step = 1, order = 14, get = function() return self.db.profile.durationRep end, set = function(info, v) self.db.profile.durationRep = v end },
                    durationHighlight = {
                        type = "range",
                        name = "Duration: Highlighted",
                        desc = "How long highlighted items stay on screen before fading.",
                        min = 1,
                        max = 60,
                        step = 1,
                        order = 15,
                        get = function() return self.db.profile.durationHighlight or 5 end,
                        set = function(info, v) self.db.profile.durationHighlight = v end,
                    },
                    globalDuration = { type = "range", name = "Global Duration (Fallback)", min = 1, max = 60, step = 1, order = 16, get = function() return self.db.profile.holdDuration end, set = function(info, v) self.db.profile.holdDuration = v end },
                },
            },

            display = {
                type = "group",
                name = "Display",
                order = 20,
                args = {
                    displayHeader = { type = "header", name = "Display Settings", order = 1 },
                    iconSize = { type = "range", name = "Icon Size", min = 8, max = 30, step = 1, order = 2, get = function() return self.db.profile.iconSize end, set = function(info, v) self.db.profile.iconSize = v for _,line in ipairs(activeLines) do line.icon:SetSize(v, v) end UpdateHighlightSize(); RecalculateQueue() end },
                    textSize = { type = "range", name = "Text Size", min = 8, max = 30, step = 1, order = 3, get = function() return self.db.profile.textSize end, set = function(info, v) self.db.profile.textSize = v for _,line in ipairs(activeLines) do line.text:SetFont(GetFont(), v, "OUTLINE") end PL.plusWidth = ComputePlusWidth(); for _,line in ipairs(activeLines) do if line.plus then line.plus:SetWidth(PL.plusWidth) end end UpdateHighlightSize(); RecalculateQueue() end },
                    rowHeight = { type = "range", name = "Row Height", min = 10, max = 30, step = 1, order = 4, get = function() return self.db.profile.rowHeight end, set = function(info, v) self.db.profile.rowHeight = v for _,line in ipairs(activeLines) do line:SetHeight(v) end UpdateHighlightSize(); RecalculateQueue() end },
                    rowSpacing = { type = "range", name = "Row Spacing", min = 0, max = 10, step = 1, order = 5, get = function() return self.db.profile.rowSpacing end, set = function(info, v) self.db.profile.rowSpacing = v UpdateHighlightSize(); RecalculateQueue() end },
                    maxItems = { type = "range", name = "Max Items", min = 1, max = 30, step = 1, order = 6, get = function() return self.db.profile.maxItems end, set = function(info, v) self.db.profile.maxItems = v while #activeLines > v do RemoveLine(activeLines[1]) end UpdateHighlightSize(); RecalculateQueue() end },
                    font = { type = "select", dialogControl = "LSM30_Font", name = "Font", values = LSM:HashTable("font"), order = 7, get = function() return self.db.profile.fontKey end, set = function(info, key) self.db.profile.fontKey = key for _,line in ipairs(activeLines) do line.text:SetFont(GetFont(), self.db.profile.textSize, "OUTLINE") end PL.plusWidth = ComputePlusWidth(); for _,line in ipairs(activeLines) do if line.plus then line.plus:SetWidth(PL.plusWidth) end end RecalculateQueue() end },
                },
            },

            lists = {
                type = "group",
                name = "Blacklist / Highlight",
                order = 30,
                args = {
                    soundHeader = { type = "header", name = "Sound Settings", order = 1 },
                    playSoundOnHighlight = { type = "toggle", name = "Play sound on highlight", order = 2, get = function() return self.db.profile.playSoundOnHighlight end, set = function(info, v) self.db.profile.playSoundOnHighlight = v end },
                    highlightSound = { type = "select", dialogControl = "LSM30_Sound", name = "Highlight sound", order = 3, values = function() return LSM:HashTable("sound") end, get = function() return self.db.profile.highlightSound end, set = function(info, key) self.db.profile.highlightSound = key end },

                    visualHeader = { type = "header", name = "Highlight Visuals", order = 5 },
                    highlightStyle = {
                        type = "select",
                        name = "Highlight style",
                        order = 6,
                        values = highlightStyles,
                        get = function() return self.db.profile.highlightStyle or "popout" end,
                        set = function(info, v) self.db.profile.highlightStyle = v end,
                    },
                    highlightBackgroundColour = {
                        type = "color",
                        name = "Highlight background colour",
                        order = 7,
                        hasAlpha = true,
                        hidden = function() return (self.db.profile.highlightStyle or "popout") ~= "background" end,
                        get = function()
                            local c = self.db.profile.highlightBackgroundColour or { r = 0.4, g = 0.2, b = 0.7, a = 0.25 }
                            return c.r or 0.4, c.g or 0.2, c.b or 0.7, c.a or 0.25
                        end,
                        set = function(info, r, g, b, a)
                            self.db.profile.highlightBackgroundColour = { r = r, g = g, b = b, a = a }
                        end,
                    },

                    previewHighlight = {
                        type = "execute",
                        name = "Preview highlighted item",
                        order = 8,
                        desc = "Show a single highlighted item using the current highlight settings.",
                        func = function()
                            ClearPreviewLines()
                            local highlightName = "|cff00ff00Highlighted Preview Item|r"
                            AddOrUpdateLoot("PREVIEW_HIGHLIGHT_ITEM", "Interface\\Icons\\INV_Misc_Rune_01", highlightName, 1, false, false, false, true, nil)
                        end,
                    },

                    listsHeader = { type = "header", name = "Lists", order = 10 },
                    blacklistDesc = { type = "description", name = "Blacklisted Items: these entries are ignored. Enter exact names or use '*' wildcards (case-insensitive). You can also enter numeric IDs or prefixes like CURRENCY:123.", order = 11 },
                    blacklist = { type = "input", multiline = true, width = "full", name = "Blacklisted Items", desc = "Comma or newline separated. Example: Silk Cloth, Silk*, 12345, CURRENCY:789", order = 12, get = function() return self.db.profile.blacklist end, set = function(info, v) self.db.profile.blacklist = v UpdateParsedLists() end },

                    highlightDesc = { type = "description", name = "Highlighted Items: entries here extend display time and optionally play sound. Use exact names or '*' wildcards (case-insensitive).", order = 20 },
                    highlight = { type = "input", multiline = true, width = "full", name = "Highlighted Items", desc = "Comma or newline separated. Example: Opulent Bracers, *cloth, REPUTATION:123", order = 21, get = function() return self.db.profile.highlight end, set = function(info, v) self.db.profile.highlight = v UpdateParsedLists() end },
                },
            },

            profiles = {
                type = "group",
                name = "Profiles",
                order = 40,
                args = {
                    profileHeader = { type = "header", name = "Profile Management", order = 1 },
                    profileSelect = { type = "select", name = "Active Profile", desc = "Switch profiles", order = 2, values = function() return GetProfileList() end, get = function() return self.db:GetCurrentProfile() end, set = function(info, name) self.db:SetProfile(name); UpdateParsedLists(); end },

                    newProfileName = {
                        type = "input",
                        name = "New profile name",
                        desc = "Enter a name for a new profile.",
                        order = 10,
                        width = "full",
                        get = function() return PL._newProfileName or "" end,
                        set = function(info, val) PL._newProfileName = Trim(val) end,
                    },

                    createProfile = {
                        type = "execute",
                        name = "Create profile",
                        desc = "Create a new profile by copying current settings. Tip: you can also create via slash: /pl create <name>",
                        order = 11,
                        func = function()
                            local name = PL._newProfileName
                            if not name or name == "" then DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: enter a name in the 'New profile name' box first"); return end
                            PrettyLoot:CreateProfile(name)
                            PL._newProfileName = ""
                        end,
                    },

                    deleteProfile = {
                        type = "execute",
                        name = "Delete profile",
                        desc = "Delete the selected profile (cannot delete Default or the active profile).",
                        order = 20,
                        func = function()
                            local sel = PrettyLoot.db:GetCurrentProfile()
                            if not sel or sel == "Default" then DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: cannot delete Default profile"); return end
                            StaticPopupDialogs["PRETTYLOOT_DELETE_PROFILE"] = StaticPopupDialogs["PRETTYLOOT_DELETE_PROFILE"] or {
                                text = "Delete profile '%s'? This cannot be undone.",
                                button1 = "Delete",
                                button2 = "Cancel",
                                OnAccept = function(self, data) PrettyLoot:DeleteProfile(data) end,
                                timeout = 0,
                                whileDead = true,
                                hideOnEscape = true,
                            }
                            StaticPopup_Show("PRETTYLOOT_DELETE_PROFILE", sel, nil, sel)
                        end,
                    },

                    exportProfile = {
                        type = "execute",
                        name = "Export Profile",
                        desc = "Export the current profile and open a copyable dialog.",
                        order = 30,
                        func = function() OpenExportDialog() end,
                    },

                    importProfile = {
                        type = "execute",
                        name = "Import Profile",
                        desc = "Open the Import dialog to paste profile data.",
                        order = 31,
                        func = function() OpenImportDialog() end,
                    },
                },
            },
        },
    }

    AceConfig:RegisterOptionsTable("PrettyLoot", options)
    AceConfigDialog:AddToBlizOptions("PrettyLoot", "PrettyLoot")
end

-- =========================================================================
-- Event handlers
-- =========================================================================
function PrettyLoot:CHAT_MSG_LOOT(event, message, _, _, _, sender)
    local senderName = sender and sender:match("^[^-]+")
    if senderName and senderName ~= UnitName("player") then return end
    local itemLink = string.match(message or "", "|Hitem:.-|h.-|h|r")
    if not itemLink then return end
    local quantity = tonumber(string.match(message, "x(%d+)")) or 1
    local itemID = tonumber(string.match(itemLink, "item:(%d+)"))
    if not itemID or itemID == 0 then return end
    local itemIcon = C_Item.GetItemIconByID(itemID) or DEFAULT_ICON
    local itemName = C_Item.GetItemNameByID(itemID) or string.match(message, "%[(.-)%]") or "Unknown Item"
    local itemQuality = C_Item.GetItemQualityByID(itemID) or DEFAULT_QUALITY
    local colorCode = qualityColors[itemQuality] or qualityColors[1]

    ClearPreviewLines()

    QueueEvent({
        key = tostring(itemID),
        icon = itemIcon,
        text = colorCode .. itemName .. "|r",
        qty = quantity,
        isMoney = false,
        isCurrency = false,
        itemLink = itemLink,
    })
end

function PrettyLoot:PLAYER_MONEY()
    local newMoney = GetMoney()
    local oldMoney = self.savedOldMoney or newMoney
    if newMoney == oldMoney then return end
    local moneyChange, isLoss
    if newMoney > oldMoney then moneyChange = newMoney - oldMoney; isLoss = false else moneyChange = oldMoney - newMoney; isLoss = true end
    self.savedOldMoney = newMoney
    local signed = isLoss and -moneyChange or moneyChange

    ClearPreviewLines()

    QueueEvent({ key = "MONEY", icon = nil, text = GetCoinTextureString(math.abs(signed)), signed = signed, qty = math.abs(signed), isMoney = true })
end

function PrettyLoot:PLAYER_ENTERING_WORLD(event, isLogin, isReload)
    C_Timer.After(1, function() SnapshotCurrencies(); SnapshotReputation() end)
end

function PrettyLoot:CURRENCY_DISPLAY_UPDATE(event, currencyID, newAmount)
    ClearPreviewLines()
    CheckCurrencyChanges(currencyID, newAmount)
end

function PrettyLoot:UPDATE_FACTION()
    ClearPreviewLines()
    CheckReputationChanges()
end

function PrettyLoot:CHAT_MSG_COMBAT_FACTION_CHANGE(event, message)
    if not self.db.profile.trackReputation or not message then return end
    ClearPreviewLines()
    local faction, amount
    faction, amount = string.match(message, "Reputation with (.-) increased by (%d+)")
    if not faction then amount, faction = string.match(message, "You have gained (%d+) reputation with (.-)%.") end
    if not faction then faction, amount = string.match(message, "Your reputation with (.-) has increased by (%d+)") end
    if not faction then amount, faction = string.match(message, "You gain (%d+) reputation with (.-)%.") end
    if not faction then
        local num = string.match(message, "(%d+)")
        if num then
            amount = num
            local stripped = message:gsub("%d+", ""):gsub("reputation", ""):gsub("Reputation", ""):gsub("with", ""):gsub("increased", ""):gsub("decreased", ""):gsub("gained", ""):gsub("by", ""):gsub("%p", "")
            stripped = stripped:match("(%u%w[%w%s%-']+)") or stripped:match("(%a[%a%s%-']+)")
            faction = stripped and (stripped:gsub("^%s+", ""):gsub("%s+$", "")) or nil
        end
    end
    if faction and amount then
        amount = tonumber(amount)
        local isLoss = string.find(message, "decreased") ~= nil or string.find(message, "lose") ~= nil
        local factionID = nil
        if C_Reputation then
            local numFactions = C_Reputation.GetNumFactions() or 0
            local fl = string.lower(faction)
            for i = 1, numFactions do
                local f = C_Reputation.GetFactionDataByIndex(i)
                if f and f.name then
                    if f.name == faction or string.lower(f.name) == fl then factionID = f.factionID; break end
                    if string.find(string.lower(f.name), fl, 1, true) or string.find(fl, string.lower(f.name), 1, true) then factionID = f.factionID; break end
                end
            end
        end
        local color = "|cffffffff"
        if factionID and C_Reputation then
            local fdata = C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(factionID)
            if fdata and fdata.reaction then color = repColors[fdata.reaction] or color end
            QueueEvent({ key = "REPUTATION_" .. factionID, icon = nil, text = color .. faction .. "|r", signed = isLoss and -amount or amount, qty = amount, isReputation = true })
        else
            QueueEvent({ key = "REPUTATION_CHAT_" .. faction, icon = nil, text = color .. faction .. "|r", signed = isLoss and -amount or amount, qty = amount, isReputation = true })
        end
    end
end

-- =========================================================================
-- Initialisation
-- =========================================================================
function PrettyLoot:ApplySavedPosition()
    anchor:ClearAllPoints()
    anchor:SetPoint("CENTER", UIParent, "CENTER", self.db.profile.x or 0, self.db.profile.y or 200)
end

function PrettyLoot:OnInitialize()
    self.db = AceDB:New("PrettyLootDB", defaults, true)

    local charProfileName = (UnitName("player") or "character") .. "-" .. (GetRealmName() or "realm")
    local current = self.db:GetCurrentProfile()
    if not current or current == "Default" then
        local currentData = DeepCopy(self.db.profile)
        self.db:SetProfile(charProfileName)
        CopyProfileValuesTo(self.db.profile, currentData)
    end

    anchor = CreateFrame("Frame", "PrettyLootAnchor", UIParent)
    anchor:SetSize(300, 25)
    anchor:SetMovable(true)
    anchor:EnableMouse(false)
    anchor:SetClampedToScreen(true)

    highlightHeader = CreateFrame("Frame", nil, anchor)
    highlightHeader:SetSize(300, 25)
    highlightHeader:SetPoint("TOP", anchor, "TOP", 0, 0)
    local headerBg = highlightHeader:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(0, 0.5, 0, 0.4)
    highlightText = highlightHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    highlightText:SetPoint("CENTER", highlightHeader, "CENTER", 0, 0)
    highlightText:SetText("Pretty Loot")
    highlightText:SetTextColor(1,1,1,1)
    highlightText:Hide()
    highlightHeader:EnableMouse(true)
    highlightHeader:RegisterForDrag("LeftButton")
    highlightHeader:SetScript("OnDragStart", function() if not self.db.profile.locked then anchor:StartMoving() end end)
    highlightHeader:SetScript("OnDragStop", function() if not self.db.profile.locked then anchor:StopMovingOrSizing(); local _,_,_,x,y = anchor:GetPoint(); self.db.profile.x = x; self.db.profile.y = y end end)
    highlightHeader:Hide()

    highlight = CreateFrame("Frame", nil, anchor)
    highlight:SetPoint("TOP", highlightHeader, "BOTTOM", 0, 0)
    local highlightBg = highlight:CreateTexture(nil, "BACKGROUND")
    highlightBg:SetAllPoints()
    highlightBg:SetColorTexture(0,0,0,0.0)
    highlight:Hide()

    self:ApplySavedPosition()
    UpdateHighlightSize()

    self:SetupOptions()
    UpdateParsedLists()

    self:RegisterChatCommand("pl", "SlashCommand")

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00PrettyLoot Loaded|r - Type /pl for options")
end

function PrettyLoot:OnEnable()
    self:RegisterEvent("CHAT_MSG_LOOT")
    self:RegisterEvent("PLAYER_MONEY")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    self:RegisterEvent("UPDATE_FACTION")
    self:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
    self.savedOldMoney = GetMoney()
end

function PrettyLoot:SlashCommand(msg)
    msg = (msg or ""):lower()
    if msg == "unlock" then
        self.db.profile.locked = false
        highlight:Show(); highlightHeader:Show(); highlightText:Show()
    elseif msg == "lock" then
        self.db.profile.locked = true
        highlight:Hide(); highlightHeader:Hide(); highlightText:Hide()
    elseif msg:match("^create%s+(.+)$") then
        local name = msg:match("^create%s+(.+)$")
        if name and Trim(name) ~= "" then
            self:CreateProfile(name)
        else
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: usage: /pl create <profile name>")
        end
    else
        AceConfigDialog:Open("PrettyLoot")
    end
end