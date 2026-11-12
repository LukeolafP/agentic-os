# Agentic OS for Windows: the brief

For a Claude Code session on Luke's Windows PC. Read this whole file first, then `PORTING.md`
beside it. You are turning OpenClicky's Windows port (this folder: C#, .NET 8, WPF) into
**Agentic OS for Windows**: the same program Luke runs on his Mac, which is the Mac fork in
`../macos/OpenClicky/OpenClicky/` (copied beside this folder as `mac-reference/` in the setup
package). Every feature below exists in Swift there; port its behaviour, its numbers and its
sentences, in Windows idioms, the way PORTING.md says. Build and test on this PC as you go,
commit per feature, and finish with the installer and a README.

## What the program is

The Agentic OS is Luke's working environment: three local dashboards and Petra, his main agent,
all run by a Node "bridge" (`~\Coding\jarvis`, installed by `install.ps1` in the setup package).
The program is the **Voice Agent**: hold a shortcut, talk, and what Luke says is routed by a local
backend (`~\Coding\jarvis\clicky\server.mjs`, port 8793) into the right Petra chat; the backend
speaks back in the Voice Agent's voice, announces when work comes back, gives guided tours with
the pointer, and sends "screen agents" that work inside app windows. The backend is already
Windows-ready; **the program talks to it exactly as the Mac program does**, so the protocol below
is fixed. Petra's own voice (Voxtral) is Apple-only; on Windows the Voice Agent's voice is
**ElevenLabs** through the key in Settings (the backend handles it: `voiceAgentVoice` and
`elevenLabsApiKey` in `%USERPROFILE%\.openclicky\shell.json`).

## Fixed protocol with the backend (do not change)

All at `http://127.0.0.1:8793` (`backendUrl` in shell.json; default it to this, token
`agentic-os-local`, no account):
- `POST /chat` Anthropic Messages (the ask lane, system prompt opening with exactly
  `you're the agentic os voice agent, a friendly always-on companion`), streamed SSE; `[POINT:x,y:label]`
  tags and `[ACTION: name {json}]` lines as in the Mac app.
- `POST /tts {text}` → `audio/mpeg` or `audio/wav`; `POST /v1/freeflow {raw, appName, bundleID, windowTitle, selectedText}` → `{text}`;
  `POST /agent/transcribe`; `GET /voices` → `{voices:[{id,name,provider,preview}], selected, error?}`; `GET /billing/me`.
- `GET /events` SSE, `data: {json}` lines: `{"type":"say","id","text","listen":bool}` (speak it through the
  same voice path, then `POST /events/said {id}`; with `listen`, open the mic for one ask turn after speaking;
  empty text with listen = just listen), `{"type":"point","x","y","label"}` (fly the pointer to global screen
  pixels, top-left of the primary monitor at 0,0, label in its bubble), `{"type":"clear"}`, `{"type":"stop"}`.
  Reconnect with backoff. Pressing the talk shortcut during an announcement stops it and listens.
- **The hands server** the program hosts on `127.0.0.1:8795`, JSON lines (one request, one reply
  `{"ok":true,...}` / `{"ok":false,"error":"…"}`), coordinates in global screen pixels (primary top-left 0,0):
  `status` (screen, accessibility, displays[{index,x,y,width,height,main,hasCursor}], busy, target), `displays`,
  `screenshot {display,maxWidth}` → `{image (base64 jpeg), width, height, scale, originX, originY, display, displays, thumb (48x30 grey, base64), frontApp, frontBundle}`,
  `cursor`, `busy {on,who}`, `move/click/drag/scroll/type/key` (real mouse and keyboard; `since` refused with
  "stopped" after Esc), `mark {x,y,label}`, `target {app,window?}` / `{clear:true}`, `window_tree {maxItems}`
  → items `{i, role, title, value, frame{x,y,w,h}, enabled, focused, actions[]}` (roles: button, link, field,
  checkbox, radio, menu, menubutton, popup, tab, list, row, cell, table, outline, slider, image, text, group,
  scroll, toolbar, window, other), `press {i}`, `set_value {i,value}`, `focus {i}`, `keys_to_app {keys}`,
  `type_to_app {text}`, `click_to_app {x,y,button,count}`. Read `mac-reference/AgenticOSHands.swift` for the
  exact behaviour; on Windows use **UI Automation** for target/window_tree/press/set_value/focus, `SendInput`
  for the real mouse and keyboard, and `PostMessage`/`SendMessage` to the target window (WM_KEYDOWN/WM_CHAR,
  WM_LBUTTONDOWN at client coordinates) for keys_to_app/type_to_app/click_to_app; screenshots with the
  Desktop Duplication API or `Graphics.CopyFromScreen`; `Esc` stops through the global keyboard hook.

## The features to port (each has a Swift home in mac-reference/)

1. **Naming and the clean-out.** The program is "Agentic OS", the companion is the "Voice Agent", the mouse
   agent is the "screen agent". Remove what the hosted service needed: account/sign-in, free allowance,
   backend host/token, every provider key but ElevenLabs, the plan rows and "answers come from", agent mode,
   workspace, other voice and speech engines, Composio, Sparkle/Velopack update checks pointing at OpenClicky,
   PostHog. Keep dictation (keys, styles, dictionary), the pointer, the island, launch at login. No /auth or
   /billing calls on the local backend.
