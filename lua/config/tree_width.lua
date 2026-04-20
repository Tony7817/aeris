local M = {}

local DEFAULT_WIDTH = 22
local MIN_WIDTH = 18
local STEP = 4
local REPEAT_TIMEOUT_MS = 1200

local current_width = DEFAULT_WIDTH
local repeat_deadline = 0

local function now_ms()
  local uv = vim.uv or vim.loop
  return uv.now()
end

local function max_width()
  return math.max(MIN_WIDTH, vim.o.columns - 24)
end

local function clamp(width)
  width = math.floor(tonumber(width) or DEFAULT_WIDTH)
  return math.min(math.max(width, MIN_WIDTH), max_width())
end

function M.get()
  current_width = clamp(current_width)
  return current_width
end

function M.set(width)
  current_width = clamp(width)
  return current_width
end

function M.increase(step)
  return M.set(M.get() + (step or STEP))
end

function M.arm_repeat()
  repeat_deadline = now_ms() + REPEAT_TIMEOUT_MS
end

function M.repeat_active()
  return repeat_deadline > 0 and now_ms() <= repeat_deadline
end

function M.apply()
  local ok, tree_api = pcall(require, "nvim-tree.api")
  if ok then
    local width = M.get()
    pcall(tree_api.tree.resize, { width = width })

    local ok_winid, winid = pcall(tree_api.tree.winid)
    if ok_winid and type(winid) == "number" and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_set_width, winid, width)
      vim.wo[winid].winfixwidth = true
    end
  end

  return M.get()
end

function M.widen_with_repeat(step)
  M.increase(step)
  M.arm_repeat()
  return M.apply()
end

return M
