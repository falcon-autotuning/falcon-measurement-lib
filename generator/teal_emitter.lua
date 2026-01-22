-- generator/teal_emitter.lua
-- Emits Teal (.tl) script scaffolds with expanded-parameter `main(ctx, ...)` signatures
-- and strictly-enforced typed return signatures derived from script schema.top-level `returns`.
--
-- Enforced preferred patterns:
-- 1) Array of MeasurementResponse:
--    returns.type = "array"
--    returns.items = {
--      allOf = [
--        { "$ref": "../lib/measurement_response.json#/definitions/MeasurementResponse" },
--        { "x-valueType": "number" }
--      ]
--    }
--
-- 2) Single MeasurementResponse:
--    returns = {
--      allOf = [
--        { "$ref": "../lib/measurement_response.json#/definitions/MeasurementResponse" },
--        { "x-valueType": "number" }
--      ]
--    }
--
-- 3) No returns: schema may omit `returns` entirely — interpreted as `: nil` (valid).
--
-- If a script schema includes a `returns` node but it does not match one of the preferred
-- patterns the emitter will error and stop generation.

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

local function title_to_filename(title, fallback)
	local name = title or fallback or "script"
	name = name:gsub("%s+", "_"):gsub("[^%w_%-]", ""):lower()
	if not name:match("%.tl$") then
		name = name .. ".tl"
	end
	return name
end

local function sanitize_comment(s)
	if not s then
		return ""
	end
	return (s:gsub("\n", " "):gsub("%s+", " "):gsub("%s+$", ""))
end

local function fail_schema(schema, reason)
	local id = schema._schema_filename or schema.title or "<unknown>"
	error(("teal_emitter: schema %s: %s"):format(id, reason))
end

-- Map a simple JSON Schema primitive to a Teal primitive
local function map_primitive(js_type)
	if js_type == "number" then
		return "number"
	end
	if js_type == "string" then
		return "string"
	end
	if js_type == "boolean" then
		return "boolean"
	end
	if js_type == "buffer" then
		return "buffer"
	end
	-- allow union forms like "number|string": return as-is (Teal supports `number | string`)
	if type(js_type) == "string" and js_type:find("|", 1, true) then
		return js_type
	end
	return "any"
end

-- extract x-valueType (or x-measurementValueType) from a schema object or from an allOf array
local function extract_x_valueType_from_obj(obj)
	if type(obj) ~= "table" then
		return nil
	end
	if obj["x-valueType"] then
		return obj["x-valueType"]
	end
	if obj["x-measurementValueType"] then
		return obj["x-measurementValueType"]
	end
	return nil
end

local function extract_x_valueType_from_allOf(allOf)
	if type(allOf) ~= "table" then
		return nil
	end
	for _, part in ipairs(allOf) do
		local vt = extract_x_valueType_from_obj(part)
		if vt then
			return vt
		end
		-- also allow part.type primitive as fallback (not preferred)
		if part.type and (part.type == "number" or part.type == "string" or part.type == "boolean") then
			return part.type
		end
	end
	return nil
end

-- Check whether an allOf array contains a $ref to MeasurementResponse (heuristic: $ref exists
-- and references "MeasurementResponse" or "measurement_response")
local function has_measurement_ref(allOf)
	if type(allOf) ~= "table" then
		return false
	end
	for _, part in ipairs(allOf) do
		if type(part) == "table" and part["$ref"] and type(part["$ref"]) == "string" then
			local ref = part["$ref"]
			if ref:match("MeasurementResponse") or ref:match("measurement_response") then
				return true
			end
		end
	end
	return false
end

-- Determine the Teal return type for a script schema `schema.returns`.
-- Enforces preferred patterns only and fails (returns nil + caller must error) otherwise.
-- Returns:
--   ret_teal_type (string), is_collection (boolean)
local function determine_return_teal_type_strict(returns_schema, schema)
	-- Allowed: no returns declared — interpreted as : nil
	if returns_schema == nil then
		return "nil", false
	end

	if type(returns_schema) ~= "table" then
		fail_schema(
			schema,
			"invalid 'returns' node. Expected preferred pattern using allOf + x-valueType or omit returns for no-return scripts."
		)
	end

	-- Preferred: array of MeasurementResponse with allOf + x-valueType and a $ref to MeasurementResponse
	if returns_schema.type == "array" and type(returns_schema.items) == "table" then
		local items = returns_schema.items
		if type(items.allOf) ~= "table" then
			fail_schema(
				schema,
				"returns.type == 'array' requires returns.items.allOf to be present and contain MeasurementResponse $ref + x-valueType."
			)
		end
		local vt = extract_x_valueType_from_allOf(items.allOf)
		if not vt then
			fail_schema(
				schema,
				'returns.items.allOf missing \'x-valueType\' annotation. Use allOf with { "$ref": "...MeasurementResponse" } and { "x-valueType": "number" }.'
			)
		end
		if not has_measurement_ref(items.allOf) then
			fail_schema(
				schema,
				"returns.items.allOf missing $ref to MeasurementResponse. Use the canonical MeasurementResponse definition by $ref."
			)
		end
		return string.format("MeasurementResponses<%s>", map_primitive(vt)), true
	end

	-- Preferred: single MeasurementResponse via allOf + x-valueType + $ref
	if type(returns_schema.allOf) == "table" then
		local vt = extract_x_valueType_from_allOf(returns_schema.allOf)
		if not vt then
			fail_schema(
				schema,
				'returns.allOf missing \'x-valueType\' annotation. Use allOf with { "$ref": "...MeasurementResponse" } and { "x-valueType": "number" }.'
			)
		end
		if not has_measurement_ref(returns_schema.allOf) then
			fail_schema(
				schema,
				"returns.allOf missing $ref to MeasurementResponse. Use the canonical MeasurementResponse definition by $ref."
			)
		end
		return string.format("MeasurementResponse<%s>", map_primitive(vt)), false
	end

	-- Nothing matched — fail loudly
	fail_schema(
		schema,
		"returns shape not recognized. Expected preferred patterns (array-of-MeasurementResponse allOf + x-valueType OR single-MeasurementResponse allOf + x-valueType), or omit 'returns' for no-return scripts."
	)
