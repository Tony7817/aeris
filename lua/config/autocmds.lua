local group = vim.api.nvim_create_augroup("erwin_nvim", { clear = true })
local nvim_tree_name_popup = {
  buf = nil,
  win = nil,
}
local workspace_state_path = vim.fn.stdpath("state") .. "/erwin-workspace-files.json"

local function normalize_path(path)
  if path == nil or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function is_real_file(path)
  path = normalize_path(path)
  return path ~= nil and vim.fn.filereadable(path) == 1 and vim.fn.isdirectory(path) == 0
end

local function is_path_in_cwd(path, cwd)
  path = normalize_path(path)
  cwd = normalize_path(cwd)

  if path == nil or cwd == nil then
    return false
  end

  return path == cwd or vim.startswith(path, cwd .. "/")
end

local function read_workspace_state()
  if vim.fn.filereadable(workspace_state_path) ~= 1 then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(workspace_state_path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  return decoded
end

local function write_workspace_state(state)
  vim.fn.mkdir(vim.fs.dirname(workspace_state_path), "p")

  local ok, encoded = pcall(vim.json.encode, state)
  if not ok then
    return
  end

  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), workspace_state_path)
end

local function normalize_cursor(cursor)
  if type(cursor) ~= "table" then
    return nil
  end

  local line = tonumber(cursor[1] or cursor.line)
  local col = tonumber(cursor[2] or cursor.col or cursor.column)

  if line == nil or col == nil then
    return nil
  end

  return {
    math.max(1, math.floor(line)),
    math.max(0, math.floor(col)),
  }
end

local function normalize_workspace_entry(entry, cwd)
  local file
  local cursor
  local focus

  if type(entry) == "string" then
    file = normalize_path(entry)
  elseif type(entry) == "table" then
    file = normalize_path(entry.file or entry.path)
    cursor = normalize_cursor(entry.cursor)
    if type(entry.focus) == "table" then
      local kind = entry.focus.kind == "tree" and "tree" or "file"
      local path = normalize_path(entry.focus.path)
      if path ~= nil and not is_path_in_cwd(path, cwd) then
        path = nil
      end

      focus = {
        kind = kind,
        path = path,
        cursor = normalize_cursor(entry.focus.cursor),
      }
    end
  end

  if not is_real_file(file) or not is_path_in_cwd(file, cwd) then
    return nil
  end

  return {
    file = file,
    cursor = cursor,
    focus = focus or {
      kind = "file",
      path = file,
      cursor = cursor,
    },
  }
end

local function workspace_file_candidates()
  local candidates = {}
  local seen = {}

  local function add(bufnr)
    if type(bufnr) ~= "number" or seen[bufnr] then
      return
    end

    seen[bufnr] = true
    table.insert(candidates, bufnr)
  end

  add(vim.api.nvim_get_current_buf())

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    add(vim.api.nvim_win_get_buf(win))
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    add(bufnr)
  end

  return candidates
end

