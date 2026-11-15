-- This model's Hyprland settings, from its hardware profile. The computer is
-- recognised by the models list nova-hw-detect reads, read the same way, so it
-- is recognised the same way everywhere.

local function first_line(path)
  local file = io.open(path)
  if not file then return nil end
  local line = file:read("l")
  file:close()
  return line
end

-- The DMI fields a line may name: those any user can read.
local fields = {
  sys_vendor = true, product_name = true, product_version = true,
  product_family = true, board_vendor = true, board_name = true,
}

-- A field as the computer's DMI tables give it, read once; nil when it has none.
local dmi = {}
local function field(name)
  if dmi[name] == nil then
    local value = first_line("/sys/class/dmi/id/" .. name)
    dmi[name] = value and value:gsub("%s+$", "") or false
  end
  return dmi[name] or nil
end

-- A pattern from the models list as a Lua pattern: `*` matches anything, and
-- everything else only itself.
local function matches(pattern, name)
  local lua = pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*")
  return name:find("^" .. lua .. "$") ~= nil
end

-- One condition: field=pattern, or a bare pattern, which is product_version's.
-- A field the computer does not have matches nothing.
local function holds(condition)
  local name, pattern = condition:match("^([%l_]+)=(.*)$")
  if not (name and fields[name]) then name, pattern = "product_version", condition end
  local value = field(name)
  return value ~= nil and matches(pattern, value)
end

local models = io.open(nova.path .. "/hardware/models")
if models then
  -- One model per line: its conditions and the profile, separated by tabs.
  -- Every condition has to hold; the first line whose do wins.
  for line in models:lines() do
    local columns = {}
    for column in line:gmatch("[^\t]+") do columns[#columns + 1] = column end
    local profile = #columns >= 2 and not columns[1]:match("^#") and columns[#columns]:match("^(%S+)")
    if profile then
      local every = true
      for i = 1, #columns - 1 do
        if not holds(columns[i]) then
          every = false
          break
        end
      end
      if every then
        nova.run_if_present(nova.path .. "/default/hypr/hardware/" .. profile .. ".lua")
        break
      end
    end
  end
  models:close()
end
