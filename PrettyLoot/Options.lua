-- Options.lua (Final Version)

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceAddon = LibStub("AceAddon-3.0")

local PL = AceAddon:GetAddon("PrettyLoot")

-- 1. Define the Options Schema (table structure)
local options = {
    name = "PrettyLoot",
    handler = PL,
    type = "group",
    args = {
        info = {
            order = 1,
            type = "description",
            name = "Use the buttons below, or the '/pl unlock' command to make the frame movable. Changes are applied instantly.",
        },
        lock = {
            order = 2,
            type = "toggle",
            name = "Lock Frame Position/Size",
            desc = "Prevents moving or resizing the loot frame.",
            get = function(info) return PL.db.profile.locked end,
            set = function(info, value)
                PL.db.profile.locked = value
                PL:UpdateAnchorVisuals()
            end,
        },
        reset = {
            order = 3,
            type = "execute",
            name = "Reset Frame Position",
            func = "HandleSlashCommand",
            arg = "reset",
        },
        scale = {
            order = 4,
            type = "range",
            name = "Display Scale",
            desc = "Adjusts the size of the loot window and text.",
            min = 0.5, max = 2.0, step = 0.1,
            get = function(info) return PL.db.profile.scale end,
            set = function(info, value)
                PL.db.profile.scale = value
                if PL.anchor then PL.anchor:SetScale(value) end
                PL:RecalculateQueue()
            end,
        },
        maxRows = {
            order = 5,
            type = "range",
            name = "Maximum Visible Rows",
            desc = "Sets the maximum number of items visible at once.",
            min = 3, max = 15, step = 1,
            get = function(info) return PL.db.profile.maxRows end,
            set = function(info, value) PL.db.profile.maxRows = value end,
        },
        holdDelay = {
            order = 6,
            type = "range",
            name = "Hold Duration (Seconds)",
            desc = "How long an item waits before starting to slide out/fade.",
            min = 1, max = 15, step = 1,
            get = function(info) return PL.db.profile.holdDelay end,
            set = function(info, value) PL.db.profile.holdDelay = value end,
        },
    },
}

-- 2. Register the Options (Now guaranteed to run after AceConfigDialog is loaded)
AceConfig:RegisterOptionsTable("PrettyLoot", options)
AceConfigDialog:AddToBlizzardOptions("PrettyLoot", "PrettyLoot")