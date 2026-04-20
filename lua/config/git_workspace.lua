local api = vim.api
local uv = vim.uv

local M = {}

local state = {
  tabpage = nil,
  sidebar_buf = nil,
  sidebar_win = nil,
  sidebar_status_buf = nil,
  sidebar_status_win = nil,
  main_win = nil,
  current_diff = nil,
  line_items = {},
  repo_expanded = {},
  repo_actions = {},
  repo_remote = {},
  sidebar_focus = nil,
  sidebar_width = 38,
  refresh_timer = nil,
  repo_snapshot = nil,
  preview_buf = nil,
  preview_signature = nil,
}

local group = api.nvim_create_augroup("erwin_git_workspace", { clear = true })
local diff_namespace = api.nvim_create_namespace("erwin_git_workspace_diff")
local close_extra_main_windows
local configure_main_window
local current_branch
local configured_remote
local current_sidebar_item
local render_sidebar_status
local render_sidebar_preview
local repo_entry

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

local function stop_refresh_timer()
  if state.refresh_timer ~= nil then
    state.refresh_timer:stop()
    state.refresh_timer:close()
    state.refresh_timer = nil
  end
end

local function in_git_tab(win)
  return is_valid_tab(state.tabpage) and is_valid_win(win) and api.nvim_win_get_tabpage(win) == state.tabpage
end

local function reset_closed_handles()
  if not is_valid_tab(state.tabpage) then
    state.tabpage = nil
    state.sidebar_win = nil
    state.sidebar_status_win = nil
    state.main_win = nil
    state.current_diff = nil
    state.repo_snapshot = nil
    stop_refresh_timer()
  end

  if not is_valid_win(state.sidebar_win) then
    state.sidebar_win = nil
  end
  if not is_valid_win(state.sidebar_status_win) then
    state.sidebar_status_win = nil
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
  if not is_valid_buf(state.sidebar_status_buf) then
    state.sidebar_status_buf = nil
  end
  if not is_valid_buf(state.preview_buf) then
    state.preview_buf = nil
    state.preview_signature = nil
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
    if win ~= state.sidebar_win and win ~= state.sidebar_status_win then
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
  local branch = first_line:match("^##%s+(.*)$") or "(unknown)"
  branch = branch:match("^No commits yet on (.+)$") or branch
  branch = branch:match("^(.-)%.%.%.") or branch
  branch = branch:match("^(.-)%s+%[") or branch
  return vim.trim(branch)
end

local function branch_push_state(repo_path)
  local branch, err = current_branch(repo_path)
  if not branch then
    return {
      branch = nil,
      push_available = false,
      has_upstream = false,
      ahead = 0,
      error = err,
    }
  end

  local upstream = run_git({ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, repo_path)
  upstream = vim.trim(upstream or "")

  if upstream ~= "" then
    local counts = run_git({ "git", "rev-list", "--left-right", "--count", upstream .. "..." .. branch }, repo_path)
    local behind, ahead = 0, 0

    if counts then
      local left, right = vim.trim(counts):match("^(%d+)%s+(%d+)$")
      behind = tonumber(left) or 0
      ahead = tonumber(right) or 0
    end

    return {
      branch = branch,
      push_available = ahead > 0,
      has_upstream = true,
      ahead = ahead,
      behind = behind,
      upstream = upstream,
    }
  end

  local remote = configured_remote(repo_path, branch)
  local head = run_git({ "git", "rev-parse", "--verify", "HEAD" }, repo_path)

  return {
    branch = branch,
    push_available = remote ~= nil and head ~= nil,
    has_upstream = false,
    ahead = head and 1 or 0,
    remote = remote,
  }
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

local function repo_status_snapshot(repos)
  local chunks = {}

  local function append_repo(repo)
    local push = repo.push or {}
    chunks[#chunks + 1] = table.concat({
      repo.path,
      tostring(repo.initialized ~= false),
      repo.display_name or repo.name or "",
      repo.branch or "",
      repo.summary or "",
      tostring(push.push_available or false),
      tostring(push.has_upstream or false),
      tostring(push.ahead or 0),
      tostring(push.behind or 0),
      table.concat(repo.status_lines or {}, "\n"),
    }, "\n")

    for _, submodule in ipairs(repo.submodules or {}) do
      append_repo(submodule)
    end
  end

  for _, repo in ipairs(repos) do
    append_repo(repo)
  end

  return table.concat(chunks, "\n---\n")
end

local function each_repo(repos, callback)
  for _, repo in ipairs(repos or {}) do
    callback(repo)
    each_repo(repo.submodules, callback)
  end
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

local function repo_title(repo)
  return trim((repo and (repo.display_name or repo.name)) or "")
end

local function repo_action_state(repo_path)
  if state.repo_actions[repo_path] == nil then
    state.repo_actions[repo_path] = {}
  end

  return state.repo_actions[repo_path]
end

local function repo_remote_state(repo_path)
  if state.repo_remote[repo_path] == nil then
    state.repo_remote[repo_path] = {}
  end

  return state.repo_remote[repo_path]
end

