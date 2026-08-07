<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/256.png" alt="Logo" width="100" height="100">
  <h3 align="center">NotchAgent</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
  </p>
</div>

> **🟢 Actively maintained**
>
> Launched v1.2 in December 2025, then took a 4-month break. v1.3 (April 2026) works through the backlog of contributor PRs and bug reports and kicks off a regular cadence again. Open PRs and issues are being reviewed — thanks for your patience.

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch

## Requirements

- macOS 15.6+
- Claude Code CLI

## Install

Download the latest release or build from source:

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

## Usage

**The pill.** NotchAgent lives as a small pill overlaid on your MacBook's notch (or floating near the menu bar on notchless Macs). It stays hidden until a Claude Code session needs your attention:

- **Spinner + elapsed time** — a session is actively working
- **Orange dot** — a session is waiting on a tool permission
- **Green checkmark** — a session finished and is waiting for your next message

Click or hover the pill to expand it.

**Sessions & chat.** Expanded, the notch lists every running Claude Code session. Click one to open its chat — full conversation history with markdown rendering, live tool-call status, and a composer to type a message directly from the notch. Messages are delivered straight to the session's terminal (via tmux, terminal scripting, or synthetic keystrokes as a last resort), so you don't have to switch windows to keep a conversation going.

**Approvals.** When Claude asks to run a tool, the notch expands with Approve/Deny buttons right there — no alt-tabbing to the terminal.

**The crab icon.** Click it to bring the relevant terminal (or Claude Desktop, if installed) to the front — useful when you want to look at the full session outside the notch.

**Settings.** Open the menu (☰ in the top-right of the expanded notch) for:

- **Theme** — light, dark, or match system
- **Screen** — which display shows the notch on multi-monitor setups
- **Sound** — the notification sound played when a session finishes
- **Claude Directory** — which `~/.claude` projects directory to watch
- **Launch at Login**
- **Hooks** — install/uninstall the Claude Code hooks NotchAgent relies on
- **Accessibility** — required so NotchAgent can type messages into a terminal or Claude Desktop on your behalf

## How It Works

NotchAgent installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to switch to the terminal.

## Analytics

NotchAgent uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new Claude Code session is detected

No personal data or conversation content is collected.

## License

Apache 2.0
