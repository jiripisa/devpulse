# Changelog

## Unreleased

- First version.
- "Install command line tool" in Settings › General puts `devpulse` on your PATH.
- Menu bar dashboard: your pull requests, review requests, Jira tickets and Claude Code sessions
  in one popover, with each source's last update or error; the icon counts direct review
  requests and sessions waiting for you.
- Notifications for new review requests, comments on your pull requests and tickets, finished CI
  runs, and Claude Code sessions that wait for you or finish; clicking one opens the page or the
  session. Each source and each kind of notification can be switched off in Settings.
- Settings window: refresh interval, launch at login, the quick launcher shortcut, GitHub status
  and team review requests, Jira site, e-mail and API token (kept in the Keychain) with a
  connection test, default repository and project, notifications and updates.
- Quick launcher on a global shortcut (⌥Space by default): type `gh` or `jira` to list, filter or open
  pull requests and tickets by title, number or key; ⌘Enter opens a pull request's Jira ticket.
- Clicking a Claude Code session brings its Ghostty window to the front.
- `devpulse` terminal UI, lazygit-style: numbered panels for pull requests, review requests, Jira
  tickets and Claude Code sessions with a detail pane, live updates, `/` filter, `?` help, mouse
  clicks and wheel, and automatic reconnect when the app restarts; `J` opens the Jira ticket of a
  pull request or session, and review requests are marked as direct or team ones.
- `devpulse upgrade` installs the latest version from the terminal.
- Updates: DevPulse asks at every launch whether a newer version exists and installs it only after
  you agree; Settings › Updates has "Check Now" and turns the automatic check off.
- GitHub and Jira refresh every 2 minutes (1–30 in Settings), pause while the Mac sleeps or the
  screen is locked, and refresh right after waking or unlocking.
- Website and manual in English and Czech.
