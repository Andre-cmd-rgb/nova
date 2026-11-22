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
-- and lxappearance write it. Every place then names <theme> itself, not
-- "default": a theme called default is also the system's
-- (/usr/share/icons/default, Inherits=Adwaita, always installed), which
-- Hyprland's XCursor loader reads beside yours, and it took Adwaita's
-- cursors before those of any theme whose folder's name sorts after it.
-- "default" is named only for a default theme with cursors of its own.
-- Hyprland then draws that theme's Hyprcursor form if it has one, else its
-- XCursor form: Hyprcursor, asked for a theme it cannot find, takes any it
-- can, which would be Nova's.
-- A HYPRCURSOR_THEME the session started with is yours too, and kept.

local home = os.getenv("HOME") or ""
local data_home = os.getenv("XDG_DATA_HOME") or ""
if data_home == "" then data_home = home .. "/.local/share" end
local data_dirs = os.getenv("XDG_DATA_DIRS") or ""
if data_dirs == "" then data_dirs = "/usr/local/share:/usr/share" end

-- Your icon folders: XDG_DATA_HOME's, and the two the cursor libraries read
-- whatever XDG_DATA_HOME says.
local yours = { data_home .. "/icons" }
if data_home ~= home .. "/.local/share" then yours[#yours + 1] = home .. "/.local/share/icons" end
yours[#yours + 1] = home .. "/.icons"

-- Where icon themes are, yours first, as the cursor libraries look.
local icons = {}
for _, dir in ipairs(yours) do icons[#icons + 1] = dir end
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

local function has_xcursor(theme)
  return find(theme, "cursors/default") ~= nil or find(theme, "cursors/left_ptr") ~= nil
end

-- The theme your own default theme stands for: "default" when it has
-- cursors of its own, else the first theme its Inherits= names, where that
-- one is installed; nil when it chooses none.
local function your_default()
  for _, dir in ipairs(yours) do
    local file = io.open(dir .. "/default/index.theme")
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
      if readable(dir .. "/default/cursors/default") or readable(dir .. "/default/cursors/left_ptr") then
        return "default"
      end
      if inherits and inherits ~= "default" and
        (has_xcursor(inherits) or has_hyprcursor(inherits) or find(inherits, "index.theme")) then
        return inherits
      end
      return nil
    end
  end
end

-- What this config set before, on a reload, is not a choice of yours: a
-- reload decides again from what is there now, so a default theme you
-- removed gives Nova's back. NOVA_CURSOR says what it set,
-- "<XCURSOR_THEME>/<HYPRCURSOR_THEME>" (a theme's name has no "/").
local set_x, set_h = (os.getenv("NOVA_CURSOR") or ""):match("^([^/]*)/([^/]*)$")
local function chosen(name, set)
  local value = os.getenv(name) or ""
  if value == "" or value == "Nova" or value == set then return nil end
  return value
end

local xcursor = chosen("XCURSOR_THEME", set_x)
local hyprcursor = chosen("HYPRCURSOR_THEME", set_h)
local default_theme = your_default()
local mine_x, mine_h = "", ""

if not xcursor then
  if default_theme then
    xcursor = default_theme
  elseif has_xcursor("Nova") then
    xcursor = "Nova"
  else
    return -- Nova's theme is not installed: the cursor libraries' own default.
  end
  hl.env("XCURSOR_THEME", xcursor)
  mine_x = xcursor
end

if not hyprcursor then
  if has_hyprcursor(xcursor) then
    hl.env("HYPRCURSOR_THEME", xcursor)
    mine_h = xcursor
  else
    -- A name this config gave Hyprcursor before stays in the environment,
    -- which a reload cannot take back: it stays marked as set here, or the
    -- reload after this one would take it for yours and draw that theme.
    mine_h = os.getenv("HYPRCURSOR_THEME") or ""
    hl.config({ cursor = { enable_hyprcursor = false } })
  end
end
hl.env("NOVA_CURSOR", mine_x .. "/" .. mine_h)
