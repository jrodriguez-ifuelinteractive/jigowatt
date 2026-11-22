# Jigowatt

A small native macOS app for keeping a list of SSH machines and opening them in tabs. Terminals are rendered by [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty). It also ships an [MCP](https://modelcontextprotocol.io) server, so coding agents can work on the hosts you allow, in Jigowatt tabs you can watch.

## Features

- **Uses the system `/usr/bin/ssh`.** `~/.ssh/config`, ssh-agent / 1Password agent, keys and `known_hosts` behave as they do in a normal shell.
- **Passwords live in the macOS Keychain.** They reach ssh through `SSH_ASKPASS` and never appear in arguments or files.
- **Your Ghostty look.** Terminal appearance comes from `~/.config/ghostty/config` (can be turned off in Settings). **Settings → Terminal → Theme** picks from Ghostty's ~650 bundled themes or your own in `~/.config/ghostty/themes/`, with an optional separate Light Mode theme. Changes apply live.
- **Agent access over MCP**, opt-in per host and fully logged. The agent works in its own visible tab per host.
- **Lives in the menu bar.** Closing the window keeps Jigowatt (and its sessions) running in the menu bar without a Dock icon. Turn this off in **Settings → Agent (MCP)**.

## Requirements

- macOS 14 or later
- Xcode, with the license accepted and the Metal Toolchain installed (`xcodebuild -downloadComponent MetalToolchain`)
- Zig **0.16.x** (Ghostty pins the exact minor version). The build looks in `.tools/zig/zig` first, then on `PATH`.

`DEVELOPER_DIR` defaults to `/Applications/Xcode.app/Contents/Developer`, so `xcode-select` can keep pointing at the Command Line Tools.

## Build

```bash
make ghostty   # clone vendor/ghostty at ghostty.commit and build GhosttyKit.xcframework (slow the first time)
make test      # unit tests
make app       # build/Jigowatt.app
make run       # build and open the app
```

## Usage

| Shortcut | Action |
|---|---|
| ⌘N | Add a host |
| ⌘O / double-click | Connect |
| ⌘W | Close tab |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘1–9 | Jump to tab |
| ⌘R | Reconnect |
| ⇧⌘A | Agent Activity window |

The **Host** field accepts a hostname, an IP, or an alias from `~/.ssh/config`. Ghostty's in-terminal shortcuts still work (⌘C/⌘V, ⌘K to clear, ⌘+/⌘− for font size); Jigowatt owns the window, tab and split shortcuts.

## Coding agent access (MCP)

The MCP server is the `jigowatt-mcp` binary inside the app bundle. **Settings → Agent (MCP)** shows the registration command with the real path filled in, or run `make mcp`. For example:

```bash
claude mcp add --scope user jigowatt -- "/path/to/Jigowatt.app/Contents/MacOS/jigowatt-mcp"   # Claude Code
copilot mcp add jigowatt -- "/path/to/Jigowatt.app/Contents/MacOS/jigowatt-mcp"              # GitHub Copilot CLI
codex mcp add jigowatt -- "/path/to/Jigowatt.app/Contents/MacOS/jigowatt-mcp"                # Codex CLI
```

### How it works

`jigowatt-mcp` relays tool calls over a private socket to the running app, starting it in the background (menu bar only) if needed. For each host the agent uses, the app opens one **agent tab**, marked ✦ AGENT, with a real interactive ssh shell. The tab opens without taking focus, and you can watch it or type into it at any time. Shell state carries over between commands: working directory, environment variables, activated virtualenvs.

Each command is typed into that shell between two hidden marker lines. The app reads the terminal to return the output, the exit code and the working directory. stdout and stderr come back together, as they appear in the terminal. On bash and zsh, a prompt hook also reports commands interrupted with Ctrl-C (exit 130). The remote shell must be POSIX-style: bash, zsh, sh, ksh or dash, not fish.

### Tools

| Tool | What it does |
|---|---|
| `list_hosts` | Name, hostname, user, group, tags, notes, whether agent access is on, and the agent session state (`idle` / `busy` / `ended`). Never returns secrets. |
| `run_command(host, command, timeout_seconds?)` | Runs a command in the host's agent tab (opening it on first use). Returns `exit_code`, `cwd` and output (last 100 KB). If it is still running at the timeout (default 60 s, max 600 s), it is **not** killed; the agent uses the tools below. |
| `send_input(host, text?, keys?, wait_ms?)` | Types into the agent tab to answer a prompt, drive an interactive program, or interrupt (`keys: ["ctrl_c"]`). Returns the screen afterwards. |
| `read_screen(host, scrollback_lines?)` | The agent tab's visible screen, or its last N lines including scrollback. |
| `close_session(host)` | Closes the agent tab. |

### Safety

- Agent access is **per host and off by default**. Enable it in the host editor or the sidebar context menu; enabled hosts show a ✦ badge.
- **Each new agent session needs your approval.** Jigowatt asks before the agent opens or reopens a connection to a host. "Don't Allow" is the default button, and a prompt left unanswered for 60 s is denied. You can turn this off in **Settings → Agent (MCP)**.
- Agent tools only touch agent tabs, never tabs you opened yourself.
- The app checks access and writes the audit entry **before** anything is typed. Every command, input and session close, including refused requests, is appended to `~/Library/Application Support/Jigowatt/audit.jsonl` and shown in **Window → Agent Activity**, and running commands show as running.
- Agent tabs use `StrictHostKeyChecking=yes`, so connect to a new host once yourself to accept its key. Key-based hosts use `BatchMode`, and the agent's ssh never shows password or passphrase dialogs.
- The socket (`agent.sock` in the data directory) is user-only, and the app checks that the connecting process belongs to the same user.

## Data files

| Path | Contents |
|---|---|
| `~/Library/Application Support/Jigowatt/hosts.json` | Host list (shared by the app and the MCP server) |
| `~/Library/Application Support/Jigowatt/audit.jsonl` | Agent command log |
| `~/Library/Application Support/Jigowatt/ghostty-overrides.conf` | Settings Jigowatt layers over your Ghostty config |
| `~/Library/Application Support/Jigowatt/agent.sock` | Socket between `jigowatt-mcp` and the app (exists while the app runs) |

Set `JIGOWATT_HOME=/some/dir` to use a different data directory.

## Development

```
Sources/JigowattCore/      models, hosts.json store, Keychain, ssh argv builder, agent socket + shell framing, audit log
Sources/Jigowatt/          SwiftUI app; Ghostty/ hosts the libghostty surface
Sources/jigowatt-mcp/      MCP stdio relay to the app + SSH_ASKPASS helper
```

**Self-test:** `JIGOWATT_SELFTEST=<dir>` makes the app connect to the first host, type a command, save the terminal text plus PNG snapshots to `<dir>`, then quit.

## Known limitations

- **Keychain prompts.** The app is ad-hoc signed and each rebuild changes the signature, so macOS may ask once whether `jigowatt-mcp` may read a saved password. Choose "Always Allow". Signing with a Developer ID fixes this.
- **libghostty's embedding API is internal** to Ghostty and can change. `ghostty.commit` pins a known-good commit; bump it deliberately and re-run `make ghostty`.

## License

[MIT](LICENSE). Code in `Sources/Jigowatt/Ghostty/` is adapted from [Ghostty's macOS app](https://github.com/ghostty-org/ghostty), also MIT-licensed.
