-- generator/teal_emitter.lua
-- Emits Teal (.tl) script scaffolds with expanded-parameter `main(ctx, ...)` signatures
-- and typed return signatures when schema.returns is present.
-- Script filenames end with .tl to be recognized by tl / Teal LSP.
--
-- Usage: require("generator.teal_emitter").emit_scripts(scriptSchemas, defs, modules, sourceLuaDir, outDir)

local M = {}

local path_sep = package.config:sub(1, 1)
local io_open = io.open

local function ensure_dir(p)
	if not p or p == "" then
		return true
	end
	os.execute(("mkdir -p %q"):format(p))
	return true
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

local function is_array_prop(pp)
	if type(pp) ~= "table" then
		return false
	end
	return pp.type == "array"
end

local function field_type_string(pp)
	if not pp then
		return "any"
	end
	if pp["$ref"] then
		return ref_to_name(pp["$ref"])
	end
	if is_array_prop(pp) then
		local items = pp.items
		if items and items["$ref"] then
			return ref_to_name(items["$ref"]) .. "[]"
		elseif items and items.type then
			return (items.type == "integer" and "integer" or items.type) .. "[]"
		else
			return "any[]"
		end
	end
	if pp.type then
		local t = pp.type
		if t == "integer" then
			return "integer"
		end
		if t == "number" then
			return "number"
		end
		if t == "string" then
			return "string"
		end
		if t == "boolean" then
			return "boolean"
		end
		if t == "object" then
			return "table"
		end
		if t == "array" then
			return "any[]"
		end
		return "any"
	end
	return "any"
end

local function teal_type_for_prop(pp)
	local t = field_type_string(pp)
	if t:match("%[%]$") then
		local elem = t:gsub("%[%]$", "")
		return "{" .. elem .. "}"
	end
	if t == "integer" or t == "number" or t == "string" or t == "boolean" or t == "table" or t == "any" then
		return t
	end
	return t
end

local function sanitize_comment(s)
	if not s then
		return ""
	end
	s = tostring(s):gsub("\r\n", "\n"):gsub("\n$", "")
	s = s:gsub("%-%-%]", "%-%- %]")
	return s
end

local function title_to_filename(title, fallback)
	local name = ""
	if title and #title > 0 then
		name = title:gsub("%s+", "_"):gsub("[^%w_%-]", ""):lower()
	else
		name = (fallback or "script"):gsub("%s+", "_"):lower()
	end
	return name .. ".tl" -- use .tl for Teal files
end

local function emit_runtime_context_block()
	return table.concat({
		"-- RuntimeContext (shared)",
		"record RuntimeContext",
		"  log: function(RuntimeContext, string): nil",
		"  call: function(RuntimeContext, string, table): any",
		"  error: function(RuntimeContext, string): nil",
		"  parallel: function(RuntimeContext, function()): nil",
		"end",
		"",
	}, "\n")
end

local function module_path_to_fs(modulePath)
	local parts = {}
	for p in modulePath:gmatch("[^.]+") do
		table.insert(parts, p)
	end
	return table.concat(parts, path_sep)
end

local function teal_type_for_schema_node(node)
	if not node then
		return "any"
	end
	if node["$ref"] then
		return ref_to_name(node["$ref"])
	end
	if node.type == "array" then
		local it = node.items
		local elem = teal_type_for_schema_node(it)
		return "{" .. elem .. "}"
	end
	if node.type == "object" then
		if node.additionalProperties then
			local val = teal_type_for_schema_node(node.additionalProperties)
			return ("{ [string]: %s }"):format(val)
		end
		return "table"
	end
	if node.type == "number" then
		return "number"
	end
	if node.type == "integer" then
		return "integer"
	end
	if node.type == "string" then
		return "string"
	end
	if node.type == "boolean" then
		return "boolean"
	end
	return "any"
end

local function collect_fields(schema)
	local out = {}
	if not schema or not schema.properties then
		return out
	end
	local keys = {}
	for k, _ in pairs(schema.properties) do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local pp = schema.properties[k]
		local tstr = field_type_string(pp)
		table.insert(out, {
			name = k,
			type = tstr,
			description = pp.description or pp["description"] or "",
			required = false,
		})
	end
	return out
end

