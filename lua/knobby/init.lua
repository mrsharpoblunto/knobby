local config_module = require("knobby.config")
local profiles = require("knobby.profiles")
local capture = require("knobby.capture")
local midi = require("knobby.midi")
local coordination = require("knobby.coordination")

local M = {}

local config
local controller
local configured = false
local installed_keys = {}
local runtime_augroup
local pending_turns = {}
local suppress_turns_until = {}
local navigation_captured_only = false
local runtime_enabled = false

local function now_ms()
  return vim.uv.hrtime() / 1000000
end

local function close_turn(index)
  local pending = pending_turns[index]
  if not pending then
    return
  end
  pending_turns[index] = nil
  pending.timer:stop()
  if not pending.timer:is_closing() then
    pending.timer:close()
  end
  return pending
end

local function apply_pending_turn(pending, discard_recent)
  if not pending then
    return
  end
  if discard_recent and pending.events[#pending.events] then
    local latest = pending.events[#pending.events]
    if now_ms() - latest.at <= config.controller.button_guard_ms then
      table.remove(pending.events)
    end
  end
  local delta = 0
  for _, event in ipairs(pending.events) do
    delta = delta + event.delta
  end
  if delta ~= 0 then
    M.turn(pending.index, delta)
  end
end

local function clear_pending_turns()
  local indices = vim.tbl_keys(pending_turns)
  for _, index in ipairs(indices) do
    close_turn(index)
  end
  suppress_turns_until = {}
end

local function queue_turn(index, delta)
  if now_ms() < (suppress_turns_until[index] or 0) then
    return
  end

  local pending = pending_turns[index]
  if pending then
    pending.events[#pending.events + 1] = { delta = delta, at = now_ms() }
    return
  end

  pending = {
    index = index,
    events = { { delta = delta, at = now_ms() } },
    timer = vim.uv.new_timer(),
  }
  pending_turns[index] = pending
  pending.timer:start(config.controller.turn_flush_ms, 0, vim.schedule_wrap(function()
    if pending_turns[index] ~= pending then
      return
    end
    apply_pending_turn(close_turn(index), false)
  end))
end

local function handle_button(index)
  apply_pending_turn(close_turn(index), true)
  suppress_turns_until[index] = now_ms() + config.controller.button_guard_ms
  M.press(index)
end

local function handle_midi_message(message)
  local events = controller.handle(message)
  for _, event in ipairs(events) do
    if event.type == "press" then
      handle_button(event.index)
    elseif event.type == "turn" then
      queue_turn(event.index, event.delta)
    end
  end
end

local function notify(message, level)
  if not config or config.ui.notifications then
    vim.notify(message, level or vim.log.levels.INFO, { title = "Knobby" })
  end
end

local function encoder_index(value)
  local index = tonumber(value)
  if not index or index < 1 or index > controller.count or index % 1 ~= 0 then
    error(string.format("knobby: encoder index must be between 1 and %d", controller.count))
  end
  return index
end

local function role_for(index)
  for name, role in pairs(config.controller.roles) do
    if role.index == index then
      return name, role
    end
  end
end

local function validate_role_indices()
  for _, role in pairs(config.controller.roles) do
    if role.index ~= false then
      encoder_index(role.index)
    end
  end
end

local function define_commands()
  vim.api.nvim_create_user_command("KnobbyToggle", function(args)
    M.toggle(encoder_index(args.args))
  end, { nargs = 1, force = true, desc = "Toggle a Knobby encoder capture" })

  vim.api.nvim_create_user_command("KnobbyRelease", function(args)
    if args.args == "" then
      capture.release_all()
    else
      capture.release(encoder_index(args.args))
    end
  end, { nargs = "?", force = true, desc = "Release one or all Knobby captures" })

  vim.api.nvim_create_user_command("KnobbyStepUp", function()
    capture.change_step(1, 1)
  end, { force = true, desc = "Increase the step of the capture under the cursor" })

  vim.api.nvim_create_user_command("KnobbyStepDown", function()
    capture.change_step(-1, 1)
  end, { force = true, desc = "Decrease the step of the capture under the cursor" })

  vim.api.nvim_create_user_command("KnobbyStepReset", function()
    capture.reset_step()
  end, { force = true, desc = "Reset the step of the capture under the cursor" })

  vim.api.nvim_create_user_command("KnobbyEnable", function()
    M.enable()
  end, { force = true, desc = "Enable the Knobby MIDI reader" })

  vim.api.nvim_create_user_command("KnobbyDisable", function()
    M.disable()
  end, { force = true, desc = "Disable the Knobby MIDI reader" })

  vim.api.nvim_create_user_command("KnobbyReconnect", function()
    M.reconnect()
  end, { force = true, desc = "Reconnect the Knobby MIDI reader" })

  vim.api.nvim_create_user_command("KnobbyActivate", function()
    M.activate()
  end, { force = true, desc = "Route Knobby MIDI events to this Neovim instance" })

  vim.api.nvim_create_user_command("KnobbyDeactivate", function()
    M.deactivate()
  end, { force = true, desc = "Stop routing Knobby MIDI events to this Neovim instance" })

  vim.api.nvim_create_user_command("KnobbyStatus", function()
    local current = M.status()
    local lines = {
      string.format(
        "MIDI: %s via %s%s",
        current.midi.status,
        current.midi.backend or "unknown backend",
        current.midi.port and " (" .. current.midi.port .. ")" or ""
      ),
      string.format("Captures: %d", #current.captures),
    }
    if current.coordination.enabled then
      lines[#lines + 1] = string.format(
        "Coordination: %s, %s, %d client%s (%s)",
        current.coordination.role,
        current.coordination.active and "active here" or "inactive here",
        current.coordination.clients,
        current.coordination.clients == 1 and "" or "s",
        current.coordination.endpoint
      )
      if current.coordination.error then
        lines[#lines + 1] = "Coordination error: " .. current.coordination.error
      end
    end
    if current.roles.navigation.index then
      lines[#lines + 1] = string.format(
        "Navigation E%d: %s",
        current.roles.navigation.index,
        current.roles.navigation.captured_only and "captured values only" or "all capturable values"
      )
    end
    if current.roles.step.index then
      lines[#lines + 1] = string.format("Step E%d", current.roles.step.index)
    end
    if current.midi.error then
      lines[#lines + 1] = "Error: " .. current.midi.error
    end
    for _, item in ipairs(current.captures) do
      lines[#lines + 1] = string.format(
        "E%d: buffer %d, %d:%d, step %s%s",
        item.index,
        item.bufnr,
        (item.row or 0) + 1,
        (item.start_col or 0) + 1,
        item.step,
        item.valid and "" or " (invalid)"
      )
    end
    notify(table.concat(lines, "\n"), current.midi.error and vim.log.levels.WARN or vim.log.levels.INFO)
  end, { force = true, desc = "Show Knobby connection and capture status" })

  vim.api.nvim_create_user_command("KnobbyDevices", function()
    midi.list_devices(function(devices, err)
      if not devices then
        notify("Unable to list MIDI devices: " .. err, vim.log.levels.ERROR)
        return
      end
      if #devices == 0 then
        notify("No MIDI inputs found", vim.log.levels.WARN)
        return
      end
      local lines = { "MIDI inputs:" }
      for _, device in ipairs(devices) do
        local identity = device.port == device.name
            and "  " .. device.name
          or string.format("  %s  %s", device.port, device.name)
        if device.usb_id or device.serial then
          identity = string.format(
            "%s  usb=%s serial=%s",
            identity,
            device.usb_id or "?",
            device.serial or "?"
          )
        end
        lines[#lines + 1] = identity
      end
      notify(table.concat(lines, "\n"))
    end)
  end, { force = true, desc = "List MIDI inputs" })
end

local function delete_installed_keys()
  for _, mapping in ipairs(installed_keys) do
    pcall(vim.keymap.del, "n", mapping)
  end
  installed_keys = {}
end

local function define_keys()
  delete_installed_keys()
  local plugs = {
    {
      name = "<Plug>(KnobbyStepDown)",
      callback = function()
        capture.change_step(-1, vim.v.count1)
      end,
      default = config.keys.step_down,
      desc = "Decrease Knobby step",
    },
    {
      name = "<Plug>(KnobbyStepUp)",
      callback = function()
        capture.change_step(1, vim.v.count1)
      end,
      default = config.keys.step_up,
      desc = "Increase Knobby step",
    },
    {
      name = "<Plug>(KnobbyStepReset)",
      callback = function()
        capture.reset_step()
      end,
      default = config.keys.step_reset,
      desc = "Reset Knobby step",
    },
  }

  for _, mapping in ipairs(plugs) do
    vim.keymap.set("n", mapping.name, mapping.callback, { desc = mapping.desc })
    if mapping.default and mapping.default ~= "" then
      vim.keymap.set("n", mapping.default, mapping.name, { remap = true, desc = mapping.desc })
      installed_keys[#installed_keys + 1] = mapping.default
    end
  end
end

function M.setup(opts)
  clear_pending_turns()
  runtime_enabled = false
  config = config_module.resolve(opts)
  controller = profiles.compile(config.controller)
  validate_role_indices()
  navigation_captured_only = config.controller.roles.navigation.captured_only
  capture.setup(config)
  coordination.setup(config.coordination, {
    on_role = function(is_broker)
      if runtime_enabled and is_broker then
        midi.start()
      else
        midi.stop()
      end
    end,
    on_active = function()
      clear_pending_turns()
      controller.reset()
      pcall(vim.cmd, "redrawstatus")
    end,
    on_message = handle_midi_message,
    on_control = function(action)
      if action == "reconnect" and coordination.status().role == "broker" then
        midi.reconnect()
      end
    end,
    on_status = function()
      pcall(vim.cmd, "redrawstatus")
    end,
  })
  local midi_handlers = {
    on_status = function(status)
      if config.coordination.enabled then
        coordination.set_midi_status(status)
      end
      pcall(vim.cmd, "redrawstatus")
    end,
  }
  if config.coordination.enabled then
    midi_handlers.on_message = function(message)
      coordination.publish(message)
    end
  else
    midi_handlers.on_message = handle_midi_message
  end
  midi.setup(config, controller, midi_handlers)
  define_commands()
  define_keys()
  runtime_augroup = vim.api.nvim_create_augroup("KnobbyRuntime", { clear = true })
  if config.coordination.enabled and config.coordination.activation == "focus" then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = runtime_augroup,
      callback = function()
        M.activate()
      end,
    })
    vim.api.nvim_create_autocmd("FocusLost", {
      group = runtime_augroup,
      callback = function()
        M.deactivate()
      end,
    })
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = runtime_augroup,
    callback = function()
      clear_pending_turns()
      runtime_enabled = false
      midi.stop()
      coordination.stop()
    end,
  })
  configured = true
  if config.midi.enabled then
    M.enable()
  end
  return M
end

function M.enable()
  runtime_enabled = true
  if config.coordination.enabled then
    coordination.start()
    if config.coordination.activation == "focus" then
      coordination.activate()
    end
  else
    midi.start()
  end
  return true
end

function M.disable()
  runtime_enabled = false
  clear_pending_turns()
  midi.stop()
  if config.coordination.enabled then
    coordination.stop()
  end
  return true
end

function M.reconnect()
  if not config.coordination.enabled then
    midi.reconnect()
    return true
  end
  if coordination.status().role == "broker" then
    midi.reconnect()
    return true
  end
  return coordination.request("reconnect")
end

function M.activate()
  if not config.coordination.enabled then
    return true
  end
  return coordination.activate()
end

function M.deactivate()
  clear_pending_turns()
  controller.reset()
  if not config.coordination.enabled then
    return true
  end
  return coordination.deactivate()
end

function M.toggle(index)
  return capture.toggle(encoder_index(index))
end

function M.turn(index, delta)
  index = encoder_index(index)
  vim.validate({ delta = { delta, "number" } })
  local role = role_for(index)
  if role == "navigation" then
    return M.navigate(delta)
  elseif role == "step" then
    if delta == 0 then
      return false, "zero delta"
    end
    return capture.change_step(delta > 0 and 1 or -1, math.abs(delta))
  end
  return capture.turn(index, delta)
end

function M.press(index)
  index = encoder_index(index)
  local role, role_options = role_for(index)
  if role == "navigation" then
    return M.toggle_navigation_scope()
  elseif role == "step" then
    if role_options.reset_on_press then
      return capture.reset_step()
    end
    return true
  end
  return capture.toggle(index)
end

function M.navigate(delta)
  local role = config.controller.roles.navigation
  if role.index == false then
    return false, "navigation encoder is not configured"
  end
  return capture.navigate(delta, {
    captured_only = navigation_captured_only,
    wrap = role.wrap,
  })
end

function M.toggle_navigation_scope()
  local role = config.controller.roles.navigation
  if role.index == false then
    return false, "navigation encoder is not configured"
  end
  navigation_captured_only = not navigation_captured_only
  local label = navigation_captured_only and "captured values only" or "all capturable values"
  notify("Navigation: " .. label)
  return true, navigation_captured_only
end

function M.release(index)
  if index == nil then
    return capture.release_all()
  end
  return capture.release(encoder_index(index))
end

function M.step_up(count)
  return capture.change_step(1, count or 1)
end

function M.step_down(count)
  return capture.change_step(-1, count or 1)
end

function M.step_reset()
  return capture.reset_step()
end

function M.status()
  local coordination_status = coordination.status()
  coordination_status.enabled = config.coordination.enabled
  local midi_status = midi.status()
  if config.coordination.enabled and coordination_status.midi then
    midi_status = coordination_status.midi
  end
  return {
    midi = midi_status,
    coordination = coordination_status,
    captures = capture.status(),
    roles = {
      navigation = {
        index = config.controller.roles.navigation.index or nil,
        captured_only = navigation_captured_only,
        wrap = config.controller.roles.navigation.wrap,
      },
      step = {
        index = config.controller.roles.step.index or nil,
        reset_on_press = config.controller.roles.step.reset_on_press,
      },
    },
  }
end

function M.statusline()
  local current = M.status()
  local connection = current.midi
  local icon = ({ connected = "●", scanning = "…", disconnected = "×", stopped = "○" })[connection.status]
    or "?"
  local routing = current.coordination.enabled and (current.coordination.active and "▶" or "·") or ""
  return string.format("Knobby %s%s %d", icon, routing, capture.count())
end

function M.is_configured()
  return configured
end

function M.get_config()
  return config and vim.deepcopy(config) or nil
end

function M.get_controller()
  return controller
end

return M
