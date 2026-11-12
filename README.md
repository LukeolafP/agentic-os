# Agentic OS

The program you talk to in the Agentic OS: hold a shortcut, say what you want, and the Voice
Agent sends it into the right Petra chat, speaks back, tells you when work comes back, walks
you through the result on screen with its pointer, and lends Petra's screen agents its hands to
work inside app windows while you keep working. It runs on your own Claude plan through the
Claude Agent SDK; nothing goes to a hosted service.

It is a fork of [OpenClicky](https://github.com/prasanthsasikumar/openclicky) (MIT), which
builds on [Clicky](https://github.com/farzaa/clicky) by Farza. OpenClicky's own README is kept as
[README-OpenClicky.md](README-OpenClicky.md). Everything the program talks to (Petra, the bridge,
the dashboards, the Obsidian plugin) is installed by the
**[agentic-os-setup](https://github.com/LukeolafP/agentic-os-setup)** repository; install
that first.

## Mac

- `macos/OpenClicky/`: the Swift app. Needs Xcode. Build and install with
  `scripts/build-agentic-os.sh`, which signs it with a local certificate
  (`scripts/make-signing-cert.sh`, run once) so macOS keeps its permissions across rebuilds, and
  puts it in `/Applications/Agentic OS.app`.
- First run: allow Microphone, Accessibility and Screen Recording. The program expects the
  backend from agentic-os-setup on `127.0.0.1:8793` and starts it when it is not running.
- Hold **⌃⌥** to talk (double-tap to keep listening), **⌃⌘** to dictate. While you talk, the
  island shows a pencil, clear and a region button to attach a drawing or part of the screen.
- Settings → Agentic OS: the Voice Agent's voice (Petra's own, or an ElevenLabs voice with your key).

## Windows

- `windows/`: OpenClicky's C# port, the base for Agentic OS on Windows. The port of our Mac
  additions is done on the PC by following [`windows/AGENTIC-OS-WINDOWS-BRIEF.md`](windows/AGENTIC-OS-WINDOWS-BRIEF.md)
  with Claude Code. Needs the .NET 8 SDK and Velopack's `vpk` for the installer.

## How it fits together

| Piece | Where | Port |
|---|---|---|
| The program (this repository) | `/Applications/Agentic OS.app` | hands on 8795 |
| The Voice Agent backend | `~/Coding/jarvis/clicky/server.mjs` | 8793 |
| Petra's bridge | `~/Coding/jarvis/bridge/server.mjs` | 8790 |
| The Agentic OS dashboard | `<vault>/Installers/Robonuggets/rubric-agentic-os` | 50000 |

The protocol between the program and the backend is in the Windows brief and in
`macos/OpenClicky/OpenClicky/AgenticOSHands.swift`.

## Licence

MIT, see [LICENSE](LICENSE). Portions are OpenClicky's and Clicky's, under MIT.