local function set_repo_action_state(repo_path, values)
  local repo_state = repo_action_state(repo_path)
  for key, value in pairs(values) do
    repo_state[key] = value
  end
  return repo_state
end

local function set_repo_remote_state(repo_path, values)
  local remote_state = repo_remote_state(repo_path)
  for key, value in pairs(values) do
    remote_state[key] = value
  end
  return remote_state
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

local function submodule_definitions(repo_path)
  if uv.fs_stat(join(repo_path, ".gitmodules")) == nil then
    return {}
  end

  local output = run_git({
    "git",
    "config",
    "--file",
    ".gitmodules",
    "--get-regexp",
    "^submodule\\..*\\.path$",
  }, repo_path)

  if not output then
    return {}
  end

  local definitions = {}
  for _, line in ipairs(vim.split(trim(output), "\n", { trimempty = true })) do
    local relpath = trim(line:match("^.-%s+(.+)$"))
    if relpath ~= "" then
      table.insert(definitions, {
        relpath = relpath,
        path = vim.fs.normalize(join(repo_path, relpath)),
      })
    end
  end

  table.sort(definitions, function(a, b)
    return a.relpath < b.relpath
  end)

  return definitions
end

local function uninitialized_submodule_entry(parent_repo_path, definition)
  return {
    name = vim.fs.basename(definition.relpath),
    display_name = definition.relpath,
    path = definition.path,
    branch = "(uninitialized)",
    summary = "submodule not initialized",
    counts = {
      staged = 0,
      unstaged = 0,
      untracked = 0,
      conflicts = 0,
    },
    status_lines = { "submodule not initialized" },
    files = {},
    push = {
      push_available = false,
      has_upstream = false,
      ahead = 0,
      behind = 0,
    },
    submodules = {},
    is_submodule = true,
    initialized = false,
    parent_repo_path = parent_repo_path,
    submodule_path = definition.relpath,
  }
end

local function collect_submodule_entries(repo_path, seen)
  local submodules = {}

  for _, definition in ipairs(submodule_definitions(repo_path)) do
    if not seen[definition.path] then
      if is_git_repo(definition.path) then
        table.insert(submodules, repo_entry(definition.path, {
          display_name = definition.relpath,
          is_submodule = true,
          initialized = true,
          parent_repo_path = repo_path,
          submodule_path = definition.relpath,
        }, seen))
      else
        seen[definition.path] = true
        table.insert(submodules, uninitialized_submodule_entry(repo_path, definition))
      end
    end
  end

  table.sort(submodules, function(a, b)
    return (a.display_name or a.name) < (b.display_name or b.name)
  end)

  return submodules
end

repo_entry = function(path, opts, seen)
  opts = opts or {}
  seen = seen or {}
  path = vim.fs.normalize(path)
  seen[path] = true

  local name = vim.fs.basename(path)
  local display_name = opts.display_name or name
  local output, err = run_git({ "git", "status", "--porcelain=v1", "--branch", "--untracked-files=all" }, path)

  if not output then
    return {
      name = name,
      display_name = display_name,
      path = path,
      branch = "(unavailable)",
      summary = err ~= "" and err or "git status failed",
      status_lines = {},
      files = {},
      submodules = {},
      is_submodule = opts.is_submodule == true,
      initialized = opts.initialized ~= false,
      parent_repo_path = opts.parent_repo_path,
      submodule_path = opts.submodule_path,
    }
  end

  local lines = vim.split(vim.trim(output), "\n", { trimempty = true })
  local branch = lines[1] and parse_branch(lines[1]) or "(unknown)"
  local counts = parse_counts(lines)
  local files = {}
  local push = branch_push_state(path)

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
    display_name = display_name,
    path = path,
    branch = branch,
    summary = format_counts(counts),
    counts = counts,
    status_lines = lines,
    files = files,
    push = push,
    submodules = collect_submodule_entries(path, seen),
    is_submodule = opts.is_submodule == true,
    initialized = opts.initialized ~= false,
    parent_repo_path = opts.parent_repo_path,
    submodule_path = opts.submodule_path,
  }
end

function M.collect(root)
  root = vim.fs.normalize(root or uv.cwd())

  local repos = {}
  local seen = {}

  if is_git_repo(root) then
    table.insert(repos, repo_entry(root, nil, seen))
  end

  for name, kind in vim.fs.dir(root) do
    if kind == "directory" then
      local path = join(root, name)
      if is_git_repo(path) and not seen[vim.fs.normalize(path)] then
        table.insert(repos, repo_entry(path, nil, seen))
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

local function start_refresh_timer()
  if state.refresh_timer ~= nil then
    return
  end

  state.refresh_timer = assert(uv.new_timer())
  state.refresh_timer:start(60000, 60000, vim.schedule_wrap(function()
    reset_closed_handles()
    if not is_valid_tab(state.tabpage) or not is_valid_buf(state.sidebar_buf) then
      return
    end

    local repos = M.collect()
    local snapshot = repo_status_snapshot(repos)
    if snapshot ~= state.repo_snapshot then
      M.render(repos)
    end
  end))
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

