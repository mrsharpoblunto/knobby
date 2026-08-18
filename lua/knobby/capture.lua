local numbers = require("knobby.numbers")

local M = {}

local namespace = vim.api.nvim_create_namespace("knobby")
local config
local slots = {}
local augroup
local pending_refresh = {}

local function notify(message, level)
  if config and config.ui.notifications then
    vim.notify(message, level or vim.log.levels.INFO, { title = "Knobby" })
  end
end

local function label_text(slot)
  local step = numbers.format_step(slot.step_exponent)
  local format = config.ui.virtual_text.format
  if type(format) == "function" then
    return format(slot.index, step, slot)
  end
  return string.format(format, slot.index, step)
end

local function delete_extmark(bufnr, id)
  if id and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, id)
  end
end

local function update_label(slot, row, end_col)
  delete_extmark(slot.bufnr, slot.label_id)
  slot.label_id = nil
  if not config.ui.virtual_text.enabled then
    return
  end

  slot.label_id = vim.api.nvim_buf_set_extmark(slot.bufnr, namespace, row, end_col, {
    virt_text = { { label_text(slot), config.ui.label_highlight } },
    virt_text_pos = config.ui.virtual_text.position,
    right_gravity = true,
    priority = 110,
  })
end

local function update_range(slot, row, start_col, end_col)
  local opts = {
    end_row = row,
    end_col = end_col,
    hl_group = config.ui.highlight,
    right_gravity = false,
    end_right_gravity = true,
    undo_restore = true,
    invalidate = true,
    priority = 110,
  }
  if slot.extmark_id then
    opts.id = slot.extmark_id
  end
  slot.extmark_id = vim.api.nvim_buf_set_extmark(slot.bufnr, namespace, row, start_col, opts)
  slot.row = row
  slot.start_col = start_col
  slot.end_col = end_col
  update_label(slot, row, end_col)
end

local function extmark_position(slot)
  if not vim.api.nvim_buf_is_valid(slot.bufnr) then
    return nil, "buffer was deleted"
  end
  local result = vim.api.nvim_buf_get_extmark_by_id(slot.bufnr, namespace, slot.extmark_id, {
    details = true,
  })
  if #result == 0 then
    return nil, "capture mark was deleted"
  end
  local details = result[3] or {}
  if details.invalid then
    return nil, "captured number was deleted"
  end
  if details.end_row == nil or details.end_col == nil or details.end_row ~= result[1] then
    return nil, "captured range is invalid"
  end
  return {
    row = result[1],
    start_col = result[2],
    end_col = details.end_col,
  }
end

local function overlapping_token(line, range)
  local best
  local best_overlap = -1
  for _, token in ipairs(numbers.find_all(line)) do
    local overlap = math.max(
      0,
      math.min(range.end_col, token.end_col) - math.max(range.start_col, token.start_col)
    )
    if overlap > best_overlap and (overlap > 0 or (
      range.start_col == range.end_col
      and token.start_col <= range.start_col
      and token.end_col >= range.start_col
    )) then
      best = token
      best_overlap = overlap
    end
  end
  return best
end

local function refresh_slot(slot)
  local range, range_error = extmark_position(slot)
  if not range then
    return nil, range_error
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, slot.bufnr, range.row, range.row + 1, true)
  if not ok or not lines[1] then
    return nil, "captured line no longer exists"
  end
  local token = overlapping_token(lines[1], range)
  if not token then
    return nil, "captured text is no longer a number"
  end
  if token.start_col ~= range.start_col or token.end_col ~= range.end_col then
    update_range(slot, range.row, token.start_col, token.end_col)
  else
    slot.row, slot.start_col, slot.end_col = range.row, range.start_col, range.end_col
    update_label(slot, range.row, range.end_col)
  end
  token.row = range.row
  return token
end

local function handle_invalid(slot, reason)
  if config.capture.invalid_number == "release" then
    M.release(slot.index, { reason = reason })
  end
end

local function schedule_refresh(bufnr, release_invalid)
  pending_refresh[bufnr] = pending_refresh[bufnr] or { release_invalid = false }
  pending_refresh[bufnr].release_invalid = pending_refresh[bufnr].release_invalid or release_invalid
  if pending_refresh[bufnr].scheduled then
    return
  end
  pending_refresh[bufnr].scheduled = true
  vim.schedule(function()
    local pending = pending_refresh[bufnr]
    pending_refresh[bufnr] = nil
    if not pending then
      return
    end
    for _, slot in pairs(slots) do
      if slot.bufnr == bufnr then
        local token, err = refresh_slot(slot)
        if not token and pending.release_invalid then
          handle_invalid(slot, err)
        end
      end
    end
  end)
end

local function duplicate_owner(bufnr, row, token, except_index)
  for index, slot in pairs(slots) do
    if index ~= except_index and slot.bufnr == bufnr then
      local current = refresh_slot(slot)
      if current
        and current.row == row
        and current.start_col == token.start_col
        and current.end_col == token.end_col
      then
        return slot
      end
    end
  end
