local label, address, scope, directory = unpack(arg)

local function path(name)
  return directory .. "/" .. name
end

local fake_command = {
  vim.v.progpath,
  "--clean",
  "--headless",
  "-u",
  "NONE",
  "-l",
  vim.fn.fnamemodify("tests/fake_midi.lua", ":p"),
  "coordinated",
  path("opens.log"),
  path("midi.trigger"),
}

local knobby = require("knobby").setup({
  midi = {
    enabled = true,
    backend = "amidi",
    command = fake_command,
    port = "fake",
    reconnect = false,
  },
  coordination = {
    enabled = true,
    address = address,
    scope = scope,
    activation = "manual",
    reconnect_interval_ms = 50,
    broker_timeout_ms = 600,
  },
  controller = { profile = "intech_en16_binary_offset" },
  ui = { notifications = false },
})

local buffer = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_buf(buffer)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
  "value = " .. (label == "a" and "1.00" or "2.00"),
})
vim.api.nvim_win_set_cursor(0, { 1, 9 })

local function consume(name, callback)
  local filename = path(label .. "." .. name)
  if vim.uv.fs_stat(filename) then
    pcall(vim.uv.fs_unlink, filename)
    callback()
  end
end

local function write_state()
  local status = knobby.status()
  vim.fn.writefile({ vim.json.encode({
    label = label,
    value = vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1],
    coordination = status.coordination,
    midi = status.midi,
  }) }, path(label .. ".state"))
end

local quitting = false
-- Must outlast the sum of the coordination test's own waits; the parent
-- signals "quit" as soon as it is done.
local completed = vim.wait(180000, function()
  consume("activate", function()
    knobby.activate()
  end)
  consume("deactivate", function()
    knobby.deactivate()
  end)
  consume("quit", function()
    quitting = true
  end)
  write_state()
  return quitting
end, 20)

write_state()
knobby.disable()
if completed then
  vim.cmd("qa!")
else
  io.stderr:write("coordinated Knobby fixture timed out\n")
  vim.cmd("cquit 9")
end
