# oil-redis.nvim

Browse and edit Redis keys inside [oil.nvim](https://github.com/stevearc/oil.nvim) — your keyspace as a file system.

Key namespaces (conventional `:` separators) become directories; leaf keys become editable files. All five Redis value types are supported for both reading and writing.

```
oil-redis://localhost:6379/0/        ← db 0 root
  user:                              ← namespace  (directory)
    123                              ← string key (file)
    456
    123:                             ← sub-namespace
      profile                        ← hash key
      sessions                       ← list key
  session:
    abc123                           ← string key
```

---

## Requirements

| Dependency | Version |
|---|---|
| Neovim | ≥ 0.10 |
| [oil.nvim](https://github.com/stevearc/oil.nvim) | any recent |
| `redis-cli` | on `$PATH` |

---

## Installation

### vim.pack.add (Neovim built-in, ≥ 0.11)

```lua
vim.pack.add("aaronshahriari/oil-redis")
```

Then register the adapter in your oil setup (see [Configuration](#configuration)).

### lazy.nvim

```lua
{
  "aaronshahriari/oil-redis",
  dependencies = { "stevearc/oil.nvim" },
}
```

### rocks.nvim / other managers

The plugin has no build step and no external Lua dependencies — any package
manager that clones the repo will work.

---

## Configuration

Add the adapter to your existing oil.nvim setup:

```lua
require("oil").setup({
  adapters = {
    ["oil-redis://"] = "redis",
  },
  -- rest of your oil config ...
})
```

Oil resolves adapters by requiring `oil.adapters.<name>`, so the value is the
string `"redis"` — the plugin exposes itself at that path automatically.

That's it. No other configuration is required.

---

## Usage

### Opening a connection

```vim
:e oil-redis://localhost:6379/0/
```

Or from Lua:

```lua
require("oil").open("oil-redis://localhost:6379/0/")
```

Bind it to a key:

```lua
vim.keymap.set("n", "<leader>rr", function()
  require("oil").open("oil-redis://localhost:6379/0/")
end)
```

### Navigation

oil-redis uses the exact same keybindings as oil.nvim — there is nothing new
to learn:

| Key | Action |
|---|---|
| `Enter` | enter namespace / open key value |
| `-` | go up to parent namespace |
| `d` | mark for deletion (`DEL`) |
| `r` | rename / move (`RENAME`) |
| `yy` | copy (`COPY`) |
| `:w` | commit pending actions |
| `g?` | show all oil keybindings |

### Editing values

Press `Enter` on any leaf key to open its value in a normal Neovim buffer.
Edit freely, then `:w` to write back to Redis.

Each Redis type is displayed in a human-readable format:

| Type | Display format | Edit rules |
|---|---|---|
| **string** | raw value, one line per `\n` in value | edit freely |
| **hash** | `field: value` per line | add/remove/edit `field: value` lines |
| **list** | one element per line, in order | reorder or add/remove lines |
| **set** | one member per line | add/remove lines |
| **zset** | `member score` per line | edit member or score |

### Creating keys

`o` (new file) creates a key with an empty string value.
`O` (new directory) is a no-op — Redis has no empty namespaces; a namespace
appears automatically once a key is created inside it.

### Multiple servers / databases

Every URL is independent — open as many as you like simultaneously:

```vim
:e oil-redis://prod.internal:6379/0/
:e oil-redis://localhost:6380/1/user:
```

---

## Authentication

### Embed credentials in the URL

```vim
" Password only (classic Redis AUTH)
:e oil-redis://:mysecret@localhost:6379/0/

" Username + password (Redis ≥ 6 ACL)
:e oil-redis://alice:mysecret@localhost:6379/0/
```

### Environment variable (recommended for sensitive environments)

```sh
REDISCLI_AUTH=mysecret nvim
```

The adapter always passes `--no-auth-warning` to `redis-cli`, so no warning
leaks into the UI either way.

> **Security note:** passwords embedded in URLs appear in `:ls`, `:buffers`,
> and Neovim's buffer list. Prefer the environment variable for production
> credentials.

---

## How it works

The adapter is a thin shim between oil.nvim's adapter interface and
`redis-cli`. It spawns `redis-cli --raw` subprocesses asynchronously using
`vim.fn.jobstart` and translates between oil's directory/file model and
Redis's flat keyspace:

- **Listing** (`SCAN` + cursor loop) — iterates the full cursor cycle so all
  keys are collected, even on large keyspaces.
- **Navigation** — the first `:` after the current prefix determines the next
  directory boundary. Keys and namespaces that share the same prefix
  (e.g., `user:123` and `user:123:sessions`) treat the namespace as the
  directory entry.
- **Writes** — type-aware: `SET` for strings, `DEL`+`HSET` for hashes,
  `DEL`+`RPUSH` for lists, `DEL`+`SADD` for sets, `DEL`+`ZADD` for sorted
  sets.
- **Copy** — uses `COPY` (Redis ≥ 6.2) with a `DUMP`/`RESTORE` fallback for
  older servers.
- **Delete namespace** — `SCAN prefix* + DEL` (not atomic; avoid on extremely
  hot keyspaces).

---

## Limitations

- Key values that contain literal newlines display incorrectly in hash, list,
  set, and sorted-set views. String values with embedded newlines are fine.
- Namespace deletion is not atomic (`SCAN` + bulk `DEL`).
- `COPY` fallback via `DUMP`/`RESTORE` does not preserve TTL.
- Redis Cluster is not supported.
- Sorted-set member names cannot contain spaces (they are parsed on whitespace
  to split member from score).
