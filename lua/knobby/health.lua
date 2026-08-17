local M = {}

local function executable(command)
  local binary = type(command) == "table" and command[1] or command
  return vim.fn.executable(binary) == 1, binary
end

function M.check()
  local health = vim.health
  health.start("Knobby")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim supports inline virtual text and vim.system")
  else
    health.error("Neovim 0.10 or newer is required")
  end

  local knobby = require("knobby")
  local cfg = knobby.get_config() or require("knobby.config").defaults()
  local found, binary = executable(cfg.midi.command)
  if found then
    health.ok(binary .. " is executable")
  else
    health.error(binary .. " is not executable; install alsa-utils or configure midi.command")
  end

  local groups = vim.fn.system({ "id", "-nG" })
  if groups:match("%f[%w]audio%f[%W]") then
    health.ok("Current user belongs to the audio group")
  else
    health.warn("Current user is not in the audio group", {
      "Run: sudo usermod -aG audio \"$USER\"",
      "Then restart WSL and reattach the USB device.",
    })
  end

  if vim.fn.isdirectory("/dev/snd") == 1 then
    health.ok("/dev/snd is available")
  else
    health.warn("/dev/snd is unavailable; attach the controller to WSL with usbipd")
  end

  local ok, compiled = pcall(require("knobby.profiles").compile, cfg.controller)
  if ok then
    health.ok(string.format("Controller profile %s defines %d controls", compiled.name, compiled.count))
  else
    health.error(tostring(compiled))
  end

  if knobby.is_configured() and found then
    local devices, err = require("knobby.midi").list_devices_sync()
    if not devices then
      health.error("Unable to list MIDI inputs: " .. tostring(err))
    elseif #devices == 0 then
      health.warn("No ALSA raw MIDI inputs were found")
    else
      for _, device in ipairs(devices) do
        health.info(string.format(
          "%s: %s (usb=%s, serial=%s)",
          device.port,
          device.name,
          device.usb_id or "unknown",
          device.serial or "unknown"
        ))
      end
    end

    local status = require("knobby.midi").status()
    if status.status == "connected" then
      health.ok("MIDI reader connected to " .. tostring(status.port))
    elseif status.error then
      health.warn("MIDI reader is " .. status.status .. ": " .. status.error)
    else
      health.info("MIDI reader is " .. status.status)
    end
  else
    health.info("Call require('knobby').setup() to check discovery and connection state")
  end
end

return M
