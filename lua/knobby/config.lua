local M = {}

local defaults = {
  midi = {
    enabled = true,
    backend = "auto",
    command = "auto",
    line_buffered = true,
    port = "auto",
    match = {},
    reconnect = true,
    reconnect_interval_ms = 2000,
  },
  coordination = {
    enabled = true,
    address = "auto",
    scope = "default",
    activation = "focus",
    reconnect_interval_ms = 150,
    broker_timeout_ms = 2000,
  },
  controller = {
    profile = "intech_en16",
    turn_flush_ms = 8,
    button_guard_ms = 25,
    roles = {
      navigation = {
        index = false,
        captured_only = false,
        wrap = true,
      },
      step = {
        index = false,
        reset_on_press = true,
      },
    },
  },
  capture = {
    duplicate = "reject",
    invalid_number = "release",
    undo_join_ms = 250,
  },
  ui = {
    highlight = "KnobbyCapture",
    label_highlight = "KnobbyLabel",
    notifications = true,
    virtual_text = {
      enabled = true,
      position = "inline",
      format = " ⟦E%d ±%s⟧",
    },
  },
  keys = {
    step_down = "[k",
    step_up = "]k",
    step_reset = false,
  },
}

local function validate(cfg)
  vim.validate({
    ["midi.enabled"] = { cfg.midi.enabled, "boolean" },
    ["midi.backend"] = { cfg.midi.backend, "string" },
    ["midi.port"] = { cfg.midi.port, "string" },
    ["midi.line_buffered"] = { cfg.midi.line_buffered, "boolean" },
    ["midi.match"] = { cfg.midi.match, "table" },
    ["midi.reconnect"] = { cfg.midi.reconnect, "boolean" },
    ["midi.reconnect_interval_ms"] = { cfg.midi.reconnect_interval_ms, "number" },
    ["coordination"] = { cfg.coordination, "table" },
    ["coordination.enabled"] = { cfg.coordination.enabled, "boolean" },
    ["coordination.address"] = { cfg.coordination.address, "string" },
    ["coordination.scope"] = { cfg.coordination.scope, "string" },
    ["coordination.activation"] = { cfg.coordination.activation, "string" },
    ["coordination.reconnect_interval_ms"] = {
      cfg.coordination.reconnect_interval_ms,
      "number",
    },
    ["coordination.broker_timeout_ms"] = { cfg.coordination.broker_timeout_ms, "number" },
    ["controller"] = { cfg.controller, "table" },
    ["controller.profile"] = { cfg.controller.profile, "string" },
    ["controller.turn_flush_ms"] = { cfg.controller.turn_flush_ms, "number" },
    ["controller.button_guard_ms"] = { cfg.controller.button_guard_ms, "number" },
    ["controller.roles"] = { cfg.controller.roles, "table" },
    ["controller.roles.navigation"] = { cfg.controller.roles.navigation, "table" },
    ["controller.roles.navigation.captured_only"] = {
      cfg.controller.roles.navigation.captured_only,
      "boolean",
    },
    ["controller.roles.navigation.wrap"] = { cfg.controller.roles.navigation.wrap, "boolean" },
    ["controller.roles.step"] = { cfg.controller.roles.step, "table" },
    ["controller.roles.step.reset_on_press"] = {
      cfg.controller.roles.step.reset_on_press,
      "boolean",
    },
    ["capture.duplicate"] = { cfg.capture.duplicate, "string" },
    ["capture.invalid_number"] = { cfg.capture.invalid_number, "string" },
    ["capture.undo_join_ms"] = { cfg.capture.undo_join_ms, "number" },
    ["ui.notifications"] = { cfg.ui.notifications, "boolean" },
    ["ui.virtual_text"] = { cfg.ui.virtual_text, "table" },
    ["keys"] = { cfg.keys, "table" },
  })

  if cfg.midi.backend ~= "auto"
    and cfg.midi.backend ~= "amidi"
    and cfg.midi.backend ~= "receivemidi"
  then
    error("knobby: unsupported MIDI backend: " .. cfg.midi.backend)
  end
  if type(cfg.midi.command) ~= "string" and type(cfg.midi.command) ~= "table" then
    error("knobby: midi.command must be a string or list")
  end
  if cfg.midi.command == "" then
    error("knobby: midi.command must not be empty")
  elseif type(cfg.midi.command) == "table" then
    if #cfg.midi.command == 0 then
      error("knobby: midi.command must not be empty")
    end
    for _, part in ipairs(cfg.midi.command) do
      if type(part) ~= "string" then
        error("knobby: every midi.command list item must be a string")
      end
    end
  end
  if cfg.capture.duplicate ~= "reject" and cfg.capture.duplicate ~= "transfer" then
    error("knobby: capture.duplicate must be 'reject' or 'transfer'")
  end
  if cfg.capture.invalid_number ~= "release" and cfg.capture.invalid_number ~= "keep" then
    error("knobby: capture.invalid_number must be 'release' or 'keep'")
  end
  if cfg.coordination.address == "" then
    error("knobby: coordination.address must not be empty")
  end
  if not cfg.coordination.scope:match("^[%w_.-]+$") or #cfg.coordination.scope > 32 then
    error("knobby: coordination.scope must use 1-32 letters, numbers, '.', '_', or '-'")
  end
  if cfg.coordination.activation ~= "focus" and cfg.coordination.activation ~= "manual" then
    error("knobby: coordination.activation must be 'focus' or 'manual'")
  end
  if cfg.coordination.reconnect_interval_ms < 10 then
    error("knobby: coordination.reconnect_interval_ms must be at least 10")
  end
  if cfg.coordination.broker_timeout_ms < 500 then
    error("knobby: coordination.broker_timeout_ms must be at least 500")
  end

  local role_indices = {}
  for name, role in pairs(cfg.controller.roles) do
    local index = role.index
    if index ~= false and (type(index) ~= "number" or index < 1 or index % 1 ~= 0) then
      error(string.format("knobby: controller.roles.%s.index must be false or a positive integer", name))
    end
    if index ~= false then
      if role_indices[index] then
        error(string.format(
          "knobby: encoder %d cannot have both the %s and %s roles",
          index,
          role_indices[index],
          name
        ))
      end
      role_indices[index] = name
    end
  end
end

function M.platform_backend(sysname)
  sysname = sysname or vim.uv.os_uname().sysname
  if sysname == "Darwin" or sysname:match("^Windows") then
    return "receivemidi"
  end
  return "amidi"
end

function M.default_command(backend, sysname)
  sysname = sysname or vim.uv.os_uname().sysname
  if backend == "receivemidi" and sysname:match("^Windows") then
    return "receivemidi.exe"
  end
  return backend
end

function M.effective_backend(cfg)
  local backend = cfg.midi.backend
  if backend == "auto" then
    return M.platform_backend()
  end
  return backend
end

function M.effective_command(cfg)
  if cfg.midi.command == "auto" then
    return M.default_command(M.effective_backend(cfg))
  end
  return cfg.midi.command
end

function M.resolve(opts)
  opts = opts or {}
  vim.validate({ opts = { opts, "table" } })
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  validate(cfg)
  return cfg
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
