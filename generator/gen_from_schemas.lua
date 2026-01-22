-- generator/gen_from_schemas.lua
-- Usage:
--   lua generator/gen_from_schemas.lua <lib-schemas-dir> <script-schemas-dir> <source-lua-dir> <out-dir> [--no-generated-lua]
--
-- This version:
--  - Emits editor-only Emmy headers (generated/emmy/)
--  - Emits Go types (generated/go-types/)
--  - Emits Teal "typing" modules (generated/teal/.../*.tl) for each schema definition. These
--    are typing-only modules that `require` the runtime Lua implementation and expose
--    Teal `record` types + signature-only function declarations so `tl`/Teal LSP can typecheck scripts.
--  - Emits Teal script scaffolds (generated/teal/scripts/*.tl) via generator/teal_emitter.lua.
--  - Optionally emits generated/lua/ runtime copies (default behavior), disable with --no-generated-lua.
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

-- Helper: extract name from $ref like ../lib/instrument_target.json#/definitions/InstrumentTarget
local function ref_to_name(ref)
	if not ref then
		return nil
	end
	local last = nil
	for part in tostring(ref):gmatch("[^/#]+") do
		last = part
	end
	return tostring(last)
end

-- Helper: extract name from $ref like ../lib/instrument_target.json#/definitions/InstrumentTarget
-- (ref_to_name already exists in the file; this function uses it)
local function go_type_from_schema(prop)
	if not prop then
		return "interface{}"
	end

	-- If the property is a $ref to a definition, map directly to the referenced type name
	if prop["$ref"] then
		local refname = ref_to_name(prop["$ref"])
		if refname and refname ~= "" then
			return refname
		end
	end

	-- If the property is an allOf that includes a $ref, pick the $ref target (useful in some schemas)
	if prop.allOf and type(prop.allOf) == "table" then
		for _, part in ipairs(prop.allOf) do
			if type(part) == "table" and part["$ref"] then
				local r = ref_to_name(part["$ref"])
				if r and r ~= "" then
					return r
				end
			end
		end
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

	-- Arrays: handle arrays of primitives or arrays of $ref
	if t == "array" and prop.items then
		local it = prop.items
		if it["$ref"] then
			return "[]" .. ref_to_name(it["$ref"])
		end
		local itype = as_string(it.type or it["type"])
		if itype == "number" then
			return "[]float64"
		end
		if itype == "integer" then
			return "[]int"
		end
		if itype == "string" then
			return "[]string"
		end
		if itype == "boolean" then
			return "[]bool"
		end
		-- fallback for complex array elements
		return "[]interface{}"
	end

	-- Objects with additionalProperties: map[string]<type>
	if t == "object" and prop["additionalProperties"] then
		local add = prop["additionalProperties"]
		if type(add) == "table" then
			if add["$ref"] then
				return string.format("map[string]%s", ref_to_name(add["$ref"]))
			end
			local atype = as_string(add.type or add["type"])
			if atype == "number" then
				return "map[string]float64"
			end
			if atype == "integer" then
				return "map[string]int"
			end
			if atype == "string" then
				return "map[string]string"
			end
			if atype == "boolean" then
				return "map[string]bool"
			end
			-- fallback
			return "map[string]interface{}"
		end
		-- If no additionalProperties described, produce a generic map
		return "map[string]interface{}"
	end

	-- fallback: unknown complex object -> interface{}
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

local function module_path_to_fs(modulePath)
	local parts = {}
	for p in modulePath:gmatch("[^.]+") do
		table.insert(parts, p)
	end
	return table.concat(parts, path_sep)
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

	local protoName = defName or parts[#parts]
	protoName = protoName:gsub("[^%w_]", "_")

	local sb = {}
	table.insert(sb, header)
	table.insert(sb, "")
	table.insert(sb, "-- Auto-generated module implementation (with generic constructor)")
	table.insert(sb, "local M = {}")
	table.insert(sb, ("local %s = {}"):format(protoName))
	table.insert(sb, ("%s.__index = %s"):format(protoName, protoName))
	table.insert(sb, "")

	-- Methods
	if def and def["x-methods"] and type(def["x-methods"]) == "table" then
		for _, m in ipairs(def["x-methods"]) do
			local name = as_string(m.name)
			table.insert(sb, ("function %s:%s(...) return nil end"):format(protoName, name))
			table.insert(sb, ("M.%s = %s.%s"):format(name, protoName, name))
			table.insert(sb, "")
		end
	end

	-- constructor
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

-- Write Teal typing module (.tl) for a def (typing-only)
local function write_teal_typing_for_def(modulePath, defName, def, outDir)
	local fs = module_path_to_fs(modulePath)
	local dest = outDir .. path_sep .. "teal" .. path_sep .. fs .. ".tl"
	ensure_dir(dest:match("(.+)" .. path_sep) or ".")
	local sb = {}
	table.insert(sb, "-- GENERATED TEAL TYPES - DO NOT EDIT")
	table.insert(sb, ("local _impl = require(%q)"):format(modulePath))
	table.insert(sb, "")

	-- record
	table.insert(sb, ("record %s"):format(defName))
	if def and def.properties then
		local keys = {}
		for k, _ in pairs(def.properties) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local p = def.properties[k]
			local t = "any"
			if p["$ref"] then
				t = ref_to_name(p["$ref"])
			elseif p.type == "number" then
				t = "number"
			elseif p.type == "integer" then
				t = "integer"
			elseif p.type == "string" then
				t = "string"
			elseif p.type == "boolean" then
				t = "boolean"
			elseif p.type == "array" then
				if p.items and p.items["$ref"] then
					t = "{ " .. ref_to_name(p.items["$ref"]) .. " }"
				elseif p.items and p.items.type then
					local it = p.items.type
					if it == "number" then
						t = "{ number }"
					elseif it == "string" then
						t = "{ string }"
					else
						t = "{ any }"
					end
				else
					t = "{ any }"
				end
			elseif p.type == "object" then
				t = "table"
			else
				t = "any"
			end

			local optional = "?"
			if def.required then
				local found = false
				for _, r in ipairs(def.required) do
					if r == k then
						found = true
						break
					end
				end
				if found then
					optional = ""
				end
			end

			table.insert(sb, ("  %s: %s%s"):format(k, t, optional))
		end
	end
	table.insert(sb, "end")
	table.insert(sb, "")

	-- constructor signature (attach to runtime impl)
	table.insert(sb, ("function _impl.new(opts?: table): %s end"):format(defName))

	-- x-methods signature placeholders
	if def and def["x-methods"] then
		for _, m in ipairs(def["x-methods"]) do
			local name = as_string(m.name)
			table.insert(sb, ("function _impl.%s(...): any end"):format(name))
		end
	end

	table.insert(sb, "")
	table.insert(sb, "return _impl")
	write_file(dest, table.concat(sb, "\n"))
end

-- Emit per-script emmy files
local function emit_emmy_scripts(scripts, outDir)
	local base = outDir .. path_sep .. "emmy" .. path_sep .. "scripts"
	ensure_dir(base)
	for _, s in ipairs(scripts) do
		local title = as_string(s.title or s["title"])
		if title == "" then
			title = (s._schema_filename and s._schema_filename:gsub("%.json$", "")) or "ScriptContext"
		end
		local name = title:gsub(" ", "_"):lower()
		local filename = base .. path_sep .. name .. "_emmy.lua"
		local sb = {}
		table.insert(sb, "---@meta")
		if s.description then
			table.insert(sb, ("--- %s"):format(s.description))
		end
		table.insert(sb, string.format("---@class %s", title))
		if s.properties then
			local keys = {}
			for k, _ in pairs(s.properties) do
				table.insert(keys, k)
			end
			table.sort(keys)
			for _, pk in ipairs(keys) do
				local pp = s.properties[pk]
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
					if pp.items and pp.items["$ref"] then
						local ref = as_string(pp.items["$ref"])
						local parts = {}
						for part in ref:gmatch("[^/]+") do
							table.insert(parts, part)
						end
						emmyt = parts[#parts] .. "[]"
					else
						emmyt = "any[]"
					end
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
		table.insert(sb, "\nreturn {}")
		write_file(filename, table.concat(sb, "\n"))
	end
end

-- Generates Go types & helpers (single-file)
local function generate_go_types_and_helpers(defs, scripts, outDir)
	local lines = {}
	table.insert(lines, "// Code generated by gen_from_schemas.lua — DO NOT EDIT")
	table.insert(lines, "package generated")
	table.insert(lines, "")
	table.insert(lines, "import (")
	table.insert(lines, '  "encoding/json"')
	-- fmt only needed if InstrumentTarget helper is generated later; add unconditionally if present
	table.insert(lines, '  "fmt"')
	table.insert(lines, ")")
	table.insert(lines, "")

	-- Helper to produce a safe Go identifier from a script title (CamelCase)
	local function to_camel(s)
		if not s then
			return "Script"
		end
		-- replace non-alnum with space, split, capitalize parts
		local out = {}
		for part in (s:gsub("[^%w]+", " ")):gmatch("%S+") do
			table.insert(out, title_case(part))
		end
		return table.concat(out)
	end

	-- Helper: detect measurement return pattern and extract value type and whether collection
	-- Accepts a returns_schema (Lua table) and returns: value_type_string (e.g. "number"), is_array(boolean), is_measurement(boolean)
	local function extract_measurement_return(returns_schema)
		if returns_schema == nil then
			return nil, false, false
		end
		-- array pattern: returns.type == "array" and items.allOf exists
		if returns_schema.type == "array" and type(returns_schema.items) == "table" then
			local items = returns_schema.items
			if type(items.allOf) == "table" then
				-- find x-valueType in allOf
				for _, part in ipairs(items.allOf) do
					if type(part) == "table" and part["x-valueType"] then
						return part["x-valueType"], true, true
					end
					-- fallback: part.type primitive
					if
						type(part) == "table"
						and type(part.type) == "string"
						and (part.type == "number" or part.type == "string" or part.type == "boolean")
					then
						return part.type, true, true
					end
				end
				-- if no x-valueType present, treat as invalid for strict generator
				error(
					"generate_go_types_and_helpers: returns.items.allOf present but missing x-valueType (preferred pattern required)."
				)
			end
			error(
				"generate_go_types_and_helpers: returns.type == 'array' but returns.items.allOf missing (preferred pattern required)."
			)
		end

		-- single measurement: returns.allOf ...
		if type(returns_schema.allOf) == "table" then
			for _, part in ipairs(returns_schema.allOf) do
				if type(part) == "table" and part["x-valueType"] then
					return part["x-valueType"], false, true
				end
				if
					type(part) == "table"
					and type(part.type) == "string"
					and (part.type == "number" or part.type == "string" or part.type == "boolean")
				then
					return part.type, false, true
				end
			end
			error(
				"generate_go_types_and_helpers: returns.allOf present but missing x-valueType (preferred pattern required)."
			)
		end

		-- If returns is present but not matching preferred pattern, error (strict)
		error(
			"generate_go_types_and_helpers: unsupported returns shape. Use preferred allOf + x-valueType pattern or omit returns."
		)
	end

	-- First: emit defs (reusable types)
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
				-- No omitempty: always serialize fields (as requested)
				table.insert(
					lines,
					string.format(
						'    %s %s `json:"%s"` // %s',
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
		-- ToMap helper (unchanged)
		local structName = n
		table.insert(lines, string.format("func (rc %s) ToMap() (map[string]interface{}, error) {", structName))
		table.insert(lines, "    b, err := json.Marshal(rc)")
		table.insert(lines, "    if err != nil { return nil, err }")
		table.insert(lines, "    var m map[string]interface{}")
		table.insert(lines, "    if err := json.Unmarshal(b, &m); err != nil { return nil, err }")
		table.insert(lines, "    return m, nil")
		table.insert(lines, "}")
		table.insert(lines, "")
	end

	-- Collect measurement value types used across scripts so we can emit MeasurementResponse<T> concrete types
	local used_value_types = {} -- map of primitive string -> true

	-- Determine per-script request/response types
	local script_names = {}
	for _, s in ipairs(scripts or {}) do
		local title = s.title or s._schema_filename or "script"
		local name = to_camel(title)
		table.insert(script_names, { name = name, schema = s })
		-- if returns present, extract measurement type (strict)
		if s.returns ~= nil then
			local ok, vt, is_array, is_measure = pcall(function()
				local value_type, is_arr, is_meas = extract_measurement_return(s.returns)
				return value_type, is_arr, is_meas
			end)
			if not ok then
				error(
					"generate_go_types_and_helpers: schema "
						.. (s._schema_filename or title)
						.. " returns parse error: "
						.. tostring(vt)
				)
			end
			if is_measure then
				used_value_types[vt] = true
			end
		end
	end

	-- Emit MeasurementResponse concrete structs for each used primitive value type
	-- e.g. MeasurementResponseNumber, MeasurementResponseString, MeasurementResponseBoolean
	local function measurement_response_struct_name(valtype)
		-- map "number" -> "Number", "string"->"String", "boolean"->"Boolean", "buffer"->"Buffer"
		local m = valtype:gsub("[^%w]", "_")
		return "MeasurementResponse" .. title_case(m)
	end
	for vt, _ in pairs(used_value_types) do
		local mname = measurement_response_struct_name(vt)
		table.insert(lines, string.format("// %s concrete for MeasurementResponse<%s>", mname, vt))
		-- choose Go type for Value field
		local goVal = "interface{}"
		if vt == "number" then
			goVal = "float64"
		end
		if vt == "string" then
			goVal = "string"
		end
		if vt == "boolean" then
			goVal = "bool"
		end
		if vt == "buffer" then
			goVal = "[]byte"
		end
		table.insert(lines, string.format("type %s struct {", mname))
		table.insert(lines, string.format('    Instrument string `json:"instrument"`'))
		table.insert(lines, string.format('    Verb string `json:"verb"`'))
		table.insert(lines, string.format('    Type string `json:"type"`'))
		table.insert(lines, string.format('    Value %s `json:"value"`', goVal))
		table.insert(lines, "}")
		table.insert(lines, "")
	end

	-- For each script, emit Request struct, Response type alias, and Spec wrapper
	for _, item in ipairs(script_names) do
		local name = item.name
		local s = item.schema

		-- Request struct
		local reqName = name .. "Request"
		table.insert(
			lines,
			string.format(
				"// %s generated request (inputs) from schema %s",
				reqName,
				as_string(s._schema_filename or s.title)
			)
		)
		table.insert(lines, string.format("type %s struct {", reqName))
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
						'    %s %s `json:"%s"` // %s',
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

		-- Response type
		local respName = name .. "Response"
		if s.returns == nil then
			-- No returns — empty struct
			table.insert(lines, string.format("// %s generated response: no return (script omits returns)", respName))
			table.insert(lines, string.format("type %s struct {}", respName))
			table.insert(lines, "")
		else
			-- parse returns - strict preferred pattern
			local vt, is_array, is_measure
			local ok, a, b, c = pcall(function()
				return extract_measurement_return(s.returns)
			end)
			if not ok then
				error(
					"generate_go_types_and_helpers: error parsing returns for script "
						.. (s._schema_filename or name)
						.. ": "
						.. tostring(a)
				)
			end
			vt, is_array, is_measure = a, b, c
			if not is_measure then
				error(
					"generate_go_types_and_helpers: unexpected non-measurement returns for script "
						.. (s._schema_filename or name)
				)
			end
			-- derive measurement struct name
			local mname = measurement_response_struct_name(vt)
			if is_array then
				table.insert(lines, string.format("// %s generated response: slice of %s", respName, mname))
				table.insert(lines, string.format("type %s []%s", respName, mname))
				table.insert(lines, "")
			else
				table.insert(lines, string.format("// %s generated response: single %s", respName, mname))
				table.insert(lines, string.format("type %s %s", respName, mname))
				table.insert(lines, "")
			end
		end

		-- Spec wrapper combining Request and Response
		local specName = name .. "Spec"
		table.insert(
			lines,
			string.format(
				"// %s pairs request and response types for script %s",
				specName,
				as_string(s._schema_filename or s.title)
			)
		)
		table.insert(lines, string.format("type %s struct {", specName))
		table.insert(lines, string.format('    Input %s `json:"input"`', reqName))
		table.insert(lines, string.format('    Output %s `json:"output"`', respName))
		table.insert(lines, "}")
		table.insert(lines, "")
	end

	-- Re-generate InstrumentTarget helper if def exists (preserve previous behavior)
	if defs["InstrumentTarget"] then
		local hb = {}
		table.insert(hb, "// Code generated helpers — DO NOT EDIT")
		table.insert(hb, "package generated")
		table.insert(hb, "")
		table.insert(hb, 'import "fmt"')
		table.insert(hb, "")
		table.insert(hb, "func (t InstrumentTarget) Serialize() string {")
		table.insert(hb, "    if t.Channel != 0 {")
		table.insert(hb, '        return fmt.Sprintf("%s:%d", t.Id, t.Channel)')
		table.insert(hb, "    }")
		table.insert(hb, "    return t.Id")
		table.insert(hb, "}")
		-- Append helper file content to generated file (or write separate file). Here we append.
		table.insert(lines, table.concat(hb, "\n"))
		table.insert(lines, "")
	end

	-- Write file
	ensure_dir(outDir .. path_sep .. "go-types")
	write_file(outDir .. path_sep .. "go-types" .. path_sep .. "generated_runtime_types.go", table.concat(lines, "\n"))
end

-- Main --------------------------------------------------------------------

local function usage_and_exit()
	print(
		"usage: lua generator/gen_from_schemas.lua <lib-schemas-dir> <script-schemas-dir> <source-lua-dir> <out-dir> [--no-generated-lua]"
	)
	os.exit(2)
end

-- CLI args parsing: positional args plus optional flags (e.g., --no-generated-lua)
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

-- For each def: optionally create generated/lua implementations, always emit emmy headers and teal typing modules (.tl)
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
	-- always produce typed Teal companion (.tl) for the def
	write_teal_typing_for_def(modulePath, defName, def, outDir)
end

-- Emit per-script emmy files
emit_emmy_scripts(scriptSchemas, outDir)

-- Emit Teal script scaffolds (if teal emitter available)
if teal_emitter then
	teal_emitter.emit_scripts(scriptSchemas, defs, modules, sourceLuaDir, outDir)
else
	io.stderr:write("generator: teal_emitter not available; skipping teal outputs\n")
end

-- Generate go types and helpers
generate_go_types_and_helpers(defs, scriptSchemas, outDir)

print("generator: wrote outputs to " .. outDir)