end

function M.setup(opts)
  if config then
    M.teardown()
  end
  config = opts
  slots = {}
  pending_refresh = {}

  vim.api.nvim_set_hl(0, "KnobbyCapture", { default = true, link = "IncSearch" })
  vim.api.nvim_set_hl(0, "KnobbyLabel", { default = true, link = "DiagnosticInfo" })

  augroup = vim.api.nvim_create_augroup("KnobbyCapture", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    callback = function(args)
      schedule_refresh(args.buf, false)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    callback = function(args)
      schedule_refresh(args.buf, true)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(args)
      M.release_buffer(args.buf)
    end,
  })
end

function M.capture(index, opts)
  opts = opts or {}
  local winid = opts.winid or vim.api.nvim_get_current_win()
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid buffer"
  end
  if not vim.bo[bufnr].modifiable then
    notify("Cannot capture a number in an unmodifiable buffer", vim.log.levels.WARN)
    return false, "buffer is not modifiable"
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row, cursor_col = cursor[1] - 1, cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1]
  local token = line and numbers.find_at_cursor(line, cursor_col)
  if not token then
    notify(string.format("Encoder %d: no number under the cursor", index), vim.log.levels.WARN)
    return false, "no number under the cursor"
  end

  local owner = duplicate_owner(bufnr, row, token, index)
  if owner then
    if config.capture.duplicate == "transfer" then
      M.release(owner.index, { silent = true })
    else
      notify(string.format("That number is already captured by encoder %d", owner.index), vim.log.levels.WARN)
      return false, "number is already captured"
    end
  end

  local slot = {
    index = index,
    bufnr = bufnr,
    step_exponent = token.step_exponent,
    default_step_exponent = token.step_exponent,
  }
  slots[index] = slot
  update_range(slot, row, token.start_col, token.end_col)
  notify(string.format("Encoder %d captured %s (step %s)", index, token.text, numbers.format_step(slot.step_exponent)))
  return true, slot
end

function M.toggle(index)
  vim.validate({ index = { index, "number" } })
  if slots[index] then
    return M.release(index)
  end
  return M.capture(index)
end

function M.release(index, opts)
  opts = opts or {}
  local slot = slots[index]
  if not slot then
    return false
  end
  delete_extmark(slot.bufnr, slot.extmark_id)
  delete_extmark(slot.bufnr, slot.label_id)
  slots[index] = nil
  if not opts.silent then
    local message = string.format("Encoder %d released", index)
    if opts.reason then
      message = message .. ": " .. opts.reason
    end
    notify(message, opts.reason and vim.log.levels.WARN or vim.log.levels.INFO)
  end
  return true
end

