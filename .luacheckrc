std = "lua51"
max_line_length = 140
exclude_files = { "test/**", ".agents/**" }

files["spec/**"] = {
    std = "+busted",
    globals = { "GameTooltip" },
    read_globals = { "TakeInboxItem", "TakeInboxMoney", "AutoLootMailItem" },
}

globals = { "SalvagerDB", "SlashCmdList", "SLASH_SALVAGER1", "SLASH_SALVAGER2", "StaticPopupDialogs" }

read_globals = {
    "C_AddOns", "C_AuctionHouse", "C_Container", "C_Item", "C_Timer", "C_UnitAuras",
    "CreateFrame", "DEFAULT_CHAT_FRAME", "Enum", "GameTooltip", "GetCoinTextureString",
    "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxItemLink", "GetInboxNumItems", "GetLootSlotInfo", "GetLootSlotLink",
    "GetMoney", "GetNumLootItems", "GetTime", "IsPlayerSpell", "IsShiftKeyDown", "ItemRefTooltip",
    "TooltipDataProcessor", "UIParent", "UISpecialFrames", "ATTACHMENTS_MAX_RECEIVE",
    "BackdropTemplateMixin", "StaticPopup_Show", "ItemLocation", "Settings", "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "GetCursorPosition",
    "date", "hooksecurefunc", "time", "tinsert", "wipe",
}
