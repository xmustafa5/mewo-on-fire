# Mewo on Fire protocol (v1)

Two parts:
- `pc/` — Rust binary `mewo` (daemon + CLI + Claude Code hook) for Linux and macOS.
- `mobile/` — Flutter app (Android, iOS) that pairs with one or more PCs and shows notifications.

All traffic is LAN only. The phone connects to the PC.

## PC files

| Path | Content |
|---|---|
| `~/.config/mewo-on-fire/config.json` | `{"pc_id": "<16 hex>", "name": "<hostname>", "port": 47821}` |
| `~/.config/mewo-on-fire/cert.der`, `key.der` | self-signed cert + PKCS#8 key (DER), generated on first run |
| `~/.config/mewo-on-fire/devices.json` | `[{"id": "<8 hex>", "name": "Pixel 8", "token": "<64 hex>", "created": <ms>}]` (mode 600) |
| `~/.local/state/mewo-on-fire/events.json` | `{"next_id": N, "events": [Event, ...]}` — last 500 events |
| `$XDG_RUNTIME_DIR/mewo-on-fire.sock` | local control socket on Linux (fallback `/tmp/mewo-on-fire-$USER.sock`) |
| `~/.local/state/mewo-on-fire/mewo-on-fire.sock` | local control socket on macOS (fallback `/tmp/mewo-on-fire-$USER.sock` if the path is longer than 103 bytes). It does not depend on the environment: the daemon (launchd), the CLI (terminal) and the hooks (terminal or the Claude desktop app) run with different ones. |

`name` defaults to the hostname; on macOS to the computer name (`scutil --get ComputerName`).

Fingerprint `fp` = lowercase hex SHA-256 of the cert DER bytes.

## Event

```json
{"id": 42, "ts": 1790000000000, "kind": "stop", "project": "business-os",
 "cwd": "/home/mus/Documents/project/business-os", "session": "44155e15",
 "message": "Fixed the payroll rounding bug and…", "detail": ""}
```

- `kind`: `stop` (Claude finished a reply) · `needs_input` (Notification hook) · `session_end` (SessionEnd hook)
- `project` = basename of `cwd`; `session` = first 8 chars of `session_id`
- `message`: first 200 chars (whitespace collapsed) of `last_assistant_message` (Stop) or `message` (Notification); empty for session_end
- `detail`: `notification_type` for needs_input, `reason` for session_end, empty for stop
- `id` is assigned by the daemon (monotonic, starts at 1); `ts` = unix ms

## Claude Code hook → daemon

`~/.claude/settings.json` gets (appended to existing arrays, never replacing them):

```json
"Stop":         [{"hooks": [{"type": "command", "command": "<bin> hook", "async": true}]}],
"Notification": [{"matcher": "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog",
                  "hooks": [{"type": "command", "command": "<bin> hook", "async": true}]}],
"SessionEnd":   [{"hooks": [{"type": "command", "command": "<bin> hook", "async": true}]}]
```

Hook stdin fields used: `hook_event_name`, `session_id`, `cwd`, `last_assistant_message`, `message`, `notification_type`, `reason`.
`mewo hook` always exits 0 and never blocks > 1 s (daemon down = silently drop).

## Local control socket (Unix, newline-delimited JSON, one request per connection)

| Request | Response |
|---|---|
| `{"cmd":"emit","event":{...Event without id/ts...}}` | `{"ok":true}` |
| `{"cmd":"pair"}` | `{"ok":true,"qr":"<QR payload string>","code":"<code>","expires_in":300}` |
| `{"cmd":"devices"}` | `{"ok":true,"devices":[{"id","name","created"}]}` |
| `{"cmd":"revoke","id":"<device id>"}` | `{"ok":true}` / `{"ok":false,"error":"not_found"}` |
| `{"cmd":"status"}` | `{"ok":true,"pc_id","name","port","fp","hosts":[...],"devices":N,"last_id":N,"connected":N}` |

## QR payload (JSON string)

```json
{"v":1,"id":"<pc_id>","name":"<hostname>","hosts":["192.168.68.133"],"port":47821,"fp":"<sha256 hex>","code":"<pairing code>"}
```

- `hosts`: IPv4 of up, non-loopback interfaces, excluding names starting with `docker`, `br-`, `veth`, `virbr`, `lxc`, `tun`, `tailscale`, `wg`. On macOS also `utun`, `awdl`, `llw`, `anpi`, `vmnet`; addresses of `bridge*` interfaces (VM networks, Internet Sharing) are listed last.
- `code`: 16 random hex chars, single use, valid 5 minutes.

## Phone ↔ PC transport

`wss://<host>:<port>/` — TLS with the self-signed cert. The phone accepts the cert **only** if SHA-256(cert DER) == `fp` (pinning). All frames are JSON text. First frame is sent by the phone:

**Pairing** (one-shot connection):
```
→ {"type":"pair","code":"<code>","device_name":"Pixel 8"}
← {"type":"paired","device_id":"<8 hex>","token":"<64 hex>","pc_id":"...","name":"...","last_id":N}
← {"type":"error","error":"invalid_code"}          (then close)
```

**Subscribe** (long-lived connection):
```
→ {"type":"auth","token":"<token>","since":<last event id the phone has, 0 if none>}
← {"type":"hello","pc_id":"...","name":"...","last_id":N}
← {"type":"event","event":{Event}}     (replay of stored events with id > since, then live)
← {"type":"error","error":"unauthorized"}          (then close)
```

- If the phone's `since` > `last_id` in `hello` (PC state was reset), the phone sets `since = last_id` locally and ignores nothing further.
- Phone ignores events with `id <= since` (dedupe) and only shows a system notification for replayed events whose `ts` is < 30 min old; older ones go to history silently.
- Server sends a WebSocket ping every 30 s; the phone sets `pingInterval = 25 s`. Server drops a client when a send fails.
- Revoked device → next auth gets `unauthorized`; the phone shows the PC as "unpaired".

## Discovery

The daemon advertises mDNS `_ccnotify._tcp.local.` on `port`, instance name = hostname, TXT `id=<pc_id>`.
Phone: tries the stored `hosts` in order; if all fail 3 times in a row, it browses `_ccnotify._tcp` for ~5 s, and on a service whose TXT `id` matches, replaces the stored hosts with the resolved address.

## Reconnect

Exponential backoff 1 s → 60 s with ±20 % jitter, reset on successful `hello`. Reconnect immediately on network change / app resume.

---

# v1.1 — answering prompts from the phone

