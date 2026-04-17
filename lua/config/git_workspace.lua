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
  repo_actions = {},
  sidebar_focus = nil,
  sidebar_width = 38,
}

local group = api.nvim_create_augroup("erwin_git_workspace", { clear = true })
local diff_namespace = api.nvim_create_namespace("erwin_git_workspace_diff")
local close_extra_main_windows
local configure_main_window

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

local function trim(text)
  return vim.trim(text or "")
end

local function shorten(text, max_width)
  text = trim(text)
  max_width = max_width or 32

  if text == "" then
    return ""
  end

  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  return vim.fn.strcharpart(text, 0, math.max(max_width - 1, 1)) .. "…"
end

local function repo_action_state(repo_path)
  if state.repo_actions[repo_path] == nil then
    state.repo_actions[repo_path] = {}
  end

  return state.repo_actions[repo_path]
end

local function set_repo_action_state(repo_path, values)
  local repo_state = repo_action_state(repo_path)
  for key, value in pairs(values) do
    repo_state[key] = value
  end
  return repo_state
end

local function reset_repo_action_state(repo_path)
  state.repo_actions[repo_path] = {}
end

local function set_sidebar_focus(repo_path, target)
  state.sidebar_focus = {
    repo_path = repo_path,
    target = target,
  }
end

local function clear_sidebar_focus()
  state.sidebar_focus = nil
end

local function wrap_sidebar_text(text, indent, max_width)
  indent = indent or "   "
  text = trim(text)
  if text == "" then
    return { indent }
  end

  max_width = max_width or math.max(state.sidebar_width - 2, 18)
  local content_width = math.max(max_width - vim.fn.strdisplaywidth(indent), 12)
  local wrapped = {}

  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local words = vim.split(paragraph, "%s+", { trimempty = true })
    if vim.tbl_isempty(words) then
      table.insert(wrapped, indent)
      goto continue
    end

    local current = indent
    local current_width = 0

    for _, word in ipairs(words) do
      local word_width = vim.fn.strdisplaywidth(word)
      if current_width == 0 then
        current = indent .. word
        current_width = word_width
      elseif current_width + 1 + word_width <= content_width then
        current = current .. " " .. word
        current_width = current_width + 1 + word_width
      else
        table.insert(wrapped, current)
        current = indent .. word
        current_width = word_width
      end
    end

    table.insert(wrapped, current)
    ::continue::
  end

  return wrapped
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

local function schedule_sidebar_refresh()
  vim.schedule(function()
    if is_valid_tab(state.tabpage) then
      M.refresh()
    end
  end)
end

local function notify_result(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO)
  end)
end

