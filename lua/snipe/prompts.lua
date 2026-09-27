local M = {}

---System prompt for autonomous task execution.
---@return string
local function task_system()
  return [[You are snipe, an autonomous AI coding assistant running inside Neovim.
You have been given ONE specific task. Work on it independently and asynchronously, then report when done.

Work in visible steps. At the start of each step emit a <status>...</status> block with one short
present-tense sentence describing exactly what you are doing right now, e.g.
<status>Reading the existing test suite for patterns</status>
Emit a new <status> whenever you switch to a different step (reading, planning, editing, verifying).

If you need to see a file that was not included in the context, request it with:
<read file="relative/path/from/project/root">
You will receive its contents in the next turn. Request files in batches; stop as soon as you have enough.

To modify code, emit one or more unified diff blocks, one per file:
<diff file="relative/path/from/project/root">
--- a/relative/path
+++ b/relative/path
@@ -start,count +start,count @@
  context line
-removed line
+added line
</diff>
The diff is applied against the file's current content, so your hunk context MUST match the real file.
Only include the hunks you actually need; never dump entire files.

When your task is finished, stop. Do not emit <status> or <read> anymore.
If your task is research, explanation, or report-only, reply as concise plain text and emit no diffs.

Rules:
- Never invent files or content; use only what is in the context or what you read.
- Keep changes minimal, consistent with the existing code style and surrounding code.
- Prefer safe, working edits over ambitious rewrites.
- If a requested change is risky or impossible, say so in plain text instead of guessing.
]]
end

---System prompt for quick questions about the project.
---@return string
local function ask_system()
  return [[You are snipe, an AI assistant embedded in Neovim, answering a question about the user's codebase.
Be concise and direct. Use markdown for code snippets.
Do not emit <diff> or <read> blocks unless the user explicitly asks you to change code.
If you need more context that is not provided, answer from what you have and note the assumption.]]
end

---@param kind string "task" | "ask"
function M.system(kind)
  if kind == "ask" then
    return ask_system()
  end
  return task_system()
end

---Build the initial user message: context + instruction.
---@param task table
function M.user_message(task)
  local ctx = task.ctx
  local lines = {}
  table.insert(lines, "=== PROJECT CONTEXT ===")
  table.insert(lines, ctx.text)
  table.insert(lines, "")
  if task.kind == "ask" then
    table.insert(lines, "=== QUESTION ===")
    table.insert(lines, task.prompt)
  else
    table.insert(lines, "=== TASK ===")
    table.insert(lines, task.prompt)
    table.insert(lines, "")
    table.insert(
      lines,
      "Start now. Emit <status> as you work, <read> when you need files, and <diff> blocks with the final edits when done."
    )
  end
  return table.concat(lines, "\n")
end

---Build the follow-up user message with the contents of requested files.
---@param task table
---@param files string[]
---@return string
function M.read_message(task, files)
  local context = require("snipe.context")
  local config = require("snipe.config")
  local root = task.ctx.root

  local parts = {}
  local skipped = {}
  for _, rel in ipairs(files) do
    if rel:match("^%.%.%/") or rel:match("^/") or rel:match(":") then
      table.insert(skipped, rel)
      goto continue
    end
    local abs = vim.fs.joinpath(root, rel)
    local lines = context.read_file_lines(abs, config.options.context.max_file_chars)
    if lines then
      local text = table.concat(lines, "\n")
      if #text > config.options.context.max_file_chars then
        text = text:sub(1, config.options.context.max_file_chars) .. "\n... [truncated]"
      end
      local ft = vim.filetype.match({ filename = rel }) or ""
      table.insert(parts, ("=== %s ===\n```%s\n%s\n```"):format(rel, ft, text))
    else
      table.insert(skipped, rel)
    end
    ::continue::
  end

  if #parts == 0 then
    return "None of the requested files could be read."
  end

  local msg = table.concat(parts, "\n\n")
  if #skipped > 0 then
    msg = msg .. ("\n\nCould not read: %s"):format(table.concat(skipped, ", "))
  end
  return msg
    .. "\n\nContinue your task now. If you still need files, request them again with <read>. "
    .. "Otherwise stop requesting and produce the final result."
end

return M
