-- The keyboard layout, from /etc/vconsole.conf, where the installer writes
-- XKBLAYOUT and XKBVARIANT. The session (input.lua) and the login greeter
-- both read it here, so a password is typed on the same keys at both.

local M = {}

-- A setting there, a shell-style NAME=value line: the value of the last line
-- for that name, with a trailing comment off and then its quotes. nil when no
-- line sets it, or there is no file.
local function vconsole(name)
  local file = io.open("/etc/vconsole.conf")
  if not file then return nil end
  local set
  for line in file:lines() do
    local value = line:match("^%s*" .. name .. "%s*=%s*(.-)%s*$")
    if value then set = value:gsub("%s+#.*$", ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1") end
  end
  file:close()
  return set
end

-- Layouts that cannot type Latin letters.
local non_latin = {}
for code in ("af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua"):gmatch("%S+") do
  non_latin[code] = true
end

-- { layout, variant, options } for Hyprland's kb_layout, kb_variant and
-- kb_options. Hyprland matches key bindings against the first layout listed,
-- whichever is in use, so with a non-Latin one first SUPER + W and every
-- other letter binding would do nothing. US goes first then, and Left Alt +
-- Right Alt switches to the system's layout.
function M.layout()
  local layout, variant = vconsole("XKBLAYOUT") or "us", vconsole("XKBVARIANT") or ""
  if non_latin[layout:match("^[^,]*")] then
    return { layout = "us," .. layout, variant = "," .. variant, options = "grp:alts_toggle" }
  end
  return { layout = layout, variant = variant, options = "" }
end

return M
