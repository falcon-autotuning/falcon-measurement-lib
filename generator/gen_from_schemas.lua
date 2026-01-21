-- generator/gen_from_schemas.lua
-- Usage:
--   lua generator/gen_from_schemas.lua <lib-schemas-dir> <script-schemas-dir> <source-lua-dir> <out-dir> [--no-generated-lua]
-- Example:
--   lua generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts ./lua ./generated --no-generated-lua
--
-- Emits editor-only generated/emmy/, generated/go-types/, and (if installed) generated/teal/.
-- Optionally emits generated/lua/ runtime modules unless --no-generated-lua is provided.
--
-- Requires: luafilesystem (lfs) and dkjson
local ok, lfs = pcall(require, "lfs")
if not ok then
	error("luafilesystem (lfs) is required. Install with: luarocks install luafilesystem")
end
local json_ok, json = pcall(require, "dkjson")
if not json_ok then
	error("dkjson is required. Install with: luarocks install dkjson")
end

-- Attempt to load Teal emitter (optional)
local ok_teal, teal_emitter = pcall(require, "generator.teal_emitter")
if not ok_teal then
	teal_emitter = nil
end

local io_open = io.open
local path_sep = package.config:sub(1, 1)

-- Helpers -------------------------------------------------------------------

local function ensure_dir(p)
	if not p or p == "" then
		return true
	end
	return os.execute(("mkdir -p %q"):format(p))
end

local function read_file(path)
	local f, err = io_open(path, "rb")
	if not f then
		return nil, err
	end
	local d = f:read("*a")
	f:close()
	return d
end

local function write_file(path, content)
	local dir = path:match("(.+)" .. path_sep)
	if dir then
		ensure_dir(dir)
	end
	local f, err = io_open(path, "wb")
	if not f then
		return nil, err
	end
	f:write(content)
	f:close()
	return true
end

local function copy_file(src, dst)
	local d, err = read_file(src)
	if not d then
		return nil, err
	end
	ensure_dir(dst:match("(.+)" .. path_sep) or ".")
	return write_file(dst, d)
end

local function file_exists(p)
	local a = lfs.attributes(p)
	return a ~= nil
end

local function list_json_files(dir)
	local out = {}
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local full = dir .. path_sep .. entry
			local attr = lfs.attributes(full)
			if attr and attr.mode == "file" and entry:match("%.json$") then
				table.insert(out, full)
			end
		end
	end
	table.sort(out)
	return out
end

local function parse_json_file(path)
	local s, err = read_file(path)
	if not s then
		return nil, err
	end
	local obj, pos, perr = json.decode(s, 1, nil)
	if not obj then
		return nil, perr
	end
	obj._schema_filename = path:match("[^" .. path_sep .. "]+$") or path
	return obj
end

local function read_schema_dir(dir)
	if not file_exists(dir) then
		return {}
	end
	local files = list_json_files(dir)
	local out = {}
	for _, f in ipairs(files) do
		local obj, err = parse_json_file(f)
		if not obj then
			error("parse error " .. f .. ": " .. tostring(err))
		end
		table.insert(out, obj)
	end
	return out
end

local function as_map(v)
	if type(v) == "table" then
		return v
	end
	return nil
end
local function as_string(v)
	if type(v) == "string" then
		return v
	end
	return ""
end
local function trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end
local function title_case(s)
	if s == "" then
		return s
	end
	return s:sub(1, 1):upper() .. s:sub(2)
end

