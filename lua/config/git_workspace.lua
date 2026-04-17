local api = vim.api
local uv = vim.uv

local M = {}

local state = {
  tabpage = nil,
  sidebar_buf = nil,
  sidebar_win = nil,
  main_win = nil,
  current_diff = nil,
  line_items = {},
  repo_expanded = {},
  dir_expanded = {},
  sidebar_width = 38,
}

local group = api.nvim_create_augroup("erwin_git_workspace", { clear = true })
local diff_namespace = api.nvim_create_namespace("erwin_git_workspace_diff")

local function join(...)
  return table.concat({ ... }, "/")
end

local function is_valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function is_valid_tab(tabpage)
  return tabpage ~= nil and api.nvim_tabpage_is_valid(tabpage)
end

local function in_git_tab(win)
  return is_valid_tab(state.tabpage) and is_valid_win(win) and api.nvim_win_get_tabpage(win) == state.tabpage
end

local function reset_closed_handles()
  if not is_valid_tab(state.tabpage) then
    state.tabpage = nil
    state.sidebar_win = nil
    state.main_win = nil
    state.current_diff = nil
  end

  if not is_valid_win(state.sidebar_win) then
    state.sidebar_win = nil
  end
  if not in_git_tab(state.main_win) then
    state.main_win = nil
  end
  if state.current_diff ~= nil then
    local current = state.current_diff
    if not is_valid_buf(current.buf) or not in_git_tab(current.win) then
      state.current_diff = nil
    end
  end
  if not is_valid_buf(state.sidebar_buf) then
    state.sidebar_buf = nil
  end
end

local function tab_wins()
  if not is_valid_tab(state.tabpage) then
    return {}
  end

  return api.nvim_tabpage_list_wins(state.tabpage)
end

local function main_wins()
  local wins = {}

  for _, win in ipairs(tab_wins()) do
    if win ~= state.sidebar_win then
      table.insert(wins, win)
    end
  end

  return wins
end

local function is_git_repo(path)
  return uv.fs_stat(join(path, ".git")) ~= nil
end

local function run_git(args, cwd)
  local result = vim.system(args, {
    cwd = cwd,
    text = true,
  }):wait()

  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or result.stdout or "")
  end

  return result.stdout or "", nil
end

local function parse_branch(first_line)
  return first_line:match("^##%s+(.*)$") or "(unknown)"
end

local function parse_counts(lines)
  local counts = {
    staged = 0,
    unstaged = 0,
    untracked = 0,
    conflicts = 0,
  }

  for _, line in ipairs(lines) do
    if line ~= "" and not vim.startswith(line, "## ") then
      local x = line:sub(1, 1)
      local y = line:sub(2, 2)
      local code = line:sub(1, 2)

      if code == "??" then
        counts.untracked = counts.untracked + 1
      elseif x == "U" or y == "U" or code == "AA" or code == "DD" then
        counts.conflicts = counts.conflicts + 1
      else
        if x ~= " " then
          counts.staged = counts.staged + 1
        end
        if y ~= " " then
          counts.unstaged = counts.unstaged + 1
        end
      end
    end
  end

  return counts
end

local function format_counts(counts)
  local parts = {}

  if counts.staged > 0 then
    table.insert(parts, "+" .. counts.staged)
  end
  if counts.unstaged > 0 then
    table.insert(parts, "~" .. counts.unstaged)
  end
  if counts.untracked > 0 then
    table.insert(parts, "?" .. counts.untracked)
  end
  if counts.conflicts > 0 then
    table.insert(parts, "!" .. counts.conflicts)
  end

  if #parts == 0 then
    return "clean"
  end

  return table.concat(parts, " ")
end

local function parse_file_status(line)
  if line == "" or vim.startswith(line, "## ") then
    return nil
  end

  local code = line:sub(1, 2)
  local path_text = vim.trim(line:sub(4))
  local old_path
  local path = path_text

  if code:find("[RC]") then
    old_path, path = path_text:match("^(.-) %-%> (.+)$")
    path = path or path_text
  end

  local x = code:sub(1, 1)
  local y = code:sub(2, 2)

  return {
    code = code,
    path = path,
    old_path = old_path,
    tracked = code ~= "??",
    deleted = x == "D" or y == "D",
    untracked = code == "??",
    added = code == "??" or x == "A" or y == "A",
    renamed = x == "R" or y == "R",
    copied = x == "C" or y == "C",
    conflicted = x == "U" or y == "U" or code == "AA" or code == "DD",
  }
