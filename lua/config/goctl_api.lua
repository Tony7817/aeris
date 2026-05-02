local api = vim.api

local M = {}

local semantic_namespace = api.nvim_create_namespace("aeris_goctl_api_semantic")
local helper_binary = vim.fn.stdpath("cache") .. "/aeris-goctl-api-indexer"
local helper_dir = vim.fn.stdpath("config") .. "/tools/goctl-api-indexer"
local helper_sources = {
  helper_dir .. "/go.mod",
  helper_dir .. "/main.go",
}

local index_cache = {}

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end

  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function file_mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime and stat.mtime.sec or 0
end

local function list_or_empty(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function helper_needs_build()
  local binary_mtime = file_mtime(helper_binary)
  if binary_mtime == 0 then
    return true
  end

  for _, source in ipairs(helper_sources) do
    if file_mtime(source) > binary_mtime then
      return true
    end
  end

  return false
end

local function ensure_helper()
  if vim.fn.executable("go") ~= 1 then
    return nil, "go is required for goctl api navigation"
  end

  if not helper_needs_build() then
    return helper_binary
  end

  vim.fn.mkdir(vim.fn.fnamemodify(helper_binary, ":h"), "p")
  local result = vim.system({ "go", "build", "-o", helper_binary, "." }, {
    cwd = helper_dir,
    text = true,
  }):wait()

  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or result.stdout or "failed to build goctl api indexer")
  end

  return helper_binary
end

local function read_index(path)
  path = normalize_path(path)
  local cached = index_cache[path]
  local mtime = file_mtime(path)
  if cached then
    local cached_mtime = file_mtime(path)
    for _, file in ipairs(cached.index.files or {}) do
      cached_mtime = math.max(cached_mtime, file_mtime(file))
    end
    if cached.mtime == cached_mtime then
      return cached.index
    end
  end

  local binary, build_err = ensure_helper()
  if not binary then
    return nil, build_err
  end

  local result = vim.system({ binary, path }, {
    text = true,
  }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or result.stdout or "failed to parse goctl api file")
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not ok or type(decoded) ~= "table" then
    return nil, "failed to decode goctl api index"
  end

  decoded.files = list_or_empty(decoded.files)
  decoded.jumps = list_or_empty(decoded.jumps)
  decoded.symbols = list_or_empty(decoded.symbols)

  for _, file in ipairs(decoded.files) do
    mtime = math.max(mtime, file_mtime(file))
  end

  index_cache[path] = { mtime = mtime, index = decoded }
  return decoded
end

local function item_contains_cursor(item, path, line, col)
  if normalize_path(item.file) ~= path then
    return false
  end
  if item.line ~= line then
    return false
  end

  local start_col = tonumber(item.column) or 0
  local end_col = tonumber(item.end_column) or start_col
  return col >= start_col and col < end_col
end

local function find_cursor_jump(index, path, line, col)
  local best
  for _, item in ipairs(index.jumps or {}) do
    if item_contains_cursor(item, path, line, col) then
      if best == nil or ((item.end_column or 0) - (item.column or 0)) < ((best.end_column or 0) - (best.column or 0)) then
        best = item
      end
    end
  end
  return best
end

local function find_word_jump(index, path, line)
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return nil
  end

  for _, item in ipairs(index.jumps or {}) do
    if normalize_path(item.file) == path and item.line == line and item.name == word then
      return item
    end
  end

  for _, item in ipairs(index.symbols or {}) do
    if item.kind == "type" and item.name == word then
      return {
        kind = "type",
        name = word,
        target = {
          file = item.file,
          line = item.line,
          column = item.column,
        },
      }
    end
  end

  return nil
end

local function highlight_item(buf, path, item)
  if item.kind ~= "type" or normalize_path(item.file) ~= path then
    return
  end

  local line = tonumber(item.line)
  local start_col = tonumber(item.column)
  local end_col = tonumber(item.end_column)
  if not line or line < 1 or not start_col or not end_col or end_col <= start_col then
    return
  end

  pcall(api.nvim_buf_set_extmark, buf, semantic_namespace, line - 1, start_col, {
    end_col = end_col,
    hl_group = "Type",
    priority = 130,
  })
end

function M.apply_semantic_highlights(buf)
  buf = buf or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(buf) then
    return false
  end

  api.nvim_buf_clear_namespace(buf, semantic_namespace, 0, -1)
  local path = normalize_path(api.nvim_buf_get_name(buf))
  if path == "" then
    return false
  end

  local index = read_index(path)
  if not index then
    return false
  end

  for _, item in ipairs(index.symbols or {}) do
    highlight_item(buf, path, item)
  end
  for _, item in ipairs(index.jumps or {}) do
    if item.target then
      highlight_item(buf, path, item)
    end
  end

  return true
end

local function open_target(target)
  if type(target) ~= "table" or type(target.file) ~= "string" or target.file == "" then
    return false
  end

  vim.cmd("edit " .. vim.fn.fnameescape(target.file))
  local line = math.max(tonumber(target.line) or 1, 1)
  local col = math.max(tonumber(target.column) or 0, 0)
  pcall(api.nvim_win_set_cursor, 0, { line, col })
  vim.cmd("normal! zz")
  return true