local function run_system_async(args, opts, callback)
  vim.system(args, opts or {}, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

local function current_branch(repo_path)
  local branch, err = run_git({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo_path)
  branch = trim(branch)

  if branch == "" or branch == "HEAD" then
    return nil, err ~= "" and err or "Detached HEAD cannot be pushed"
  end

  return branch, nil
end

local function configured_remote(repo_path, branch)
  local remote = run_git({ "git", "config", "branch." .. branch .. ".remote" }, repo_path)
  remote = trim(remote)
  if remote ~= "" then
    return remote
  end

  local remotes = run_git({ "git", "remote" }, repo_path)
  if not remotes then
    return nil
  end

  local names = vim.split(trim(remotes), "\n", { trimempty = true })
  if vim.tbl_isempty(names) then
    return nil
  end

  for _, name in ipairs(names) do
    if name == "origin" then
      return name
    end
  end

  return names[1]
end

local function push_command(repo_path)
  local branch, err = current_branch(repo_path)
  if not branch then
    return nil, nil, err
  end

  local upstream = run_git({ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, repo_path)
  if upstream and trim(upstream) ~= "" then
    return { "git", "push" }, branch, nil
  end

  local remote = configured_remote(repo_path, branch)
  if not remote then
    return nil, branch, "No git remote configured for this repository"
  end

  return { "git", "push", "--set-upstream", remote, branch }, branch, nil
end

local function normalize_commit_message(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  local cleaned = {}

  for _, line in ipairs(lines) do
    line = line:gsub("\r", "")
    if not line:match("^```") then
      table.insert(cleaned, line)
    end
  end

  while #cleaned > 0 and trim(cleaned[1]) == "" do
    table.remove(cleaned, 1)
  end

  while #cleaned > 0 and trim(cleaned[#cleaned]) == "" do
    table.remove(cleaned, #cleaned)
  end

  if #cleaned == 0 then
    return ""
  end

  cleaned[1] = cleaned[1]:gsub("^['\"]", ""):gsub("['\"]$", "")
  return table.concat(cleaned, "\n")
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
    "Select a repo action to generate a commit message, commit, or push.",
    "",
    "Controls:",
    "  <CR> / o  open file diff or run action",
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

local function add_sidebar_line(lines, item, text)
  table.insert(lines, text)
  if item then
    state.line_items[#lines] = item
  end
end

local function add_wrapped_sidebar_lines(lines, item, text)
  for _, wrapped in ipairs(wrap_sidebar_text(text, "     ")) do
    add_sidebar_line(lines, item, wrapped)
  end
end

local function render_repo_actions(lines, repo)
  local action_state = repo_action_state(repo.path)
  local has_changes = not vim.tbl_isempty(repo.files)
  local message = action_state.commit_message

  if action_state.busy then
    add_sidebar_line(lines, {
      kind = "status",
      repo = repo,
      focus_target = action_state.busy_focus or "busy",
      highlight = "Comment",
    }, "   … " .. shorten(action_state.busy, 28))
  end

  if action_state.error then
    add_sidebar_line(lines, {
      kind = "status",
      repo = repo,
      highlight = "DiagnosticError",
    }, "   ! " .. shorten(action_state.error, 28))
  end

  if action_state.push_available then
    add_sidebar_line(lines, {
      kind = "action",
      repo = repo,
      action = "push",
      focus_target = "push",
      highlight = "Identifier",
    }, "   [ Push " .. shorten(action_state.push_branch or trim(repo.branch), 18) .. " ]")
  end

  if message and has_changes then
    add_sidebar_line(lines, {
      kind = "action",
      repo = repo,
      action = "commit",
      focus_target = "commit",
      highlight = "DiffAdd",
    }, "   [ Commit staged changes ]")
  end

  if (has_changes or message) and action_state.busy_focus ~= "busy_generate_message" then
    add_sidebar_line(lines, {
      kind = "action",
      repo = repo,
      action = "generate_message",
      focus_target = "generate_message",
      highlight = "Function",
    }, "   [ " .. (message and "Regenerate" or "Generate") .. " commit message ]")
  end

  if message then
    add_wrapped_sidebar_lines(lines, {
      kind = "message",
      repo = repo,
      highlight = "String",
    }, message)
  end
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

    add_sidebar_line(lines, {
      kind = "repo",
      repo = repo,
      focus_target = "repo",
    }, string.format(" %s %s  %s  %s", expanded and "▾" or "▸", repo.name, repo.branch, repo.summary))

    if expanded then
      render_repo_actions(lines, repo)

      if vim.tbl_isempty(repo.tree) then
        add_sidebar_line(lines, {
          kind = "status",
          highlight = "Comment",
        }, "   No changes")
      else
        for _, node in ipairs(repo.tree) do
          render_tree_node(lines, repo, node, 1)
        end
      end
    end

    table.insert(lines, "")
  end

  table.insert(lines, "  <CR> open/run   <Tab> toggle")
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
    elseif item.highlight then
      api.nvim_buf_add_highlight(state.sidebar_buf, -1, item.highlight, line - 1, 0, -1)
    end
  end

  local hint_start = math.max(#lines - 3, 0)
  for line = hint_start, #lines - 1 do
    api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Comment", line, 0, -1)
  end

  local focus = state.sidebar_focus
  if focus and is_valid_win(state.sidebar_win) then
    for line, item in pairs(state.line_items) do
      if item.repo and item.repo.path == focus.repo_path and item.focus_target == focus.target then
        api.nvim_win_set_cursor(state.sidebar_win, { line, 0 })
        clear_sidebar_focus()
        break
      end
    end
  end
end

local function restore_placeholder_view()
  if not is_valid_tab(state.tabpage) then
    return
  end

  local win = in_git_tab(state.main_win) and state.main_win or main_wins()[1]
  if not win then
    return
  end

  close_extra_main_windows(win)
  state.main_win = win
  state.current_diff = nil
  api.nvim_win_set_buf(win, placeholder_buf())
  configure_main_window(win)
end

local function show_action_output(title, body_lines, filetype)
  if not is_valid_tab(state.tabpage) then
    return
  end

  local win = in_git_tab(state.main_win) and state.main_win or main_wins()[1]
  if not win then
    return
  end

  close_extra_main_windows(win)
  state.main_win = win
  state.current_diff = nil

  local lines = { title, "" }
  vim.list_extend(lines, body_lines or {})

  local buf = create_scratch_buffer("git-workspace://output", lines, nil, false)
  if filetype and filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end

  api.nvim_win_set_buf(win, buf)
  configure_main_window(win)
  api.nvim_buf_add_highlight(buf, diff_namespace, "Title", 0, 0, -1)
end

local function run_repo_action(repo, action_name)
  local action_state = repo_action_state(repo.path)
  if action_state.busy then
    notify_result("Git action already running for " .. repo.name, vim.log.levels.WARN)
    return
  end

  if action_name == "generate_message" then
    set_repo_action_state(repo.path, {
      busy = "Generating commit message...",
      busy_focus = "busy_generate_message",
      error = false,
      info = false,
    })
    set_sidebar_focus(repo.path, "busy_generate_message")
    schedule_sidebar_refresh()

    local output_file = vim.fn.tempname()
    local prompt = table.concat({
      "Write a detailed Conventional Commit message for the current git changes.",
      "Requirements:",
      "1. First line must be a specific Conventional Commit subject using feat:, fix:, refactor:, docs:, chore:, test:, or perf: as appropriate.",
      "2. The subject must clearly say what changed, not generic wording like update or improve.",
      "3. If there are multiple meaningful changes, add a blank line and then 2-4 concise body lines describing the important modifications.",
      "4. Output only the commit message text. No code fences, no explanation.",
    }, "\n")
    local args = {
      "codex",
      "exec",
      "--ephemeral",
      "-m",
      "gpt-5.4-mini",
      "-c",
      'model_reasoning_effort="low"',
      "-s",
      "read-only",
      "--color",
      "never",
      "-C",
      repo.path,
      "--output-last-message",
      output_file,
      prompt,
    }

    run_system_async(args, {
      cwd = repo.path,
      text = true,
    }, function(result)
      local message = ""
      if result.code == 0 and vim.fn.filereadable(output_file) == 1 then
        message = normalize_commit_message(table.concat(vim.fn.readfile(output_file), "\n"))
      end
      vim.fn.delete(output_file)

      if result.code ~= 0 or message == "" then
        set_repo_action_state(repo.path, {
          busy = false,
          busy_focus = false,
          error = trim(result.stderr or result.stdout or "Failed to generate commit message"),
        })
        set_sidebar_focus(repo.path, "generate_message")
        notify_result("Failed to generate commit message for " .. repo.name, vim.log.levels.ERROR)
        schedule_sidebar_refresh()
        return
      end

      set_repo_action_state(repo.path, {
        busy = false,
        busy_focus = false,
        commit_message = message,
        error = false,
        info = false,
      })
      set_sidebar_focus(repo.path, "commit")
      schedule_sidebar_refresh()
    end)
    return
  end

  if action_name == "commit" then
    local message = trim(action_state.commit_message)
    if message == "" then
      notify_result("Generate a commit message first", vim.log.levels.WARN)
      return
    end

    if vim.tbl_isempty(repo.files) then
      notify_result("No changes to commit in " .. repo.name, vim.log.levels.WARN)
      return
    end

    set_repo_action_state(repo.path, {
      busy = "Running git add && git commit...",
      busy_focus = "busy_commit",
      error = false,
      info = false,
    })
    set_sidebar_focus(repo.path, "busy_commit")
    schedule_sidebar_refresh()

    run_system_async({ "git", "add", "-A" }, {
      cwd = repo.path,
      text = true,
    }, function(add_result)
      if add_result.code ~= 0 then
        set_repo_action_state(repo.path, {
          busy = false,
          busy_focus = false,
          error = trim(add_result.stderr or add_result.stdout or "git add failed"),
        })
        set_sidebar_focus(repo.path, "commit")
        notify_result("git add failed for " .. repo.name, vim.log.levels.ERROR)
        schedule_sidebar_refresh()
        return
      end

      local commit_message_file = vim.fn.tempname()
      vim.fn.writefile(vim.split(message, "\n", { plain = true }), commit_message_file)

      run_system_async({ "git", "commit", "-F", commit_message_file }, {
        cwd = repo.path,
        text = true,
      }, function(commit_result)
        vim.fn.delete(commit_message_file)

        if commit_result.code ~= 0 then
          set_repo_action_state(repo.path, {
            busy = false,
            busy_focus = false,
            error = trim(commit_result.stderr or commit_result.stdout or "git commit failed"),
          })
          set_sidebar_focus(repo.path, "commit")
          notify_result("git commit failed for " .. repo.name, vim.log.levels.ERROR)
          schedule_sidebar_refresh()
          return
        end

        local branch = current_branch(repo.path)
        local sha = run_git({ "git", "rev-parse", "--short", "HEAD" }, repo.path) or ""
        set_repo_action_state(repo.path, {
          busy = false,
          busy_focus = false,
          error = false,
          info = false,
          last_commit_sha = trim(sha),
          push_available = branch ~= nil,
          push_branch = branch,
        })
        set_sidebar_focus(repo.path, "push")
        show_action_output(
          "Commit Result · " .. repo.name,
          vim.split(trim(commit_result.stdout or "Commit created"), "\n", { trimempty = true }),
          ""
        )
        schedule_sidebar_refresh()
      end)
    end)
    return
  end

  if action_name == "push" then
    local args, branch, err = push_command(repo.path)
    if not args then
      set_repo_action_state(repo.path, {
        error = err,
      })
      notify_result(err, vim.log.levels.ERROR)
      schedule_sidebar_refresh()
      return
    end

    set_repo_action_state(repo.path, {
      busy = "Pushing branch " .. branch .. "...",
      busy_focus = "busy_push",
      error = false,
      info = false,
      push_available = true,
      push_branch = branch,
    })
    set_sidebar_focus(repo.path, "busy_push")
    schedule_sidebar_refresh()

    run_system_async(args, {
      cwd = repo.path,
      text = true,
    }, function(push_result)
      if push_result.code ~= 0 then
        set_repo_action_state(repo.path, {
          busy = false,
          busy_focus = false,
          error = trim(push_result.stderr or push_result.stdout or "git push failed"),
          push_available = true,
        })
        set_sidebar_focus(repo.path, "push")
        notify_result("git push failed for " .. repo.name, vim.log.levels.ERROR)
        schedule_sidebar_refresh()
        return
      end

      set_repo_action_state(repo.path, {
        busy = false,
        busy_focus = false,
        error = false,
        info = false,
      })
      reset_repo_action_state(repo.path)
      set_sidebar_focus(repo.path, "repo")
      restore_placeholder_view()
      schedule_sidebar_refresh()
    end)
  end
end

close_extra_main_windows = function(keep)
  for _, win in ipairs(main_wins()) do
    if win ~= keep then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

configure_main_window = function(win)
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

local function build_diff_view(file, raw_lines)
  local lines = {}
  local highlights = {}
  local hunks = {}
  local scrollbar_marks = {}
  local pending_hunk = false

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
      pending_hunk = true
    elseif line:sub(1, 1) == "+" then
      local line_number = add_line(line:sub(2), "DiffAdd", "GitAdd")
      if pending_hunk then
        table.insert(hunks, line_number)
        pending_hunk = false
      end
    elseif line:sub(1, 1) == "-" then
      local line_number = add_line(line:sub(2), "DiffDelete", "GitDelete")
      if pending_hunk then
        table.insert(hunks, line_number)
        pending_hunk = false
      end
    elseif line:sub(1, 1) == " " then
      local line_number = add_line(line:sub(2), nil)
      if pending_hunk then
        table.insert(hunks, line_number)
        pending_hunk = false
      end
    elseif line == "\\ No newline at end of file" then
      add_line("  [No newline at end of file]", "Comment")
    elseif line ~= "" then
      local line_number = add_line(line, "Comment")
      if pending_hunk then
        table.insert(hunks, line_number)
        pending_hunk = false
      end
    end
  end

  if #lines == 0 then
    add_line("No textual diff available.", "Comment")
  end

  return {
    lines = lines,
    highlights = highlights,
    hunks = hunks,
    scrollbar_marks = scrollbar_marks,
  }
end

local function apply_diff_code_syntax(buf, win, repo, file)
  if not is_valid_buf(buf) or not is_valid_win(win) then
    return
  end

  local source_path = file.old_path or file.path
  local absolute_path = source_path and join(repo.path, source_path) or nil
  local filetype = absolute_path and vim.filetype.match({ filename = absolute_path }) or nil
  if not filetype or filetype == "" then
    return
  end

  window_call(win, function()
    vim.bo[buf].filetype = filetype
    vim.bo[buf].syntax = filetype
    pcall(vim.treesitter.start, buf, filetype)
  end)
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
  api.nvim_win_set_buf(win, buf)
  apply_diff_code_syntax(buf, win, repo, file)
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

  if item.kind == "action" then
    run_repo_action(item.repo, item.action)
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