end

-- convert a schema property to a Teal type (used for generating parameter annotations)
local function teal_type_for_prop(p)
	local jst = nil
	if not p then
		return "any"
	end
	if p.type then
		jst = p.type
	end
	-- array -> { [number]: <item type> } but frequently item type is a $ref (we fallback to table)
	if jst == "array" then
		if p.items and p.items.type then
			return string.format("{ %s }", map_primitive(p.items.type))
		end
		return "{ [number]: table }"
	end
	if jst == "object" then
		return "table"
	end
	if jst == "number" then
		return "number"
	end
	if jst == "string" then
		return "string"
	end
	if jst == "boolean" then
		return "boolean"
	end
	return "any"
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
	table.insert(
		parts,
		"-- NOTE: Ensure runtime teal definitions (runtime_context.tl) are available to the typechecker"
	)
	table.insert(parts, "")

	-- Emit RuntimeContext reference placeholder (consumer should provide runtime_context.tl)
	table.insert(parts, "local RuntimeContext = {} -- runtime context type must be provided by runtime teal module")
	table.insert(parts, "")

	-- Build parameter list
	local params = {}
	if schema.properties and type(schema.properties) == "table" then
		-- sort keys for deterministic output
		local keys = {}
		for k, _ in pairs(schema.properties) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local pp = schema.properties[k]
			local ptype = "table"
			-- heuristic: arrays -> { [number]: table }, else use teal_type_for_prop
			if pp and pp.type == "array" then
				ptype = "{ [number]: table }"
			elseif pp and pp["$ref"] then
				-- for $ref we default to table; runtime teal modules may provide record definitions
				ptype = "table"
			else
				ptype = teal_type_for_prop(pp)
			end
			table.insert(params, string.format("%s: %s", k, ptype))
		end
	end

	-- Determine return type using the strict preferred pattern (allow no returns)
	local ret_teal_type, is_collection = determine_return_teal_type_strict(schema.returns, schema)

	-- Compose function signature
	local param_list = "ctx: RuntimeContext"
	if #params > 0 then
		param_list = "ctx: RuntimeContext, " .. table.concat(params, ", ")
	end

	local func_name = "main"
	if schema.title and #schema.title > 0 then
		-- use title as function name if it looks like a valid identifier
		local candidate = schema.title:gsub("%s+", "_"):gsub("[^%w_]", "")
		if candidate ~= "" then
			func_name = candidate
		end
	end

	-- Include typed return in signature (strict)
	table.insert(parts, string.format("local function %s(%s): %s", func_name, param_list, ret_teal_type))

	-- Emit body scaffolding
	if ret_teal_type == "nil" then
		table.insert(parts, "  -- script declares no return value")
		table.insert(parts, "  return nil")
	else
		if is_collection then
			table.insert(parts, string.format("  local out: %s = {}", ret_teal_type))
		else
			table.insert(parts, string.format("  local out: %s", ret_teal_type))
			table.insert(
				parts,
				"  -- TODO: populate out by calling ctx:call and returning the single MeasurementResponse"
			)
		end
		-- add parameter TODO comments and example usage
		if schema.properties and type(schema.properties) == "table" then
			for k, _ in pairs(schema.properties) do
				table.insert(parts, ("  -- local %s = %s"):format(k, k))
			end
		end
		table.insert(parts, "")
		table.insert(parts, "  -- TODO: implement measurement logic here")
		table.insert(parts, "  return out")
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
		-- emit_teal_for_script will error if schema includes returns but does not use the preferred pattern
		local content = emit_teal_for_script(s, defs, modules, sourceLuaDir, outDir)
		local ok, err = write_file(dest, content)
		if not ok then
			io.stderr:write("teal_emitter: failed to write " .. dest .. ": " .. tostring(err) .. "\n")
		else
			io.stdout:write("teal_emitter: wrote " .. dest .. "\n")
		end
	end
end

return M
