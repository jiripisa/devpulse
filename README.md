# DevPulse

Your GitHub PRs, Jira tickets and Claude Code sessions — live in the menu bar and the terminal.

DevPulse is a menu bar app for macOS 27 or later. It shows your open pull
requests, review requests, Jira Cloud tickets and running Claude Code sessions
in one popover, and the same data live in the terminal with `devpulse`, a
lazygit-style dashboard. Every item opens with one click or key. It notifies
you about review requests, comments, finished CI runs and Claude Code waiting
for you, and `⌥Space` opens a quick launcher for `gh …` and `jira …`.

- Website: https://jiripisa.github.io/devpulse/
- Manual: https://jiripisa.github.io/devpulse/manual.html (Czech:
  https://jiripisa.github.io/devpulse/cs/manual.html)

## Install

1. Download the DMG from the [website](https://jiripisa.github.io/devpulse/#get) or
   the [latest release](https://github.com/jiripisa/devpulse/releases/latest) and
   drag DevPulse to Applications.
2. Sign in to GitHub with the GitHub CLI: `gh auth login`.
3. In Settings › Jira, enter your site, e-mail and an
   [API token](https://id.atlassian.com/manage-profile/security/api-tokens).
4. In Settings › General, click Install next to "Command line tool" to put
   `devpulse` on your PATH.

DevPulse updates itself (it asks first); `devpulse upgrade` updates from the
terminal.

## Development

Native SwiftUI app built with Swift Package Manager and shell scripts; no
Xcode project. The terminal client in `tui/` is Rust.

### Build and run

You need the Xcode command line tools and a Rust toolchain.

```
./run.sh            # debug build, runs in the terminal with logs (Ctrl+C quits)
./run.sh release    # optimized build, opens the app
swift test          # tests
./build.sh dist     # signed, notarized DMG (needs a Developer ID, see development_workflow.md)
```

Details: [development_workflow.md](development_workflow.md).

## License

MIT License, see [LICENSE](LICENSE).