current_branch = function(repo_path)
  local branch, err = run_git({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo_path)
  branch = trim(branch)

  if branch == "" or branch == "HEAD" then
    return nil, err ~= "" and err or "Detached HEAD cannot be pushed"
  end

  return branch, nil
end

configured_remote = function(repo_path, branch)
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

local function upstream_ref(repo_path)
  local upstream = run_git({ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, repo_path)
  upstream = trim(upstream)
  if upstream == "" then
    return nil
  end

  return upstream
end

local function remote_check_command(repo)
  if repo.initialized == false then
    return nil, nil
  end

  local repo_path = repo.path
  local branch, err = current_branch(repo_path)
  if not branch then
    return nil, err
  end

  local remote = configured_remote(repo_path, branch)
  if not remote then
    return nil, "No git remote configured for this repository"
  end

  return { "git", "fetch", "--quiet", "--prune", remote }, nil
end

local function push_command(repo_path)
  local branch, err = current_branch(repo_path)
  if not branch then
    return nil, nil, err
  end

  if upstream_ref(repo_path) then
    return { "git", "push" }, branch, nil
  end

  local remote = configured_remote(repo_path, branch)
  if not remote then
    return nil, branch, "No git remote configured for this repository"
  end

  return { "git", "push", "--set-upstream", remote, branch }, branch, nil
end

local function sync_command(repo)
  if repo.initialized == false then
    if repo.is_submodule and repo.parent_repo_path and repo.submodule_path then
      return {
        "git",
        "submodule",
        "update",
        "--init",
        "--recursive",
        "--",
        repo.submodule_path,
      }, repo.submodule_path, nil, repo.parent_repo_path
    end

    return nil, nil, "Submodule not initialized", nil
  end

  local repo_path = repo.path
  local branch, err = current_branch(repo_path)
  if not branch then
    return nil, nil, err, nil
  end

  if upstream_ref(repo_path) then
    return { "git", "pull", "--ff-only" }, branch, nil, repo_path
  end

  local remote = configured_remote(repo_path, branch)
  if not remote then
    return nil, branch, "No git remote configured for this repository", nil
  end

  return { "git", "fetch", "--prune", remote }, branch, nil, repo_path
end

local function queue_remote_check(repo, opts)
  if repo.initialized == false then
    set_repo_remote_state(repo.path, {
      checking = false,
      checked = false,
      error = false,
    })
    return
  end

  local remote_state = repo_remote_state(repo.path)
  if remote_state.checking then
    return
  end

  if remote_state.checked and not (opts and opts.force) then
    return
  end

  local args, err = remote_check_command(repo)
  if not args then
    if not err then
      return
    end
    set_repo_remote_state(repo.path, {
      checking = false,
      checked = false,
      error = err,
    })
    schedule_sidebar_refresh()
    return
  end

  set_repo_remote_state(repo.path, {
    checking = true,
    checked = false,
    error = false,
  })
  schedule_sidebar_refresh()

  run_system_async(args, {
    cwd = repo.path,
    text = true,
  }, function(result)
    if result.code ~= 0 then
      set_repo_remote_state(repo.path, {
        checking = false,
        checked = false,
        error = trim(result.stderr or result.stdout or "git fetch failed"),
      })
      schedule_sidebar_refresh()
      return
    end

    set_repo_remote_state(repo.path, {
      checking = false,
      checked = true,
      error = false,
    })
    schedule_sidebar_refresh()
  end)
end

local function queue_remote_checks(repos, opts)
  each_repo(repos, function(repo)
    queue_remote_check(repo, opts)
  end)
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
  return current_sidebar_item()
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
    "Select any repo item on the left to preview full details here.",
    "Select a repo action to sync, generate a commit message, commit, or push.",
    "",
    "Controls:",
    "  <CR> / o  open file diff or run action",
    "  <Tab>     expand or collapse",
    "  r         refresh status",
    "  q         close this Git tab",
  }

  return create_scratch_buffer("git-workspace://home", lines, nil, false)
end

local function split_text_lines(text)
  text = trim(text)
  if text == "" then
    return {}
  end

  return vim.split(text, "\n", { plain = true })
end

local function append_preview_section(lines, title, body_lines)
  if body_lines == nil or vim.tbl_isempty(body_lines) then
    return
  end

  if #lines > 0 and lines[#lines] ~= "" then
    table.insert(lines, "")
  end

  table.insert(lines, title)
  for _, line in ipairs(body_lines) do
    table.insert(lines, line)
  end
end

local function preview_buffer(lines)
  if is_valid_buf(state.preview_buf) then
    vim.bo[state.preview_buf].modifiable = true
    api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, lines)
    vim.bo[state.preview_buf].modifiable = false
    vim.bo[state.preview_buf].readonly = true
    vim.bo[state.preview_buf].filetype = ""
    return state.preview_buf
  end

  state.preview_buf = create_scratch_buffer("git-workspace://preview", lines, nil, false)
  return state.preview_buf
end

