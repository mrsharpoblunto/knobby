local config_module = require("knobby.config")
local profiles = require("knobby.profiles")
local capture = require("knobby.capture")
local midi = require("knobby.midi")

local M = {}

local config
local controller
local configured = false
local installed_keys = {}
local runtime_augroup
local pending_turns = {}
local suppress_turns_until = {}
local navigation_captured_only = false

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
    midi.start()
  end, { force = true, desc = "Enable the Knobby MIDI reader" })

  vim.api.nvim_create_user_command("KnobbyDisable", function()
    midi.stop()
  end, { force = true, desc = "Disable the Knobby MIDI reader" })

  vim.api.nvim_create_user_command("KnobbyReconnect", function()
    midi.reconnect()
  end, { force = true, desc = "Reconnect the Knobby MIDI reader" })

  vim.api.nvim_create_user_command("KnobbyStatus", function()
    local current = M.status()
    local lines = {
      string.format("MIDI: %s%s", current.midi.status, current.midi.port and " (" .. current.midi.port .. ")" or ""),
      string.format("Captures: %d", #current.captures),
    }
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
        notify("No ALSA raw MIDI inputs found", vim.log.levels.WARN)
        return
      end
      local lines = { "MIDI inputs:" }
      for _, device in ipairs(devices) do
        lines[#lines + 1] = string.format(
          "  %s  %s  usb=%s serial=%s",
          device.port,
          device.name,
          device.usb_id or "?",
          device.serial or "?"
        )
      end
      notify(table.concat(lines, "\n"))
    end)
  end, { force = true, desc = "List ALSA raw MIDI inputs" })
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
  config = config_module.resolve(opts)
  controller = profiles.compile(config.controller)
  validate_role_indices()
  navigation_captured_only = config.controller.roles.navigation.captured_only
  capture.setup(config)
  midi.setup(config, controller, {
    on_press = function(index)
      handle_button(index)
    end,
    on_turn = function(index, delta)
      queue_turn(index, delta)
    end,
    on_status = function()
      pcall(vim.cmd, "redrawstatus")
    end,
  })
  define_commands()
  define_keys()
  runtime_augroup = vim.api.nvim_create_augroup("KnobbyRuntime", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = runtime_augroup,
    callback = function()
      clear_pending_turns()
      midi.stop()
    end,
  })
  configured = true
  if config.midi.enabled then
    midi.start()
  end
  return M
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
  return {
    midi = midi.status(),
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
  local connection = midi.status()
  local icon = ({ connected = "●", scanning = "…", disconnected = "×", stopped = "○" })[connection.status]
    or "?"
  return string.format("Knobby %s %d", icon, capture.count())
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