local function find_workspace_location(cwd)
  cwd = normalize_path(cwd)
  if cwd == nil then
    return nil
  end

  local current_win = vim.api.nvim_get_current_win()
  local seen_windows = {}

  local function location_from_window(win)
    if type(win) ~= "number" or not vim.api.nvim_win_is_valid(win) or seen_windows[win] then
      return nil
    end

    seen_windows[win] = true

    local bufnr = vim.api.nvim_win_get_buf(win)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
      return nil
    end

    local name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
    if not is_real_file(name) or not is_path_in_cwd(name, cwd) then
      return nil
    end

    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    return {
      file = name,
      cursor = ok and normalize_cursor(cursor) or nil,
    }
  end

  local current_location = location_from_window(current_win)
  if current_location then
    return current_location
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local location = location_from_window(win)
    if location then
      return location
    end
  end

  for _, bufnr in ipairs(workspace_file_candidates()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" then
      local name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      if is_real_file(name) and is_path_in_cwd(name, cwd) then
        return {
          file = name,
          cursor = nil,
        }
      end
    end
  end

  return nil
end

local function current_workspace_focus(cwd)
  cwd = normalize_path(cwd)
  if cwd == nil then
    return nil
  end

  local current_win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(current_win) then
    return nil
  end

  local bufnr = vim.api.nvim_win_get_buf(current_win)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local cursor = normalize_cursor(vim.api.nvim_win_get_cursor(current_win))
  local filetype = vim.bo[bufnr].filetype

  if filetype == "NvimTree" then
    local focus = {
      kind = "tree",
      cursor = cursor,
    }

    local ok, tree_api = pcall(require, "nvim-tree.api")
    if ok then
      local node = tree_api.tree.get_node_under_cursor()
      local path = node and normalize_path(node.absolute_path)
      if path ~= nil and is_path_in_cwd(path, cwd) then
        focus.path = path
      end
    end

    return focus
  end

  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end

  local name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  if not is_real_file(name) or not is_path_in_cwd(name, cwd) then
    return nil
  end

  return {
    kind = "file",
    path = name,
    cursor = cursor,
  }
end

local function save_workspace_file()
  local cwd = normalize_path(vim.fn.getcwd())
  local location = find_workspace_location(cwd)
  local focus = current_workspace_focus(cwd)

  if cwd == nil or location == nil then
    return
  end

  local state = read_workspace_state()
  state[cwd] = {
    file = location.file,
    cursor = location.cursor,
    focus = focus,
  }
  write_workspace_state(state)
end

local function should_autosave(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].buftype ~= "" then
    return false
  end

  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly or not vim.bo[bufnr].modified then
    return false
  end

  local name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  if name == nil or vim.fn.isdirectory(name) == 1 then
    return false
  end

  return true
end

local function autosave_buffer(bufnr)
  if not should_autosave(bufnr) then
    return
  end

  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent update")
  end)
end

local function last_workspace_location(cwd)
  cwd = normalize_path(cwd)
  if cwd == nil then
    return nil
  end

  local state = read_workspace_state()
  local entry = normalize_workspace_entry(state[cwd], cwd)
  if entry == nil then
    return nil
  end

  return entry
end