local function repo_preview_lines(repo)
  local lines = {
    "Path: " .. repo.path,
    "Branch: " .. (repo.branch or "(unknown)"),
    "Summary: " .. (repo.summary or "clean"),
  }

  if repo.is_submodule then
    table.insert(lines, "Submodule path: " .. (repo.submodule_path or repo_title(repo)))
  end

  if repo.initialized == false then
    append_preview_section(lines, "State", {
      "This submodule is not initialized.",
      "Run the Init action to execute git submodule update --init --recursive for it.",
    })
    return lines
  end

  local counts = repo.counts or {}
  append_preview_section(lines, "Working Tree", {
    string.format(
      "staged %d  unstaged %d  untracked %d  conflicts %d",
      counts.staged or 0,
      counts.unstaged or 0,
      counts.untracked or 0,
      counts.conflicts or 0
    ),
  })

  local push = repo.push or {}
  local remote_lines = {}
  if push.branch then
    table.insert(remote_lines, "Local branch: " .. push.branch)
  end
  if push.upstream then
    table.insert(remote_lines, "Upstream: " .. push.upstream)
  end
  if push.has_upstream then
    table.insert(remote_lines, string.format("Ahead %d  Behind %d", push.ahead or 0, push.behind or 0))
  elseif push.remote then
    table.insert(remote_lines, "Remote: " .. push.remote)
  end
  append_preview_section(lines, "Remote", remote_lines)

  if not vim.tbl_isempty(repo.submodules or {}) then
    local submodule_lines = {}
    for _, submodule in ipairs(repo.submodules or {}) do
      table.insert(submodule_lines, string.format("- %s  %s", repo_title(submodule), submodule.branch or "(unknown)"))
    end
    append_preview_section(lines, "Submodules", submodule_lines)
  end

  append_preview_section(lines, "Usage", {
    "Press <Tab> to expand or collapse.",
    "Press <CR> on a file to open its diff.",
    "Press <CR> on an action to run it.",
  })

  return lines
end

local function action_preview(repo, action_name)
  local title_prefix = ({
    sync = "Sync",
    push = "Push",
    commit = "Commit",
    generate_message = "Commit Message",
  })[action_name] or "Action"
  local title = title_prefix .. " · " .. repo_title(repo)
  local lines = repo_preview_lines(repo)
  local action_state = repo_action_state(repo.path)
  local remote_state = repo_remote_state(repo.path)

  if action_name == "sync" then
    local body = {}
    if repo.initialized == false then
      body = {
        "This action will initialize the submodule in the parent repository.",
        "It runs git submodule update --init --recursive for the selected submodule.",
      }
    else
      local push = repo.push or {}
      body = {
        push.has_upstream and "This action runs git pull --ff-only." or "This action fetches the configured remote.",
      }
      if push.has_upstream then
        table.insert(body, string.format("Behind %d  Ahead %d", push.behind or 0, push.ahead or 0))
      end
    end
    if remote_state.checking then
      table.insert(body, "Remote status check is in progress.")
    end
    append_preview_section(lines, "Action", body)
  elseif action_name == "push" then
    append_preview_section(lines, "Action", {
      "Push the current branch to its remote.",
      "If upstream is missing, gw will push with --set-upstream.",
    })
  elseif action_name == "commit" then
    append_preview_section(lines, "Action", {
      "Commit all current changes in this repository using the generated message below.",
    })
  elseif action_name == "generate_message" then
    append_preview_section(lines, "Action", {
      "Generate a Conventional Commit message from the current repository changes.",
    })
  end

  if action_state.busy then
    append_preview_section(lines, "Current Status", split_text_lines(action_state.busy))
  end
  if action_state.error then
    append_preview_section(lines, "Last Error", split_text_lines(action_state.error))
  end
  if action_state.commit_message then
    append_preview_section(lines, "Commit Message", split_text_lines(action_state.commit_message))
  elseif action_name == "commit" or action_name == "generate_message" then
    append_preview_section(lines, "Commit Message", { "No generated commit message yet." })
  end

  return title, lines, table.concat({
    "action",
    repo.path,
    action_name,
    tostring(action_state.busy or ""),
    tostring(action_state.error or ""),
    tostring(action_state.commit_message or ""),
    tostring(remote_state.checking or false),
    tostring(remote_state.checked or false),
  }, "\n")
end

local function status_preview(item)
  local repo = item.repo
  if repo == nil then
    return "Workspace Source Control", {
      item.status_text or item.status_title or "Status unavailable.",
    }, table.concat({
      "status",
      tostring(item.status_title or ""),
      tostring(item.status_text or ""),
    }, "\n")
  end

  local title = (item.status_title or "Status") .. " · " .. repo_title(repo)
  local lines = repo_preview_lines(repo)
  append_preview_section(lines, item.status_title or "Status", split_text_lines(item.status_text or ""))
  return title, lines, table.concat({
    "status",
    repo.path,
    tostring(item.status_title or ""),
    tostring(item.status_text or ""),
  }, "\n")
end

local function file_preview(item)
  local repo = item.repo
  local file = item.file
  local title = "File · " .. vim.fs.basename(file.path)
  local lines = {
    "Repository: " .. repo_title(repo),
    "Path: " .. file.path,
    "Status: [" .. file.code .. "] " .. diff_status_summary(file),
    "",
    "Press <CR> to open the unified diff for this file.",
  }

  if file.old_path then
    append_preview_section(lines, "Source", { file.old_path })
  end

  return title, lines, table.concat({
    "file",
    repo.path,
    file.path,
    file.code,
  }, "\n")