end

local function compare_nodes(a, b)
  if a.kind ~= b.kind then
    return a.kind == "dir"
  end

  return a.name < b.name
end

local function sort_tree(nodes)
  table.sort(nodes, compare_nodes)

  for _, node in ipairs(nodes) do
    if node.kind == "dir" then
      sort_tree(node.children)
    end
  end
end

local function build_tree(files)
  local root = {}

  for _, file in ipairs(files) do
    local parts = vim.split(file.path, "/", { plain = true })
    local children = root
    local current_path = {}

    for index, part in ipairs(parts) do
      table.insert(current_path, part)
      local path = table.concat(current_path, "/")

      if index == #parts then
        table.insert(children, {
          kind = "file",
          name = part,
          path = path,
          file = file,
        })
      else
        local dir
        for _, node in ipairs(children) do
          if node.kind == "dir" and node.name == part then
            dir = node
            break
          end
        end

        if not dir then
          dir = {
            kind = "dir",
            name = part,
            path = path,
            children = {},
          }
          table.insert(children, dir)
        end

        children = dir.children
      end
    end
  end

  sort_tree(root)
  return root
end

local function repo_entry(path)
  local name = vim.fs.basename(path)
  local output, err = run_git({ "git", "status", "--porcelain=v1", "--branch", "--untracked-files=all" }, path)

  if not output then
    return {
      name = name,
      path = path,
      branch = "(unavailable)",
      summary = err ~= "" and err or "git status failed",
      status_lines = {},
      files = {},
      tree = {},
    }
  end

  local lines = vim.split(vim.trim(output), "\n", { trimempty = true })
  local branch = lines[1] and parse_branch(lines[1]) or "(unknown)"
  local counts = parse_counts(lines)
  local files = {}

  for _, line in ipairs(lines) do
    local entry = parse_file_status(line)
    if entry then
      table.insert(files, entry)
    end
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)

  return {
    name = name,
    path = path,
    branch = branch,
    summary = format_counts(counts),
    status_lines = lines,
    files = files,
    tree = build_tree(files),
  }
end

function M.collect(root)
  root = vim.fs.normalize(root or uv.cwd())

  local repos = {}

  if is_git_repo(root) then
    table.insert(repos, repo_entry(root))
  end

  for name, kind in vim.fs.dir(root) do
    if kind == "directory" then
      local path = join(root, name)
      if is_git_repo(path) then
        table.insert(repos, repo_entry(path))
      end
    end
  end

  table.sort(repos, function(a, b)
    return a.name < b.name
  end)

  return repos
end

local function selected_item()
  reset_closed_handles()

  if not is_valid_win(state.sidebar_win) then
    return nil
  end

  local line = api.nvim_win_get_cursor(state.sidebar_win)[1]
  return state.line_items[line]
end

local function focus_sidebar()
  reset_closed_handles()

  if is_valid_win(state.sidebar_win) then
    api.nvim_set_current_win(state.sidebar_win)
  end
end

local function window_call(win, callback)
  if not is_valid_win(win) then
    return
  end

  local previous = api.nvim_get_current_win()
  api.nvim_set_current_win(win)
  local ok, result = pcall(callback)

  if is_valid_win(previous) then
    api.nvim_set_current_win(previous)
  end

  if not ok then
    error(result)
  end

  return result
end

local function create_scratch_buffer(name, lines, file_path, modifiable)
  local buf = api.nvim_create_buf(false, true)

  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true

  if name then
    pcall(api.nvim_buf_set_name, buf, name)
  end

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable == true
  vim.bo[buf].readonly = modifiable ~= true

  local filetype = file_path and vim.filetype.match({ filename = file_path }) or nil
  if filetype then
    vim.bo[buf].filetype = filetype
  end

  return buf
