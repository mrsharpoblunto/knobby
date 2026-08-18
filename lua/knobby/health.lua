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
  local config_module = require("knobby.config")
  local cfg = knobby.get_config() or config_module.defaults()
  local backend = config_module.effective_backend(cfg)
  local sysname = vim.uv.os_uname().sysname
  local is_macos = sysname == "Darwin"
  local is_windows = sysname:match("^Windows") ~= nil
  local found, binary = executable(config_module.effective_command(cfg))
  if found then
    health.ok(string.format("%s backend: %s is executable", backend, binary))
  elseif backend == "receivemidi" then
    local advice
    if is_macos then
      advice = {
        "Install it with: brew install gbevin/tools/receivemidi",
        "Or configure midi.command with the ReceiveMIDI executable path.",
      }
    elseif is_windows then
      advice = {
        "Download receivemidi.exe from https://github.com/gbevin/ReceiveMIDI/releases",
        "Place it on PATH, or set midi.command to its full path.",
      }
    else
      advice = { "Configure midi.command with the ReceiveMIDI executable path." }
    end
    health.error(binary .. " is not executable", advice)
  else
    health.error(binary .. " is not executable; install alsa-utils or configure midi.command")
  end

  if backend == "amidi" then
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
  elseif is_macos then
    health.ok("CoreMIDI does not require ALSA device or audio-group setup")
  elseif is_windows then
    health.ok("Windows MIDI does not require ALSA device or audio-group setup")
  else
    health.info("ReceiveMIDI manages MIDI device access on this platform")
  end

  local ok, compiled = pcall(require("knobby.profiles").compile, cfg.controller)
  if ok then
    health.ok(string.format("Controller profile %s defines %d controls", compiled.name, compiled.count))
  else
    health.error(tostring(compiled))
  end

  local plugin_status
  if knobby.is_configured() then
    plugin_status = knobby.status()
    local coordination = plugin_status.coordination
    if coordination.enabled then
      local summary = string.format(
        "%s; %s; %d connected instance%s",
        coordination.role,
        coordination.active and "active here" or "inactive here",
        coordination.clients,
        coordination.clients == 1 and "" or "s"
      )
      if coordination.status == "connected" then
        health.ok("Multi-instance coordination connected: " .. summary)
        health.info("Coordination endpoint: " .. tostring(coordination.endpoint))
        if coordination.role == "broker" then
          health.info("This instance owns the shared MIDI reader")
        else
          health.info("The broker owns MIDI; this instance does not open the device")
        end
      elseif coordination.error then
        health.warn(
          string.format("Multi-instance coordination is %s: %s", coordination.status, coordination.error),
          { "Use :KnobbyStatus for live state or :KnobbyReconnect after coordination recovers." }
        )
      else
        health.info("Multi-instance coordination is " .. coordination.status)
      end
    else
      health.info("Multi-instance coordination is disabled; this instance opens MIDI directly")
    end
  end

  if knobby.is_configured() and found then
    local devices, err = require("knobby.midi").list_devices_sync()
    if not devices then
      health.error("Unable to list MIDI inputs: " .. tostring(err))
    elseif #devices == 0 then
      health.warn("No MIDI inputs were found")
    else
      for _, device in ipairs(devices) do
        if backend == "amidi" then
          health.info(string.format(
            "%s: %s (usb=%s, serial=%s)",
            device.port,
            device.name,
            device.usb_id or "unknown",
            device.serial or "unknown"
          ))
        else
          health.info(string.format("%s: %s", device.port, device.name))
        end
      end
    end

    local status = plugin_status.midi
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
