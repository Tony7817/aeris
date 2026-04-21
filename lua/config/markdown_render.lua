local M = {}

local group = vim.api.nvim_create_augroup("erwin_markdown_render", { clear = true })
local buffer_states = {}

vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(args)
    buffer_states[args.buf] = nil
  end,
})

local function target_buffer(buf)
  buf = tonumber(buf) or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  return buf
end

local function is_markdown_buffer(buf)
  return buf ~= nil and vim.bo[buf].filetype == "markdown"
end

local function renderer_enabled(buf)
  local ok, state = pcall(require, "render-markdown.state")
  if not ok then
    return false
  end

  local ok_config, config = pcall(state.get, buf)
  return ok_config and type(config) == "table" and config.enabled == true
end

local function ensure_renderer_attached(buf)
  local ok, manager = pcall(require, "render-markdown.core.manager")
  if not ok or type(manager.attach) ~= "function" then
    return false
  end

  manager.attach(buf)
  return true
end

local function call_renderer(buf, method)
  local ok, render_markdown = pcall(require, "render-markdown")
  if not ok or type(render_markdown[method]) ~= "function" then
    return false
  end

  ensure_renderer_attached(buf)

  local called = pcall(vim.api.nvim_buf_call, buf, function()
    render_markdown[method]()
  end)

  return called
end

local function remember_buffer_state(buf)
  if buffer_states[buf] ~= nil then
    return
  end

  buffer_states[buf] = {
    modifiable = vim.bo[buf].modifiable,
    readonly = vim.bo[buf].readonly,
  }
end

local function restore_buffer_state(buf)
  local state = buffer_states[buf]
  if state == nil then
    return
  end

  vim.bo[buf].modifiable = state.modifiable
  vim.bo[buf].readonly = state.readonly
  buffer_states[buf] = nil
end

function M.enable(buf)
  buf = target_buffer(buf)
  if not is_markdown_buffer(buf) then
    return false
  end

  if vim.api.nvim_get_current_buf() == buf then
    pcall(vim.cmd, "stopinsert")
  end

  remember_buffer_state(buf)

  if not call_renderer(buf, "buf_enable") then
    buffer_states[buf] = nil
    return false
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  return true
end

function M.disable(buf)
  buf = target_buffer(buf)
  if not is_markdown_buffer(buf) then
    return false
  end

  call_renderer(buf, "buf_disable")
  restore_buffer_state(buf)
  return true
end

function M.toggle(buf)
  buf = target_buffer(buf)
  if not is_markdown_buffer(buf) then
    return false
  end

  if renderer_enabled(buf) then
    return M.disable(buf)
  end

  return M.enable(buf)
end

function M.reset(buf)
  buf = target_buffer(buf)
  if not is_markdown_buffer(buf) then
    return false
  end

  if package.loaded["render-markdown"] ~= nil or package.loaded["render-markdown.state"] ~= nil then
    call_renderer(buf, "buf_disable")
  end

  restore_buffer_state(buf)
  return true
end

return M
