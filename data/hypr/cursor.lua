-- The cursor theme: Nova's own (theme/cursor, in /usr/share/icons/Nova), in
-- its two forms. Hyprland draws the cursor from the Hyprcursor form, its own
-- and the one an app asks it for by shape, at the size each display's scale
-- asks for; apps that draw their own cursor, and X11 apps, load the XCursor
-- form, which XCURSOR_THEME names. Hyprland writes XCURSOR_THEME into
-- GSettings as it starts (cursor:sync_gsettings_theme), where GTK, Flatpak
-- apps (through the settings portal) and X11 apps (as XSETTINGS, by
-- nova-hyprland-x11-scale) read it. The sizes are env.lua's.
--
-- A theme you chose wins over Nova's: an XCURSOR_THEME the session started
-- with (exported by your login profile), or your own default theme, the
-- standard place to choose one: ~/.local/share/icons/default/index.theme
-- (or ~/.icons/default/index.theme) saying Inherits=<theme>, as nwg-look
-- and lxappearance write it. Hyprland then draws that theme's
-- Hyprcursor form if it has one, else its XCursor form: Hyprcursor, asked for
-- a theme it cannot find, takes any it can, which would be Nova's.
-- A HYPRCURSOR_THEME the session started with is yours too, and kept.

local home = os.getenv("HOME") or ""
local data_home = os.getenv("XDG_DATA_HOME") or ""
if data_home == "" then data_home = home .. "/.local/share" end
local data_dirs = os.getenv("XDG_DATA_DIRS") or ""
if data_dirs == "" then data_dirs = "/usr/local/share:/usr/share" end

-- Where icon themes are, yours first, as the cursor libraries look.
local icons = { data_home .. "/icons", home .. "/.icons" }
for dir in data_dirs:gmatch("[^:]+") do icons[#icons + 1] = dir .. "/icons" end

local function readable(path)
  local file = io.open(path)
  if file then file:close() end
  return file ~= nil
end

-- The first <icons>/<theme>/<file> there is, or nil.
local function find(theme, file)
  for _, dir in ipairs(icons) do
    local path = dir .. "/" .. theme .. "/" .. file
    if readable(path) then return path end
  end
end

local function has_hyprcursor(theme)
  return find(theme, "manifest.hl") ~= nil or find(theme, "manifest.toml") ~= nil
end

-- Your own default theme's index.theme, and the first theme it inherits.
local function your_default()
  for _, dir in ipairs({ data_home .. "/icons", home .. "/.icons" }) do
    local path = dir .. "/default/index.theme"
    local file = io.open(path)
    if file then
      local inherits
      for line in file:lines() do
        local list = line:match("^%s*Inherits%s*=%s*(.-)%s*$")
        if list then
          inherits = list:match("^([^,%s]+)")
          break
        end
      end
      file:close()
      return path, inherits
    end
  end
end

-- What this config set before, on a reload, is not a choice of yours: a
-- reload decides again from what is there now.
local function chosen(name)
  local value = os.getenv(name) or ""
  if value == "" or value == "Nova" then return nil end
  return value
end

local xcursor = chosen("XCURSOR_THEME")
local hyprcursor = chosen("HYPRCURSOR_THEME")
local default_path, default_inherits = your_default()

if not xcursor then
  if default_path then
    -- "default" is your index.theme, as libXcursor and every toolkit read it.
    xcursor = "default"
  elseif find("Nova", "cursors/default") then
    xcursor = "Nova"
  else
    return -- Nova's theme is not installed: the cursor libraries' own default.
  end
  hl.env("XCURSOR_THEME", xcursor)
end

if hyprcursor then return end
local wanted = xcursor == "default" and (default_inherits or "") or xcursor
if wanted ~= "" and has_hyprcursor(wanted) then
  hl.env("HYPRCURSOR_THEME", wanted)
else
  hl.config({ cursor = { enable_hyprcursor = false } })
end
