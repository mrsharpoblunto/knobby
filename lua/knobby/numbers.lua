local M = {}

local MAX_EXPONENT = 1000

local function is_digit(char)
  return char ~= "" and char:match("%d") ~= nil
end

local function strip_zeroes(digits)
  local stripped = digits:gsub("^0+", "")
  return stripped == "" and "0" or stripped
end

local function compare_abs(left, right)
  left, right = strip_zeroes(left), strip_zeroes(right)
  if #left ~= #right then
    return #left < #right and -1 or 1
  end
  if left == right then
    return 0
  end
  return left < right and -1 or 1
end

local function add_abs(left, right)
  local carry = 0
  local out = {}
  local li, ri = #left, #right
  while li > 0 or ri > 0 or carry > 0 do
    local ld = li > 0 and tonumber(left:sub(li, li)) or 0
    local rd = ri > 0 and tonumber(right:sub(ri, ri)) or 0
    local sum = ld + rd + carry
    out[#out + 1] = tostring(sum % 10)
    carry = math.floor(sum / 10)
    li, ri = li - 1, ri - 1
  end
  return table.concat(out):reverse()
end

local function subtract_abs(left, right)
  local borrow = 0
  local out = {}
  local li, ri = #left, #right
  while li > 0 do
    local ld = tonumber(left:sub(li, li)) - borrow
    local rd = ri > 0 and tonumber(right:sub(ri, ri)) or 0
    if ld < rd then
      ld = ld + 10
      borrow = 1
    else
      borrow = 0
    end
    out[#out + 1] = tostring(ld - rd)
    li, ri = li - 1, ri - 1
  end
  return strip_zeroes(table.concat(out):reverse())
end

local function add_signed(left_sign, left, right_sign, right)
  left, right = strip_zeroes(left), strip_zeroes(right)
  if left == "0" then
    return right == "0" and 1 or right_sign, right
  elseif right == "0" then
    return left_sign, left
  elseif left_sign == right_sign then
    return left_sign, add_abs(left, right)
  end

  local comparison = compare_abs(left, right)
  if comparison == 0 then
    return 1, "0"
  elseif comparison > 0 then
    return left_sign, subtract_abs(left, right)
  end
  return right_sign, subtract_abs(right, left)
end

local function parse_at(text, start_index)
  local length = #text
  local position = start_index
  local sign_char = ""
  local first = text:sub(position, position)
  if first == "+" or first == "-" then
    sign_char = first
    position = position + 1
  end

  local integer_start = position
  while position <= length and is_digit(text:sub(position, position)) do
    position = position + 1
  end
  local integer_digits = text:sub(integer_start, position - 1)

  local has_dot = text:sub(position, position) == "."
  local fraction_digits = ""
  if has_dot then
    position = position + 1
    local fraction_start = position
    while position <= length and is_digit(text:sub(position, position)) do
      position = position + 1
    end
    fraction_digits = text:sub(fraction_start, position - 1)
  end

  if integer_digits == "" and fraction_digits == "" then
    return nil
  end

  local exponent_marker, exponent_sign, exponent_digits = "", "", ""
  local marker = text:sub(position, position)
  if marker == "e" or marker == "E" then
    local exponent_position = position + 1
    local possible_sign = text:sub(exponent_position, exponent_position)
    if possible_sign == "+" or possible_sign == "-" then
      exponent_sign = possible_sign
      exponent_position = exponent_position + 1
    end
    local exponent_start = exponent_position
    while exponent_position <= length and is_digit(text:sub(exponent_position, exponent_position)) do
      exponent_position = exponent_position + 1
    end
    if exponent_position > exponent_start then
      exponent_marker = marker
      exponent_digits = text:sub(exponent_start, exponent_position - 1)
      position = exponent_position
    else
      exponent_sign = ""
    end
  end

  local previous = start_index > 1 and text:sub(start_index - 1, start_index - 1) or ""
  if sign_char == "" and previous:match("[%w_%.]") then
    return nil
  end

  local exponent = 0
  if exponent_digits ~= "" then
    exponent = tonumber((exponent_sign == "-" and "-" or "") .. exponent_digits)
    if not exponent or math.abs(exponent) > MAX_EXPONENT then
      return nil
    end
  end

  local token = text:sub(start_index, position - 1)
  local coefficient = strip_zeroes((integer_digits == "" and "0" or integer_digits) .. fraction_digits)
  return {
    start_col = start_index - 1,
    end_col = position - 1,
    text = token,
    sign = sign_char == "-" and -1 or 1,
    explicit_plus = sign_char == "+",
    integer_digits = integer_digits,
    fraction_digits = fraction_digits,
    fraction_length = #fraction_digits,
    has_dot = has_dot,
    leading_dot = integer_digits == "" and has_dot,
    integer_width = #integer_digits,
    exponent = exponent,
    exponent_marker = exponent_marker,
    exponent_sign = exponent_sign,
    exponent_digits = exponent_digits,
    coefficient = coefficient,
    value_power = exponent - #fraction_digits,
    step_exponent = exponent - #fraction_digits,
  }
end

function M.find_all(text)
  local tokens = {}
  local position = 1
  while position <= #text do
    local char = text:sub(position, position)
    local next_char = text:sub(position + 1, position + 1)
    local can_start = is_digit(char)
      or (char == "." and is_digit(next_char))
      or ((char == "+" or char == "-") and (is_digit(next_char) or next_char == "."))
    if can_start then
      local token = parse_at(text, position)
      if token then
        tokens[#tokens + 1] = token
        position = token.end_col + 1
      else
        position = position + 1
      end
    else
      position = position + 1
    end
  end
  return tokens
end

function M.find_at_cursor(text, cursor_col)
  for _, token in ipairs(M.find_all(text)) do
    if cursor_col >= token.start_col and cursor_col < token.end_col then
      return token
    end
  end
end

function M.parse(text)
  local token = parse_at(text, 1)
  if token and token.end_col == #text then
    return token
  end
end

local function signed_delta(delta)
  if delta < 0 then
    return -1, tostring(-delta)
  end
  return 1, tostring(delta)
end

local function pad_integer(integer, width)
  if #integer >= width then
    return integer
  end
  return string.rep("0", width - #integer) .. integer
end

local function fixed_text(sign, digits, power, fraction_length, format)
  local scaled = digits .. string.rep("0", power + fraction_length)
  if #scaled <= fraction_length then
    scaled = string.rep("0", fraction_length - #scaled + 1) .. scaled
  end

  local integer
  local fraction = ""
  if fraction_length == 0 then
    integer = scaled
  else
    integer = scaled:sub(1, #scaled - fraction_length)
    fraction = scaled:sub(#scaled - fraction_length + 1)
  end
  integer = pad_integer(integer, format.integer_width)

  if format.leading_dot and integer == "0" then
    integer = ""
  end
  local prefix = sign < 0 and "-" or (format.explicit_plus and "+" or "")
  local dot = fraction_length > 0 or format.has_dot and fraction_length == 0
  return prefix .. integer .. (dot and "." or "") .. fraction
end

function M.increment(text, step_exponent, delta)
  local number = M.parse(text)
  if not number then
    return nil, "not a supported decimal number"
  end
  if math.abs(step_exponent) > MAX_EXPONENT then
    return nil, "step exponent is too large"
  end

  local delta_sign, delta_digits = signed_delta(delta)
  local base_power = math.min(number.value_power, step_exponent)
  local value_digits = number.coefficient .. string.rep("0", number.value_power - base_power)
  local step_digits = delta_digits .. string.rep("0", step_exponent - base_power)
  local result_sign, result_digits = add_signed(number.sign, value_digits, delta_sign, step_digits)

  if number.exponent_marker ~= "" then
    local fraction_length = math.max(number.fraction_length, number.exponent - base_power)
    local mantissa_power = number.exponent - fraction_length
    local mantissa_digits = result_digits .. string.rep("0", base_power - mantissa_power)
    local mantissa = fixed_text(result_sign, mantissa_digits, -fraction_length, fraction_length, number)
    return mantissa .. number.exponent_marker .. number.exponent_sign .. number.exponent_digits
  end

  local fraction_length = math.max(number.fraction_length, math.max(0, -base_power))
  return fixed_text(result_sign, result_digits, base_power, fraction_length, number)
end

function M.format_step(exponent)
  if exponent > 12 or exponent < -12 then
    return "1e" .. tostring(exponent)
  elseif exponent >= 0 then
    return "1" .. string.rep("0", exponent)
  end
  return "0." .. string.rep("0", -exponent - 1) .. "1"
end

return M
