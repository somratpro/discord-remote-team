# Contributing to Remote Team

Thank you for taking the time to contribute! This is a small focused macOS app, so contributions that keep things simple and minimal are most welcome.

## Ground rules

- Remote Team is a **native macOS 13+ app** built with SwiftUI and AppKit, compiled for Apple silicon with Apple's command-line tools. Keep it that way — no external package managers or third-party Swift packages.
- Discord is the source of truth. No local databases, no synced cloud state.
- Keep credentials, private channel IDs, real user IDs, real message text and generated binaries out of the repository. Use synthetic fixtures in tests.
- All test cases go in `Tests/main.swift` using the existing lightweight harness. Run the full verification suite before opening a pull request.

## Development setup

You need a Mac with Apple silicon running macOS 13 or later and Xcode Command Line Tools.

```sh
xcode-select --install
git clone https://github.com/somratpro/discord-remote-team.git
cd discord-remote-team
```

Build and run verification in one command:

```sh
test_dir="$(mktemp -d)"
xcrun swiftc Discord.swift Directory.swift MCP.swift Tests/main.swift -o "$test_dir/remote-team-tests"
"$test_dir/remote-team-tests"
./build.sh
codesign --verify --strict "build/Remote Team.app"
lipo -archs "build/Remote Team.app/Contents/MacOS/TeamCheckin"
```

All tests must pass and the final output must be `arm64`.

## Code map

| File | Responsibility |
| --- | --- |
| `Discord.swift` | Discord API client, pagination, Keychain, attendance rules, work-update matching |
| `Directory.swift` | Guild role discovery, designation resolution (operator → bio → role), profile storage |
| `State.swift` | Periodic refresh, in-memory snapshots, status text, avatar fetching |
| `Views.swift` | SwiftUI roster, Settings, simplified Team Directory |
| `main.swift` | AppKit menu bar and panel, DM navigation, stdio MCP dispatch |
| `MCP.swift` | JSON-RPC stdio: `list_team`, `find_teammate`, `get_daily_summary` |
| `Tests/main.swift` | Deterministic unit tests with mocked Discord API |

## Submitting changes

1. Fork the repository and create a branch from `main`.
2. Make your change. Update `AGENTS.md` if you change behavior, architecture or release steps.
3. Run the full verification suite above and confirm everything is green.
4. Open a pull request with a short description of the problem and the solution.

For large changes, open an issue first to discuss the direction.

## Reporting bugs

Open a [GitHub issue](https://github.com/somratpro/discord-remote-team/issues) with:
- macOS version and Mac chip
- Steps to reproduce
- What you expected vs what happened

Do **not** include real bot tokens, channel IDs or private message content.

## Code style

Follow the conventions already in the file you are editing. No linter is enforced, but keep it consistent: 4-space indentation, short functions, no force unwraps outside of well-understood safe paths.
