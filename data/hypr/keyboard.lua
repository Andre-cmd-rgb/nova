-- The keyboard layout, from /etc/vconsole.conf, where the installer writes
-- XKBLAYOUT and XKBVARIANT. The session (input.lua) and the login greeter
-- both read it here, so a password is typed on the same keys at both. The
-- layouts chosen in Settings are the session's alone (M.chosen).

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

-- Layouts that cannot type Latin letters. nova input reads this line too.
local NON_LATIN = "af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua"
local non_latin = {}
for code in NON_LATIN:gmatch("%S+") do
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

-- The layouts chosen in Settings → Keyboard & Mouse (nova input), as a list
-- of layouts and one of their variants, and the grp: option that switches
-- between them, "" for none and nil for what is set already: Hyprland's
-- input settings for them. A non-Latin layout first gets US ahead of it, as
-- above: the US among them, moved up, else one more (nova input keeps the
-- whole to four, xkb's most). The options set so far, Nova's and yours, are
-- kept, all but their switch; with no switch set anywhere, two layouts or
-- more get both Alts.
function M.chosen(layouts, variants, switch)
  if non_latin[layouts[1]] then
    local at
    for i, layout in ipairs(layouts) do
      if layout == "us" then
        at = i
        break
      end
    end
    local variant = at and table.remove(variants, at) or ""
    if at then table.remove(layouts, at) end
    table.insert(layouts, 1, "us")
    table.insert(variants, 1, variant)
  end
  local options, kept = {}, nil
  for option in tostring(hl.get_config("input.kb_options") or ""):gmatch("[^,]+") do
    if option:match("^grp:") then
      kept = kept or option
    else
      options[#options + 1] = option
    end
  end
  if switch == nil then switch = kept or "grp:alts_toggle" end
  if switch ~= "" and #layouts > 1 then options[#options + 1] = switch end
  return {
    kb_layout = table.concat(layouts, ","),
    kb_variant = table.concat(variants, ","),
    kb_options = table.concat(options, ","),
  }
end

return M
