-- This model's Hyprland settings, from its hardware profile. The computer is
-- recognised by the models list nova-hw-detect reads, so it is recognised the
-- same way everywhere.

local function first_line(path)
  local file = io.open(path)
  if not file then return nil end
  local line = file:read("l")
  file:close()
  return line
end

-- A PC names itself in its DMI tables; a board without them (a Raspberry Pi)
-- in its devicetree, where the name ends at a NUL.
local function model()
  local name = first_line("/sys/class/dmi/id/product_version")
  if not name then
    name = first_line("/proc/device-tree/model")
    if not name then return nil end
    name = name:match("^[^\0]*")
  end
  return (name:gsub("%s+$", ""))
end

-- A pattern from the models list as a Lua pattern: `*` matches anything, and
-- everything else only itself.
local function matches(pattern, name)
  local lua = pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*")
  return name:find("^" .. lua .. "$") ~= nil
end

local name = model()
local models = name and io.open(nova.path .. "/hardware/models")
if models then
  -- One model per line: a pattern, a tab, the profile. The first match wins.
  for line in models:lines() do
    local pattern, profile = line:match("^([^#\t][^\t]*)\t(%S+)")
    if pattern and matches(pattern, name) then
      nova.run_if_present(nova.path .. "/default/hypr/hardware/" .. profile .. ".lua")
      break
    end
  end
  models:close()
end