2. **AgenticOS** (`AgenticOS.swift`): on launch make sure the services are up (the five Scheduled Tasks from
   install.ps1, or start `node` by hand for any port that does not answer: 8790, 50000, 5211, 5050), run the
   voice backend `node clicky\server.mjs` in `~\Coding\jarvis` as a child while the program runs (unless 8793
   already answers), and show the OS dashboard `http://localhost:50000` in the program's own window (WebView2),
   with "Open Agentic OS" in the tray menu; opening the program again shows the window. Outside links: Google
   links to Chrome, everything else `obsidian://gtd-open?url=…`.
3. **Hands + outline** (`AgenticOSHands.swift`, `AgenticOSOutline.swift`): the server above; a click-through,
   topmost outline window (3 px #00E5FF rounded border with a glow, a pill "Screen agent · App" at the top-left,
   pulse rings for marks) that follows the target window's rectangle (poll every 100 ms); hides on busy off,
   target clear, or when the window is gone. The pointer flies to each real click/drag point with the label
   before the mouse acts.
4. **Settings → Agentic OS** (`SettingsAgenticOSPage.swift`): the Voice Agent's voice (from `/voices`,
   Refresh, Play Sample via `/tts`, Use Petra → "petra"), saved as `voiceAgentVoice` in shell.json; the
   ElevenLabs key; the `/voices` `error` sentence as a footnote.
5. **Announcements** (`AgenticOSEvents.swift`): the `/events` client as above.
6. **Shortcuts**: hold **Ctrl+Alt** to talk (double-tap latches until the next press, island shows
   "listening · press ctrl+alt to send"); **Ctrl+Win** dictates (hold; tap to start, tap to paste; double-tap
   latches); Ctrl+Alt+Win must not fire talk; keys pressed during a hold still cancel the take. Port the
   recognizer logic from `CompanionShortcutRecognizer.swift` and `DictationTakeController.swift`.
7. **Drawing, clear, region** (`ScreenDrawing.swift`): while a talk turn listens, the island shows pencil,
   clear and region buttons and an "N attached" badge; a full-screen transparent drawing window (red, 4 px);
   clear captures the screen with the strokes and attaches it; auto-capture 3 s after the last stroke and when
   the turn is sent; region = drag a rectangle (own overlay); attachments go after the pointer close-up as
   "Luke's drawing on screen N" / "Luke's screenshot of a region".
8. **FreeFlow polish** (`Dictation/TakePolishers.swift`, `LocalHTTPTakePolisher`): first polisher on the local
   backend, 8 s, app name / window title / selected text through UI Automation; empty answer pastes nothing;
   failure falls back to local formatting.
9. **One voice** (`AccountVoiceGuard.swift`, `AnswerVoicePlayer.swift`, `RecordedVoice.swift`): on the local
   backend every spoken line comes from `/tts`; wait up to 45 s a piece; a late or failed piece is skipped in
   silence, never spoken by the Windows voice; recorded notices and tour lines are rendered through `/tts`.
10. **Installer and README.** `installer\build-release.ps1` with Velopack, pack id `AgenticOS`, app title
    "Agentic OS", no update feed; the Setup.exe installs to `%LOCALAPPDATA%\AgenticOS` (the backend expects
    `%LOCALAPPDATA%\AgenticOS\current\Agentic OS.exe`), adds a Start menu entry and launch at login. A README
    for the person: install the backend first (`install.ps1` from the setup package), then the app; first-run
    permissions (microphone); the shortcuts; where settings live; how to rebuild.

## How to work

- Build often: `dotnet build OpenClicky.Windows.sln`; run the tests; run the exe and try each feature on this PC.
  Check `%LOCALAPPDATA%\OpenClicky\Logs\app.log` (rename the folder to `AgenticOS` as part of feature 1).
- Test the hands from PowerShell with a TCP client (one JSON line to 127.0.0.1:8795): `status`, `target` on
  File Explorer, `window_tree`, `press` a harmless control, `keys_to_app`, `target clear`.
- Test the backend connection: with the bridge and voice backend running (`check.ps1`), hold Ctrl+Alt and ask
  "what's on my screen?"; the backend log is `~\Coding\jarvis\clicky\clicky.log` (look for `route:` lines).
- Commit per feature on a branch `agentic-os-windows`, messages ending with
  `Co-Authored-By: Claude <noreply@anthropic.com>`. Never push unless Luke says so.
- Match the surrounding code's style and comment density. When something in the Mac code is Mac-only with no
  Windows equivalent (Voxtral, launchd, the menu bar), do the Windows thing and say so in the commit.

## Done means

The Setup.exe installs Agentic OS on this PC; Ctrl+Alt routes a request into a Petra chat and the Voice Agent
answers in the ElevenLabs voice; a finished chat is announced and a tour points at things on screen; a screen
agent sent by Petra works inside an outlined window without taking the mouse; dictation with Ctrl+Win pastes
FreeFlow-cleaned text; Settings shows only what applies. Report what is tested on this PC and what is not.
