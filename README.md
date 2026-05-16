# redis.nvim

A native Neovim Redis browser. Browse keys, filter by pattern, and view/edit values — all without leaving your editor.

```
┌─ keys ──────────────────────────────────────────┐  ┌─ viewer ─────────────────────────────────────┐
│  redis-nvim │ local 6379/db0 │ rjbank_kb_v1:* │  │  rjbank_kb_v1:abc123 │ string │ ttl: 3600   │
│  [f]filter  [R]reload  [c]conn  [a]add          │  │  [e]edit  [q]close                           │
├─────────────────────────────────────────────────┤  ├──────────────────────────────────────────────┤
│  rjbank_kb_v1:abc123                            │  │  {                                           │
│  rjbank_kb_v1:def456                            │  │    "user": "aaron",                          │
│  rjbank_kb_v1:ghi789                            │  │    "score": 99                               │
│  ── load more ──                                │  │  }                                           │
└─────────────────────────────────────────────────┘  └──────────────────────────────────────────────┘
```

## Requirements

- Neovim ≥ 0.10
- `redis-cli` on `$PATH`
- `jq` on `$PATH` _(optional — used for JSON pretty-printing)_

## Installation

**vim.pack.add** (Neovim ≥ 0.11)
```lua
vim.pack.add("aaronshahriari/redis.nvim")
```

**lazy.nvim**
```lua
{ "aaronshahriari/redis.nvim" }
```

Then call setup somewhere in your config (required, even with no options):
```lua
require("redis-nvim").setup()
```

## Usage

### Open the browser

```vim
:Redis
:Redis myconn        " open and switch to a named connection
```

Or bind it:
```lua
vim.keymap.set("n", "<leader>rd", "<cmd>Redis<cr>")
```

### First run — add a connection

Press `a` in the keys pane and follow the prompts:

```
Name:     local
Host:     localhost
Port:     6379
DB:       0
Password: (blank for none)
```

Connections are saved to `~/.local/share/nvim/redis-nvim/connections.json`.

### Key browser

| Key | Action |
|-----|--------|
| `<CR>` | Open key value in viewer / trigger load-more |
| `f` | Set filter pattern (glob, e.g. `user:*`) |
| `R` | Reload from scratch |
| `c` | Pick a different connection |
| `a` | Add a new connection |
| `dd` | Delete key under cursor |

### Value viewer

| Key | Action |
|-----|--------|
| `e` | Enter edit mode |
| `:w` | Save edits back to Redis |
| `u` | Undo edits |
| `q` | Close viewer |

JSON string values are auto pretty-printed if `jq` is available.

### Value formats by type

| Redis type | Format shown in viewer |
|------------|------------------------|
| string | raw value (JSON pretty-printed if valid) |
| hash | `field: value` per line |
| list | one element per line |
| set | one member per line |
| zset | `member score` per line |

Edit in these formats and `:w` — the plugin writes back using the correct Redis command.

## Auth

```vim
:Redis              " prompts via 'a' → add connection with password field
```

Passwords are stored in the connections JSON file (`chmod 600` recommended).
Alternatively set `REDISCLI_AUTH` in your environment before starting Neovim.

## Configuration

```lua
require("redis-nvim").setup({
  page_size     = 200,   -- keys per SCAN batch
  key_win_width = 55,    -- width of the key browser pane
  keymaps = {
    select    = "<CR>",
    filter    = "f",
    reload    = "R",
    delete    = "dd",
    conn_pick = "c",
    conn_add  = "a",
    edit      = "e",
    close     = "q",
  },
})
```

## How it works

- Keys are loaded via Redis `SCAN` in batches (`page_size` per page). Press `<CR>` on `── load more ──` to fetch the next batch.
- Viewing a key fetches `TYPE` and `TTL` concurrently, then fetches the value with the type-appropriate command (`GET`, `HGETALL`, `LRANGE`, `SMEMBERS`, `ZRANGE WITHSCORES`).
- Editing writes back with `SET` / `DEL`+`HSET` / `DEL`+`RPUSH` / `DEL`+`SADD` / `DEL`+`ZADD` depending on type.
- All Redis I/O is async via `vim.fn.jobstart`.

## Limitations

- Hash/list/set/zset values containing newlines will not parse correctly on write-back.
- No cluster support.
- Sorted-set member names cannot contain spaces.