local function restore_workspace_cursor(win, bufnr, cursor)
  cursor = normalize_cursor(cursor)
  if cursor == nil or not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
  local line = math.min(cursor[1], line_count)
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local col = math.min(cursor[2], #line_text)

  pcall(vim.api.nvim_win_set_cursor, win, { line, col })
end

local function try_restore_workspace_file(win, file)
  file = normalize_path(file)
  if file == nil or not vim.api.nvim_win_is_valid(win) then
    return false, nil, nil
  end

  vim.api.nvim_set_current_win(win)

  local ok, err = pcall(vim.cmd, "silent edit " .. vim.fn.fnameescape(file))
  if ok then
    local bufnr = vim.api.nvim_win_get_buf(win)
    if normalize_path(vim.api.nvim_buf_get_name(bufnr)) == file then
      return true, bufnr, nil
    end

    return false, nil, "Failed to restore workspace file"
  end

  local message = tostring(err or "")
  if message:find("E325", 1, true) then
    return false, nil, "Swap file exists for the last workspace file"
  end

  return false, nil, message
end

local function ensure_buffer_highlighting(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  local name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  if name == nil then
    return
  end

  if vim.bo[bufnr].filetype == "" then
    local detected = vim.filetype.match({
      buf = bufnr,
      filename = name,
    })
    if detected and detected ~= "" then
      vim.bo[bufnr].filetype = detected
    end
  end

  local filetype = vim.bo[bufnr].filetype
  if filetype == "" then
    return
  end

  if vim.bo[bufnr].syntax == "" then
    vim.bo[bufnr].syntax = filetype
  end

  vim.api.nvim_buf_call(bufnr, function()
    vim.api.nvim_exec_autocmds("FileType", {
      buffer = bufnr,
      modeline = false,
    })

    pcall(vim.treesitter.start)
  end)
end

local function apply_ui_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local end_of_buffer = vim.api.nvim_get_hl(0, { name = "EndOfBuffer", link = false })
  local line_nr = vim.api.nvim_get_hl(0, { name = "LineNr", link = false })
  local cursor_line_nr = vim.api.nvim_get_hl(0, { name = "CursorLineNr", link = false })
  local normal_bg = "#2B3036"
  local normal_fg = normal.fg
  local nvim_tree_bg = "#1F2428"
  local terminal_bg = nvim_tree_bg
  local vscode = {
    bracket1 = "#b392f0",
    bracket2 = "#ec619c",
    terminal_fg = "#ffffff",
    warning = "#C792EA",
    func = "#b392f0",
    variable = "#6bb7ff",
    string = "#8acaff",
    keyword = "#ec619c",
    type = "#b392f0",
    constant = "#ec619c",
    go_variable = "#b392f0",
  }

  local function set_many(groups, spec)
    for _, group_name in ipairs(groups) do
      vim.api.nvim_set_hl(0, group_name, spec)
    end
  end

  vim.api.nvim_set_hl(0, "Normal", { fg = normal_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "NormalNC", { fg = normal_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "NormalFloat", { fg = normal_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "SignColumn", { fg = normal_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "FoldColumn", { fg = normal_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "LineNr", { fg = line_nr.fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "CursorLineNr", { fg = cursor_line_nr.fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "EndOfBuffer", { fg = end_of_buffer.fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "WinSeparator", { fg = "#585b70", bg = normal_bg })
  vim.api.nvim_set_hl(0, "VertSplit", { link = "WinSeparator" })
  vim.api.nvim_set_hl(0, "NvimTreeNormal", { fg = normal_fg, bg = nvim_tree_bg })
  vim.api.nvim_set_hl(0, "NvimTreeNormalNC", { fg = normal_fg, bg = nvim_tree_bg })
  vim.api.nvim_set_hl(0, "NvimTreeEndOfBuffer", { fg = end_of_buffer.fg, bg = nvim_tree_bg })
  vim.api.nvim_set_hl(0, "NvimTreeSignColumn", { fg = normal_fg, bg = nvim_tree_bg })
  vim.api.nvim_set_hl(0, "NvimTreeWinSeparator", { fg = "#585b70", bg = nvim_tree_bg })
  vim.api.nvim_set_hl(0, "TerminalSidebarNormal", { fg = normal_fg, bg = nvim_tree_bg })
  vim.api.nvim_set_hl(0, "TerminalSidebarEndOfBuffer", { fg = end_of_buffer.fg, bg = nvim_tree_bg })
  local opened_file = vim.api.nvim_get_hl(0, { name = "NvimTreeOpenedFile", link = false })
  local popup_bg = opened_file.fg or 0x89B4FA
  vim.api.nvim_set_hl(0, "NvimTreeNamePopup", { fg = normal_bg, bg = popup_bg, bold = true })
  vim.api.nvim_set_hl(0, "TerminalNormal", { fg = vscode.terminal_fg, bg = terminal_bg })
  vim.api.nvim_set_hl(0, "TerminalNormalNC", { fg = vscode.terminal_fg, bg = terminal_bg })
  vim.api.nvim_set_hl(0, "TerminalCursorLine", { bg = "#313244" })
  vim.api.nvim_set_hl(0, "ScrollbarHandle", { bg = "#585b70", fg = "#585b70" })
  vim.api.nvim_set_hl(0, "ScrollbarCursor", { bg = normal_bg, fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "ScrollbarCursorHandle", { bg = "#89b4fa", fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "ScrollbarGitAdd", { bg = normal_bg, fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "ScrollbarGitAddHandle", { bg = "#a6e3a1", fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "ScrollbarGitChange", { bg = normal_bg, fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "ScrollbarGitChangeHandle", { bg = "#a6e3a1", fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "ScrollbarGitDelete", { bg = normal_bg, fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "ScrollbarGitDeleteHandle", { bg = "#f38ba8", fg = "#f38ba8" })
  set_many({ "GitSignsAdd", "GitSignsChange", "GitSignsChangedelete", "GitSignsUntracked" }, {
    fg = "#a6e3a1",
    bg = normal_bg,
  })
  set_many({ "GitSignsDelete", "GitSignsTopdelete" }, {
    fg = "#f38ba8",
    bg = normal_bg,
  })
  vim.api.nvim_set_hl(0, "RainbowDelimiterAeris1", { fg = vscode.bracket1 })
  vim.api.nvim_set_hl(0, "RainbowDelimiterAeris2", { fg = vscode.bracket2 })
  vim.api.nvim_set_hl(0, "MatchParen", { fg = vscode.bracket1, bold = true, underline = false, bg = nil })

  set_many({ "Function", "@function", "@function.call", "@function.builtin", "@method", "@method.call", "@constructor", "@lsp.type.function", "@lsp.type.method" }, {
    fg = vscode.func,
  })
  set_many({ "Identifier", "@variable", "@variable.member", "@variable.parameter", "@property", "@field", "@lsp.type.variable", "@lsp.type.parameter", "@lsp.type.property" }, {
    fg = vscode.variable,
  })
  set_many({ "String", "Character", "@string", "@string.documentation", "@string.escape", "@string.special", "@string.special.path" }, {
    fg = vscode.string,
  })
  set_many({ "Keyword", "Conditional", "Repeat", "Statement", "@keyword", "@keyword.function", "@keyword.conditional", "@keyword.repeat", "@keyword.return", "@lsp.type.keyword" }, {
    fg = vscode.keyword,
  })
  set_many({ "Type", "Structure", "Typedef", "@type", "@type.builtin", "@lsp.type.type", "@lsp.type.class", "@lsp.type.struct", "@lsp.type.interface", "@module", "@namespace", "@lsp.type.namespace" }, {
    fg = vscode.type,
  })
  set_many({ "Constant", "Boolean", "Number", "Float", "@constant", "@constant.builtin", "@boolean", "@number" }, {
    fg = vscode.constant,
  })
  set_many({ "Include", "@keyword.import", "@include" }, {
    fg = vscode.string,
  })

  set_many({ "goImport", "goImportString" }, {
    fg = vscode.string,
  })
  set_many({ "goPackage", "goVar", "goConst", "goDeclaration", "goTypeDecl", "goDeclType" }, {
    fg = vscode.keyword,
  })
  set_many({ "goType", "goTypeName", "goTypeConstructor" }, {
    fg = vscode.type,
  })
  set_many({ "goVarDefs", "goVarAssign", "@variable.go" }, {
    fg = vscode.go_variable,
  })
  vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = vscode.warning })
  vim.api.nvim_set_hl(0, "DiagnosticSignWarn", { fg = vscode.warning })
  vim.api.nvim_set_hl(0, "DiagnosticVirtualTextWarn", { fg = vscode.warning })
  vim.api.nvim_set_hl(0, "DiagnosticFloatingWarn", { fg = vscode.warning })
  vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = vscode.terminal_fg })
  vim.api.nvim_set_hl(0, "DiagnosticSignInfo", { fg = vscode.terminal_fg })
  vim.api.nvim_set_hl(0, "DiagnosticVirtualTextInfo", { fg = vscode.terminal_fg })
  vim.api.nvim_set_hl(0, "DiagnosticFloatingInfo", { fg = vscode.terminal_fg })
end

local open_quickfix_and_close_on_enter

local function jump_to_implementation(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/implementation" })

  if vim.tbl_isempty(clients) then
    if opts.fallback_to_definition then
      vim.lsp.buf.definition()
    end
    return
  end

  vim.lsp.buf_request_all(bufnr, "textDocument/implementation", params, function(results)
    local locations = {}
    local offset_encoding = "utf-8"

    for _, result in pairs(results) do
      if result.result then
        offset_encoding = result.client and result.client.offset_encoding or offset_encoding

        if vim.islist(result.result) then
          vim.list_extend(locations, result.result)
        else
          table.insert(locations, result.result)
        end
      end
    end

    if vim.tbl_isempty(locations) then
      if opts.fallback_to_definition then
        vim.lsp.buf.definition()
      else
        vim.notify("No implementations found", vim.log.levels.INFO)
      end
      return
    end

    if #locations == 1 then
      vim.lsp.util.show_document(locations[1], offset_encoding, { reuse_win = true })
      return
    end

    open_quickfix_and_close_on_enter(
      "LSP implementations",
      vim.lsp.util.locations_to_items(locations, offset_encoding)
    )
  end)
end

local function jump_to_implementation_or_definition()
  jump_to_implementation({ fallback_to_definition = true })
end

open_quickfix_and_close_on_enter = function(title, items)
  vim.fn.setqflist({}, " ", {
    title = title,
    items = items,
  })
  vim.cmd.copen()

  local qf_win = vim.fn.getqflist({ winid = 0 }).winid
  if qf_win == nil or qf_win == 0 or not vim.api.nvim_win_is_valid(qf_win) then
    return
  end

  local qf_buf = vim.api.nvim_win_get_buf(qf_win)
  vim.keymap.set("n", "<CR>", function()
    local index = vim.api.nvim_win_get_cursor(qf_win)[1]
    vim.cmd("cc " .. index)
    vim.cmd.cclose()
  end, {
    buffer = qf_buf,
    desc = "Open quickfix item and close list",
    nowait = true,
    silent = true,
  })
end

local function jump_to_references()
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = true }
  local current_uri = vim.uri_from_bufnr(bufnr)

  local function position_in_range(position, range)
    if range == nil then
      return false
    end

    if position.line < range.start.line or position.line > range["end"].line then
      return false
    end

    if position.line == range.start.line and position.character < range.start.character then
      return false
    end

    if position.line == range["end"].line and position.character > range["end"].character then
      return false
    end

    return true
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/references" })
  if vim.tbl_isempty(clients) then
    return
  end

  vim.lsp.buf_request_all(bufnr, "textDocument/references", params, function(results)
    local locations = {}

    for _, result in pairs(results) do
      if result.result then
        if vim.islist(result.result) then
          vim.list_extend(locations, result.result)
        else
          table.insert(locations, result.result)
        end
      end
    end

    if vim.tbl_isempty(locations) then
      vim.notify("No references found", vim.log.levels.INFO)
      return
    end

    local items = {}
    local seen = {}

    for _, location in ipairs(locations) do
      local uri = location.uri or location.targetUri
      local range = location.range or location.targetSelectionRange or location.targetRange

      if uri and range then
        local key = string.format(
          "%s:%d:%d:%d:%d",
          uri,
          range.start.line,
          range.start.character,
          range["end"].line,
          range["end"].character
        )

        if seen[key] then
          goto continue
        end
        seen[key] = true

        if uri == current_uri and position_in_range(params.position, range) then
          goto continue
        end

        local ref_bufnr = vim.uri_to_bufnr(uri)
        vim.fn.bufload(ref_bufnr)

        local filename = vim.uri_to_fname(uri)
        local lnum = range.start.line + 1
        local col = range.start.character + 1
        local text = vim.api.nvim_buf_get_lines(ref_bufnr, lnum - 1, lnum, false)[1] or ""

        table.insert(items, {
          bufnr = ref_bufnr,
          filename = filename,
          lnum = lnum,
          col = col,
          location = location,
          text = text,
        })
      end

      ::continue::
    end

    if vim.tbl_isempty(items) then
      vim.notify("No other references found", vim.log.levels.INFO)
      return
    end

    if #items == 1 then
      vim.lsp.util.show_document(items[1].location, "utf-8", { reuse_win = true })
      return
    end

    require("config.references").open(items)
  end)
end

local function keep_nvim_tree_node_visible()
  if vim.bo.filetype ~= "NvimTree" or vim.wo.wrap then
    return
  end

  local ok, tree_api = pcall(require, "nvim-tree.api")
  if not ok then
    return
  end

  local node = tree_api.tree.get_node_under_cursor()
  if not node or not node.name then
    return
  end

  local line = vim.api.nvim_get_current_line()
  local start_col = line:find(node.name, 1, true)
  if not start_col then
    vim.fn.winrestview({ leftcol = 0 })
    return
  end

  local prefix_width = vim.fn.strdisplaywidth(line:sub(1, start_col - 1))
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1] or {}
  local available_width = vim.api.nvim_win_get_width(0) - (wininfo.textoff or 0)

  if available_width <= 0 then
    return
  end

  local max_visible_prefix = 4
  if available_width <= 18 then
    max_visible_prefix = 3
  end
  if available_width <= 12 then
    max_visible_prefix = 2
  end
  local target_leftcol = 0

  if prefix_width > max_visible_prefix then
    target_leftcol = math.max(0, prefix_width - max_visible_prefix)
  end

  local view = vim.fn.winsaveview()
  if view.leftcol ~= target_leftcol then
    vim.fn.winrestview({ leftcol = target_leftcol })
  end
end

local function hide_nvim_tree_name_popup()
  if nvim_tree_name_popup.win and vim.api.nvim_win_is_valid(nvim_tree_name_popup.win) then
    vim.api.nvim_win_close(nvim_tree_name_popup.win, true)
  end

  nvim_tree_name_popup.win = nil

  if nvim_tree_name_popup.buf and not vim.api.nvim_buf_is_valid(nvim_tree_name_popup.buf) then
    nvim_tree_name_popup.buf = nil
  end
end

local function show_nvim_tree_name_popup()
  if vim.bo.filetype ~= "NvimTree" or vim.wo.wrap then
    hide_nvim_tree_name_popup()
    return
  end

  local ok, tree_api = pcall(require, "nvim-tree.api")
  if not ok then
    hide_nvim_tree_name_popup()
    return
  end

  local node = tree_api.tree.get_node_under_cursor()
  if not node or not node.name then
    hide_nvim_tree_name_popup()
    return
  end

  local line = vim.api.nvim_get_current_line()
  local start_col = line:find(node.name, 1, true)
  if not start_col then
    hide_nvim_tree_name_popup()
    return
  end

  local name_width = vim.fn.strdisplaywidth(node.name)
  local prefix_width = vim.fn.strdisplaywidth(line:sub(1, start_col - 1))
  local view = vim.fn.winsaveview()
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1] or {}
  local available_width = vim.api.nvim_win_get_width(0) - (wininfo.textoff or 0)
  local visible_prefix = math.max(prefix_width - view.leftcol, 0)
  local visible_name_width = math.max(available_width - visible_prefix, 0)

  if available_width <= 0 or name_width <= visible_name_width then
    hide_nvim_tree_name_popup()
    return
  end

  local win_pos = vim.api.nvim_win_get_position(0)
  local row = win_pos[1] + vim.api.nvim_win_get_cursor(0)[1] - view.topline
  local col = win_pos[2] + vim.api.nvim_win_get_width(0) + 1
  local text = " " .. node.name .. " "
  local width = math.min(vim.fn.strdisplaywidth(text), math.max(vim.o.columns - col - 1, 12))

  if width <= 2 then
    hide_nvim_tree_name_popup()
    return
  end

  hide_nvim_tree_name_popup()

  local buf = nvim_tree_name_popup.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    nvim_tree_name_popup.buf = buf
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].buflisted = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modifiable = false

  nvim_tree_name_popup.win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    noautocmd = true,
    zindex = 45,
  })
  vim.wo[nvim_tree_name_popup.win].winhighlight = "Normal:NvimTreeNamePopup"
end

local function sync_visible_nvim_tree_to_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.bo[bufnr].filetype == "NvimTree" or vim.bo[bufnr].buftype ~= "" then
    return
  end

  local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  if not is_real_file(path) then
    return
  end

  local ok, tree_api = pcall(require, "nvim-tree.api")
  if not ok then
    return
  end

  local tree_win = tree_api.tree.winid()
  if type(tree_win) ~= "number" or not vim.api.nvim_win_is_valid(tree_win) then
    return
  end

  local function sync_tree_view()
    local current_tree_win = tree_api.tree.winid()
    if type(current_tree_win) ~= "number" or not vim.api.nvim_win_is_valid(current_tree_win) then
      return
    end

    vim.api.nvim_win_call(current_tree_win, function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local height = vim.api.nvim_win_get_height(0)
      local topline = math.max(cursor[1] - math.floor(height / 2), 1)
      vim.fn.winrestview({ topline = topline })
      keep_nvim_tree_node_visible()
      show_nvim_tree_name_popup()
    end)
  end

  local ok_finder, finder = pcall(require, "nvim-tree.actions.finders.find-file")
  if ok_finder and finder and finder.fn then
    finder.fn(path)
  else
    tree_api.tree.find_file({
      buf = bufnr,
      focus = false,
      open = false,
      update_root = true,
    })
  end

  sync_tree_view()
  vim.schedule(sync_tree_view)
  vim.defer_fn(sync_tree_view, 40)
  vim.defer_fn(sync_tree_view, 120)
end

vim.api.nvim_create_autocmd("TextYankPost", {
  group = group,
  callback = function()
    vim.highlight.on_yank()
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = apply_ui_highlights,
})

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  callback = function(args)
    if #vim.api.nvim_list_uis() == 0 then
      return
    end

    local ok, tree_api = pcall(require, "nvim-tree.api")
    if not ok then
      return
    end

    local function mark_as_workspace_placeholder(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      if vim.api.nvim_buf_get_name(bufnr) ~= "" then
        return
      end

      vim.bo[bufnr].bufhidden = "wipe"
      vim.bo[bufnr].buflisted = false
      vim.bo[bufnr].swapfile = false
    end

    local path = args.file ~= "" and vim.fn.fnamemodify(args.file, ":p") or ""
    local is_directory = path ~= "" and vim.fn.isdirectory(path) == 1
    local has_args = vim.fn.argc() > 0
    local should_restore_workspace_file = not has_args or is_directory

    if is_directory then
      vim.cmd.cd(path)
      vim.cmd.enew()
    end

    local content_win = vim.api.nvim_get_current_win()
    local content_buf = vim.api.nvim_get_current_buf()

    if not has_args or is_directory then
      mark_as_workspace_placeholder(content_buf)
    end

    local workspace_entry = nil
    local workspace_restore_file = nil
    local workspace_restore_error = nil

    if should_restore_workspace_file then
      workspace_entry = last_workspace_location(vim.fn.getcwd())
      if workspace_entry then
        workspace_restore_file = workspace_entry.file
        vim.api.nvim_set_current_win(content_win)
        local restored, restored_buf, err = try_restore_workspace_file(content_win, workspace_entry.file)
        if restored then
          content_buf = restored_buf
        else
          workspace_restore_error = err
          workspace_entry = nil
          mark_as_workspace_placeholder(content_buf)
        end
      end
    end

    local tree_width = require("config.tree_width").get()
    vim.cmd(string.format("topleft vertical %dnew", tree_width))
    local tree_win = vim.api.nvim_get_current_win()
    tree_api.tree.open({ current_window = true, path = vim.fn.getcwd() })
    vim.cmd(string.format("vertical resize %d", tree_width))

    if vim.api.nvim_win_is_valid(tree_win) then
      vim.wo[tree_win].winfixwidth = true
    end

    if vim.api.nvim_buf_get_name(content_buf) ~= "" then
      tree_api.tree.find_file({
        buf = content_buf,
        focus = false,
        open = false,
        update_root = true,
      })
    end

    if workspace_entry then
      vim.schedule(function()
        ensure_buffer_highlighting(content_buf)
        restore_workspace_cursor(content_win, content_buf, workspace_entry.cursor)

        local focus = workspace_entry.focus or { kind = "file" }
        if focus.kind == "tree" and vim.api.nvim_win_is_valid(tree_win) then
          if focus.path then
            tree_api.tree.find_file({
              buf = focus.path,
              focus = true,
              open = false,
              update_root = true,
            })
          else
            vim.api.nvim_set_current_win(tree_win)
          end
        elseif vim.api.nvim_win_is_valid(content_win) then
          vim.api.nvim_set_current_win(content_win)
        end
      end)
    elseif vim.api.nvim_buf_get_name(content_buf) ~= "" then
      vim.schedule(function()
        ensure_buffer_highlighting(content_buf)
        if vim.api.nvim_win_is_valid(tree_win) then
          vim.api.nvim_set_current_win(tree_win)
        end
      end)
    elseif vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_set_current_win(tree_win)
    end

    if workspace_restore_error and should_restore_workspace_file then
      local file_label = workspace_restore_file and vim.fn.fnamemodify(workspace_restore_file, ":~:.")
        or "the last workspace file"
      vim.schedule(function()
        vim.notify(
          string.format("Skipped workspace restore for %s: %s", file_label, workspace_restore_error),
          vim.log.levels.WARN
        )
      end)
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = save_workspace_file,
})

vim.api.nvim_create_autocmd("InsertLeave", {
  group = group,
  callback = function(args)
    autosave_buffer(args.buf)
  end,
})

vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "FocusLost" }, {
  group = group,
  callback = function(args)
    autosave_buffer(args.buf)
  end,
})

vim.api.nvim_create_autocmd("TermOpen", {
  group = group,
  callback = function()
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.cursorline = false
    vim.opt_local.winhighlight =
      "Normal:TerminalNormal,NormalNC:TerminalNormalNC,EndOfBuffer:TerminalNormal,SignColumn:TerminalNormal,CursorLine:TerminalCursorLine"
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "markdown", "gitcommit" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.spell = true
  end,
})

vim.api.nvim_create_autocmd({ "BufWinEnter", "CursorMoved" }, {
  group = group,
  pattern = "NvimTree_*",
  callback = function()
    keep_nvim_tree_node_visible()
    show_nvim_tree_name_popup()
  end,
})

vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
  group = group,
  pattern = "NvimTree_*",
  callback = hide_nvim_tree_name_popup,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(args)
    if args.buf == nil or args.buf == 0 then
      return
    end

    vim.schedule(function()
      sync_visible_nvim_tree_to_buffer(args.buf)
    end)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "go", "goctlapi" },
  callback = function()
    vim.opt_local.expandtab = false
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.softtabstop = 4
    vim.opt_local.commentstring = "// %s"
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "swift", "python", "sql" },
  callback = function()
    vim.opt_local.expandtab = true
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.softtabstop = 4
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = {
    "bash",
    "css",
    "dockerfile",
    "go",
    "gomod",
    "gotmpl",
    "html",
    "javascript",
    "javascriptreact",
    "json",
    "jsonc",
    "lua",
    "markdown",
    "proto",
    "python",
    "sh",
    "sql",
    "swift",
    "toml",
    "typescript",
    "typescriptreact",
    "vue",
    "yaml",
    "zsh",
  },
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)

    local ok, treesitter = pcall(require, "nvim-treesitter")
    if ok and vim.bo[args.buf].filetype ~= "markdown" then
      vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "goctlapi",
  callback = function()
    vim.bo.commentstring = "// %s"
    vim.bo.syntax = "go"
  end,
})

vim.api.nvim_create_autocmd("LspAttach", {
  group = group,
  callback = function(event)
    local map = vim.keymap.set
    local opts = { buffer = event.buf }

    map("n", "<F12>", jump_to_implementation_or_definition, vim.tbl_extend("force", opts, { desc = "Go to implementation or definition" }))
    map("n", "gd", vim.lsp.buf.definition, vim.tbl_extend("force", opts, { desc = "Go to definition" }))
    map("n", "gr", jump_to_references, vim.tbl_extend("force", opts, { desc = "Go to references" }))
    map("n", "gi", jump_to_implementation, vim.tbl_extend("force", opts, { desc = "Go to implementation" }))
    map("n", "K", vim.lsp.buf.hover, vim.tbl_extend("force", opts, { desc = "Hover documentation" }))
    map("n", "<leader>ds", vim.lsp.buf.document_symbol, vim.tbl_extend("force", opts, { desc = "Document symbols" }))
  end,
})