end

local function placeholder_buf()
  local lines = {
    "Workspace Source Control",
    "",
    "Select a changed file from the left panel to open a unified diff.",
    "",
    "Controls:",
    "  <CR> / o  open file diff",
    "  <Tab>     expand or collapse",
    "  r         refresh status",
    "  q         close this Git tab",
  }

  return create_scratch_buffer("git-workspace://home", lines, nil, false)
end

local function apply_sidebar_mappings(buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      desc = desc,
      nowait = true,
      silent = true,
    })
  end

  map("<CR>", M.open_selected, "Open selected Git item")
  map("o", M.open_selected, "Open selected Git item")
  map("<Tab>", M.toggle_selected, "Toggle selected Git tree item")
  map("za", M.toggle_selected, "Toggle selected Git tree item")
  map("r", M.refresh, "Refresh Git panel")
  map("q", M.close, "Close Git tab")
end

local function ensure_sidebar_buf()
  if is_valid_buf(state.sidebar_buf) then
    return state.sidebar_buf
  end

  local buf = api.nvim_create_buf(false, true)
  state.sidebar_buf = buf

  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "erwin-git-workspace"
  vim.bo[buf].swapfile = false

  apply_sidebar_mappings(buf)

  return buf
end

local function configure_sidebar_window(win)
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].spell = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = false
  vim.wo[win].winblend = 0
  vim.wo[win].winhighlight =
    "Normal:Normal,NormalNC:Normal,EndOfBuffer:Normal,WinSeparator:WinSeparator,CursorLine:Visual"
end

local function attach_sidebar()
  local buf = ensure_sidebar_buf()

  if is_valid_win(state.sidebar_win) then
    api.nvim_win_set_buf(state.sidebar_win, buf)
    return
  end

  state.sidebar_win = api.nvim_open_win(buf, false, {
    split = "left",
    vertical = true,
    win = state.main_win,
    width = state.sidebar_width,
  })

  configure_sidebar_window(state.sidebar_win)
end

local function render_tree_node(lines, repo, node, depth)
  local indent = string.rep("  ", depth)

  if node.kind == "dir" then
    local key = repo.path .. "::" .. node.path
    local expanded = state.dir_expanded[key]
    if expanded == nil then
      expanded = true
      state.dir_expanded[key] = true
    end

    table.insert(lines, string.format(" %s%s %s/", indent, expanded and "▾" or "▸", node.name))
    state.line_items[#lines] = {
      kind = "dir",
      repo = repo,
      node = node,
    }

    if expanded then
      for _, child in ipairs(node.children) do
        render_tree_node(lines, repo, child, depth + 1)
      end
    end

    return
  end

  local file = node.file
  table.insert(lines, string.format(" %s  [%s] %s", indent, file.code, node.name))
  state.line_items[#lines] = {
    kind = "file",
    repo = repo,
    node = node,
    file = file,
  }
end