-- Prefer a Teal typing module if present either in sourceLuaDir (.tl) or in generated output (outDir/teal/*.tl)
local function has_teal_module_for(defName, modules, sourceLuaDir, outDir)
	local mod = modules[defName]
	if not mod then
		return false
	end
	local fs = module_path_to_fs(mod)
	-- source .tl
	local candidate1 = sourceLuaDir .. path_sep .. fs .. ".tl"
	local f1 = io.open(candidate1, "rb")
	if f1 then
		f1:close()
		return true
	end
	-- generated .tl
	if outDir and outDir ~= "" then
		local candidate2 = outDir .. path_sep .. "teal" .. path_sep .. fs .. ".tl"
		local f2 = io.open(candidate2, "rb")
		if f2 then
			f2:close()
			return true
		end
	end
	-- fallback: older .teal (if present)
	local candidate3 = sourceLuaDir .. path_sep .. fs .. ".teal"
	local f3 = io.open(candidate3, "rb")
	if f3 then
		f3:close()
		return true
	end
	local candidate4 = outDir .. path_sep .. "teal" .. path_sep .. fs .. ".teal"
	local f4 = io.open(candidate4, "rb")
	if f4 then
		f4:close()
		return true
	end
	return false
end

local function emit_record_stub(name, fields)
	local out = {}
	table.insert(out, ("-- Minimal stub for %s (generated)"):format(name))
	table.insert(out, ("record %s"):format(name))
	for _, f in ipairs(fields or {}) do
		local t = teal_type_for_prop(f)
		local comment = ""
		if f.description and #f.description > 0 then
			comment = " -- " .. sanitize_comment(f.description)
		end
		table.insert(out, ("  %s: %s%s"):format(f.name, t, comment))
	end
	table.insert(out, "end")
	table.insert(out, "")
	return table.concat(out, "\n")
end

local function emit_teal_for_script(schema, defs, modules, sourceLuaDir, outDir)
	local parts = {}
	table.insert(parts, "-- GENERATED TEAL - DO NOT EDIT")
	if schema.title and #schema.title > 0 then
		table.insert(parts, ("-- %s"):format(sanitize_comment(schema.title)))
	end
	if schema.description and #schema.description > 0 then
		table.insert(parts, ("-- %s"):format(sanitize_comment(schema.description)))
	end
	table.insert(parts, "")

	table.insert(parts, emit_runtime_context_block())

	local fields = collect_fields(schema)

	-- collect referenced record names
	local ref_names = {}
	for _, f in ipairs(fields) do
		local nm = tostring(f.type):gsub("%[%]$", "")
		if nm:match("^[A-Z]") then
			if not ref_names[nm] then
				ref_names[nm] = true
			end
		end
	end

	-- Emit requires for referenced typing modules when available
	for name, _ in pairs(ref_names) do
		local mod = modules[name] or ("falcon_measurement_lib." .. name:lower())
		local emits_req = false
		local fs = module_path_to_fs(mod)
		local candidate1 = sourceLuaDir .. path_sep .. fs .. ".tl"
		local f1 = io.open(candidate1, "rb")
		if f1 then
			f1:close()
			emits_req = true
		end
		local candidate2 = outDir .. path_sep .. "teal" .. path_sep .. fs .. ".tl"
		local f2 = io.open(candidate2, "rb")
		if f2 then
			f2:close()
			emits_req = true
		end

		if emits_req then
			table.insert(parts, ("local %s = require(%q)"):format(name, mod))
		end
	end

	if next(ref_names) then
		table.insert(parts, "")
	end

	-- Emit stubs or notes for referenced record types (prefer teal typing module if available)
	for name, _ in pairs(ref_names) do
		local skip_stub = has_teal_module_for(name, modules, sourceLuaDir, outDir)
		if not skip_stub then
			local def = defs[name]
			if def and def.properties then
				local stub_fields = {}
				for pk, pv in pairs(def.properties) do
					table.insert(stub_fields, {
						name = pk,
						type = field_type_string(pv),
						description = pv.description or pv["description"] or "",
					})
				end
				table.insert(parts, emit_record_stub(name, stub_fields))
			else
				table.insert(parts, ("record %s end\n"):format(name))
			end
		else
			local mod = modules[name] or ("falcon_measurement_lib." .. name:lower())
			table.insert(
				parts,
				("-- NOTE: %s is provided by runtime typing module %s; using that module's types instead of emitting a stub."):format(
					name,
					tostring(mod)
				)
			)
			table.insert(parts, "")
		end
	end

	-- Parameters docblock
	table.insert(parts, "-- Parameters")
	for _, f in ipairs(fields) do
		local pdesc = sanitize_comment(f.description)
		local t = f.type or "any"
		table.insert(parts, ("-- @param %s %s%s"):format(f.name, t, (pdesc ~= "" and " - " .. pdesc or "")))
	end
	table.insert(parts, "")

	-- Determine return type if present
	local ret_type = nil
	if schema.returns then
		ret_type = teal_type_for_schema_node(schema.returns)
		local rd = sanitize_comment(schema.returns.description or "")
		table.insert(parts, ("-- @return %s%s"):format(ret_type, (rd ~= "" and " - " .. rd or "")))
		table.insert(parts, "")
	end

	-- Build function signature
	local param_list = { "ctx: RuntimeContext" }
	for _, f in ipairs(fields) do
		local t = teal_type_for_prop(f)
		table.insert(param_list, (("%s: %s"):format(f.name, t)))
	end

	local sig
	if ret_type then
		sig = ("function main(%s): %s"):format(table.concat(param_list, ", "), ret_type)
	else
		sig = ("function main(%s): nil"):format(table.concat(param_list, ", "))
	end

	table.insert(parts, sig)
	table.insert(parts, '  ctx:log("Starting measurement")')
	table.insert(parts, "")
	table.insert(parts, "  -- Example: access parameters directly by name")
	for _, f in ipairs(fields) do
		table.insert(parts, ("  -- local %s = %s"):format(f.name, f.name))
	end
	table.insert(parts, "")
	table.insert(parts, "  -- TODO: implement measurement logic here")
	if ret_type then
		table.insert(parts, "  return {}")
	else
		table.insert(parts, "  return nil")
	end
	table.insert(parts, "end")
	table.insert(parts, "")
	table.insert(parts, "return { main = main }")
	return table.concat(parts, "\n")
end

function M.emit_scripts(scriptSchemas, defs, modules, sourceLuaDir, outDir)
	outDir = outDir or "generated"
	local dest_base = outDir .. path_sep .. "teal" .. path_sep .. "scripts"
	ensure_dir(dest_base)
	for _, s in ipairs(scriptSchemas or {}) do
		local title = s.title or s._schema_filename or "script"
		local filename = title_to_filename(title, s._schema_filename)
		local dest = dest_base .. path_sep .. filename
		local content = emit_teal_for_script(s, defs or {}, modules or {}, sourceLuaDir or "lua", outDir)
		local ok, err = write_file(dest, content)
		if not ok then
			io.stderr:write(("teal_emitter: failed to write %s: %s\n"):format(dest, tostring(err)))
		else
			io.stderr:write(("teal_emitter: wrote %s\n"):format(dest))
		end
	end
end

return M
