# snipe.nvim

Minimal, **async** AI for Neovim. Leave the AI working on a task, always know
what it's doing, and ask quick questions about your project. No dependencies
beyond `curl`.

Built around one idea: reach for the AI when you feel friction, nothing more.
It never blocks the editor — everything runs through `vim.system` + `curl` with
streaming SSE.

## Features

- **Async tasks** — give the AI a task (`complete this function`, `write tests
  for foo`) and keep working. It runs in the background.
- **Always know what it's doing** — the model streams `<status>…</status>
  updates in real time; see them in the panel, its log buffer, and your
  statusline.
- **Agent loop** — the model can request files it needs via `<read>`, gets their
  contents, and keeps going (bounded rounds), so "write tests for X" actually
  reads X first.
- **Diffs** — results come back as unified diffs. Default is *review then
  apply*; use `--auto` for fire-and-forget. Edits are applied to real buffers
  (undo works) and can be reverted.
- **Minimal Q&A** — `:SnipeAsk` opens one small input, streams the answer into
  a floating window. Close it and keep working.
- **LSP integration** — context includes diagnostics, the symbol under your
  cursor, modified files (git) and project files. After applying edits it runs
  LSP formatting and refreshes diagnostics.
- **OpenAI-compatible** — works with OpenAI, Ollama, LM Studio, vLLM… just
  change `base_url` + `model`.

## Install

```lua
-- lazy.nvim
{ "luisfer-cli/snipe.nvim", opts = {} }
```

## Setup

```lua
require("snipe").setup({
  provider = { name = "openai" }, -- "openai" | "openrouter" | "ollama" | "lmstudio" | { base_url=..., model=..., api_key=... }
  tasks = { apply = "confirm" },  -- "confirm" | "auto"
})
```

API keys, in priority order: explicit `api_key` in the config, then a provider
environment variable (`OPENROUTER_API_KEY`, `OPENAI_API_KEY`, …), then the key
stored with `:SnipeAuth`.

```vim
:SnipeAuth            " prompt and store the API key for the current provider
:SnipeAuth openrouter " ... or for a specific provider
```

Stored keys live in `~/.config/snipe/key` (chmod 600). The `openrouter` preset
points at `https://openrouter.ai/api/v1` with model `deepseek/deepseek-v4-flash`
and sends the standard `HTTP-Referer` / `X-Title` headers.

## Commands

| Command | Action |
| --- | --- |
| `:Snipe` / `:SnipePanel` | Toggle/open the task panel |
| `:SnipeTask <prompt>` | Start an async task (default apply mode = `confirm`) |
| `:SnipeTask --auto <prompt>` | Start a task and auto-apply its edits |
| `:SnipeAsk <question>` | Ask a question about the project (async) |
| `:SnipeKill [id]` | Kill the running task (or one by id) |
| `:SnipeApply [id]` | Apply pending edits |
| `:SnipeRevert [id]` | Revert applied edits |
| `:SnipeAuth [provider]` | Store the API key locally (chmod 600) |
| `:SnipeAuthRemove [provider]` | Remove the stored API key |

## Suggested keymaps

```lua
vim.keymap.set("n", "<leader>ap", require("snipe").panel_toggle)
vim.keymap.set("n", "<leader>aa", function() require("snipe").ask() end)
vim.keymap.set("n", "<leader>at", function() require("snipe").task("") end)
```

## Statusline

```lua
-- lualine
{ function() return require("snipe").statusline() end }
```

Shows `⚡1`, `✋2`, `⋯1` plus the current status message while running. The
panel shows the full picture.

## Panel keys

| Key | Action |
| --- | --- |
| `j` / `k` | move |
| `<cr>` | apply pending edits |
| `o` | open the task log in a split |
| `x` | kill running task |
| `d` | dismiss task |
| `q` / `<esc>` | close |

## License

MIT
