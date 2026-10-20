-- The system's keyboard layout, from /etc/vconsole.conf (XKBLAYOUT and
-- XKBVARIANT, which the installer writes). The session (input.lua) and the
-- login greeter both take it from here, so a password typed at one is typed on
-- the same keys at the other.

local M = {}

local function read_vconsole()
  local values = {}
  local file = io.open("/etc/vconsole.conf", "r")
  if not file then
    return values
  end

  for line in file:lines() do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and value then
      value = value:gsub("%s+#.*$", "")
      value = value:gsub('^"(.*)"$', "%1")
      value = value:gsub("^'(.*)'$", "%1")
      values[key] = value
    end
  end

  file:close()
  return values
end

-- Layouts that can't type Latin letters.
local non_latin_layouts =
  " af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua "

-- { layout, variant, options } for Hyprland's kb_layout, kb_variant and
-- kb_options. Hyprland resolves keybindings against the first entry in
-- kb_layout, not the layout that's currently active, so Nova's Latin-keysym
-- bindings (SUPER + W and friends) only fire when a Latin layout leads.
-- Installing with a non-Latin one would otherwise leave the desktop unusable,
-- so US goes first and the system's layout is reached with Left Alt + Right Alt.
function M.layout()
  local vconsole = read_vconsole()
  local layout = vconsole.XKBLAYOUT or "us"
  local variant = vconsole.XKBVARIANT or ""
  local options = ""
  if non_latin_layouts:find(" " .. layout:match("^[^,]*") .. " ", 1, true) then
    layout = "us," .. layout
    variant = "," .. variant
    options = "grp:alts_toggle"
  end
  return { layout = layout, variant = variant, options = options }
end

return M
