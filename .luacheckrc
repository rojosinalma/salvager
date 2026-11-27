std = "lua51"
max_line_length = 140
exclude_files = { "test/**", ".agents/**" }

files["spec/**"] = {
    std = "+busted",
    globals = { "GameTooltip" },
    read_globals = { "TakeInboxItem", "TakeInboxMoney", "AutoLootMailItem", "RepairAllItems" },
}

globals = { "SalvagerDB", "SalvagerBackup", "SlashCmdList", "SLASH_SALVAGER1", "SLASH_SALVAGER2", "StaticPopupDialogs" }

read_globals = {
    "C_AddOns", "C_AuctionHouse", "C_Container", "C_Item", "C_Texture", "C_Timer", "C_UnitAuras",
    "CreateFrame", "DEFAULT_CHAT_FRAME", "Enum", "GameTooltip", "GetCoinTextureString",
    "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxItemLink", "GetInboxNumItems", "GetLootSlotInfo", "GetLootSlotLink",
    "GetMoney", "GetInventoryItemID", "GetNumLootItems", "GetTime", "IsPlayerSpell", "IsShiftKeyDown", "ItemRefTooltip",
    "TooltipDataProcessor", "UIParent", "UISpecialFrames", "ATTACHMENTS_MAX_RECEIVE",
    "BackdropTemplateMixin", "StaticPopup_Show", "ItemLocation", "Settings", "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "GetCursorPosition",
    "UnitName", "GetRealmName", "GetNormalizedRealmName", "InCombatLockdown", "GetScreenWidth", "GetScreenHeight",
    "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_TabResize",
    "C_DateAndTime", "GetGameTime", "NUM_BAG_SLOTS", "GetCVarBool",
    "date", "hooksecurefunc", "time", "tinsert", "wipe",
}
