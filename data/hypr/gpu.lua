-- This computer's graphics cards, from the IDs the kernel keeps in sysfs.
-- lspci would read each card's PCI config space instead, and that wakes a
-- sleeping NVIDIA card on a hybrid laptop for longer than Hyprland waits for
-- its config to reload.
--
--   nvidia          an NVIDIA card is present
--   gsp             one runs on GSP firmware: Turing (2018) or newer
--   legacy          one predates GSP: Maxwell, Pascal or Volta
--   nvidia_display  an NVIDIA card drives the display, not a hybrid laptop's iGPU

local devices = "/sys/bus/pci/devices/"

local function read(path)
  local file = io.open(path)
  if not file then return nil end
  local line = file:read("l")
  file:close()
  return line
end

local gpu = { nvidia = false, gsp = false, legacy = false, nvidia_display = false }
local nvidia_boots, other_boots = false, false

local ls = io.popen("exec ls " .. devices .. " 2>/dev/null")
if ls then
  for name in ls:lines() do
    local device = devices .. name .. "/"
    if (read(device .. "class") or ""):sub(1, 4) == "0x03" then
      local boots = read(device .. "boot_vga") == "1"
      if read(device .. "vendor") == "0x10de" then
        gpu.nvidia = true
        nvidia_boots = nvidia_boots or boots
        -- Turing's device IDs start at 0x1e00, Maxwell's at 0x1340, the first
        -- after Kepler, which needs a driver Nova does not package.
        local id = tonumber(read(device .. "device") or "") or 0
        if id >= 0x1e00 then
          gpu.gsp = true
        elseif id >= 0x1340 then
          gpu.legacy = true
        end
      elseif boots then
        other_boots = true
      end
    end
  end
  ls:close()
end

-- The card the firmware drew its boot screen on drives the display; when no
-- card says so, NVIDIA's is taken to.
gpu.nvidia_display = gpu.nvidia and (nvidia_boots or not other_boots)

return gpu
