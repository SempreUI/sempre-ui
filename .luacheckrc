stds.wow = { read_globals = { table = { fields = { "wipe" } } } }
std = "lua51+wow"
max_line_length = false
self = false
exclude_files = { "libs/", ".release/" }

globals = {
	"SempreUI",
	"SempreDB",
	"SempreItemsDB",
	"SLASH_SEMPRE1",
	"SlashCmdList",
}

read_globals = {
	"C_AddOns",
	"CreateFrame",
	"GetBuildInfo",
	"GetLocale",
	"GetRealmName",
	"UnitName",
	"GetAddOnMemoryUsage",
	"UpdateAddOnMemoryUsage",
	"geterrorhandler",
	"issecretvalue",
	"time",
	"C_Container",
	"C_Item",
	"C_EventUtils",
	"Enum",
	"InCombatLockdown",
	"UnitClass",
	"UnitFactionGroup",
	"UnitLevel",
	"GetMoney",
	"GetInventoryItemID",
	"GetInventoryItemLink",
	"GetInboxNumItems",
	"GetInboxHeaderInfo",
	"GetInboxItem",
	"GetInboxItemLink",
	"GetInboxInvoiceInfo",
	"ATTACHMENTS_MAX_RECEIVE",
	"TooltipDataProcessor",
	"RAID_CLASS_COLORS",
	"GameTooltip",
	"ItemRefTooltip",
}

