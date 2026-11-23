# Remote Team

A native macOS menu bar app for teammates who check in through Discord. Requires macOS 13 or later.

| Discord message | Status |
| --- | --- |
| `in` | Checked in with a green ring |
| `break` | On break with a yellow ring |
| `back` | Checked in with a green ring |
| `out` | Checked out and removed from the menu bar |

Use standalone messages in your chosen channel. A break requires a check-in that day. The roster automatically checks someone out nine hours after their first check-in of the team day, including during a break. This happens in the roster and does not post to Discord. The menu shows up to three photos and the available count. The roster includes recent check-in authors and people who posted a work update today. Each person’s latest text update for the team day appears below their name and links to the original Discord message. Standalone attendance commands are excluded. By default, updates come from the check-in channel. Set **Work updates channel** in Settings to read them from a separate channel the bot can access.

## Download and install

Download the universal DMG from [GitHub Releases](https://github.com/somratpro/discord-remote-team/releases). Open it and drag **Remote Team** into **Applications**. These builds are ad hoc signed and have no Apple notarization. If Gatekeeper blocks the downloaded app, use [Apple’s instructions for opening an app you trust](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

GitHub Actions tests and packages a DMG on main, pull requests, and manual runs. Run `./package.sh` to package a DMG locally under `build/`.

### Publish a release

From a clean `main` branch on macOS, run one of these commands with pnpm installed:

```sh
pnpm run release:patch
pnpm run release:minor
pnpm run release:major
```

The command bumps the version and build number, creates the release commit and tag, and pushes both to GitHub. Actions builds the tagged version and publishes its DMG on Releases. If the push fails, fix the Git connection and rerun the command to retry the pending release.

## Build and connect

Run `./build.sh` with Apple's Swift command line tools. Move the resulting app to Applications, open Settings, and paste the check-in channel URL. Install a Discord bot with **View Channels** and **Read Message History** for that channel, and enable **Message Content Intent**. Paste the bot token in Remote Team Settings. Each Mac stores its credential in Keychain and reads attendance from Discord. See [Discord’s bot setup guide](https://docs.discord.com/developers/quick-start/getting-started).

Click an avatar to try the Discord DM route automatically. Existing saved DM links take precedence. Discord may require the actual conversation ID for some people. If Discord opens Friends, right-click the person in the Remote Team roster, choose **Open Discord profile**, and use **Message** in Discord. The desktop profile shortcut uses the Discord app if installed.

## Connect an AI client

Choose **Copy AI setup prompt** in Settings or the roster menu. Paste the prompt into a client with local stdio MCP support on the same Mac. The prompt contains the executable path, local configuration and delegation instructions. The client may require approval to register the server or enable its tools.

Call the read-only `list_team` tool once with no arguments for availability questions. It returns a summary, counts, check-in timestamps and Discord navigation links in the same response. Repeated calls within five seconds can reuse the same Discord snapshot while recalculating the current statuses. It uses the local Keychain credential. Clients that support persistent instructions can use the supplied prompt to ask about delegation for substantial tasks, get the team roster and draft a handoff. Sending a DM requires an authorized messaging interface and explicit approval of the recipient and draft.

## Tests

From the source directory run:

```sh
test_dir="$(mktemp -d)"
xcrun swiftc Discord.swift Tests/main.swift -o "$test_dir/remote-team-tests"
"$test_dir/remote-team-tests"
```