end

local function preview_for_item(item)
  if not item then
    return "Workspace Source Control", {
      "Select any repo, action, or file on the left to preview details here.",
    }, "home"
  end

  if item.kind == "repo" then
    return "Repository · " .. repo_title(item.repo), repo_preview_lines(item.repo), table.concat({
      "repo",
      item.repo.path,
      tostring(item.repo.summary or ""),
      tostring(item.repo.branch or ""),
    }, "\n")
  end

  if item.kind == "action" then
    return action_preview(item.repo, item.action)
  end

  if item.kind == "status" then
    return status_preview(item)
  end

  if item.kind == "file" then
    return file_preview(item)
  end

  return "Workspace Source Control", {
    "Select any repo, action, or file on the left to preview details here.",
  }, "home"
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
  map("<Tab>", M.toggle_selected, "Toggle selected Git repo")
  map("za", M.toggle_selected, "Toggle selected Git repo")
  map("r", function()
    M.refresh({ check_remote = true, force_remote_check = true })
  end, "Refresh Git panel")
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
  api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "WinEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      render_sidebar_status()
      render_sidebar_preview()
    end,
  })

  return buf
end

local function ensure_sidebar_status_buf()
  if is_valid_buf(state.sidebar_status_buf) then
    return state.sidebar_status_buf
  end

  local buf = api.nvim_create_buf(false, true)
  state.sidebar_status_buf = buf

  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "erwin-git-workspace-status"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

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

local function configure_sidebar_status_window(win)
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].spell = false
  vim.wo[win].winfixheight = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].statusline = ""
  vim.wo[win].winhighlight =
    "Normal:StatusLine,NormalNC:StatusLineNC,EndOfBuffer:StatusLine,WinSeparator:WinSeparator"
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

current_sidebar_item = function()
  reset_closed_handles()

  if not is_valid_win(state.sidebar_win) then
    return nil
  end

  local line = api.nvim_win_get_cursor(state.sidebar_win)[1]
  return state.line_items[line]
end

local function sidebar_status_lines()
  local item = current_sidebar_item()
  if item and item.kind == "file" and item.file and item.file.path then
    return { " Path: " .. item.file.path }
  end

  return { " Path: " }
end

render_sidebar_status = function()
  if not is_valid_buf(state.sidebar_status_buf) then
    return
  end

  vim.bo[state.sidebar_status_buf].modifiable = true
  api.nvim_buf_set_lines(state.sidebar_status_buf, 0, -1, false, sidebar_status_lines())
  vim.bo[state.sidebar_status_buf].modifiable = false
end

render_sidebar_preview = function()
  if not is_valid_tab(state.tabpage) then
    return
  end

  local win = in_git_tab(state.main_win) and state.main_win or main_wins()[1]
  if not win then
    return
  end

  local item = current_sidebar_item()
  if item and item.kind == "file" and state.current_diff ~= nil then
    local current = state.current_diff
    if current.repo_path == item.repo.path and current.file_path == item.file.path and is_valid_buf(current.buf) then
      return
    end
  end

  local title, body_lines, signature = preview_for_item(item)
  if signature == state.preview_signature and is_valid_buf(state.preview_buf) and api.nvim_win_get_buf(win) == state.preview_buf then
    return
  end

  close_extra_main_windows(win)
  state.main_win = win
  state.current_diff = nil
  state.preview_signature = signature

  local lines = { title, "" }
  vim.list_extend(lines, body_lines or {})

  local buf = preview_buffer(lines)
  api.nvim_win_set_buf(win, buf)
  configure_main_window(win)
  api.nvim_buf_clear_namespace(buf, diff_namespace, 0, -1)
  api.nvim_buf_add_highlight(buf, diff_namespace, "Title", 0, 0, -1)
end

local function attach_sidebar_status()
  local buf = ensure_sidebar_status_buf()

  if is_valid_win(state.sidebar_status_win) then
    api.nvim_win_set_buf(state.sidebar_status_win, buf)
    render_sidebar_status()
    return
  end

  state.sidebar_status_win = api.nvim_open_win(buf, false, {
    split = "below",
    win = state.sidebar_win,
    height = 2,
  })

  configure_sidebar_status_window(state.sidebar_status_win)
  render_sidebar_status()
end