Claude Code runs a `PermissionRequest` hook right before it shows a permission prompt, an
`AskUserQuestion` question, or an `ExitPlanMode` plan approval (verified: it fires for all three).
In VS Code / Desktop sessions the on-screen prompt and the hook race — whichever answers first
wins. If the PC answers first, Claude Code does **not** kill the hook: it keeps running (stdout open)
until its timeout. So `mewo ask` watches the transcript itself, and the daemon has a safety net.

## Hook

Added by `mewo install` (not async, long timeout):

```json
"PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": "<bin> ask", "timeout": 86400}]}]
```

`mewo ask`:
1. Reads the hook JSON (`tool_name`, `tool_input`, `permission_suggestions`, `session_id`, `cwd`, `transcript_path`, `agent_id` — set when the prompt comes from a subagent).
2. Starts the transcript watcher (below), sends `{"cmd":"ask","request":{Request without id/ts},"agent_id":"<agent_id or empty>"}` on the control socket and **blocks** reading the reply line (no read timeout). `agent_id` is private (never forwarded to phones).
3. Reply `{"ok":false,"error":"no_devices"}` (sent immediately when no phone is connected), `cancelled`, `timeout`, or any error / daemon down → print nothing, exit 0 (normal prompt flow).
4. Reply `{"ok":true,"answer":{Answer}}` → print the hook output below, exit 0.
5. Answered on the PC → the watcher exits the process (code 0, no output); the socket closes, the daemon notices EOF and resolves the request (`by: "pc"`).

### Transcript watcher (thread in `mewo ask`)

