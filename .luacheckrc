std = "lua51"
globals = {
	"vim",
}
exclude_files = {
	"doc/*",
}
ignore = {
	"631", -- line is too long
	"211", -- unused variable
	"212", -- unused argument
	"311", -- value assigned to variable is unused
	"314", -- value of variable is mutated but never accessed
	"432", -- shadowing upvalue
}
