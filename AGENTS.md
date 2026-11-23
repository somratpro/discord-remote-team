# Remote Team

This file applies to the whole project. Read the README for user-facing setup. Keep this file current when changing behavior, architecture, or release steps.

## Scope and invariants

- Remote Team is a native macOS 13+ menu bar app for Discord-based team check-ins and work updates. SwiftUI renders the views, and AppKit manages the status items and roster panel. The app builds for Apple silicon and Intel using Apple's command line tools.
- Discord is the source of truth. Keep message history and derived attendance in memory. Store preferences in UserDefaults and the Discord bot token in macOS Keychain. Keep credentials, private channel IDs, user IDs, private message text and generated binaries out of source control. Use synthetic fixtures.
- Maintain compatibility with existing installations. The display name is Remote Team, but the bundle ID is `com.teamcheckin.mac`, the executable is `TeamCheckin`, and the Keychain service is `TeamCheckin.Discord`. Changes to those identifiers need migration for settings, Keychain and MCP clients.
- Keep setup minimal. A fresh install asks for a Discord check-in channel and a bot token. The bot needs View Channels, Read Message History, and Message Content Intent. The optional work updates channel uses the check-in channel when blank. The prior roster-message setting was removed.
- The operator can share a universal DMG with a partner. Each Mac connects to Discord independently with an authorized bot credential and uses its own signed-in Discord account for DMs. Source lives in this directory. Installation, packaging, and Git publishing are separate actions.

## Code map

| File | Responsibility |
| --- | --- |
| `Discord.swift` | Discord channel and message URLs, API client, pagination, Keychain, attendance rules and work-update matching |
| `State.swift` | App settings, periodic refresh, in-memory snapshots, status text and avatar fetching |
| `Views.swift` | SwiftUI roster, update previews, Settings, and sample preview |
| `main.swift` | AppKit menu bar and panel, DM/profile navigation, launch and wake handling, and dispatch to stdio MCP |
| `MCP.swift` | JSON-RPC stdio, `list_team`, and the copyable setup prompt |
| `build.sh`, `Info.plist`, `Icon.swift` | Universal compilation, bundle metadata, icon generation and local signing |
| `Tests/main.swift` | Deterministic roster, work-update, navigation, and mocked Discord API tests |

## Attendance and updates

- Match the complete trimmed, case-insensitive message against `in`, `out`, `break`, or `back`. Ignore bot and webhook messages. Ignore a break or return that has no matching current state. Process attendance chronologically by Discord message ID.
- Calculate team-day boundaries in the configured timezone, with Asia/Dhaka as the default. Track the first `in` independently of the latest status change. A person still checked in or on break becomes **Auto out** nine elapsed hours after their first `in` of the team day. A manual `out` retains its posted time. Attendance changes derived by the app stay local.
- Show up to three checked-in or on-break photos in the menu bar, with green and yellow rings respectively. Count only checked-in people as available. The borderless roster has a compact heading in its body. The close control hides it, and the footer provides Pin, Settings and refresh.
- Clicking an avatar tries a saved DM URL or the ID-based route. A Discord conversation ID can differ from the user ID. Keep the **Open Discord profile** fallback, and leave message sending to the user or an independently authorized interface.
- In the chosen updates channel, show each author's latest human text update for the current team day. Exclude standalone attendance commands and link to the source message. An update-only author appears in the UI with no attendance update. Keep a separate updates-channel failure from clearing the attendance roster, and surface stale updates in the UI.
- Refresh the app roughly every 20 seconds, and reconcile on launch, wake and manual refresh. Preserve pagination, Discord rate-limit backoff, stale-state disclosure and cancellation when settings change.

## MCP and agent handoffs

- The installed stdio command is `/Applications/Remote Team.app/Contents/MacOS/TeamCheckin --mcp`. Stdout is reserved for newline-delimited JSON-RPC. Read the Keychain credential locally. The copyable connection prompt contains the command and instructions, with the token kept in Keychain.
- For an availability question, call `list_team` once with no arguments and answer from its result. Preserve the summary, counts, available/on-break names, full attendance roster, timestamps, and Discord navigation links in that single response. It exposes attendance through MCP. Work-update text is displayed in the app.
- The MCP server can reuse a Discord snapshot for up to five seconds per process and recalculates status at call time. A new fetch follows the saved check-in channel setting. A temporary app launch with a channel override can make the app and MCP read different channels, so pass the same override to both during an isolated test.
- For a substantial task that a human could take on, ask if the operator wants to delegate. If they agree, use `list_team`, suggest checked-in teammates, and let the operator select a recipient. Draft the goal, deliverable and deadline if known. Show the draft and send only with explicit approval of the exact recipient and message through an authorized Discord interface. Provide the link and draft if sending is unavailable. The app's MCP server is read-only.

## Build and verification

Run from the project root:

```sh
test_dir="$(mktemp -d)"
xcrun swiftc Discord.swift Tests/main.swift -o "$test_dir/remote-team-tests"
"$test_dir/remote-team-tests"
./build.sh
codesign --verify --strict "build/Remote Team.app"
lipo -archs "build/Remote Team.app/Contents/MacOS/TeamCheckin"
```

- Build and verify before replacing an installed app. The build is ad hoc signed. Keep a recoverable copy when replacing the local app. If delivering a partner DMG, verify the image and confirm it contains the same build.
- For UI changes, check Preview and the normal roster. For Discord behavior, use a designated test channel and confirm the visible status or work update. Get authorization for live test posts or bot permission changes. Avoid changing the operator's saved channel just to run a test.
- For MCP changes, verify initialize, tools/list, and tools/call over stdio. If Codex is the target client, verify a tool call through Codex too. Report which checks used synthetic data and which reached live Discord, and omit private roster contents from test logs.