function M.render()
  reset_closed_handles()

  if not is_valid_buf(state.sidebar_buf) then
    return
  end

  local repos = M.collect()
  local lines = {
    " Source Control",
    "",
  }

  state.line_items = {}

  if vim.tbl_isempty(repos) then
    table.insert(lines, "  No Git repositories found")
  end

  for _, repo in ipairs(repos) do
    local expanded = state.repo_expanded[repo.path]
    if expanded == nil then
      expanded = true
      state.repo_expanded[repo.path] = true
    end

    table.insert(lines, string.format(" %s %s  %s  %s", expanded and "▾" or "▸", repo.name, repo.branch, repo.summary))
    state.line_items[#lines] = {
      kind = "repo",
      repo = repo,
    }

    if expanded then
      if vim.tbl_isempty(repo.tree) then
        table.insert(lines, "   No changes")
      else
        for _, node in ipairs(repo.tree) do
          render_tree_node(lines, repo, node, 1)
        end
      end
    end

    table.insert(lines, "")
  end

  table.insert(lines, "  <CR> open   <Tab> toggle")
  table.insert(lines, "  r refresh")
  table.insert(lines, "  q close")

  vim.bo[state.sidebar_buf].modifiable = true
  api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
  vim.bo[state.sidebar_buf].modifiable = false

  api.nvim_buf_clear_namespace(state.sidebar_buf, -1, 0, -1)
  api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Title", 0, 1, -1)

  for line, item in pairs(state.line_items) do
    if item.kind == "repo" then
      api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Directory", line - 1, 0, -1)
    elseif item.kind == "dir" then
      api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Directory", line - 1, 0, -1)
    elseif item.kind == "file" then
      local hl = "Normal"
      if item.file.conflicted then
        hl = "DiagnosticError"
      elseif item.file.untracked or item.file.added then
        hl = "DiffAdd"
      elseif item.file.deleted then
        hl = "DiffDelete"
      elseif item.file.renamed or item.file.copied then
        hl = "DiffChange"
      elseif item.file.code:find("M", 1, true) then
        hl = "DiffChange"
      end

      api.nvim_buf_add_highlight(state.sidebar_buf, -1, hl, line - 1, 0, -1)
    end
  end

  local hint_start = math.max(#lines - 3, 0)
  for line = hint_start, #lines - 1 do
    api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Comment", line, 0, -1)
  end
end

local function close_extra_main_windows(keep)
  for _, win in ipairs(main_wins()) do
    if win ~= keep then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

local function configure_main_window(win)
  if not is_valid_win(win) then
    return
  end

  vim.wo[win].diff = false
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].foldenable = false
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false

  window_call(win, function()
    vim.cmd("silent! diffoff!")
    vim.cmd("silent! normal! zR")
  end)
end

local function run_git_capture(args, cwd, ok_codes)
  local result = vim.system(args, {
    cwd = cwd,
    text = true,
  }):wait()

  if not vim.tbl_contains(ok_codes or { 0 }, result.code) then
    return nil, vim.trim(result.stderr or result.stdout or "")
  end

  return result.stdout or "", nil
end

