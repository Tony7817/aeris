local api = vim.api
local uv = vim.uv

local M = {}

local state = {
  tabpage = nil,
  sidebar_buf = nil,
  sidebar_win = nil,
  main_win = nil,
  left_diff_win = nil,
  right_diff_win = nil,
  current_diff = nil,
  line_items = {},
  repo_expanded = {},
  dir_expanded = {},
  sidebar_width = 38,
}

local group = api.nvim_create_augroup("erwin_git_workspace", { clear = true })

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
    state.left_diff_win = nil
    state.right_diff_win = nil
    state.current_diff = nil
  end

  if not is_valid_win(state.sidebar_win) then
    state.sidebar_win = nil
  end
  if not in_git_tab(state.main_win) then
    state.main_win = nil
  end
  if not in_git_tab(state.left_diff_win) then
    state.left_diff_win = nil
  end
  if not in_git_tab(state.right_diff_win) then
    state.right_diff_win = nil
  end
  if state.current_diff ~= nil then
    local current = state.current_diff
    if not in_git_tab(current.left_win) or not in_git_tab(current.right_win) then
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

local function focus_main()
  reset_closed_handles()

  if in_git_tab(state.right_diff_win) then
    api.nvim_set_current_win(state.right_diff_win)
    return
  end

  if in_git_tab(state.main_win) then
    api.nvim_set_current_win(state.main_win)
    return
  end

  for _, win in ipairs(main_wins()) do
    state.main_win = win
    api.nvim_set_current_win(win)
    return
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
    "Select a changed file from the left panel to open a side-by-side diff.",
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

local function resolve_base_content(repo, file)
  if file.untracked or (file.added and not file.old_path) then
    return ""
  end

  local path = file.old_path or file.path
  local out = run_git({ "git", "show", "HEAD:" .. path }, repo.path)

  if out then
    return out
  end

  out = run_git({ "git", "show", ":" .. path }, repo.path)
  return out or ""
end

local function close_extra_main_windows(keep)
  for _, win in ipairs(main_wins()) do
    if win ~= keep then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

local function ensure_diff_windows()
  reset_closed_handles()

  if in_git_tab(state.left_diff_win) and in_git_tab(state.right_diff_win) then
    return state.left_diff_win, state.right_diff_win
  end

  local anchor = in_git_tab(state.main_win) and state.main_win or main_wins()[1]
  if not anchor then
    return nil, nil
  end

  close_extra_main_windows(anchor)
  state.main_win = anchor

  window_call(anchor, function()
    vim.cmd("diffoff!")
    vim.cmd("leftabove vsplit")
  end)

  local left
  local right
  for _, win in ipairs(main_wins()) do
    if win ~= state.sidebar_win then
      if not left then
        left = win
      else
        right = win
      end
    end
  end

  if left and right and api.nvim_win_get_position(left)[2] > api.nvim_win_get_position(right)[2] then
    left, right = right, left
  end

  state.left_diff_win = left
  state.right_diff_win = right
  state.main_win = right

  return left, right
end

local function open_file_buffer(win, abs_path)
  if not is_valid_win(win) then
    return
  end

  window_call(win, function()
    vim.cmd("silent edit " .. vim.fn.fnameescape(abs_path))
    vim.wo.wrap = false
  end)
end

local function set_buffer(win, buf)
  if is_valid_win(win) and is_valid_buf(buf) then
    api.nvim_win_set_buf(win, buf)
    vim.wo[win].wrap = false
  end
end

local function configure_diff_window(win)
  if not is_valid_win(win) then
    return
  end

  vim.wo[win].foldcolumn = "0"
  vim.wo[win].foldenable = false
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].wrap = false

  window_call(win, function()
    vim.cmd("silent! normal! zR")
  end)
end

local function enable_diff(left, right)
  window_call(left, function()
    vim.cmd("diffthis")
  end)

  window_call(right, function()
    vim.cmd("diffthis")
  end)
end

local function hunk_range(start, count, line_count)
  local first = math.max(start, 1)
  local last = first + math.max(count, 1) - 1

  if line_count > 0 then
    first = math.min(first, line_count)
    last = math.min(last, line_count)
  end

  if last < first then
    last = first
  end

  return {
    start = first,
    finish = last,
  }