-- Simple JSON Schema -> Go type mapping (keeps previous behavior)
local function go_type_from_schema(prop)
	if not prop then
		return "interface{}"
	end
	local t = as_string(prop.type or prop["type"])
	if t == "number" then
		return "float64"
	end
	if t == "integer" then
		return "int"
	end
	if t == "string" then
		return "string"
	end
	if t == "boolean" then
		return "bool"
	end
	if t == "object" then
		if prop["additionalProperties"] then
			local add = prop["additionalProperties"]
			if type(add) == "table" and add["$ref"] then
				local ref = add["$ref"]
				local parts = {}
				for part in ref:gmatch("[^/]+") do
					table.insert(parts, part)
				end
				return "map[string]" .. parts[#parts]
			end
		end
		return "map[string]interface{}"
	end
	if t == "array" then
		local items = prop.items
		if items and type(items) == "table" and items["$ref"] then
			local ref = items["$ref"]
			local parts = {}
			for part in ref:gmatch("[^/]+") do
				table.insert(parts, part)
			end
			return "[]" .. parts[#parts]
		end
		local it = as_string(items and (items.type or items["type"]))
		if it == "string" then
			return "[]string"
		end
		if it == "number" then
			return "[]float64"
		end
		if it == "integer" then
			return "[]int"
		end
		return "[]interface{}"
	end
	return "interface{}"
end

local function collect_defs_and_modules(lib_schemas)
	local defs = {}
	local modules = {}
	for _, s in ipairs(lib_schemas) do
		local d = as_map(s.definitions or s["definitions"])
		if d then
			for name, def in pairs(d) do
				defs[name] = def
				local xm = as_string(def["x-module"])
				if xm ~= "" then
					modules[name] = xm
				end
			end
		end
	end
	return defs, modules
end

local function path_from_module(modulePath)
	local parts = {}
	for p in modulePath:gmatch("[^.]+") do
		table.insert(parts, p)
	end
	return table.concat(parts, path_sep) .. ".lua"
end

-- Build Emmy header text. Always include a constructor field `new`.
local function build_emmy_header(modulePath, defName, def)
	local parts = {}
	for p in modulePath:gmatch("[^.]+") do
		table.insert(parts, p)
	end
	local sb = {}
	table.insert(sb, "---@meta")
	if def and def.description then
		table.insert(sb, ("--- %s"):format(def.description))
	end
	local className = defName or parts[#parts]
	table.insert(sb, string.format("---@class %s.%s", table.concat(parts, "."), className))
	table.insert(sb, string.format("---@class %s", className))
	if def and def.properties then
		local keys = {}
		for k, _ in pairs(def.properties) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, pk in ipairs(keys) do
			local pp = def.properties[pk]
			local jst = as_string(pp.type or pp["type"])
			local emmyt = "any"
			if jst == "number" then
				emmyt = "number"
			end
			if jst == "integer" then
				emmyt = "integer"
			end
			if jst == "string" then
				emmyt = "string"
			end
			if jst == "array" then
				emmyt = "any[]"
			end
			if jst == "object" then
				emmyt = "table"
			end
			table.insert(
				sb,
				string.format("---@field %s %s %s", pk, emmyt, as_string(pp.description or pp["description"]))
			)
		end
	end

	-- methods from x-methods
	if def and def["x-methods"] then
		for _, m in ipairs(def["x-methods"]) do
			local mname = as_string(m.name)
			local sig = as_string(m.signature)
			local funsig = "fun(...): any"
			if sig ~= "" then
				local rest = sig:gsub("^%s*" .. mname, "")
				rest = trim(rest)
				if rest ~= "" then
					funsig = "fun" .. rest
				end
			end
			table.insert(sb, string.format("---@field %s %s", mname, funsig))
			if m.description then
				table.insert(sb, ("--- %s"):format(as_string(m.description)))
			end
		end
	end

	-- always include constructor in the header
	table.insert(sb, string.format("---@field new fun(opts?: table): %s", className))

	return table.concat(sb, "\n")
end

-- Copy & annotate source module. Do NOT inject a constructor into copied source.
local function copy_and_annotate_source_module(src_root, dst_root, modulePath, defName, def)
	local rel = path_from_module(modulePath)
	local src = src_root .. path_sep .. rel
	local dst = dst_root .. path_sep .. rel
	if not file_exists(src) then
		return false, "source missing"
	end

	local content, err = read_file(src)
	if not content then
		return false, "read failed: " .. tostring(err)
	end

	local header = build_emmy_header(modulePath, defName, def)

	-- If the source already contains an Emmy header at top, don't duplicate; otherwise prepend the generated header.
	local combined
	if content:match("^%s*---@meta") then
		combined = content
	else
		combined = header .. "\n\n" .. content
	end

	ensure_dir(dst:match("(.+)" .. path_sep) or ".")
	write_file(dst, combined)
	return true
end

-- Generate a combined Emmy header + implementation for missing modules.
-- The prototype uses the CamelCase defName (if provided) so the constructor and methods
-- are attached to the same prototype that Emmy documents.
local function generate_combined_module(modulePath, defName, def, outLuaRoot)
	local rel = path_from_module(modulePath)
	local dest = outLuaRoot .. path_sep .. rel
	if file_exists(dest) then
		return
	end

	local header = build_emmy_header(modulePath, defName, def)
	local parts = {}
	for p in modulePath:gmatch("[^.]+") do
		table.insert(parts, p)
	end

	-- Use defName (CamelCase) for the prototype variable if present; otherwise use module leaf
	local protoName = defName or parts[#parts]
	-- sanitize protoName to be a valid Lua identifier (basic): replace non-alphanum with underscore
	protoName = protoName:gsub("[^%w_]", "_")

	local sb = {}
	table.insert(sb, header)
	table.insert(sb, "")
	table.insert(sb, "-- Auto-generated module implementation (with generic constructor)")
	table.insert(sb, "local M = {}")
	table.insert(sb, ("local %s = {}"):format(protoName))
	table.insert(sb, ("%s.__index = %s"):format(protoName, protoName))
	table.insert(sb, "")

	-- Methods: implement x-methods on prototype and expose them on M for LSP visibility
	if def and def["x-methods"] and type(def["x-methods"]) == "table" then
		for _, m in ipairs(def["x-methods"]) do
			local name = as_string(m.name)
			table.insert(sb, ("function %s:%s(...) return nil end"):format(protoName, name))
			table.insert(sb, ("M.%s = %s.%s"):format(name, protoName, name))
			table.insert(sb, "")
		end
	end

	-- generic constructor placed BEFORE return
	table.insert(sb, ("---@param opts table? Optional table of fields for %s"):format(protoName))
	table.insert(sb, ("---@return %s"):format(protoName))
	table.insert(sb, "function M.new(opts)")
	table.insert(sb, "  opts = opts or {}")
	table.insert(sb, ("  setmetatable(opts, %s)"):format(protoName))
	table.insert(sb, "  return opts")
	table.insert(sb, "")
	table.insert(sb, ("%s.new = M.new"):format(protoName))
	table.insert(sb, "")
	table.insert(sb, "return M")

	ensure_dir(dest:match("(.+)" .. path_sep) or ".")
	write_file(dest, table.concat(sb, "\n"))
end

-- Editor-only emmy file (kept for compatibility); includes constructor field
local function emit_emmy_file(modulePath, defName, def, outDir)
	local parts = {}
	for p in modulePath:gmatch("[^.]+") do
		table.insert(parts, p)
	end
	local outBase = outDir .. path_sep .. "emmy"
	for i = 1, #parts - 1 do
		outBase = outBase .. path_sep .. parts[i]
	end
	ensure_dir(outBase)
	local filename = outBase .. path_sep .. parts[#parts] .. ".lua"
	local sb = {}
	table.insert(sb, "---@meta")
	if def and def.description then
		table.insert(sb, ("--- %s"):format(def.description))
	end
	local className = defName or parts[#parts]
	table.insert(sb, string.format("---@class %s.%s", table.concat(parts, "."), className))
	table.insert(sb, string.format("---@class %s", className))
	if def and def.properties then
		local keys = {}
		for k, _ in pairs(def.properties) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, pk in ipairs(keys) do
			local pp = def.properties[pk]
			local jst = as_string(pp.type or pp["type"])
			local emmyt = "any"
			if jst == "number" then
				emmyt = "number"
			end
			if jst == "integer" then
				emmyt = "integer"
			end
			if jst == "string" then
				emmyt = "string"
			end
			if jst == "array" then
				table.insert(
					sb,
					string.format("---@field %s any[] %s", pk, as_string(pp.description or pp["description"]))
				)
			else
				if jst == "object" then
					emmyt = "table"
				end
				table.insert(
					sb,
					string.format("---@field %s %s %s", pk, emmyt, as_string(pp.description or pp["description"]))
				)
			end
		end
	end
	if def and def["x-methods"] then
		for _, m in ipairs(def["x-methods"]) do
			local mname = as_string(m.name)
			local sig = as_string(m.signature)
			local funsig = "fun(...): any"
			if sig ~= "" then
				local rest = sig:gsub("^%s*" .. mname, "")
				rest = trim(rest)
				if rest ~= "" then
					funsig = "fun" .. rest
				end
			end
			table.insert(sb, string.format("---@field %s %s", mname, funsig))
			if m.description then
				table.insert(sb, ("--- %s"):format(as_string(m.description)))
			end
		end
	end
	-- constructor
	table.insert(sb, string.format("---@field new fun(opts?: table): %s", className))

	table.insert(sb, "")
	table.insert(sb, "-- Try to return the runtime module if installed; otherwise return empty table for LSP.")
	table.insert(sb, string.format("local ok, m = pcall(require, %q)", modulePath))
	table.insert(sb, "if ok and type(m) == 'table' then")
	table.insert(sb, "  return m")
	table.insert(sb, "end")
	table.insert(sb, "")
	table.insert(sb, "return {}")
	write_file(filename, table.concat(sb, "\n"))
end

-- Generate Go types & helpers (single-file)
local function generate_go_types_and_helpers(defs, scripts, outDir)
	local lines = {}
	table.insert(lines, "// Code generated by gen_from_schemas.lua — DO NOT EDIT")
	table.insert(lines, "package generated")
	table.insert(lines, 'import "encoding/json"')
	local names = {}
	for n, _ in pairs(defs) do
		table.insert(names, n)
	end
	table.sort(names)
	for _, n in ipairs(names) do
		local def = defs[n]
		table.insert(lines, string.format("// %s: %s", n, as_string(def.description)))
		table.insert(lines, string.format("type %s struct {", n))
		if def.properties then
			local keys = {}
			for k, _ in pairs(def.properties) do
				table.insert(keys, k)
			end
			table.sort(keys)
			for _, pk in ipairs(keys) do
				local pp = def.properties[pk]
				local gtype = go_type_from_schema(pp)
				local field = title_case(pk)
				table.insert(
					lines,
					string.format(
						'    %s %s `json:"%s,omitempty"` // %s',
						field,
						gtype,
						pk,
						as_string(pp.description or pp["description"])
					)
				)
			end
		end
		table.insert(lines, "}")
		table.insert(lines, "")
	end

	for _, s in ipairs(scripts) do
		local title = as_string(s.title or s["title"])
		if title == "" then
			title = (s._schema_filename and s._schema_filename:gsub("%.json$", "")) or "ScriptContext"
		end
		local structName = title:gsub(" ", "_")
		table.insert(lines, string.format("// %s generated from schema", structName))
		table.insert(lines, string.format("type %s struct {", structName))
		if s.properties then
			local keys = {}
			for k, _ in pairs(s.properties) do
				table.insert(keys, k)
			end
			table.sort(keys)
			for _, pk in ipairs(keys) do
				local pp = s.properties[pk]
				local gtype = go_type_from_schema(pp)
				local field = title_case(pk)
				table.insert(
					lines,
					string.format(
						'    %s %s `json:"%s,omitempty"` // %s',
						field,
						gtype,
						pk,
						as_string(pp.description or pp["description"])
					)
				)
			end
		end
		table.insert(lines, "}")
		table.insert(lines, "")
		table.insert(lines, string.format("func (rc %s) ToMap() (map[string]interface{}, error) {", structName))
		table.insert(lines, "    b, err := json.Marshal(rc)")
		table.insert(lines, "    if err != nil { return nil, err }")
		table.insert(lines, "    var m map[string]interface{}")
		table.insert(lines, "    if err := json.Unmarshal(b, &m); err != nil { return nil, err }")
		table.insert(lines, "    return m, nil")
		table.insert(lines, "}")
		table.insert(lines, "")
	end

	ensure_dir(outDir .. path_sep .. "go-types")
	write_file(outDir .. path_sep .. "go-types" .. path_sep .. "generated_runtime_types.go", table.concat(lines, "\n"))

	if defs["InstrumentTarget"] then
		local hb = {}
		table.insert(hb, "// Code generated helpers — DO NOT EDIT")
		table.insert(hb, "package generated")
		table.insert(hb, 'import "fmt"')
		table.insert(hb, "func (t InstrumentTarget) Serialize() string {")
		table.insert(hb, "    if t.Channel != 0 {")
		table.insert(hb, '        return fmt.Sprintf("%s:%d", t.Id, t.Channel)')
		table.insert(hb, "    }")
		table.insert(hb, "    return t.Id")
		table.insert(hb, "}")
		write_file(outDir .. path_sep .. "go-types" .. path_sep .. "generated_helpers.go", table.concat(hb, "\n"))
	end
end

-- Main --------------------------------------------------------------------

local function usage_and_exit()
	print(
		"usage: lua generator/gen_from_schemas.lua <lib-schemas-dir> <script-schemas-dir> <source-lua-dir> <out-dir> [--no-generated-lua]"
	)
	os.exit(2)
end

-- Simple CLI args parsing: positional args plus optional flags (e.g., --no-generated-lua)
local raw_args = { ... }
local flags = {}
local posargs = {}
for _, v in ipairs(raw_args) do
	if tostring(v):match("^%-%-") then
		flags[v] = true
	else
		table.insert(posargs, v)
	end
end

if #posargs < 4 then
	usage_and_exit()
end

local libDir = posargs[1]
local scriptsDir = posargs[2]
local sourceLuaDir = posargs[3]
local outDir = posargs[4]

-- default: generate lua outputs; pass --no-generated-lua to disable
local generate_lua = not flags["--no-generated-lua"]

local libSchemas = read_schema_dir(libDir)
local scriptSchemas = read_schema_dir(scriptsDir)
local defs, modules = collect_defs_and_modules(libSchemas)

-- prepare generated output
if file_exists(outDir) then
	os.execute(("rm -rf %q"):format(outDir))
end
ensure_dir(outDir)

-- generated lua root (only if enabled)
local generatedLuaRoot = outDir .. path_sep .. "lua"
if generate_lua then
	ensure_dir(generatedLuaRoot)
else
	io.stderr:write("generator: skipping generated/lua output (--no-generated-lua)\n")
end

-- For each def: optionally create generated/lua implementations, but ALWAYS emit emmy headers
for defName, def in pairs(defs) do
	local modulePath = modules[defName] or ("falcon_measurement_lib." .. string.lower(defName))
	local rel = path_from_module(modulePath)
	local srcCandidate = sourceLuaDir .. path_sep .. rel
	if generate_lua then
		if file_exists(srcCandidate) then
			local ok, err = copy_and_annotate_source_module(sourceLuaDir, generatedLuaRoot, modulePath, defName, def)
			if not ok then
				error("copy annotate failed: " .. tostring(err))
			end
		else
			generate_combined_module(modulePath, defName, def, generatedLuaRoot)
		end
	end
	-- always produce editor-only emmy file for compatibility
	emit_emmy_file(modulePath, defName, def, outDir)
end

-- Emit Teal script scaffolds (if teal emitter available)
if teal_emitter then
	teal_emitter.emit_scripts(scriptSchemas, defs, modules, sourceLuaDir, outDir)
else
	io.stderr:write("generator: teal_emitter not available; skipping teal outputs\n")
end

-- Generate go types and helpers
generate_go_types_and_helpers(defs, scriptSchemas, outDir)

print("generator: wrote outputs to " .. outDir)