- Subagent prompt (`agent_id` set): watch `agent_transcript_path` if the input has one different from `transcript_path` (all its lines count, sidechain or not), else no watcher.
- Start: read the last 2 MB of `transcript_path` (drop the first partial line). Target = the most recent main-chain (`isSidechain` not true) `assistant` `tool_use` block with `name == tool_name` and no `tool_result` in the tail, preferring one whose `input` equals `tool_input`. Remember the file length as the offset.
- Every 1 s read only the appended bytes (a partial last line is carried over; file shrank → offset 0). Exit 0 silently when a main-chain line shows:
  - a `user` `tool_result` with the target's `tool_use_id` (answered on the PC);
  - a new non-meta `user` text prompt (session moved on; `<task-notification>` texts don't count);
- No target at start → the target is adopted from the appended `assistant` lines (same rule): Claude Code can start the hook before it flushes the `tool_use` line (seen: same millisecond). New `assistant` lines never end the watch by themselves.
- The `tool_result` is written right when the PC answers — for an approved long-running command only when it finishes (accepted; the safety net covers the end of the turn).
- Race: an atomic flag is set once by whoever ends the process — the main thread right before it prints a phone answer (or exits), or the watcher; the other one then neither exits nor prints.

### Safety net (daemon)

`emit` of kind `stop` or `session_end`, or `session_state` `working` (UserPromptSubmit) for session S → every pending request with `session` == S and no `agent_id` is resolved: its `ask` gets `{"ok":false,"error":"cancelled"}` (exits 0 silently) and phones get `resolved` with `by: "pc"`.

## Request (daemon → phone)

```json
{"id": "<8 hex>", "ts": 1790000000000, "kind": "permission", "project": "business-os",
 "session": "44155e15", "tool": "Bash", "title": "Run a command",
 "summary": "npm test", "detail": "npm test\n\nRun test suite", "can_allow_always": true,
 "questions": []}
```

- `kind`: `question` if `tool_name == "AskUserQuestion"`, `plan` if `ExitPlanMode`, else `permission`.
- `title` / `summary` (≤ 200 chars) / `detail` (≤ 4000 chars) by tool:
  - `Bash`: "Run a command" / `command` / `command` + "\n\n" + `description`
  - `Edit`, `Write`, `MultiEdit`, `NotebookEdit`: "Edit a file" / `file_path` / `file_path` + (`old_string` → `new_string`, or first 1500 chars of `content`)
  - `WebFetch`: "Fetch a URL" / `url`; `WebSearch`: "Search the web" / `query`
  - `ExitPlanMode`: "Approve the plan" / first line of `plan` / `plan`
  - `AskUserQuestion`: "Claude has a question" / first `question` / all question texts
  - anything else (incl. `mcp__*`): "Use <tool>" / compact JSON of `tool_input`
- `can_allow_always`: `permission_suggestions` is a non-empty array (permission kind only).
- `questions`: `tool_input.questions` as-is (`question`, `header`, `options[{label, description}]`, `multiSelect`) for kind `question`, else `[]`.
- The original `tool_input` and `permission_suggestions` stay in the hook process (never sent to the daemon's phones); the hook builds its own output from them.

## Answer (phone → daemon → hook)

| kind | Answer | Hook stdout |
|---|---|---|
| permission | `{"action":"allow"}` | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| permission | `{"action":"allow_always"}` | same + `"updatedPermissions": <permission_suggestions>` |
| permission | `{"action":"deny","message":"..."}` | `decision: {"behavior":"deny","message": message or "Denied from phone (Mewo on Fire)"}` |
| question | `{"answers":{"<question text>":"<label>"}}` | `decision: {"behavior":"allow","updatedInput": {...tool_input, "answers": answers}}` |
| plan | `{"action":"approve"}` | `decision: {"behavior":"allow","updatedInput": tool_input}` |
| plan | `{"action":"reject","message":"..."}` | `decision: {"behavior":"deny","message": message or "Plan rejected from phone (Mewo on Fire)"}` |

Multi-select answers join labels with ", ". A typed custom answer is sent as the value text.

## Wire frames (after a successful `auth`, in addition to v1)

```
← {"type":"request","request":{Request}}     — sent live, and on (re)connect for every still-pending request
← {"type":"resolved","request_id":"<id>","by":"phone|pc|timeout"}   — answered elsewhere / cancelled
→ {"type":"answer","request_id":"<id>","answer":{Answer}}
```

- The first valid answer wins; the daemon then sends `resolved` (by `phone`) to all phones. An answer for an unknown/finished request gets a `resolved` reply to that phone only.
- When the hook connection closes before an answer, or the safety net fires: `resolved` with `by: "pc"`.
- Pending requests older than 24 h are dropped (`by: "timeout"`).
- Duplicate suppression: while a request is pending for session S, an `emit` of kind `needs_input` with the same `session` and `detail` `permission_prompt` or `elicitation_dialog` is dropped (not stored, not sent).

## Control socket additions

| Request | Response |
|---|---|
| `{"cmd":"ask","request":{...},"agent_id":"..."}` | blocks → `{"ok":true,"answer":{...}}` / `{"ok":false,"error":"no_devices\|cancelled\|timeout"}` |
| `{"cmd":"status"}` | adds `"pending": N` |

## Phone behaviour

- Notification channel `requests` (max importance, heads-up), one notification per request, id derived from pc_id + request id, `ongoing` until resolved.
- Action buttons (no UI opened, handled in the background):
  - permission: **Allow**, **Deny**, and **Always** if `can_allow_always`
  - question with exactly 1 question, `multiSelect` false and ≤ 3 options: one button per option label
  - plan: **Approve**, **Reject**
- Tapping the notification body opens the app on the answer screen for that request (full detail, option list with multi-select, "Other…" free text, deny/reject with an optional message).
- The app shows pending requests at the top of the PCs tab ("Waiting for you").
- On `resolved`: cancel the notification and drop the request from the pending list.
- iOS: the buttons of a notification come from its category (a fixed set registered at start): `ccn_permission` (Allow, Deny), `ccn_permission_always` (Allow, Always allow, Deny), `ccn_plan` (Approve, Reject). Allow / Always allow / Approve need the phone unlocked. A question has no buttons: its option labels differ per request, so it is answered in the app. Notifications cannot be `ongoing`; they stay in Notification Center until resolved.

---

# v1.2 — session chat on the phone, continue from the phone

## New hooks (added by `mewo install`)

```json
"Stop":             [..., {"hooks": [{"type": "command", "command": "<bin> listen", "async": true, "asyncRewake": true, "timeout": 86400}]}],
"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "<bin> hook", "async": true}]}]
```

`asyncRewake`: the hook runs in the background; when it exits with code 2, Claude Code wakes the
session immediately (even if idle) and shows the hook's stderr to Claude as a system reminder.

## `mewo hook` changes

`emit` now also sends private fields (never forwarded to phones): `session_id` (full), `transcript_path`,
`effort` (`effort.level` from the hook input, may be empty). `UserPromptSubmit` → `{"cmd":"session_state","session_id","cwd","transcript_path","effort","state":"working"}` (no event, no notification).

Events sent to phones gain one field: `"session_id": "<full session id>"` (used to open the chat).

## `mewo listen` (Stop hook, asyncRewake)

1. Read stdin (`session_id`, `cwd`, `transcript_path`).
2. Send `{"cmd":"listen","session_id","cwd","transcript_path"}` on the control socket; block with no read timeout.
3. Reply `{"ok":true,"text":"..."}` → write to **stderr**:
   `The user sent this message from their phone (via Mewo on Fire). Treat it exactly as if they had typed it in this session:\n\n<text>`
   and exit **2** (wakes Claude).
4. Any other reply (`superseded`, `cancelled`, error, daemon down) → exit 0 silently.

Daemon side:
- If messages are queued for the session → reply immediately with them joined by `"\n\n"` and clear the queue.
- Else register as the session's listener, replacing any previous listener (which gets `{"ok":false,"error":"superseded"}`).
- `UserPromptSubmit` or `SessionEnd` for the session → current listener gets `{"ok":false,"error":"cancelled"}`.
- EOF on the listener socket → unregister.

## Session registry (daemon)

Kept in memory and persisted to `~/.local/state/mewo-on-fire/sessions.json` (last 50 by activity; ended sessions older than 7 days dropped).

```json
{"id": "<full session_id>", "short": "44155e15", "project": "business-os", "cwd": "...",
 "title": "Fix payroll rounding", "state": "working", "listening": false, "read_only": false,
 "effort": "xhigh", "last_ts": 1790000000000, "last_text": "first 200 chars of Claude's last reply", "queued": 0}
```

- `state`: `working` (UserPromptSubmit, or a phone message was delivered) · `idle` (Stop) · `waiting` (needs_input event or a pending v1.1 request for the session) · `ended` (SessionEnd).
- `title`: last `custom-title` entry's `customTitle` in the transcript (a renamed session; the Claude desktop app titles its sessions this way), else the last `ai-title` entry's `aiTitle`, else the project name.
- `listening`: a `listen` hook is currently registered.
- `read_only`: `state == "working"` AND `effort` is `xhigh` or `max` AND agents are running (see below).
- Any change → push `{"type":"session","session":{Session}}` to phones.

## Transcript → chat items

The daemon reads the last 4 MB of `transcript_path` (JSONL; drop the first partial line) on demand.

- Skip lines with `isSidechain: true` or `isMeta: true`, and every `type` other than `user` / `assistant` / `ai-title` / `custom-title`.
- `user`, content string or `text` blocks → strip `<system-reminder>…</system-reminder>`, `<ide_selection>…</ide_selection>`, `<ide_opened_file>…</ide_opened_file>` and `<command-…>…</command-…>` wrappers; non-empty remainder → item role `user`. `image` blocks → "[image]". `tool_result` blocks → skipped.
- `assistant`: `text` blocks → role `assistant`; `thinking` → skipped; `tool_use` → role `tool` with a one-liner:
  Bash → first line of `command` · Edit/Write/MultiEdit/NotebookEdit/Read → file path · Grep/Glob → `pattern` ·
  WebFetch → `url` · WebSearch → `query` · Agent/Task → `description` · Workflow → `description` or `name` ·
  AskUserQuestion → first question · TodoWrite → "update todos" · anything else → tool name.
- Text per item ≤ 6000 chars. Return the last `limit` (default 100) items.
- Messages sent from the phone are also recorded by the daemon (per session, last 100) and merged by `ts` as role `phone`
  (the rewake text does not appear as a normal user message in the transcript).
- **Agents running**: after the last role-`user` item, some `tool_use` named `Agent`, `Task` or `Workflow` has no matching `tool_result` (`tool_use_id`).

ChatItem: `{"id": "<line uuid or generated>", "ts": <ms>, "role": "user|assistant|tool|phone", "text": "...", "tool": "Bash"}` (`tool` only for role `tool`).

## Wire frames (after `auth`)

```
→ {"type":"sessions"}                                              ← {"type":"sessions","sessions":[Session...]}   (newest first)
← {"type":"session","session":{Session}}                            (live update)
→ {"type":"get_chat","session_id":"...","limit":100}               ← {"type":"chat","session_id":"...","title":"...","items":[ChatItem...]}
→ {"type":"send","session_id":"...","text":"...","client_id":"<id>"}
← {"type":"send_result","client_id":"...","status":"delivered|queued|rejected","reason":"..."}
```

`send` rules:
- unknown or `ended` session → `rejected` ("Session is closed").
- `read_only` → `rejected` ("Claude is running agents at high effort — read-only until it finishes").
- a listener is registered → deliver now → `delivered`; state becomes `working`.
- no listener and state `working` or `waiting` → queue → `queued` (delivered by the next `listen`).
- no listener and state `idle` → `rejected` ("This session is not listening — run `mewo install` on the PC and send a message from the PC once").
- After `delivered`, the phone refreshes the chat when the next `stop` event for the session arrives.

## Phone

- New **Sessions** tab (between PCs and History): all sessions from all PCs, newest first — title, project · PC, state chip (Working / Finished / Needs you / Closed), `last_text`, relative time; queued count badge.
- **Chat screen**: items as bubbles — `user` and `phone` right-aligned (phone ones marked "📱 from phone"), `assistant` left with Markdown, `tool` as compact grey one-liners (grouped consecutive ones collapsible). Pull to refresh; auto-refresh on `session` updates and `stop` events for this session. Bottom input: disabled with the reason when `read_only` or `ended`; otherwise send → show the `send_result` status on the bubble (Delivered / Queued / Rejected + reason).
- Tapping a `stop` / `needs_input` / `session_end` notification (or a history item with `session_id`) opens that session's chat.
- `stop` notifications get a **Reply** action with inline text input (RemoteInput) → handled in the background like v1.1 answers → `send`; the notification is updated to "Sent: <text>" / "Queued" / the rejection reason.
- iOS: Reply is the text-input action of category `ccn_reply` (needs the phone unlocked). iOS removes the notification when the reply is sent, so the result is posted as a new notification: quietly for "Sent" / "Queued", with an alert for a rejection.

## iOS: connection lifetime

iOS has no foreground service. The connections live in the app process: always while the app is open, for about 25 s after it goes to the background (and again when a notification button wakes it), and for as long as the app stays in the background when the user turns on **Stay connected in the background** (silent audio with the `audio` background mode). On resume the app pings every connected PC and reconnects the ones that do not answer; events missed in between are replayed through `since` as on Android.

---

# v1.3 — images in the chat

## Sending images from the phone

`send` takes up to 4 images:

```
→ {"type":"send","session_id":"...","text":"...","client_id":"<id>",
   "images":[{"mime":"image/jpeg","data":"<base64>"}]}
```

- `text` may be empty when there are images.
- An image is at most 2.5 MB (decoded) and must be a JPEG, PNG, GIF or WebP; the daemon tells the type by the content, not by `mime`. Otherwise the message is `rejected` ("Too many images (4 at most)", "An image is too large", "Only JPEG, PNG, GIF and WebP images can be sent").
- The daemon saves them as `~/.local/state/mewo-on-fire/uploads/<session short>/<client_id>-<n>.<ext>` (mode 600, directory 700) and deletes them again when the message is rejected. Uploads older than 7 days are removed.
- What Claude Code gets (through `listen`) is the text followed by the files, which it looks at with its Read tool:

  ```
  <text>

  The user attached images from their phone. Look at them with the Read tool:
  /home/u/.local/state/mewo-on-fire/uploads/44155e15/9f2c…-1.jpg
  /home/u/.local/state/mewo-on-fire/uploads/44155e15/9f2c…-2.jpg
  ```

## ChatItem

ChatItem gains `"images": [{"id": "<image id>"}]` (left out when there are none):

- a `phone` item: the images sent with it, `up/<session short>/<file>`; its `text` is the message without the file list;
- a `user` item: the image blocks of that transcript line, `tr/<line uuid>/<content block index>`. The text still has one "[image]" per image for phones that do not show images; a phone that does leaves those lines out.

## Fetching an image

```
→ {"type":"get_image","session_id":"...","image_id":"..."}
← {"type":"image","session_id":"...","image_id":"...","mime":"image/png","data":"<base64>"}
← {"type":"image","session_id":"...","image_id":"...","error":"not_found"}
```

An `up/…` id is only served for its own session. For a `tr/…` id the daemon finds the line by its uuid in the session's transcript (the whole file, not only the last 4 MB).

## Phone

- The input bar has an attach button: photo library (up to 4) or camera. Pictures are scaled to 1600 px and re-encoded before sending. They are not queued while the service is stopped: the message is rejected locally instead.
- Bubbles show their pictures (fetched once, kept in memory); a tap opens one in full.
- Every bubble is Markdown; what the user typed keeps its line breaks.
- A long press on a bubble opens its options: **Reply**, **Copy**, **Select text**; a rejected message of this phone has **Send again** and **Remove**.
- **Reply** quotes the start of the message (its prose up to the first code block or table, at most 240 characters) as a Markdown quote above the reply, so no protocol change is needed:

  ```
  > <start of the quoted message>

  <the reply>
  ```

# v1.4 — reaching the PC from outside the LAN

The transport does not change: the phone connects to one of the PC's
addresses with the pinned certificate. What changes is which addresses there
are and how the phone picks one.

## Addresses

`hosts` (QR payload, `status`, `hello`) lists, in this order:

1. the LAN addresses (as before);
2. the PC's Tailscale addresses: IPv4 in `100.64.0.0/10` on any interface;
3. `extra_hosts` of `config.json` (`["mac.example.ts.net", "10.8.0.2"]`):
   other VPN addresses, or DNS names;
4. the relay of `config.json` (`relay`, set with `mewo relay <url>`), as
   its URL: `wss://relay.example`. See "Relay" below.

mDNS still advertises LAN addresses only.

## hello

```json
{"type":"hello","pc_id":"...","name":"...","last_id":N,"hosts":["192.168.0.64","100.101.102.103"]}
```

`hosts` is optional (absent from older daemons). A phone that gets it stores
the list in place of the one from pairing, so a paired phone learns a new
remote address the next time it connects at home.

## Phone

- A host that starts with `wss://` (or `ws://`) is a relay: the phone
  connects to `<relay>/pc/<pc_id>/connect` and runs the usual connection
  (TLS with the pinned certificate, `auth`, …) through it.
- A host is *LAN* when it is an address in `10/8`, `172.16/12`, `192.168/16`,
  `169.254/16` (or IPv6 link-local / `fc00::/7`), and *remote* otherwise
  (VPN addresses, names).
- Each round tries the stored hosts with the one that last got a `hello`
  first, then the others in stored order. With more than one host, a LAN host
  gets 4 s to connect (10 s otherwise): away from home it cannot answer.
- After mDNS discovery, the stored hosts become the discovered addresses
  followed by the remote hosts known before.

## Relay

For a PC that the internet cannot reach (provider NAT). The daemon and the
phone both connect out to the relay with WebSockets; it passes bytes between
them and understands none of them. `relay/` is one for Cloudflare Workers,
`mewo relay-server [port]` one for a machine of your own.

- Daemon: `GET <relay>/pc/<pc_id>/listen?key=<relay_key>`. The first daemon
  for a `pc_id` sets the key (48 hex characters, `relay_key` in
  `config.json`); another key is refused afterwards. A new connection of the
  daemon replaces the old one and closes its phones.
- Phone: `GET <relay>/pc/<pc_id>/connect`; refused (HTTP 503, or closed) when
  the daemon is not connected.
- Relay → daemon, text: `{"open": N}` when a phone connected (N: unsigned 32
  bit), `{"close": N}` when it left. Daemon → relay, text: `{"close": N}`.
- Daemon ↔ relay, binary: 4 bytes N (big endian), then the bytes of that
  phone's connection. Phone ↔ relay, binary: the bytes.
- The daemon opens a TCP connection to its own port on `127.0.0.1` for every
  `open` and pipes it; it pings the relay every 30 s and reconnects (1 s … 60 s
  backoff) when it hears nothing for 75 s.
- The phone opens a listening socket on `127.0.0.1`, pipes it to the relay,
  and connects to it as to any other address of the PC.

# v1.5 — suggested next messages

Claude Code's own prompt suggestion exists only inside the app that shows it
(it is not in the transcript, and no hook gets it). So the phone's comes from
Claude itself:

- `suggestions: true` in `config.json` (`mewo suggestions on|off`; read by
  the hooks on every prompt, no restart).
- With it on, `mewo hook` answers `UserPromptSubmit` with
  `hookSpecificOutput.additionalContext`: a request to end the final reply
  with one more line, after an empty line:

  ```text
  [next]: # "first suggestion | second suggestion"
  ```

  One to three short messages the user would plausibly send next. It is a
  Markdown link reference definition, which no renderer displays. `listen`
  appends the same request to a message from the phone (no
  `UserPromptSubmit` runs for those).
- The daemon takes the last line that starts with `[next]: #` out of an
  assistant text (transcript items, and the `stop` event's message), splits
  what is between the quotes (or parentheses) at `|`, and keeps up to three
  entries of up to 120 characters as the ChatItem's `suggestions`:

  ```json
  {"id":"…","ts":1790000000000,"role":"assistant","text":"All tests pass.","suggestions":["commit it","push"]}
  ```

- Phone: offers the `suggestions` of the last chat item while it is Claude's,
  the session is not `working` or `ended`, and nothing was sent after it. A
  tap puts the text in the message box (the watch asks, then sends).

# v1.6 — pull requests

The open pull requests of a session's repository, as Claude Desktop pins
them above its input. The PC reads them with the GitHub CLI (`gh`, logged in
by the user) in the session's folder; the phone asks while a chat is open.

## Wire frames (after `auth`)

- Phone → PC: `{"type":"get_prs","session_id":"…"}`.
- PC → phone: `{"type":"prs","session_id":"…","repo":"owner/name","branch":"<checked out>",
  "prs":[…],"error":""}`. `error` is a sentence for the user when nothing
  could be read ("GitHub CLI (gh) is not installed on the PC", "Not a git
  repository", …); `prs` is empty then.
- One pull request: `{"number":65,"title":"…","branch":"feature/…","url":"https://…",
  "additions":87,"deletions":0,"draft":false,"review":"approved|changes|required|",
  "ci":"pass|fail|pending|none","checks":[{"name":"build","state":"pass|fail|pending"}],
  "author":"login","updated":"<ISO 8601>","current":true}`. `current`: its
  branch is the one checked out in the session's folder; those come first.

## Daemon

- `gh repo view --json nameWithOwner`, then `gh pr list --state open --limit 20
  --json number,title,headRefName,additions,deletions,url,isDraft,reviewDecision,
  statusCheckRollup,updatedAt,author`, run in the session's `cwd`; `gh` is looked
  for in the usual places because launchd/systemd give the daemon a short PATH.
- `ci` rolls `statusCheckRollup` up: any failed check → `fail`, else any
  running → `pending`, else `pass`; no checks → `none`.
- Answers are kept 45 s per folder; a `gh` call is given 25 s.

## Phone

- Asks on opening a chat, every 2 minutes while it is open, and 3 s after a
  `stop` event of that session (Claude may have pushed or opened one).
- Shows up to two above the input ("Show N more" for the rest): number,
  repository, branch, `+adds −dels`, a CI pill. Tapping one lists the checks
  and offers the GitHub link and, when CI fails, a message to Claude asking
  it to fix the failures. The × hides one until the chat is opened again.



## Session `desktop` (optional)

A session that runs inside Claude Desktop carries `"desktop": "local_…"`,
the app's own id of it, taken by the hooks from
`CLAUDE_CODE_HOST_SESSION_ID` in their environment. Absent for sessions in
a terminal. `claude://claude.ai/epitaxy/<desktop>` opens the session in the
app; the operations console does that on a click. On macOS the console also
reads the app's own records (`~/Library/Application Support/Claude/
claude-code-sessions`) for sessions the hooks did not tag.
\n

## Session `artifacts` (optional)

What the session made with Claude's Artifact tool, read from the transcript
(a tool_use named `Artifact`; the url from its input, or from the
tool_result of a create): `"artifacts": [{"url": "https://claude.ai/artifact/…",
"title": "Onboarding", "kind": "design|document|page|artifact", "ts": <unix ms>}]`,
oldest first, at most 20. `kind` comes from the files the call sent
(`.dc.html`/`canvas.json` → design, `.md` → document, `.html` → page). The
phone shows them above the chat input and opens them; the console lists them
on a session's card.

## New session (v1.6)

- Phone → PC: `{"type":"new_session","client_id":"…","cwd":"<folder or empty>","prompt":"<first message>"}`.
- PC → phone: `{"type":"new_session_result","client_id":"…","ok":true|false,"error":"…"}`.
- Control socket: `{"cmd":"new_session","cwd","prompt"}` → `{"ok", "error"}`.

The daemon opens `claude://code/new?q=<prompt>&folder=<cwd>&source=mewo` with
`open`; Claude Desktop creates the session and sends the prompt itself. The
session then reaches the phone through the hooks like any other, a few
seconds later. macOS with Claude Desktop only; a Linux PC answers with an
error. Whether Desktop honours `folder` is its own business: when it does
not, the session opens in the project Desktop has in front.

## Artifact files (v1.6)

A session's `artifacts` entries carry, when the daemon kept a copy of the
published files, `id` (the last segment of the url), `local: true` and
`entry`: what to open in the copy (`…/canvas.json` for a design, the page,
or the `.md` of a document). The copy lives under
`~/.local/state/mewo-on-fire/artifacts/<id>/`; a design's boards have their
`{{prop}}` placeholders filled with the props' defaults so they render on
their own, and a document has a `<name>.md.html` page beside it.

- Phone → PC: `{"type":"get_artifact","client_id":"…","session_id":"…","url":"…"}`.
- PC → phone: one `{"type":"artifact_file","client_id","path","part","parts","encoding":"text"|"base64","data"}`
  per chunk (under 600 KB each), then
  `{"type":"artifact_end","client_id","ok":true,"id","kind","entry","title"}`,
  or `{"type":"artifact_end","client_id","ok":false,"error":"…"}` when the
  files are gone.
- `mewo dashboard` serves the copies at `/artifact/<id>/<path>`; the Mac
  console reads them through its `mewo-artifact://a/<id>/<path>` scheme.

## The TORCH flow (v1.7)

Support for the TORCH Agentic Development Policy: a *workspace* is a folder
with `app-notebooks/` and `context/templates/SESSION_PLAN.md`; the daemon
remembers every workspace a session ran in (`workspaces.json` in its
state folder) and reads each feature's records from
`app-notebooks/{app}/features/{slug}/`.

### Session additions

`branch` (from the hook, `git branch --show-current` in `cwd`), `model`
and `tier` (1 strongest, 3 lightest, from the transcript), `feature`
(`app/slug`, from a `feature/{app}-{slug}` or `fix/{app}-{slug}` branch),
`plan_session` (the plan's session whose prompt the first message
matches), `checks` (the owner's self-check, Checklist F).

### Frames (phone ↔ PC)

- `get_features` → `features {ok, features: [...], workspaces, self_check,
  review_check, warning}`. A feature carries `key, app, slug, branch,
  light, workspace, dir, step (1..12), step_label, released, gates,
  plan, handoff_files, handoff_id, open_questions, repos, prd,
  prd_signed, warnings, sessions_merged, sessions_total`. A gate: `id`
  (`handoff1`, `handoff2`, `intake`, `plan`, `staging`, `uat`,
  `production`, `light`), `checklist` (D, E, I, J, K, L), `title`,
  `step`, `file`, `items [{text, checked}]`, `roles`, `signatures
  [{role, name}]`, `date`, `signed`, `present`. A plan session: the
  template's fields plus `effective` (`merged`, `review`, `progress`,
  `blocked`, `waiting`, `ready`), `note`, `running`, `attempts`, `live`,
  `pr_state`, `pr_url`, `pr_number`, `warnings`.
- `sign {client_id, feature, workspace, gate, role, name, checks:[bool]}`
  → `sign_result {ok, file, committed, signed, note, error}`. Ticks the
  confirmed items and writes the name and date into the record's
  signature table; commits when the workspace is on the feature branch.
- `plan_status {feature, n, status, pr}` → `plan_status_result`.
- `start_session {feature, n}` → `start_session_result`: Claude Desktop
  starts the plan's session with its prompt in its repository, and the
  plan's table says "In progress".
- `request_sign {feature, gate, role, name}` → `request_sign_result`,
  and a `signoff` event to every phone.
- `get_scan {session_id}` → `scan_result {ok, base, files, additions,
  deletions, findings [{rule, file, line, text}], counts}`: the session's
  changes against the feature branch (or main) checked for leftover
  TODOs, debug output, commented-out code, placeholder text, new
  dependencies, hardcoded colours, swallowed errors, large files and
  weakened tests (Checklists F and H).
- `set_check {session_id, index, checked}` → `set_check_result`; the
  session push carries `checks`.
- `get_artifact` also takes `id` (+ `entry`, `title`) for a folder the
  daemon exposed itself: a feature's handoff (`handoff_id`).

### Events

`warning` (a guard rail: a commit or push to main of a code repository
refused by the PreToolUse hook, or a session on main / an off-pattern
branch at SessionStart) and `signoff` (a signature asked for; `detail`
is `feature|gate|role`).

### Hooks

`mewo install` adds `SessionStart` (async) and `PreToolUse` with matcher
`Bash` (blocking, 10 s): the latter answers
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":…}}`
for a `git commit`, `merge`, `cherry-pick`, `revert` on main, a switch to
main followed by one, or a push to main, inside a workspace's code
repository.

### Control socket

`features`, `sign`, `plan_status`, `start_session`, `request_sign`,
`scan {session_id | dir, base}`, `set_check`, with the same fields.
`mewo dashboard` forwards them from `POST /api/daemon`; the Mac console
through its `daemon` message. On macOS the daemon needs Files and
Folders access to the workspace; while macOS holds it out, `features`
answers with the last known records and `warning` says so.

## The flow runner (v1.8)

The daemon drives a feature through the policy's twelve steps: Claude's
work runs as Claude Desktop sessions it starts with the right prompt and
skill (prd-writer, the design, handoff-intake, session-plan, the
planned build sessions), people's decisions come back as signatures.
Per feature, `flow.json` in the state folder keeps `autopilot`, the
runs (`step`, `started`), what was asked of whom and when, the
estimates and a short log.

A feature now carries `flow: {autopilot, estimates, estimates_done, log,
released_at, closed_at, action}`. `action` is what the flow does next:
`kind` (`run`, `ask`, `estimates`, `export`, `start`, `release`,
`close`, `wait`, `done`), `step`, `title`, `detail`, `gate`, `roles`,
`session`, `auto` (autopilot may do it by itself). The PRD's signature
is a gate of its own (`id: prd`, roles `[CEO]`): `sign` with gate `prd`
writes the newest draft as `…_PRD_V1.0.md` (status Signed, changelog
row) and the Register's §2 row. Step 2 (estimates) shows while the
three estimates are missing or not yet in the PRD.

`features` also returns `workspaces`, `roles` (workspace →
`[{role, name, phone}]`, from `context/roles.md`), `apps` (workspace →
notebooks) and `role_names`. A `signoff` event for a role whose row
names a phone carries `to: <device name>` and reaches that phone only.

Frames and control commands, all answered as `<name>_result`:

- `flow_next {feature, workspace, name}`: does the next action now.
- `flow_set {feature, autopilot}`: autopilot on or off. With it on, the
  daemon does every `auto` action every half minute, asking each role
  at most once a day.
- `estimate {feature, role, name, days, assumptions}` (design, FE or BE
  lead) and `estimates_done {feature}` (the estimates are in the PRD).
- `export_handoff {feature}`: the feature's design artifacts (the
  daemon's rendered copies) become `handoff/<board>.html` and the README.
- `uat_user {feature, user, role, unaided, notes}`: a row of RELEASE.md's
  UAT table and the pass-bar line; answers `{total, unaided, percent,
  pass}`.
- `release {feature, name}`: PRD status Released, changelog row, the
  Register's "Released on".
- `close_branches {feature}`: merges the feature branch into main in
  torch-main and every fetched code repository on it, pushes, deletes it.
- `new_feature {workspace, app, slug, light}`: `new-feature.sh`, or the
  same work done by the daemon when the Mac's bash is too old for it.
- `set_role {workspace, role, name, phone}`: a row of `context/roles.md`;
  from a phone, an empty `phone` means that phone.

## Rollback (v1.9)

Every write the flow makes lands in the feature's journal, `flow.history`
(newest first): `{id, ts, kind, title, files, commit, undoable, undone}`.
`kind` is `sign`, `prd`, `release`, `export`, `uat`, `estimate`,
`estimates_done`, `plan_status`, `run`, `start`, `new_feature` or
`close`; `commit` is the hash when the write was committed.

`rollback {feature, workspace, id}` → `rollback_result {ok, notes,
error}`: a committed entry is reverted with `git revert` on the feature
branch (a conflict is reported, nothing is forced); an uncommitted one
has its files restored from their last commit, or removed when they were
new; a `run` or `start` is forgotten so the flow offers the step again;
an `estimate` is dropped; `estimates_done` and `release` are unset; a
`new_feature` whose branch holds nothing but its start commit is
deleted with its folder. `close` (merged branches) is not undoable.

## The network (v2.0)

A daemon can pair with other PCs' daemons the way a phone does and stay
connected to them: it is then the hub of its network, and the console
that talks to it shows every PC. Peers live in `peers.json` (mode 600)
in the config folder: `pc_id, name, hosts, port, fp, token, device_id`.
The hub connects over the LAN with the certificate pinned by `fp`, sends
`auth {token, since}`, and keeps the peer's `sessions`, `session`
pushes, `event`s, `request`s and its `features` (asked every 30 s).

- The mDNS advertisement's TXT now carries `fp` next to `id`, so a hub
  can pair with the 8-character code from `mewo pair` alone.
- `hello` and `status` carry `account`: the Claude account's display
  name on that PC.

Control commands: `peers` → `{pc_id, name, account, peers: [{pc_id,
name, hosts, port, connected, error, host, last_seen, latency_ms,
account, sessions, working, waiting, events, requests, features}]}`;
`peer_scan {seconds}` → `{found: [{id, name, hosts, port, fp}]}`;
`peer_pair {payload}` (the line `mewo pair` prints, or `{id, name,
hosts, port, fp, code}`); `peer_remove {pc_id}`.

Any control command or phone frame that carries another PC's `pc_id` is
forwarded to that peer by the hub and answered with the peer's reply
(`client_id` and `pc_id` restored). `features` returns the peers'
features too, each with `pc_id` and `pc_name`, and the `peers` summary.
A feature carries `sync {remote, ahead, behind, local}` for its branch
in torch-main and `branches`, the fetched code repositories that have
the branch. Records are pulled (`--rebase --autostash`) before a write
and pushed after a commit; the hub fetches every workspace every 90 s.

`context/roles.md` has a fourth column, `PC`. When a plan session's
owner maps to a role whose PC is a connected peer that has the feature
with its branch ready, the flow starts that session there.

## Plane (v2.1)

The daemon mirrors the flow onto a Plane project: one work item per
feature (the parent), and under it one per sign-off (`Sign-off: …
(Checklist X)`), the PRD signature, the estimates, and each plan
session (`S2: …`). States move forward with the flow (backlog, todo
when the step is reached, in progress when asked or running, done when
signed or merged) and never back; a state someone sets in Plane stays.
Assignees come from `context/roles.md` (its new fifth column, the Plane
user id) and from the people who signed in; an assignee changed in
Plane wins, and a signature request then goes to that person's phone.
Every journal entry becomes a comment on the item. The sync runs every
minute and stays under Plane's 60 requests a minute. The markdown
records stay the truth: Done in Plane does not sign.

`plane.json` in the config folder (mode 600): `base_url, app_url,
workspace, project_id, project_name, token, items_path (work-items or
issues), states {group: id}, people [{plane_id, display, email, phone,
since}]`. `plane-map.json` in the state folder: which item is which.

Control commands (also phone frames where noted): `plane_test
{base_url, workspace, token}` → `{me, projects, members}`;
`plane_config {base_url, app_url, workspace, project_id, project_name,
token}` (an empty token keeps the saved one); `plane_status` →
`{config (no token), last_sync, last_error, items, members}`;
`plane_members`; `plane_sync`; `plane_disconnect`; `plane_signin
{token}` (phone frame: the PC fills `phone` in) → `{me}`; `plane_mine`
(phone frame) → the items assigned to that phone's person;
`plane_tasks {feature, n}` → the tasks under the session's item;
`plane_task_add {feature, n, name}` (assigned to the phone's person);
`plane_task_done {id, done}`. `features` carries `plane` (the
connection, no token) and each feature `plane: {parent, parent_url,
items: {key: {id, url, group, assignees, sequence_id}}}`.

# v2.2 — which PRD a feature follows

A feature's PRD is found by name: the file the session plan names, else
the newest `{App}_{Feature}_PRD_V…`, else the app's own
`{App}_App_PRD_V…`. When the PRD is named differently (a module PRD
such as `Contact_Center_Conversation_PRD_V1.0.md` for a feature called
`contacts-ui`), the feature can be pointed at a PRD *family*: the part
of the file name before `_PRD_V`. The newest version of that family
counts, so the pick survives the rename to V1.0 at signature.

Control commands (also phone frames): `prds {feature, workspace}` →
`{prd (file in use), source, prds: [{stem, display, file, folder,
version, signed, app, current}]}`, the app's own families first;
`set_prd {feature, workspace, prd}` with a stem or a file name (cut at
`_PRD_V`), empty to go back to the name match. The pick lives in the
flow state, is journaled as `prd_pick` (rolls back to the previous
pick) and shows in `features` as `prd_source: "picked"`.

# v2.3 — the design system a feature follows

The policy's default is Glare. A feature can follow another system (a
template such as `TORCH-Corp/tauri-templete`): the record is
`DESIGN_SYSTEM.md` in the feature folder, a `| Field | Value |` table
with System, Repository, Checkout (under the workspace, like
`code/tauri-templete`) and Reference (what to read first), committed on
the feature branch so every session and every PC reads the same. The
design prompt (step 4) draws on that system's shell, components and
tokens instead of Glare, the intake prompt (step 7) maps values to its
tokens, the session-plan prompt (step 8) names it, and the self-check
accepts its name and checkout folder in a line with a colour as it
accepts "glare".

Control command (also a phone frame): `set_design {feature, workspace,
name, repo, dir, reference}`; an empty name or "Glare" removes the
record. A missing checkout is cloned from `repo` when the daemon can;
otherwise the reply's `notes` say what to run. Journaled as `design`
(rolls back by reverting the commit). `features` carries each
feature's `design: {name, repo, dir, reference, present, checked_out,
glare}` and a warning when the checkout is missing.

# v2.4 — a step's session again

`flow_redo {feature, workspace, step, name, dry}` (also a phone frame)
starts a new Claude session with the step's prompt as it stands now
(steps 1, 2, 4, 7, 8), whatever the flow offers at the moment: a changed
PRD or design system reaches it this way. With `dry: true` the reply
only carries the `action` (its `prompt` included). For step 4 the flow
remembers `design_since`: boards made before it no longer count, so the
export takes the new ones; journaled as `redo`, which rolls back.

`session_forget {session_id}` (control socket; a prefix of the id
works) drops a session from the daemon for good with its feed events,
after its transcript under `~/.claude/projects/` was deleted; the
phones learn on their next list.

# v2.5 — review notes on a design

Notes pinned on a design's boards, the way a product team reviews with
a designer, kept per artifact under `<state>/notes/<artifact>.json`:
`{id, board, board_title, x, y (fractions of the board), text, status
open|sent|done, by, ts, sent_ts}`. Control commands: `notes {artifact}`;
`note_add {artifact, board, board_title, x, y, text, by}`; `note_set
{artifact, id, text?, status?}`; `note_remove {artifact, id}`;
`notes_send {artifact, ids?, title?, url?, dry?}` sends the open notes
as one review message to the session that made the design (the
phone's send path: `how` is `delivered` or `queued`), or opens a new
session with them when that session is gone (`how: new_session`), and
marks them `sent`; `dry: true` only returns the `message`. The console
draws the pins over the boards (NOTES, or N) with a rail of the notes
and the designer's latest word.

# v2.6 — the build autopilot

One button: every session of the plan runs by itself. `build_set
{feature, workspace, on, parallel?, review?}` (also a phone frame) turns
it on or off; on, it turns the flow's autopilot on too. Every 30 s the
daemon then, for the feature: writes Merged and In review into the plan
as GitHub says; starts a reviewer session for each open pull request
(Checklists G and H, lint, types, tests, the done-when items; it merges
with `gh pr merge --squash` into the feature branch, or fixes, or says
BLOCKED), at most two reviews per pull request, then a warning to the
phones; reminds a session that finished without a pull request through
the session's own chat, runs it again when it is gone or the reminder
went unanswered for 30 minutes (attempt 3 one tier up), and marks it
Blocked after three attempts with a warning; starts ready sessions,
`parallel` at a time across the network, one every tick. When every
session is merged it turns itself off and sends "Build done". `features`
carries `flow.build: {on, parallel, review}`; journal kinds `build`
(rolls back), `review`, `review_stuck`, `blocked`, `build_done`.

The build autopilot runs its sessions headless with the Claude Code
command (`claude -p … --dangerously-skip-permissions`, the Mewo guard
hook still refusing pushes to main; Tier 2 on Sonnet, Tier 3 on Haiku,
Tier 1 on the account's default), their output under `<state>/runs/`.
Claude Desktop's deep link only types a prompt in and waits for Enter,
so it serves the manual Start only. `build_set on` refuses, and the loop
stops with a warning, when the command is missing or not signed in
(the login keychain item "Claude Code-credentials").

`github_user {user}` pins the GitHub account (a `gh auth login` user)
the daemon, its git and gh commands and its headless sessions act as:
its token from gh's store goes into their environment as `GH_TOKEN`,
so another session switching gh's active account on the computer
changes nothing for the build. `github_status` → `{user, signed_in}`.
Kept in config.json as `github_user`; empty means the active account.

`session_detail {feature, workspace, n}` (also a phone frame) → one plan
session in full: `session` (goal, repo, tier, dependencies, status,
pull request, attempts, done-when), `run` (the headless run: pid,
alive, exit, elapsed, the log's tail), `review` (the reviewer session),
`live` (its Claude sessions with their last steps), `timing`
(started, in review, merged, elapsed, `typical_s` for the tier from
the sessions finished so far or a default, `eta_s` while it runs, and a
rough `build_remaining_s`). `session_stop {feature, workspace, n}`
ends its headless run and review with SIGTERM.

# v2.7 — pausing the build, and work hours

`build_set {on: false, resume_next_work: true}` pauses: what runs
finishes, nothing new starts, and the loop turns the build back on by
itself at the next work hours (`flow.build.resume_at`); with
`stop_running: true` the running sessions and reviews are ended too
(SIGTERM) and run again from their branches on resume; `resume_at` (ms)
sets the time directly; `on: true` resumes now. `work_hours {hours:
"09:00-18:00", days: [1..7]}` (local time, 1 = Monday; empty = always,
every day) is kept in config.json; outside them the build autopilot
starts nothing and reviews nothing, and the flow notes the change.
`features` carries `work: {hours, days, within, next_start}` and each
feature's `flow.build.within_hours`.

# v2.8 — every session in its own worktree

A build session runs in a git worktree of its repository,
`code/.worktrees/<repo>-S<n>` on `feature/<app>-<slug>-s<n>` made from
the feature branch (origin's copy when it has one); a review runs in
`code/.worktrees/<repo>-S<n>-review` on the pull request's branch. So
sessions of one repository run side by side, and the only limit is the
autopilot's "at a time". The worktrees are removed when the session is
merged; `code/.worktrees/` is in torch-main's local exclude. The
prompt tells the session where it is and where the workspace root is.
`session_detail.run.folder` says which folder a run used.

# v2.9 — merge on pass

`build_set {merge_on_pass: true}` (per feature, off by default, a
setting of the owner): when a pull request's review session ended with
the word PASS, the daemon marks the pull request ready and merges it
(squash) itself; GitHub records no approval, the reviewer's comment is
the record. A failed merge is journaled (`merge_failed`) and warned
once. The reviewer's brief asks for a closing PASS or BLOCKED line.
`flow.build.merge_on_pass` carries the setting.