local function add_sidebar_line(lines, item, text)
  table.insert(lines, text)
  if item then
    state.line_items[#lines] = item
  end
end

local function repo_header_indent(depth)
  return " " .. string.rep("  ", depth or 0)
end

local function repo_content_indent(depth)
  return "   " .. string.rep("  ", depth or 0)
end

local function render_repo_files(lines, repo, depth)
  local indent = repo_content_indent(depth)
  for _, file in ipairs(repo.files or {}) do
    add_sidebar_line(lines, {
      kind = "file",
      repo = repo,
      file = file,
      focus_target = "file:" .. file.path,
    }, string.format("%s[%s] %s", indent, file.code, vim.fs.basename(file.path)))
  end
end

local function render_repo_actions(lines, repo, depth)
  local action_state = repo_action_state(repo.path)
  local remote_state = repo_remote_state(repo.path)
  local indent = repo_content_indent(depth)
  local has_changes = repo.initialized ~= false and not vim.tbl_isempty(repo.files)
  local message = action_state.commit_message
  local show_push = repo.initialized ~= false and repo.push and repo.push.push_available
  local push_branch = repo.push and repo.push.branch or trim(repo.branch)
  local behind = repo.initialized ~= false and repo.push and repo.push.behind or 0
  local sync_suffix = ""

  if remote_state.checking then
    sync_suffix = "  …"
  elseif remote_state.checked and behind > 0 then
    sync_suffix = "  ↓" .. behind
  end

  if action_state.busy then
    add_sidebar_line(lines, {
      kind = "status",
      repo = repo,
      focus_target = action_state.busy_focus or "busy",
      highlight = "Comment",
      status_title = "Current Status",
      status_text = action_state.busy,
    }, indent .. "… " .. shorten(action_state.busy, 28))
  end

  if action_state.error then
    add_sidebar_line(lines, {
      kind = "status",
      repo = repo,
      highlight = "DiagnosticError",
      status_title = "Last Error",
      status_text = action_state.error,
    }, indent .. "! " .. shorten(action_state.error, 28))
  end

  add_sidebar_line(lines, {
    kind = "action",
    repo = repo,
    action = "sync",
    focus_target = "sync",
    highlight = "Special",
  }, indent .. "[ " .. (repo.initialized == false and "Init" or "Sync") .. " ]" .. sync_suffix)

  if repo.initialized == false then
    add_sidebar_line(lines, {
      kind = "status",
      repo = repo,
      highlight = "Comment",
      status_title = "State",
      status_text = repo.summary,
    }, indent .. shorten(repo.summary, 28))
    return
  end

  if show_push then
    add_sidebar_line(lines, {
      kind = "action",
      repo = repo,
      action = "push",
      focus_target = "push",
      highlight = "Identifier",
    }, indent .. "[ Push " .. shorten(push_branch, 18) .. " ]")
  end

  if message and has_changes then
    add_sidebar_line(lines, {
      kind = "action",
      repo = repo,
      action = "commit",
      focus_target = "commit",
      highlight = "DiffAdd",
    }, indent .. "[ Commit staged changes ]")
  end

  if message then
    add_sidebar_line(lines, {
      kind = "status",
      repo = repo,
      focus_target = "message",
      highlight = "String",
      status_title = "Commit Message",
      status_text = message,
    }, indent .. "• Commit message ready")
  end

  if has_changes and action_state.busy_focus ~= "busy_generate_message" then
    add_sidebar_line(lines, {
      kind = "action",
      repo = repo,
      action = "generate_message",
      focus_target = "generate_message",
      highlight = "Function",
    }, indent .. "[ " .. (message and "Regenerate" or "Generate") .. " commit message ]")
  end
end

local function render_repo_block(lines, repo, depth)
  depth = depth or 0

  local expanded = state.repo_expanded[repo.path]
  if expanded == nil then
    expanded = depth == 0
    state.repo_expanded[repo.path] = expanded
  end

  local label = repo_title(repo)
  if depth > 0 then
    label = "↳ " .. label
  end

  add_sidebar_line(lines, {
    kind = "repo",
    repo = repo,
    focus_target = "repo",
  }, string.format("%s%s %s  %s", repo_header_indent(depth), expanded and "▾" or "▸", label, repo.branch))

  if expanded then
    render_repo_actions(lines, repo, depth)

    for _, submodule in ipairs(repo.submodules or {}) do
      render_repo_block(lines, submodule, depth + 1)
    end

    if vim.tbl_isempty(repo.files) and vim.tbl_isempty(repo.submodules or {}) then
      add_sidebar_line(lines, {
        kind = "status",
        repo = repo,
        highlight = "Comment",
        status_title = "Status",
        status_text = "No changes",
      }, repo_content_indent(depth) .. "No changes")
    elseif not vim.tbl_isempty(repo.files) then
      render_repo_files(lines, repo, depth)
    end
  end

  table.insert(lines, "")
end

function M.render(repos)
  reset_closed_handles()

  if not is_valid_buf(state.sidebar_buf) then
    return
  end

  repos = repos or M.collect()
  state.repo_snapshot = repo_status_snapshot(repos)
  local lines = {
    " Source Control",
    "",
  }

  state.line_items = {}

  if vim.tbl_isempty(repos) then
    table.insert(lines, "  No Git repositories found")
  end

  for _, repo in ipairs(repos) do
    render_repo_block(lines, repo, 0)
  end

  table.insert(lines, "  <CR> open/run   <Tab> toggle repo")
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

  render_sidebar_status()
  render_sidebar_preview()
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
  state.preview_signature = "home"
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
  state.preview_signature = nil

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
  local title = repo_title(repo)
  local action_state = repo_action_state(repo.path)
  if action_state.busy then
    notify_result("Git action already running for " .. title, vim.log.levels.WARN)
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
        notify_result("Failed to generate commit message for " .. title, vim.log.levels.ERROR)
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
      set_sidebar_focus(repo.path, "message")
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
      notify_result("No changes to commit in " .. title, vim.log.levels.WARN)
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
        notify_result("git add failed for " .. title, vim.log.levels.ERROR)
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
          notify_result("git commit failed for " .. title, vim.log.levels.ERROR)
          schedule_sidebar_refresh()
          return
        end

      local sha = run_git({ "git", "rev-parse", "--short", "HEAD" }, repo.path) or ""
      set_repo_action_state(repo.path, {
        busy = false,
        busy_focus = false,
        commit_message = false,
        error = false,
        info = false,
        last_commit_sha = trim(sha),
      })
      set_sidebar_focus(repo.path, "push")
        show_action_output(
          "Commit Result · " .. title,
          vim.split(trim(commit_result.stdout or "Commit created"), "\n", { trimempty = true }),
          ""
        )
        schedule_sidebar_refresh()
      end)
    end)
    return
  end

  if action_name == "sync" then
    local args, branch, err, action_cwd = sync_command(repo)
    if not args then
      set_repo_action_state(repo.path, {
        error = err,
      })
      set_sidebar_focus(repo.path, "sync")
      notify_result(err, vim.log.levels.ERROR)
      schedule_sidebar_refresh()
      return
    end

    set_repo_action_state(repo.path, {
      busy = repo.initialized == false and ("Initializing submodule " .. title .. "...") or ("Syncing branch " .. branch .. "..."),
      busy_focus = "busy_sync",
      error = false,
      info = false,
    })
    set_sidebar_focus(repo.path, "busy_sync")
    schedule_sidebar_refresh()

    run_system_async(args, {
      cwd = action_cwd or repo.path,
      text = true,
    }, function(sync_result)
      if sync_result.code ~= 0 then
        set_repo_action_state(repo.path, {
          busy = false,
          busy_focus = false,
          error = trim(sync_result.stderr or sync_result.stdout or "git sync failed"),
        })
        set_sidebar_focus(repo.path, "sync")
        notify_result("git sync failed for " .. title, vim.log.levels.ERROR)
        schedule_sidebar_refresh()
        return
      end

      set_repo_action_state(repo.path, {
        busy = false,
        busy_focus = false,
        error = false,
        info = false,
      })
      set_repo_remote_state(repo.path, {
        checking = false,
        checked = true,
        error = false,
      })
      set_sidebar_focus(repo.path, "sync")
      restore_placeholder_view()
      schedule_sidebar_refresh()
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
        })
        set_sidebar_focus(repo.path, "push")
        notify_result("git push failed for " .. title, vim.log.levels.ERROR)
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

