local M = {}

local defaults = {
  midi = {
    enabled = true,
    backend = "amidi",
    command = "amidi",
    line_buffered = true,
    port = "auto",
    match = {},
    reconnect = true,
    reconnect_interval_ms = 2000,
  },
  controller = {
    profile = "intech_en16",
    turn_flush_ms = 8,
    button_guard_ms = 25,
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
    ["controller"] = { cfg.controller, "table" },
    ["controller.profile"] = { cfg.controller.profile, "string" },
    ["controller.turn_flush_ms"] = { cfg.controller.turn_flush_ms, "number" },
    ["controller.button_guard_ms"] = { cfg.controller.button_guard_ms, "number" },
    ["capture.duplicate"] = { cfg.capture.duplicate, "string" },
    ["capture.invalid_number"] = { cfg.capture.invalid_number, "string" },
    ["capture.undo_join_ms"] = { cfg.capture.undo_join_ms, "number" },
    ["ui.notifications"] = { cfg.ui.notifications, "boolean" },
    ["ui.virtual_text"] = { cfg.ui.virtual_text, "table" },
    ["keys"] = { cfg.keys, "table" },
  })

  if cfg.midi.backend ~= "amidi" then
    error("knobby: unsupported MIDI backend: " .. cfg.midi.backend)
  end
  if cfg.capture.duplicate ~= "reject" and cfg.capture.duplicate ~= "transfer" then
    error("knobby: capture.duplicate must be 'reject' or 'transfer'")
  end
  if cfg.capture.invalid_number ~= "release" and cfg.capture.invalid_number ~= "keep" then
    error("knobby: capture.invalid_number must be 'release' or 'keep'")
  end
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