end

local function trim_handler_suffix(name)
  name = tostring(name or "")
  name = name:gsub("[Hh]andler$", "")
  return name
end

local function title_word(text)
  text = tostring(text or "")
  return (text:gsub("^%l", string.upper))
end

local function to_snake_case(text)
  text = tostring(text or "")
  text = text:gsub("([a-z0-9])([A-Z])", "%1_%2")
  text = text:gsub("([A-Z])([A-Z][a-z])", "%1_%2")
  return text:lower()
end

local function file_name_candidates(go_name)
  local lower = go_name:lower()
  local snake = to_snake_case(go_name)
  local lower_first = go_name:gsub("^%u", string.lower)
  local candidates = {}
  local seen = {}

  for _, name in ipairs({ lower, snake, lower_first, go_name }) do
    if name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(candidates, name .. ".go")
    end
  end

  return candidates
end

local function root_candidates(api_file)
  local roots = {}
  local seen = {}
  local current = vim.fn.fnamemodify(api_file, ":h")
  local cwd = vim.fn.getcwd()

  while current and current ~= "" do
    if not seen[current] then
      seen[current] = true
      table.insert(roots, current)
    end
    if vim.uv.fs_stat(current .. "/.git") or current == "/" then
      break
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      break
    end
    current = parent
  end

  if cwd ~= "" and not seen[cwd] then
    table.insert(roots, cwd)
  end

  return roots
end

local function find_existing_file(paths)
  for _, path in ipairs(paths) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
end

local function find_symbol_line(path, names)
  local lines = vim.fn.readfile(path)
  for index, line in ipairs(lines) do
    for _, name in ipairs(names) do
      if line:find("func%s+" .. vim.pesc(name) .. "%s*%(") or line:find("func%s*%([^)]*%)%s+" .. vim.pesc(name) .. "%s*%(") then
        return index
      end
    end
  end
  return 1
end

local function handler_target(api_file, item)
  local base = trim_handler_suffix(item.name)
  if base == "" then
    return nil
  end

  local group = tostring(item.group or "")
  local handler_name = base .. "Handler"
  local logic_name = base .. "Logic"
  if group ~= "" then
    handler_name = title_word(handler_name)
  end

  local paths = {}
  for _, root in ipairs(root_candidates(api_file)) do
    for _, filename in ipairs(file_name_candidates(handler_name)) do
      if group ~= "" then
        table.insert(paths, table.concat({ root, "internal", "handler", group, filename }, "/"))
      end
      table.insert(paths, table.concat({ root, "internal", "handler", filename }, "/"))
    end
    for _, filename in ipairs(file_name_candidates(logic_name)) do
      if group ~= "" then
        table.insert(paths, table.concat({ root, "internal", "logic", group, filename }, "/"))
      end
      table.insert(paths, table.concat({ root, "internal", "logic", filename }, "/"))
    end
  end

  local path = find_existing_file(paths)
  if not path then
    return nil
  end

  return {
    file = path,
    line = find_symbol_line(path, { handler_name, title_word(logic_name), title_word(base) }),
    column = 0,
  }
end

function M.goto_definition()
  local path = normalize_path(api.nvim_buf_get_name(0))
  if path == "" then
    return false
  end

  local index, err = read_index(path)
  if not index then
    vim.notify(err or "Unable to index goctl api file", vim.log.levels.WARN)
    return false
  end

  local cursor = api.nvim_win_get_cursor(0)
  local item = find_cursor_jump(index, path, cursor[1], cursor[2])
  if not item then
    item = find_word_jump(index, path, cursor[1])
  end
  if not item then
    vim.notify("No goctl api target under cursor", vim.log.levels.WARN)
    return false
  end

  if item.kind == "handler" then
    local target = handler_target(path, item)
    if not target then
      vim.notify("Generated Go handler/logic file was not found", vim.log.levels.WARN)
      return false
    end
    return open_target(target)
  end

  if not item.target then
    vim.notify("No goctl api target found for " .. tostring(item.name), vim.log.levels.WARN)
    return false
  end
  return open_target(item.target)
end

function M.setup()
  local group = api.nvim_create_augroup("aeris_goctl_api", { clear = true })

  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "goctlapi",
    callback = function(args)
      vim.b[args.buf].current_syntax = nil
      vim.bo[args.buf].syntax = "goctlapi"
      vim.keymap.set("n", "gd", M.goto_definition, {
        buffer = args.buf,
        desc = "Go to goctl api definition",
      })
      vim.schedule(function()
        M.apply_semantic_highlights(args.buf)
      end)
    end,
  })

  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.api",
    callback = function(args)
      if vim.bo[args.buf].filetype == "goctlapi" then
        vim.schedule(function()
          M.apply_semantic_highlights(args.buf)
        end)
      end
    end,
  })
end

return M