local function read_file_lines(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, lines
  end

  return lines
end

local function parse_diff_blocks(raw_lines)
  local blocks = {}
  local current

  for _, line in ipairs(raw_lines) do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      current = {
        old_start = tonumber(old_start) or 0,
        old_count = old_count == "" and 1 or tonumber(old_count) or 0,
        new_start = tonumber(new_start) or 0,
        new_count = new_count == "" and 1 or tonumber(new_count) or 0,
        ops = {},
      }
      table.insert(blocks, current)
    elseif current ~= nil then
      local prefix = line:sub(1, 1)
      if prefix == "+" or prefix == "-" or prefix == " " then
        table.insert(current.ops, {
          kind = prefix,
          text = line:sub(2),
        })
      end
    end
  end

  return blocks
end

local function build_diff_view(repo, file, raw_lines)
  local lines = {}
  local highlights = {}
  local hunks = {}
  local scrollbar_marks = {}
  local line_map = {}
  local diff_blocks = parse_diff_blocks(raw_lines)

  local function add_line(text, group, scrollbar_type, source_line)
    table.insert(lines, text)
    local line_number = #lines

    if source_line ~= nil then
      line_map[line_number] = source_line
    end

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
    if line:match("^Binary files ") then
      add_line("Binary file changed", "Comment")
      return {
        lines = lines,
        highlights = highlights,
        hunks = hunks,
        scrollbar_marks = scrollbar_marks,
        line_map = line_map,
      }
    end
  end

  local current_lines = {}
  if not file.deleted then
    local path = join(repo.path, file.path)
    local read_result, read_err = read_file_lines(path)
    if read_result == nil then
      add_line("Unable to read file contents.", "Comment")
      add_line(tostring(read_err), "DiagnosticError")
      return {
        lines = lines,
        highlights = highlights,
        hunks = hunks,
        scrollbar_marks = scrollbar_marks,
        line_map = line_map,
      }
    end
    current_lines = read_result
  end

  if #diff_blocks == 0 then
    if file.deleted then
      add_line("No textual diff available.", "Comment")
    else
      for index, line in ipairs(current_lines) do
        add_line(line, nil, nil, index)
      end
    end
    return {
      lines = lines,
      highlights = highlights,
      hunks = hunks,
      scrollbar_marks = scrollbar_marks,
      line_map = line_map,
    }
  end

  local current_index = 1

  for _, block in ipairs(diff_blocks) do
    local block_start = math.max(block.new_start, 1)

    while not file.deleted and current_index < block_start and current_index <= #current_lines do
      add_line(current_lines[current_index], nil, nil, current_index)
      current_index = current_index + 1
    end

    local hunk_anchor
    for _, op in ipairs(block.ops) do
      if op.kind == "-" then
        local source_line = not file.deleted and current_index or nil
        local line_number = add_line(op.text, "DiffDelete", "GitDelete", source_line)
        hunk_anchor = hunk_anchor or line_number
      elseif op.kind == "+" then
        local text = file.deleted and op.text or (current_lines[current_index] or op.text)
        local source_line = not file.deleted and current_index or nil
        local line_number = add_line(text, "DiffAdd", "GitAdd", source_line)
        hunk_anchor = hunk_anchor or line_number
        if not file.deleted then
          current_index = current_index + 1
        end
      elseif op.kind == " " then
        local text = file.deleted and op.text or (current_lines[current_index] or op.text)
        add_line(text, nil, nil, not file.deleted and current_index or nil)
        if not file.deleted then
          current_index = current_index + 1
        end
      end
    end

    if hunk_anchor then
      table.insert(hunks, hunk_anchor)
    end
  end

  while not file.deleted and current_index <= #current_lines do
    add_line(current_lines[current_index], nil, nil, current_index)
    current_index = current_index + 1
  end

  if #lines == 0 then
    add_line("No textual diff available.", "Comment")
  end

  return {
    lines = lines,
    highlights = highlights,
    hunks = hunks,
    scrollbar_marks = scrollbar_marks,
    line_map = line_map,
  }
end

local function current_diff_absolute_path(repo, file)
  if not repo or not file or file.deleted then
    return nil
  end

  if not file.path or file.path == "" then
    return nil
  end

  return join(repo.path, file.path)
end

function M.goto_definition()
  reset_closed_handles()

  if not is_valid_tab(state.tabpage) or api.nvim_get_current_tabpage() ~= state.tabpage then
    vim.lsp.buf.definition()
    return
  end

  local current = state.current_diff
  if current == nil or not is_valid_buf(current.buf) or not in_git_tab(current.win) then
    state.current_diff = nil
    vim.lsp.buf.definition()
    return
  end

  if api.nvim_get_current_win() ~= current.win or api.nvim_get_current_buf() ~= current.buf then
    vim.lsp.buf.definition()
    return
  end

  if not current.absolute_path then
    vim.notify("Cannot jump to definition for this diff entry", vim.log.levels.WARN)
    return
  end

  local diff_cursor = api.nvim_win_get_cursor(current.win)
  local source_line = current.line_map and current.line_map[diff_cursor[1]] or diff_cursor[1]
  local source_cursor = {
    math.max(source_line or 1, 1),
    diff_cursor[2],
  }

  require("config.code_navigation").goto_definition_from({
    path = current.absolute_path,
    cursor = source_cursor,
    workspace_root = current.repo_path,
    return_location = {
      tabpage = state.tabpage,
      win = current.win,
      buf = current.buf,
      cursor = diff_cursor,
    },
  })
end

local function apply_diff_mappings(buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      desc = desc,
      nowait = true,
      silent = true,
    })
  end

  map("gd", M.goto_definition, "Go to definition from Git diff")
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
      "--unified=0",
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
    "--unified=0",
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
    diff_view = build_diff_view(repo, file, diff_lines(output))
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
  apply_diff_mappings(buf)
  configure_main_window(win)
  apply_diff_highlights(buf, diff_view)
  apply_diff_scrollbar_marks(buf, win, diff_view)

  state.current_diff = {
    absolute_path = current_diff_absolute_path(repo, file),
    file_path = file.path,
    buf = buf,
    hunks = diff_view.hunks,
    line_map = diff_view.line_map,
    repo_path = repo.path,
    win = win,
  }
  state.preview_signature = nil
  api.nvim_set_current_win(win)
  if diff_view.hunks and diff_view.hunks[1] then
    api.nvim_win_set_cursor(win, { diff_view.hunks[1], 0 })
    window_call(win, function()
      vim.cmd("normal! zz")
    end)
  else
    api.nvim_win_set_cursor(win, { 1, 0 })
  end
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
end

function M.open_selected()
  local item = selected_item()
  if not item then
    return
  end

  if item.kind == "repo" then
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

function M.refresh(opts)
  if not is_valid_tab(state.tabpage) then
    return
  end

  local repos = M.collect()
  M.render(repos)

  if opts and opts.check_remote then
    queue_remote_checks(repos, {
      force = opts.force_remote_check,
    })
  end
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
  state.sidebar_status_win = nil
  state.main_win = nil
  state.current_diff = nil
  state.repo_snapshot = nil
  state.preview_buf = nil
  state.preview_signature = nil
  stop_refresh_timer()

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
    if is_valid_win(state.sidebar_win) and is_valid_win(state.sidebar_status_win) then
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
  attach_sidebar_status()
  M.render()
  focus_sidebar()
end

function M.open()
  ensure_layout()
  M.refresh({ check_remote = true, force_remote_check = true })
  start_refresh_timer()
end

api.nvim_create_autocmd("TabClosed", {
  group = group,
  callback = function()
    vim.schedule(reset_closed_handles)
  end,
})

return M