end

local function buffer_text(buf)
  if not is_valid_buf(buf) then
    return ""
  end

  return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function compute_diff_ranges(left_buf, right_buf)
  local hunks = vim.diff(buffer_text(left_buf), buffer_text(right_buf), {
    algorithm = "histogram",
    ctxlen = 0,
    result_type = "indices",
  })

  local left_count = math.max(api.nvim_buf_line_count(left_buf), 1)
  local right_count = math.max(api.nvim_buf_line_count(right_buf), 1)
  local left_ranges = {}
  local right_ranges = {}

  for _, hunk in ipairs(hunks) do
    table.insert(left_ranges, hunk_range(hunk[1], hunk[2], left_count))
    table.insert(right_ranges, hunk_range(hunk[3], hunk[4], right_count))
  end

  return left_ranges, right_ranges
end

local function refresh_current_diff()
  local current = state.current_diff
  if current == nil then
    return nil
  end

  if not is_valid_buf(current.left_buf) or not is_valid_buf(current.right_buf) then
    state.current_diff = nil
    return nil
  end

  current.left_ranges, current.right_ranges = compute_diff_ranges(current.left_buf, current.right_buf)
  return current
end

local function jump_to_range(win, ranges, direction)
  if not is_valid_win(win) or #ranges == 0 then
    return false
  end

  local cursor = api.nvim_win_get_cursor(win)
  local current_line = cursor[1]
  local target

  if direction == "next" then
    for _, range in ipairs(ranges) do
      if range.start > current_line then
        target = range
        break
      end
    end
  else
    for index = #ranges, 1, -1 do
      local range = ranges[index]
      if range.finish < current_line then
        target = range
        break
      end
    end
  end

  if target == nil then
    return false
  end

  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { target.start, 0 })
  window_call(win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

local function open_diff(repo, file)
  if not repo or not file then
    return
  end

  if not is_valid_tab(state.tabpage) then
    return
  end

  api.nvim_set_current_tabpage(state.tabpage)

  local left, right = ensure_diff_windows()
  if not left or not right then
    return
  end

  local base_path = file.old_path or file.path
  local base_lines = vim.split(resolve_base_content(repo, file), "\n", { plain = true })
  if vim.tbl_isempty(base_lines) then
    base_lines = { "" }
  end

  local left_buf = create_scratch_buffer(
    string.format("git://%s/%s@HEAD", repo.name, base_path),
    base_lines,
    base_path,
    false
  )

  local abs_path = join(repo.path, file.path)
  if file.deleted or uv.fs_stat(abs_path) == nil then
    local right_buf = create_scratch_buffer(
      string.format("git://%s/%s@WORKTREE", repo.name, file.path),
      { "" },
      file.path,
      false
    )
    set_buffer(right, right_buf)
  else
    open_file_buffer(right, abs_path)
  end

  set_buffer(left, left_buf)
  enable_diff(left, right)
  configure_diff_window(left)
  configure_diff_window(right)

  state.current_diff = {
    file_path = file.path,
    left_buf = api.nvim_win_get_buf(left),
    left_win = left,
    right_buf = api.nvim_win_get_buf(right),
    right_win = right,
  }
  refresh_current_diff()
  api.nvim_set_current_win(right)
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

  local current = refresh_current_diff()
  if current == nil then
    return false
  end

  local win = api.nvim_get_current_win()
  if win == current.right_win then
    return jump_to_range(win, current.right_ranges or {}, direction)
  end

  if win == current.left_win then
    return jump_to_range(win, current.left_ranges or {}, direction)
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
  state.left_diff_win = nil
  state.right_diff_win = nil
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
    state.left_diff_win = nil
    state.right_diff_win = state.main_win
    state.current_diff = nil
    api.nvim_win_set_buf(state.main_win, placeholder_buf())
  end

  state.main_win = in_git_tab(state.main_win) and state.main_win or api.nvim_get_current_win()
  state.right_diff_win = state.main_win

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
