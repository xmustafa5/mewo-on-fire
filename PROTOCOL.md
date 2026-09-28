# ccnotify protocol (v1)

Two parts:
- `pc/` — Rust binary `ccnotify` (daemon + CLI + Claude Code hook) for any Linux.
- `mobile/` — Flutter Android app that pairs with one or more PCs and shows notifications.

All traffic is LAN only. The phone connects to the PC.

## PC files

| Path | Content |
|---|---|
| `~/.config/ccnotify/config.json` | `{"pc_id": "<16 hex>", "name": "<hostname>", "port": 47821}` |
| `~/.config/ccnotify/cert.der`, `key.der` | self-signed cert + PKCS#8 key (DER), generated on first run |
| `~/.config/ccnotify/devices.json` | `[{"id": "<8 hex>", "name": "Pixel 8", "token": "<64 hex>", "created": <ms>}]` (mode 600) |
| `~/.local/state/ccnotify/events.json` | `{"next_id": N, "events": [Event, ...]}` — last 500 events |
| `$XDG_RUNTIME_DIR/ccnotify.sock` | local control socket (fallback `/tmp/ccnotify-$USER.sock`) |

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
`ccnotify hook` always exits 0 and never blocks > 1 s (daemon down = silently drop).

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

- `hosts`: IPv4 of up, non-loopback interfaces, excluding names starting with `docker`, `br-`, `veth`, `virbr`, `lxc`, `tun`, `tailscale`, `wg`.
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
wins; if the PC answers first, Claude Code kills the hook process.

## Hook

Added by `ccnotify install` (not async, long timeout):

```json
"PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": "<bin> ask", "timeout": 86400}]}]
```

`ccnotify ask`:
1. Reads the hook JSON (`tool_name`, `tool_input`, `permission_suggestions`, `session_id`, `cwd`).
2. Sends `{"cmd":"ask","request":{Request without id/ts}}` on the control socket and **blocks** reading the reply line (no read timeout).
3. Reply `{"ok":false,"error":"no_devices"}` (sent immediately when no phone is connected) or any error / daemon down → print nothing, exit 0 (normal prompt flow).
4. Reply `{"ok":true,"answer":{Answer}}` → print the hook output below, exit 0.
5. If Claude Code kills the hook (PC answered first), the socket closes; the daemon notices EOF and resolves the request as `cancelled`.

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
| permission | `{"action":"deny","message":"..."}` | `decision: {"behavior":"deny","message": message or "Denied from phone (ccnotify)"}` |
| question | `{"answers":{"<question text>":"<label>"}}` | `decision: {"behavior":"allow","updatedInput": {...tool_input, "answers": answers}}` |
| plan | `{"action":"approve"}` | `decision: {"behavior":"allow","updatedInput": tool_input}` |
| plan | `{"action":"reject","message":"..."}` | `decision: {"behavior":"deny","message": message or "Plan rejected from phone (ccnotify)"}` |

Multi-select answers join labels with ", ". A typed custom answer is sent as the value text.

## Wire frames (after a successful `auth`, in addition to v1)

```
← {"type":"request","request":{Request}}     — sent live, and on (re)connect for every still-pending request
← {"type":"resolved","request_id":"<id>","by":"phone|pc|timeout"}   — answered elsewhere / cancelled
→ {"type":"answer","request_id":"<id>","answer":{Answer}}
```

- The first valid answer wins; the daemon then sends `resolved` (by `phone`) to all phones. An answer for an unknown/finished request gets a `resolved` reply to that phone only.
- When the hook connection closes before an answer: `resolved` with `by: "pc"`.
- Pending requests older than 24 h are dropped (`by: "timeout"`).
- Duplicate suppression: while a request is pending for session S, an `emit` of kind `needs_input` with the same `session` and `detail` `permission_prompt` or `elicitation_dialog` is dropped (not stored, not sent).

## Control socket additions

| Request | Response |
|---|---|
| `{"cmd":"ask","request":{...}}` | blocks → `{"ok":true,"answer":{...}}` / `{"ok":false,"error":"no_devices"}` |
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
