# Remote Team

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native macOS menu bar app for teammates who check in through Discord. Requires an Apple silicon Mac running macOS 13 or later.

| Discord message | Status |
| --- | --- |
| `in` | Checked in with a green ring |
| `break` | On break with a yellow ring |
| `back` | Checked in with a green ring |
| `out` | Checked out and removed from the menu bar |

Use standalone messages in your chosen channel. A break requires a check-in that day. The roster automatically checks someone out nine hours after their first check-in of the team day, including during a break. This happens in the roster and does not post to Discord. The menu shows up to three photos and an “in” count that includes people on break. The roster automatically includes anyone who checked in during the past seven days. A checkout alone does not extend that window. Today’s work updates can still appear for authors without a recent check-in. Each person’s latest text update for the team day appears below their name and links to the original Discord message. Standalone attendance commands are excluded. By default, updates come from the check-in channel. Paste a separate Discord channel URL into **Settings → Discord connection → Work updates channel link**. The bot needs access to that channel. Click **Open work updates channel** in the roster to open the selected channel.

## Download and install

Download `Remote-Team-macOS-arm64.dmg` from [GitHub Releases](https://github.com/somratpro/discord-remote-team/releases). Open it and drag **Remote Team** into **Applications**. These builds are ad hoc signed and have no Apple notarization. The quarantine attribute is stripped during packaging so Gatekeeper should not block the app after dragging it to Applications.

GitHub Actions tests and packages a DMG on main, pull requests, and manual runs. Run `./package.sh` to package a DMG locally under `build/`.

### Publish a release

From a clean `main` branch on macOS, run one of these commands with pnpm installed:

```sh
pnpm run release:patch
pnpm run release:minor
pnpm run release:major
```

The command bumps the version and build number, creates the release commit and tag, and pushes both to GitHub. Actions builds the tagged version and publishes its DMG on Releases. If the push fails, fix the Git connection and rerun the command to retry the pending release.

## Connect your Discord bot

Each team creates a free Discord bot to read check-ins directly from their server. To set it up:

1. **Create the bot application**: Open the [Discord Developer Portal](https://discord.com/developers/applications) and click **New Application**. Give it a name (e.g. `Remote Team`).
2. **Enable Privileged Intents**: Go to the **Bot** tab on the left. Under **Privileged Gateway Intents**, turn on:
   - **Message Content Intent** (required to read `in`, `out`, `break`, `back` commands and updates)
   - **Server Members Intent** (required for role discovery and team directory)
   Click **Save Changes**.
3. **Copy the Bot Token**: On the same **Bot** page, click **Reset Token** (confirm with 2FA if prompted) and **Copy** the token.
4. **Invite the bot to your server**:
   - Go to **OAuth2 → URL Generator**.
   - Under **Scopes**, select `bot`.
   - Under **Bot Permissions**, select **View Channels** and **Read Message History**.
   - Copy the generated URL at the bottom, open it in your browser, and authorize the bot into your team's Discord server.
5. **Grant channel access**: In Discord, make sure the bot has access to view and read message history in your check-in channel (and optional work updates channel). Right-click the channel name and select **Copy Channel Link**.
6. **Connect the Mac app**: Open Remote Team on your Mac, go to **Settings** (gear icon), paste the channel URL and bot token, and click **Save & connect**. Each Mac stores the bot token securely in macOS Keychain.

Click an avatar to try the Discord DM route automatically. Right-click a teammate and choose **Set Discord DM link** to save the link copied from their conversation. A saved link takes precedence. Discord may require the actual conversation ID for some people. If Discord opens Friends, right-click the person in the Remote Team roster, choose **Open Discord profile**, and use **Message** in Discord. The desktop profile shortcut uses the Discord app if installed.

## Review the team directory

Open the roster menu and choose **Review team directory**. The app reads the check-in author's assigned Discord roles and the server's role catalogue. Approve exact job labels together, and teammates with those assignments inherit the title. Edit the recognized-title list if your server uses other job labels. A person with several approved roles can have a preferred role selected. It stays valid while their role is assigned and approved.

For a designation from Discord, open the teammate’s profile, copy the job-title line from **About Me**, and click **Paste from About Me** in the title review. For example, “Dev Team Lead at Example Studio” becomes “Dev Team Lead.” Discord’s documented bot API does not expose About Me, so the copied text supplies the title. The app saves the designation only.

Use **Export saved directory** and **Import** to move the saved titles, skills and ownership between Macs for the same Discord server. Import previews new and conflicting entries before saving. Each Mac keeps its own capacity, bot credential and DM links.

Right-click a roster entry and choose **Prepare handoff** to paste or write the exact draft for that person. Check the displayed Discord user ID if names collide. **Approve, copy & open DM** copies the text and opens Discord. Send it in Discord after verifying the conversation. The profile shortcut provides a fallback.

## Connect an AI client

Choose **Copy AI setup prompt** in Settings or the roster menu. Paste the prompt into a client with local stdio MCP support on the same Mac. The prompt contains the executable path, local configuration and delegation instructions. The client may require approval to register the server or enable its tools.

Call the read-only `list_team` tool once with no arguments for availability questions. It returns a summary, counts, check-in timestamps, job titles and their sources, skills, ownership, current capacity, and Discord navigation links in one response. Connected AI clients can also call `find_teammate` to filter by skills or project ownership, or `get_daily_summary` for an automated Markdown standup report. Repeated calls within five seconds can reuse the same Discord snapshot while recalculating the current statuses. It uses the local Keychain credential. Clients that support persistent instructions can use the supplied prompt to ask about delegation for substantial tasks, get the team roster and draft a handoff. Sending a DM requires an authorized messaging interface and explicit approval of the recipient and draft.

Grok Build can register the command as a [local stdio server](https://docs.x.ai/build/features/mcp-servers). The xAI API's [remote MCP integration](https://docs.x.ai/developers/tools/remote-mcp) requires a hosted server URL. For Dot, verify that the actual host can register or bridge the local stdio command, discover `list_team`, and complete a test call before using it for handoffs.

## Tests

From the source directory run:

```sh
test_dir="$(mktemp -d)"
xcrun swiftc Discord.swift Directory.swift MCP.swift Tests/main.swift -o "$test_dir/remote-team-tests"
"$test_dir/remote-team-tests"
```

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, code map, testing requirements and pull request process.

## License

Released under the [MIT License](LICENSE). Copyright 2024 Somrat Claw.
