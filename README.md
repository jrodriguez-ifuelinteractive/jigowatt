# Jigowatt

A small native macOS app for keeping a list of SSH machines and opening them in tabs. Terminals are rendered by [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty). It also ships an [MCP](https://modelcontextprotocol.io) server, so coding agents can list your hosts and run commands on the ones you allow.

## Features

- **Uses the system `/usr/bin/ssh`.** `~/.ssh/config`, ssh-agent / 1Password agent, keys and `known_hosts` behave as they do in a normal shell.
- **Passwords live in the macOS Keychain.** They reach ssh through `SSH_ASKPASS` and never appear in arguments or files.
- **Your Ghostty look.** Terminal appearance comes from `~/.config/ghostty/config` (can be turned off in Settings). **Settings → Terminal → Theme** picks from Ghostty's ~650 bundled themes or your own in `~/.config/ghostty/themes/`, with an optional separate Light Mode theme. Changes apply live.
- **Agent access over MCP**, opt-in per host and fully logged.

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

### Tools

| Tool | What it does |
|---|---|
| `list_hosts` | Name, hostname, user, group, tags, notes, and whether agent access is on. Never returns secrets. |
| `run_command(host, command, timeout_seconds?)` | Runs a non-interactive command (no TTY, no stdin) and returns the exit code, stdout and stderr. Output is capped at 100 KB; timeout defaults to 60 s (max 600 s). |

### Safety

- Agent access is **per host and off by default**. Enable it in the host editor or the sidebar context menu; enabled hosts show a ✦ badge.
- Every request, including refused ones, is appended to `~/Library/Application Support/Jigowatt/audit.jsonl` and shown in **Window → Agent Activity**.
- Agent runs use `StrictHostKeyChecking=yes`, so connect to a new host once from the app to accept its key. Key-based hosts run in `BatchMode`, so they fail instead of hanging on a prompt.

## Data files

| Path | Contents |
|---|---|
| `~/Library/Application Support/Jigowatt/hosts.json` | Host list (shared by the app and the MCP server) |
| `~/Library/Application Support/Jigowatt/audit.jsonl` | Agent command log |
| `~/Library/Application Support/Jigowatt/ghostty-overrides.conf` | Settings Jigowatt layers over your Ghostty config |
| `~/.ssh/sshtb-*` | ssh ControlMaster sockets for agent commands (expire after 60 s idle) |

Set `JIGOWATT_HOME=/some/dir` to use a different data directory.

## Development

```
Sources/JigowattCore/      models, hosts.json store, Keychain, ssh argv builder, command runner, audit log
Sources/Jigowatt/          SwiftUI app; Ghostty/ hosts the libghostty surface
Sources/jigowatt-mcp/      MCP stdio server + SSH_ASKPASS helper
```

**Self-test:** `JIGOWATT_SELFTEST=<dir>` makes the app connect to the first host, type a command, save the terminal text plus PNG snapshots to `<dir>`, then quit.

## Known limitations

- **Keychain prompts.** The app is ad-hoc signed and each rebuild changes the signature, so macOS may ask once whether `jigowatt-mcp` may read a saved password. Choose "Always Allow". Signing with a Developer ID fixes this.
- **libghostty's embedding API is internal** to Ghostty and can change. `ghostty.commit` pins a known-good commit; bump it deliberately and re-run `make ghostty`.

## License

[MIT](LICENSE). Code in `Sources/Jigowatt/Ghostty/` is adapted from [Ghostty's macOS app](https://github.com/ghostty-org/ghostty), also MIT-licensed.