function M.release_all(opts)
  opts = opts or {}
  local indices = vim.tbl_keys(slots)
  table.sort(indices)
  for _, index in ipairs(indices) do
    M.release(index, { silent = true })
  end
  if #indices > 0 and not opts.silent then
    notify(string.format("Released %d capture%s", #indices, #indices == 1 and "" or "s"))
  end
  return #indices
end

function M.release_buffer(bufnr)
  local indices = {}
  for index, slot in pairs(slots) do
    if slot.bufnr == bufnr then
      indices[#indices + 1] = index
    end
  end
  for _, index in ipairs(indices) do
    M.release(index, { silent = true })
  end
end

function M.turn(index, delta)
  local slot = slots[index]
  if not slot or delta == 0 then
    return false, slot and "zero delta" or "encoder is not captured"
  end
  if not vim.api.nvim_buf_is_valid(slot.bufnr) or not vim.bo[slot.bufnr].modifiable then
    handle_invalid(slot, "buffer is no longer modifiable")
    return false, "buffer is no longer modifiable"
  end

  local token, refresh_error = refresh_slot(slot)
  if not token then
    handle_invalid(slot, refresh_error)
    return false, refresh_error
  end
  local replacement, increment_error = numbers.increment(token.text, slot.step_exponent, delta)
  if not replacement then
    handle_invalid(slot, increment_error)
    return false, increment_error
  end

  local now = vim.uv.hrtime() / 1000000
  local changedtick = vim.api.nvim_buf_get_changedtick(slot.bufnr)
  if slot.last_turn_ms
    and now - slot.last_turn_ms <= config.capture.undo_join_ms
    and slot.last_changedtick == changedtick
  then
    vim.api.nvim_buf_call(slot.bufnr, function()
      pcall(vim.cmd, "silent! undojoin")
    end)
  end

  vim.api.nvim_buf_set_text(
    slot.bufnr,
    token.row,
    token.start_col,
    token.row,
    token.end_col,
    { replacement }
  )
  update_range(slot, token.row, token.start_col, token.start_col + #replacement)
  slot.last_turn_ms = now
  slot.last_changedtick = vim.api.nvim_buf_get_changedtick(slot.bufnr)
  return true, replacement
end

local function navigation_targets(bufnr, captured_only)
  local targets = {}
  if captured_only then
    for _, slot in pairs(slots) do
      if slot.bufnr == bufnr then
        local token = refresh_slot(slot)
        if token then
          targets[#targets + 1] = {
            row = token.row,
            start_col = token.start_col,
            end_col = token.end_col,
          }
        end
      end
    end
  else
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
    for row, line in ipairs(lines) do
      for _, token in ipairs(numbers.find_all(line)) do
        targets[#targets + 1] = {
          row = row - 1,
          start_col = token.start_col,
          end_col = token.end_col,
        }
      end
    end
  end

  table.sort(targets, function(left, right)
    return left.row < right.row or left.row == right.row and left.start_col < right.start_col
  end)
  return targets
end

local function target_at_cursor(targets, row, col)
  for index, target in ipairs(targets) do
    if target.row == row and col >= target.start_col and col < target.end_col then
      return index
    end
  end
end

local function first_target_in_direction(targets, row, col, direction)
  if direction > 0 then
    for index, target in ipairs(targets) do
      if target.row > row or target.row == row and target.start_col > col then
        return index
      end
    end
  else
    for index = #targets, 1, -1 do
      local target = targets[index]
      if target.row < row or target.row == row and target.start_col < col then
        return index
      end
    end
  end
end

function M.navigate(delta, opts)
  opts = opts or {}
  vim.validate({ delta = { delta, "number" }, opts = { opts, "table" } })
  if delta == 0 or delta % 1 ~= 0 then
    return false, delta == 0 and "zero delta" or "navigation delta must be an integer"
  end

  local winid = opts.winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local targets = navigation_targets(bufnr, opts.captured_only == true)
  if #targets == 0 then
    local kind = opts.captured_only and "captured" or "capturable"
    notify("No " .. kind .. " numbers in the current buffer", vim.log.levels.WARN)
    return false, "no " .. kind .. " numbers in the current buffer"
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row, col = cursor[1] - 1, cursor[2]
  local direction = delta > 0 and 1 or -1
  local count = math.abs(delta)
  local index = target_at_cursor(targets, row, col)
  local moved = false

  if index then
    for _ = 1, count do
      local next_index = index + direction
      if next_index < 1 or next_index > #targets then
        if opts.wrap == false then
          break
        end
        next_index = direction > 0 and 1 or #targets
      end
      index = next_index
      moved = true
    end
  else
    index = first_target_in_direction(targets, row, col, direction)
    if not index and opts.wrap ~= false then
      index = direction > 0 and 1 or #targets
    end
    moved = index ~= nil
    for _ = 2, count do
      if not index then
        break
      end
      local next_index = index + direction
      if next_index < 1 or next_index > #targets then
        if opts.wrap == false then
          break
        end
        next_index = direction > 0 and 1 or #targets
      end
      index = next_index
    end
  end

  if not moved or not index then
    return false, direction > 0 and "no next number" or "no previous number"
  end

  local target = targets[index]
  vim.api.nvim_win_set_cursor(winid, { target.row + 1, target.start_col })
  vim.api.nvim_win_call(winid, function()
    pcall(vim.cmd, "normal! zv")
  end)
  return true, target
end

local function slot_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  for _, slot in pairs(slots) do
    if slot.bufnr == bufnr then
      local token = refresh_slot(slot)
      if token and token.row == row and col >= token.start_col and col < token.end_col then
        return slot, token
      end
    end
  end
end

function M.change_step(direction, count)
  local slot = slot_at_cursor()
  if not slot then
    notify("Cursor is not on a captured number", vim.log.levels.WARN)
    return false, "cursor is not on a captured number"
  end
  slot.step_exponent = slot.step_exponent + direction * (count or vim.v.count1)
  update_label(slot, slot.row, slot.end_col)
  notify(string.format("Encoder %d step: %s", slot.index, numbers.format_step(slot.step_exponent)))
  return true, slot.step_exponent
end

function M.reset_step()
  local slot, token = slot_at_cursor()
  if not slot then
    notify("Cursor is not on a captured number", vim.log.levels.WARN)
    return false, "cursor is not on a captured number"
  end
  slot.step_exponent = token.step_exponent
  slot.default_step_exponent = token.step_exponent
  update_label(slot, slot.row, slot.end_col)
  notify(string.format("Encoder %d step reset to %s", slot.index, numbers.format_step(slot.step_exponent)))
  return true, slot.step_exponent
end

function M.status()
  local captures = {}
  for index, slot in pairs(slots) do
    local token = refresh_slot(slot)
    captures[#captures + 1] = {
      index = index,
      bufnr = slot.bufnr,
      row = token and token.row or slot.row,
      start_col = token and token.start_col or slot.start_col,
      end_col = token and token.end_col or slot.end_col,
      step_exponent = slot.step_exponent,
      step = numbers.format_step(slot.step_exponent),
      valid = token ~= nil,
    }
  end
  table.sort(captures, function(left, right)
    return left.index < right.index
  end)
  return captures
end

function M.count()
  return vim.tbl_count(slots)
end

function M.teardown()
  M.release_all({ silent = true })
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  config = nil
end

M.namespace = namespace

return M
