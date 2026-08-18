local scenario, command, port, mode = unpack(arg)

local function emit(data)
  io.stdout:write(data)
  io.stdout:flush()
end

local function pause(milliseconds)
  vim.uv.sleep(milliseconds)
end

if scenario == "coordinated" then
  local open_log, trigger = command, port
  local log = assert(io.open(open_log, "a"))
  log:write(tostring(vim.uv.os_getpid()), "\n")
  log:close()

  local deadline = vim.uv.hrtime() + 20 * 1000000000
  while vim.uv.hrtime() < deadline do
    local claim = trigger .. "." .. tostring(vim.uv.os_getpid())
    if vim.uv.fs_rename(trigger, claim) then
      local lines = vim.fn.readfile(claim)
      pcall(vim.uv.fs_unlink, claim)
      if lines[1] == "press_turn" then
        emit("90 20 7F\n")
        pause(60)
        emit("B0 20 41\n")
      elseif lines[1] == "turn" then
        emit("B0 20 41\n")
      end
    end
    pause(20)
  end
elseif scenario == "amidi_stream" then
  emit("90 20 7F\n")
  pause(60)
  emit("B0 20 01\n")
elseif scenario == "amidi_unterminated" then
  emit("\n90 20 7F")
  pause(60)
  emit("\nB0 20 41")
  pause(1000)
elseif scenario == "amidi_button_guard" then
  emit("90 20 7F\n")
  pause(60)
  emit("B0 20 01\n")
  pause(60)
  emit("B0 20 02\n90 20 7F\n")
elseif scenario == "receivemidi_stream" and command == "list" then
  emit("Grid\n")
elseif scenario == "receivemidi_stream"
  and command == "dev"
  and port == "Grid"
  and mode == "nn"
then
  emit("channel  1   note-on           32 127\n")
  pause(60)
  emit("channel  1   control-change    32  65\n")
else
  io.stderr:write("unexpected fake MIDI invocation\n")
  io.stderr:flush()
  vim.cmd("cquit 9")
  return
end

vim.cmd("qa!")
