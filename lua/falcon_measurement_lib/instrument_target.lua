-- Module: falcon_measurement_lib.instrument_target
-- Implements InstrumentTarget helpers (serialize, normalize factory).

local InstrumentTarget = {}
InstrumentTarget.__index = InstrumentTarget

-- Serialize the instrument target to "id" or "id:channel"
function InstrumentTarget:serialize()
	if self.channel ~= nil then
		return string.format("%s:%d", tostring(self.id), tonumber(self.channel))
	else
		return tostring(self.id)
	end
end

-- Factory: normalize a string or table into an InstrumentTarget object
local function normalize(v)
	if type(v) == "string" then
		local id, ch = string.match(v, "^([^:]+):?(%d*)$")
		local t = { id = id }
		if ch ~= nil and ch ~= "" then
			t.channel = tonumber(ch)
		end
		setmetatable(t, InstrumentTarget)
		return t
	elseif type(v) == "table" then
		if getmetatable(v) ~= InstrumentTarget then
			setmetatable(v, InstrumentTarget)
		end
		return v
	else
		return v
	end
end

---@param opts table? Optional table of fields for InstrumentTarget
---@return InstrumentTarget
local function new(opts)
	opts = opts or {}
	setmetatable(opts, InstrumentTarget)
	return opts
end

local M = {
	InstrumentTarget = InstrumentTarget,
	normalize = normalize,
	new = new,
}
return M
