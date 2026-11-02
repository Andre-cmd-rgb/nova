-- The keyboard layout, from /etc/vconsole.conf, where the installer writes
-- XKBLAYOUT and XKBVARIANT. The session (input.lua) and the login greeter
-- both read it here, so a password is typed on the same keys at both.

local M = {}

local function vconsole()
  local values = {}
  local file = io.open("/etc/vconsole.conf")
  if not file then return values end
  for line in file:lines() do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key then
      -- A trailing comment off, then quotes.
      value = value:gsub("%s+#.*$", ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      values[key] = value
    end
  end
  file:close()
  return values
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
  local conf = vconsole()
  local layout, variant = conf.XKBLAYOUT or "us", conf.XKBVARIANT or ""
  if non_latin[layout:match("^[^,]*")] then
    return { layout = "us," .. layout, variant = "," .. variant, options = "grp:alts_toggle" }
  end
  return { layout = layout, variant = variant, options = "" }
end

return M
