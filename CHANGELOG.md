# Changelog

## Unreleased

- In the quick launcher, move to a ticket or a pull request and rest there for half a second:
  it expands. A ticket shows its pull requests (yours, and those GitHub finds with its key in
  your repositories) and its related tickets; a pull request shows its ticket and that ticket's
  related tickets. The arrow keys move into the indented rows, and Enter opens one.
- The mouse moves the launcher's selection too.

## 0.11.0 — 2026-11-23

- Settings › GitHub › Repositories: list the repositories (`owner/name`, or a pasted GitHub
  address) in which the quick launcher looks up a bare number and `gh <number>`; it shows a row
  for each of them with the pull request's title and state. It replaces the single default
  repository, and your earlier choice is kept as the first entry.
- `gh <name> <number>` also knows the repositories from that list by their name.
- The quick launcher asks GitHub about all those pull requests in one request.

## 0.10.0 — 2026-11-22

- Settings › Jira › Projects: list the Jira projects (`STORE, WA`) in which the quick launcher
  looks up a bare number and `jira <number>`; it shows a row for each of them. It replaces the
  single default project, and your earlier choice is kept as the first entry.
- The quick launcher shows the title and state of tickets and pull requests that are not in your
  lists: once you stop typing, it asks Jira and GitHub about them (one request each). Tickets or
  pull requests that do not exist disappear from a bare number's results, and `jira <key>` or
  `gh <number>` say "Not found".
- The quick launcher also finds the tickets of your pull requests that are not assigned to you.
- A pull request links to a Jira key of any project in the list, not only the default one.

## 0.9.1 — 2026-11-20

- In the `devpulse` terminal UI, a plain click (or ⌘-click) on an underlined link in the detail
  opens it in the browser; ⇧⌘-click is no longer needed.

## 0.9.0 — 2026-11-20

- `,` in the `devpulse` terminal UI opens Settings in front of the terminal; before, the window
  could open behind it.
- The quick launcher's hint reads "Number, gh … or jira …" in a lighter grey, so it no longer
  looks like typed text.
- Type just a number in the quick launcher to find it everywhere: your pull requests and review
  requests with that number in any repository, your Jira tickets with it in any project, and
  Claude Code sessions whose Jira key or folder has it, plus rows for the default repository and
  project. Each row shows an icon for what it is.
- No more number next to the menu bar icon.
- A new app icon, a radar, and a new menu bar icon, a sonar dial. The app icon fills the macOS
  icon shape; before, it sat small on a light tile.
- In the `devpulse` terminal UI, ⌘-click the Jira key, the branch, the pull request's title or a
  related ticket in the detail to open it in Jira or on GitHub (in Ghostty and other terminals
  with hyperlinks).
- The terminal UI's detail shows a ticket's related Jira tickets (blocks, is blocked by, relates
  to …) with key, status and summary.
- A pull request's detail in the terminal UI shows the status and the related tickets of its
  Jira ticket also when that ticket is not assigned to you.
- The website shows real screenshots of the app.
- Building from source now needs Xcode; the Command Line Tools alone are no longer enough.

## 0.1.0 — 2026-11-20

- First version.
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
- "Install command line tool" in Settings › General puts `devpulse` on your PATH.
