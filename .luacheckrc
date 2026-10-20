stds.wow = { read_globals = { table = { fields = { "wipe" } } } }
std = "lua51+wow"
max_line_length = false
self = false
exclude_files = { "libs/", ".release/" }

globals = {
	"SempreUI",
	"SempreDB",
	"SLASH_SEMPRE1",
	"SlashCmdList",
}

read_globals = {
	"C_AddOns",
	"CreateFrame",
	"GetBuildInfo",
	"GetLocale",
	"GetAddOnMemoryUsage",
	"UpdateAddOnMemoryUsage",
	"geterrorhandler",
	"issecretvalue",
}

