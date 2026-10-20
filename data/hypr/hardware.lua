-- Per-model settings from Nova's hardware profiles. The model list is the one
-- nova-hw-detect reads, so a computer is recognised the same way everywhere.

local paths = require("default.hypr.paths")
local require_optional = require("default.hypr.require_optional")

local function read_line(path)
  local file = io.open(path)
  if not file then return nil end
  local line = file:read("l")
  file:close()
  return line and (line:gsub("%s+$", ""))
end

-- A models-file pattern is a glob where only `*` is special.
local function glob_matches(pattern, value)
  local lua_pattern = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
  return value:match(lua_pattern) ~= nil
end

local version = read_line("/sys/class/dmi/id/product_version")
local models = io.open(paths.nova_path .. "/hardware/models")
if version and models then
  for line in models:lines() do
    local pattern, profile = line:match("^([^#\t][^\t]*)\t(%S+)")
    if pattern and glob_matches(pattern, version) then
      require_optional.module("default.hypr.hardware." .. profile)
      break
    end
  end
end
if models then models:close() end