local function diff_lines(output)
  local lines = vim.split(output or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  if vim.tbl_isempty(lines) then
    return { "" }
  end
  return lines
end

local function diff_status_summary(file)
  local labels = {}

  if file.renamed then
    table.insert(labels, "renamed")
  elseif file.copied then
    table.insert(labels, "copied")
  elseif file.deleted then
    table.insert(labels, "deleted")
  elseif file.untracked then
    table.insert(labels, "new file")
  elseif file.added then
    table.insert(labels, "added")
  elseif file.code:find("M", 1, true) then
    table.insert(labels, "modified")
  end

  if file.conflicted then
    table.insert(labels, "conflicted")
  end

  return #labels > 0 and table.concat(labels, " • ") or "changed"
end

local function format_hunk_header(line)
  local before, after, context = line:match("^@@ %-(.-) %+(.-) @@%s*(.*)$")
  if not before or not after then
    return line
  end

  local header = string.format("Change %s -> %s", before, after)
  if context and context ~= "" then
    header = header .. "  " .. context
  end

  return header
end

local function build_diff_view(file, raw_lines)
  local lines = {
    file.old_path and file.old_path ~= file.path and (file.old_path .. " -> " .. file.path) or file.path,
    diff_status_summary(file),
    "",
  }
  local highlights = {
    { line = 1, group = "Title" },
    { line = 2, group = "Comment" },
  }
  local hunks = {}
  local scrollbar_marks = {}

  local function add_line(text, group, scrollbar_type)
    table.insert(lines, text)
    local line_number = #lines

    if group then
      table.insert(highlights, { line = line_number, group = group })
    end

    if scrollbar_type then
      table.insert(scrollbar_marks, {
        line = line_number - 1,
        text = "▏",
        type = scrollbar_type,
        level = 1,
      })
    end

    return line_number
  end

  for _, line in ipairs(raw_lines) do
    if
      line:match("^diff %-%-git ")
      or line:match("^index ")
      or line:match("^--- ")
      or line:match("^%+%+%+ ")
      or line:match("^old mode ")
      or line:match("^new mode ")
      or line:match("^new file mode ")
      or line:match("^deleted file mode ")
      or line:match("^similarity index ")
      or line:match("^rename from ")
      or line:match("^rename to ")
    then
      -- Drop raw git metadata. The view should focus on the code changes.
    elseif line:match("^Binary files ") then
      add_line("Binary file changed", "Comment")
    elseif line:match("^@@") then
      local line_number = add_line(format_hunk_header(line), "DiffChange")
      table.insert(hunks, line_number)
    elseif line:sub(1, 1) == "+" then
      add_line("+ " .. line:sub(2), "DiffAdd", "GitAdd")
    elseif line:sub(1, 1) == "-" then
      add_line("- " .. line:sub(2), "DiffDelete", "GitDelete")
    elseif line:sub(1, 1) == " " then
      add_line("  " .. line:sub(2), nil)
    elseif line == "\\ No newline at end of file" then
      add_line("  [No newline at end of file]", "Comment")
    elseif line ~= "" then
      add_line(line, "Comment")
    end
  end

  if #lines == 3 then
    add_line("No textual diff available.", "Comment")
  end

  return {
    lines = lines,
    highlights = highlights,
    hunks = hunks,
    scrollbar_marks = scrollbar_marks,
  }
end

local function repo_base_ref(repo_path)
  local head = run_git({ "git", "rev-parse", "--verify", "HEAD" }, repo_path)
  if head then
    return "HEAD"
  end

  return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
end

local function unified_diff_output(repo, file)
  if file.untracked then
    return run_git_capture({
      "git",
      "diff",
      "--no-index",
      "--no-color",
      "--no-ext-diff",
      "--",
      "/dev/null",
      file.path,
    }, repo.path, { 0, 1 })
  end

  local args = {
    "git",
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--find-renames",
    "--find-copies",
    repo_base_ref(repo.path),
    "--",
  }

  if file.old_path and file.old_path ~= file.path then
    table.insert(args, file.old_path)
  end
  table.insert(args, file.path)

  return run_git(args, repo.path)
end

local function apply_diff_highlights(buf, diff_view)
  api.nvim_buf_clear_namespace(buf, diff_namespace, 0, -1)

  for _, item in ipairs(diff_view.highlights or {}) do
    api.nvim_buf_add_highlight(buf, diff_namespace, item.group, item.line - 1, 0, -1)
  end
end

local function apply_diff_scrollbar_marks(buf, win, diff_view)
  local ok_utils, scrollbar_utils = pcall(require, "scrollbar.utils")
  if not ok_utils then
    return
  end

  local scrollbar_marks = scrollbar_utils.get_scrollbar_marks(buf)
  scrollbar_marks.erwin_git_workspace = diff_view.scrollbar_marks or {}
  scrollbar_utils.set_scrollbar_marks(buf, scrollbar_marks)

  local ok_scrollbar, scrollbar = pcall(require, "scrollbar")
  if ok_scrollbar and is_valid_win(win) then
    vim.api.nvim_win_call(win, function()
      scrollbar.render()
    end)
  end
end

local function jump_to_hunk(win, hunks, direction)
  if not is_valid_win(win) or #hunks == 0 then
    return false
  end

  local current_line = api.nvim_win_get_cursor(win)[1]
  local target

  if direction == "next" then
    for _, line_number in ipairs(hunks) do
      if line_number > current_line then
        target = line_number
        break
      end
    end
  else
    for index = #hunks, 1, -1 do
      local line_number = hunks[index]
      if line_number < current_line then
        target = line_number
        break
      end
    end
  end

  if not target then
    return false
  end

  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { target, 0 })
  window_call(win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

local function open_diff(repo, file)
  if not repo or not file or not is_valid_tab(state.tabpage) then
    return
  end

  api.nvim_set_current_tabpage(state.tabpage)

  local win = in_git_tab(state.main_win) and state.main_win or main_wins()[1]
  if not win then
    return
  end

  close_extra_main_windows(win)
  state.main_win = win

  local output, err = unified_diff_output(repo, file)
  local diff_view
  if output and output ~= "" then
    diff_view = build_diff_view(file, diff_lines(output))
  elseif err and err ~= "" then
    diff_view = {
      lines = {
        file.path,
        "diff unavailable",
        "",
        "Unable to render diff for " .. file.path,
        err,
      },
      highlights = {
        { line = 1, group = "Title" },
        { line = 2, group = "Comment" },
        { line = 4, group = "Comment" },
        { line = 5, group = "DiagnosticError" },
      },
      hunks = {},
      scrollbar_marks = {},
    }
  else
    diff_view = {
      lines = {
        file.path,
        diff_status_summary(file),
        "",
        "No textual diff available.",
      },
      highlights = {
        { line = 1, group = "Title" },
        { line = 2, group = "Comment" },
        { line = 4, group = "Comment" },
      },
      hunks = {},
      scrollbar_marks = {},
    }
  end

  local buf = create_scratch_buffer(
    string.format("git-workspace://%s/%s.diff", repo.name, file.path),
    diff_view.lines,
    nil,
    false
  )
  vim.bo[buf].filetype = "erwin-git-diff"
  api.nvim_win_set_buf(win, buf)
  configure_main_window(win)
  apply_diff_highlights(buf, diff_view)
  apply_diff_scrollbar_marks(buf, win, diff_view)

  state.current_diff = {
    file_path = file.path,
    buf = buf,
    hunks = diff_view.hunks,
    win = win,
  }
  api.nvim_set_current_win(win)
end

function M.toggle_selected()
  local item = selected_item()
  if not item then
    return
  end

  if item.kind == "repo" then
    state.repo_expanded[item.repo.path] = not state.repo_expanded[item.repo.path]
    M.render()
    focus_sidebar()
    return
  end

  if item.kind == "dir" then
    local key = item.repo.path .. "::" .. item.node.path
    state.dir_expanded[key] = not state.dir_expanded[key]
    M.render()
    focus_sidebar()
  end
end

function M.open_selected()
  local item = selected_item()
  if not item then
    return
  end

  if item.kind == "repo" or item.kind == "dir" then
    M.toggle_selected()
    return
  end

  if item.kind == "file" then
    open_diff(item.repo, item.file)
  end
end

function M.refresh()
  if not is_valid_tab(state.tabpage) then
    return
  end

  api.nvim_set_current_tabpage(state.tabpage)
  M.render()
end

function M.jump_change(direction)
  reset_closed_handles()

  if not is_valid_tab(state.tabpage) or api.nvim_get_current_tabpage() ~= state.tabpage then
    return false
  end

  local current = state.current_diff
  if current == nil or not is_valid_buf(current.buf) or not in_git_tab(current.win) then
    state.current_diff = nil
    return false
  end

  if api.nvim_get_current_win() == current.win then
    return jump_to_hunk(current.win, current.hunks or {}, direction)
  end

  return false
end

function M.close()
  reset_closed_handles()

  if not is_valid_tab(state.tabpage) then
    return
  end

  local tabpage = state.tabpage
  state.tabpage = nil
  state.sidebar_win = nil
  state.main_win = nil
  state.current_diff = nil

  if api.nvim_get_current_tabpage() == tabpage then
    vim.cmd("tabclose")
    return
  end

  api.nvim_set_current_tabpage(tabpage)
  vim.cmd("tabclose")
end

local function ensure_layout()
  reset_closed_handles()

  if is_valid_tab(state.tabpage) then
    api.nvim_set_current_tabpage(state.tabpage)
    if is_valid_win(state.sidebar_win) then
      focus_sidebar()
      M.render()
      return
    end
  else
    vim.cmd("tabnew")
    state.tabpage = api.nvim_get_current_tabpage()
    state.main_win = api.nvim_get_current_win()
    state.current_diff = nil
    api.nvim_win_set_buf(state.main_win, placeholder_buf())
  end

  state.main_win = in_git_tab(state.main_win) and state.main_win or api.nvim_get_current_win()
  close_extra_main_windows(state.main_win)
  configure_main_window(state.main_win)

  attach_sidebar()
  M.render()
  focus_sidebar()
end

function M.open()
  ensure_layout()
end

api.nvim_create_autocmd("TabClosed", {
  group = group,
  callback = function()
    vim.schedule(reset_closed_handles)
  end,
})

return M
