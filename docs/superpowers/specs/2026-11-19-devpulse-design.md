# DevPulse — design

Date: 2026-11-19
Status: approved by the user on 2026-11-19

## 1. Intent

DevPulse is a personal developer dashboard for macOS. It watches the three tools the user works in all
day: GitHub, Jira Cloud and Claude Code. The goal is that nothing important slips by and
every item is one click (or one keystroke) away from its page in the browser.

It has three faces over one shared set of data:

1. **Menu bar app**: an icon in the macOS menu bar with a popover dashboard. There is no Dock icon.
2. **Terminal UI**: the `devpulse` command opens a lazygit-style TUI. The user keeps it open in one
   Ghostty window for most of the day, so it must be **live** and update by itself.
3. **Quick launcher**: a floating search panel on a global hotkey. Typing `gh` lists PRs,
   typing `jira` lists tickets, and typing a number opens it in the browser.

The user's top non-functional priority is **speed and minimal system load**: CPU, RAM, and network
where possible.

## 2. Goals

### 2.1 Data shown

**My open pull requests (GitHub):**
- repository, PR number and title;
- the linked Jira ticket, when it can be detected;
- detail: check status, review state, comment count and the time of the last comment.

**Review requests:** open PRs where my review is requested.

**My open Jira tickets:** assigned to me and not done, with key, status and summary.

**Claude Code sessions:**
- every running interactive session on this Mac;
- its name and working directory;
- its state: **working** (`busy`), **waiting for my input** (`waiting`) or **idle** (`idle`);
- the linked Jira ticket, when the working directory name contains a key (e.g. `STORE-2290-…`).

Everything that has a page is clickable or openable:
- PR → GitHub;
- ticket → Jira;
- Claude session → its Ghostty window.

### 2.2 Notifications

Notifications are macOS user notifications. Each **source** (GitHub, Jira, Claude Code) has a
master switch in Settings, and every **trigger** below has its own switch too. Switching off one
source or one trigger leaves the others notifying. The triggers and their defaults are:

| Source | Trigger | Default |
|---|---|---|
| GitHub | a new **direct** review request for me | on |
| GitHub | a new review request for one of my teams | off |
| GitHub | a new human comment (issue comment, review or review comment) on one of my PRs | on |
| GitHub | a new comment or review by **Copilot** on one of my PRs | on |
| GitHub | a new comment by any other bot (CI, Sonar, Dependabot, …) on one of my PRs | off |
| GitHub | **CI finished** on one of my PRs: the check rollup of the head commit leaves pending and reaches a final state (success / failure / error); the notification says which | on |
| Jira | a new human comment on one of my tickets | on |
| Jira | a new comment by Jira automation or an app account on one of my tickets | off |
| Claude Code | a session changes to `waiting` (blocked on a prompt, e.g. a permission prompt; the file's `waitingFor` says what) | on |
| Claude Code | a session finishes its work: `busy` → `idle` | on |

The rules below were decided with the user. The order of reasoning is mine.
- Bots are told apart by author type: a GraphQL `Bot` author on GitHub, and on Jira an
  `accountType` other than `atlassian`. Copilot is the GitHub bot or app whose login contains
  `copilot`.
- My own comments never notify.
- The first fetch after install, or after a source was switched on, only records what exists; it
  never notifies about it.
- "Seen" state is persisted, so a restart does not repeat notifications.
- A Claude session notifies once per transition, into `waiting` or from `busy` to `idle`, and not
  again while it stays in that state.
- CI notifies once per head commit and final state. A new push starts a new cycle.
- Clicking a notification opens the PR or ticket, or focuses the Claude session's Ghostty window.

### 2.3 Refresh

- GitHub and Jira refresh automatically. The default interval is **2 minutes**, configurable in
  Settings (1–30 min).
- Fetching pauses while the Mac sleeps or the screen is locked. When the Mac wakes or the screen
  unlocks, one fetch runs right away.
- `r` in the TUI and a button in the popover force a refresh.
- Claude Code sessions are **not polled**. The app watches the session directory for file changes,
  so state changes show up immediately at near-zero cost.

### 2.4 Distribution

The project follows the user's `new-macos-app` skill pipeline:
- SwiftPM and `build.sh`, with no Xcode project;
- a public GitHub repo;
- a GitHub Pages site with a manual and a download link to the Developer ID-signed, notarized DMG;
- Sparkle auto-update.

`devpulse upgrade` in the terminal updates **headlessly**, as the user chose:
- It checks for an update, downloads and installs it, and prints progress and the result.
- It restarts the app; the TUI reconnects by itself.
- It needs no dialog. This takes a custom Sparkle user driver and progress/result messages in the
  socket protocol.

Automatic background updates **ask first**, using Sparkle's standard dialog. That is my call; the
user did not object to it.

Getting the CLI onto `PATH` must be as simple as possible for the user (see 5.6).

Decided by the user at approval:
- **License:** MIT.
- **Website languages:** English and Czech (EN + CS), with the manual in both.
- **Artwork:** the app icon and the GitHub Pages graphics are requested from **Codex** through the
  `codex:rescue` agent.
  - The icon is a macOS app icon **without a white border or frame** around the artwork.
  - It replaces the placeholder from `make_icon.swift`.

## 3. Non-goals

These are out of scope for v1:
- **Write actions.** No approving or merging PRs, no Jira transitions, no replying to Claude.
  DevPulse only shows things and opens them.
- **Integration with the system Spotlight via App Intents** (option Y). It is a later phase that
  starts with a spike to see what macOS 27 actually offers.
- **Other terminals than Ghostty** for focusing a Claude session.
- **Multiple accounts.** One GitHub account and one Jira site.
- **Remote Claude Code sessions.** Cloud and other machines are excluded.
- **Intel Macs and macOS older than 27.**

## 4. Anti-goals (failure even if it "works")

- **Noticeable load:** CPU or battery use while idle, or a large memory footprint. Budgets (my
  call, to be measured):
  - the menu bar app stays under about 40 MB of memory and near 0 % CPU between fetches;
  - the TUI stays under about 15 MB of memory and does not redraw when nothing changed.

  These are targets, not release gates. Memory is measured as physical footprint (Activity
  Monitor's "Memory"). An early spike measures the SwiftUI menu bar shell (`MenuBarExtra`,
  Settings, the launcher panel and Sparkle together). If it is far over the target, the UI moves to
  AppKit (`NSStatusItem`/`NSPopover`) before the rest of the UI is built.
- **Duplicate work:** the TUI and the menu bar app each fetching the same data, or both sending the
  same notification.
- **Noisy notifications:** repeats, notifications about my own comments, or a burst of old items
  on first run.
- **A live TUI that silently shows stale data.** When a fetch fails, the UI says so and shows the
  data's age.
- **A TUI that feels clunky** next to lazygit.

## 5. Decided design

### 5.1 Constraints

- **Minimum macOS 27** ("Golden Gate"), so the newest system APIs are available.
- **UI language** is English.
- **Toolchain:** Swift 6.4 is installed. The new-macos-app skill maps macOS 27 to
  swift-tools-version 6.4.

### 5.2 Architecture (approach B, chosen)

```
            ┌──────────────── DevPulse.app (Swift, menu bar, LSUIElement) ─────────────────┐
GitHub ◀──▶ │ GitHubSource ─┐                                                              │
Jira   ◀──▶ │ JiraSource ───┼─▶ Store (single source of truth) ─▶ Popover UI               │
~/.claude/  │ ClaudeSource ─┘        │            │              ─▶ Notifier               │
 sessions ─▶│ (FS watch)             │            └────────────▶ Launcher panel           │
            │                        ▼                                                     │
            │             local socket server ──────────────────────────────────────────┐ │
            └──────────────────────────────────────────────────────────────────────────│─┘
                                                                                        │ snapshot + updates
                              devpulse (Rust + ratatui, bundled in the app) ◀───────────┘
```

**The menu bar app owns all data.** It is the only process that fetches, watches files, persists
state and sends notifications.

**`devpulse` is a thin, live client.**
- On start it connects to the app's local Unix-domain socket and receives a full snapshot, then a
  push for every change. It never fetches anything itself.
- If the app is not running, `devpulse` launches it by bundle ID and waits for the socket.
- If the app quits while the TUI is open, the TUI shows a disconnected state and reconnects.

**The protocol** is my call: newline-delimited JSON over the socket.
- It is versioned.
- Messages: `snapshot`, `update`, `status` (fetch errors, last fetch time per source) and client
  commands (`refresh`, `upgrade`, `open <item>`).
- The Swift and Rust sides each own their model types. The JSON schema is the contract, and a
  shared fixture file is tested on both sides.

**The TUI is written in Rust with ratatui** (chosen over writing a TUI layer in Swift).
- Reason: lazygit-level polish with mature widgets and diff-based rendering, at very low resource
  use.
- The binary ships inside the app bundle. It is signed with the hardened runtime and updated
  together with the app by Sparkle.

### 5.3 Data sources

**GitHub:**
- **Authentication** reuses the existing `gh` CLI login: the app runs `gh auth token` at start and
  again after a 401, and keeps the token in memory only.
- **One GraphQL request per refresh** fetches:
  - the searches `is:open is:pr author:@me` and `is:open is:pr user-review-requested:@me` (direct
    requests);
  - when the team-requests setting is on, also `review-requested:@me`, with the direct ones
    subtracted;
  - for each PR: repo, number, title, URL, head branch, the head commit's OID and status-check
    rollup state, review decision and review counts, comment/review totals, and the most recent
    comments and reviews with author login, author type (User/Bot) and time.

  Fetching "only the latest comment" is not enough: a bot comment would hide a human one before
  it. The query fetches the last few comments and reviews of each kind, and new ones are found by
  comparing IDs with the persisted "seen" set.
- If `gh` is missing or logged out, Settings and the GitHub section say so and show the command to
  fix it (`gh auth login`).

**Jira Cloud:**
- **Authentication:** site URL, account e-mail and API token, entered in Settings. The token goes
  into the Keychain.
- **Query:** REST v3 JQL search, `assignee = currentUser() AND statusCategory != Done ORDER BY
  updated DESC`.
- **Fields:** key, summary, status, priority, updated, `issuelinks` (the related tickets), and the
  latest comment's author/time/ID. Whether the comment fields are enough to detect new comments by
  others is left to the builder (6).
- **Tickets of PRs that are not mine:** the keys of my PRs and review requests that are not among
  my tickets go into one bulk fetch (`POST /rest/api/3/issue/bulkfetch`), capped at 50 keys, with
  the same fields but no comments. It is skipped when my own search failed; when it fails itself,
  the PR shows just the key and the error is logged.
- The current user's account ID is fetched once, to filter out my own comments.

**Linking PRs to tickets:**
- A Jira key matching `[A-Z][A-Z0-9]+-\d+` is looked for in the PR title first, then in the head
  branch name.
- A Claude session gets a key the same way, from its working directory name.
- The ticket URL is `<jira site>/browse/<KEY>`.

**Claude Code:**
- The app watches `~/.claude/sessions/` for file changes (FSEvents or a dispatch source).
- Each `<pid>.json` holds `pid`, `name`, `cwd`, `status` (`busy` | `waiting` | `idle`), `kind` and
  `entrypoint`, among other fields.
- **Liveness:** a session counts as running only while its PID is alive and is a `claude`
  process. Stale files are ignored.
- **Risk:** this is an undocumented, internal Claude Code format. The parser must be lenient:
  unknown fields are ignored and a missing `status` shows as "unknown". It must not crash. If the
  format disappears, only this section degrades.

### 5.4 Menu bar app

- **Icon:** a SwiftUI `MenuBarExtra` (window style) with `LSUIElement`, so there is no Dock icon.
  The icon shows no badge or count.
- **Popover:** the same four sections as the TUI, as compact lists, plus each source's last fetch
  time and any error. Rows open their page.
- **Settings window:**
  - Jira site, e-mail and token;
  - GitHub status (from `gh`);
  - refresh interval;
  - notifications: a master switch per source and a switch per trigger (2.2);
  - "include team review requests" (off by default);
  - the default GitHub repo and the default Jira project for the launcher;
  - launcher hotkey;
  - launch at login, on by default (`SMAppService`);
  - "Install command line tool";
  - "Check for updates".

### 5.5 TUI (approved sketch)

The layout and the keys follow lazygit:
- numbered, bordered panels on the left (My pull requests, Review requests, Jira, Claude Code);
- a detail pane on the right;
- a key hint bar at the bottom.

```
╭─[1] My pull requests ─────────────────────────╮╭─ Detail ─────────────────────────────────╮
│ ▶ acme-webapp  #812  Replace invoice order…   ││ acmecorp/acme-webapp #812                │
│   acme-webapp  #798  Přehled příliš žluť…     ││ Replace invoice order on update          │
├─[2] Review requests ──────────────────── 2 ───┤│                                          │
│ ● webapp       #455  Column defs for …        ││ Jira    STORE-2474 · In Review           │
│   acme-webapp  #801  Fix statement export     ││ Checks  ✓ passing                        │
├─[3] Jira ─────────────────────────────────────┤│ Reviews 1 approved · 1 pending           │
│   STORE-2290  In Progress  Přehled příliš…    ││ Comments 3 · last 12 min ago             │
│   STORE-2474  In Review    Replace invoice…   ││                                          │
├─[4] Claude Code ──────────────────────────────┤│ enter  open in browser                   │
│ ◐ devpulse-b0     busy                        ││ J      open Jira ticket                  │
│ ● main-0f         waiting for input           ││                                          │
│ ○ store-2290-…    idle      → STORE-2290      ││                                          │
╰───────────────────────────────────────────────╯╰──────────────────────────────────────────╯
 ↑↓/jk move · 1-4 panel · enter open · / filter · r refresh · , settings · ? help · q quit
```

**Keys:**

| Key | Action |
|---|---|
| `↑↓` / `jk` | move |
| `1`–`4` / `Tab` | switch panel |
| `Enter` | open: browser for a PR or ticket, Ghostty window for a session |
| `J` | open the linked Jira ticket |
| `/` | filter |
| `r` | refresh |
| `,` | open Settings in the app |
| `?` | help |
| `q` | quit |

**Rendering and behavior:**
- Colors come from the terminal's ANSI palette, so the TUI matches the Ghostty theme.
- Redraws happen only on a socket update, a key press, a resize, or once a minute to refresh
  relative times.
- A header line shows each source's state: OK with its age, fetching, or error.
- Mouse support: click to select, scroll wheel (my call). A click on an underlined link in the
  detail opens it in the browser with `/usr/bin/open` (web links only), whatever modifier bits
  come with it, so ⌘-click works too.

**Subcommands:**
- `devpulse`: the TUI;
- `devpulse upgrade`: the headless update from 2.4, with progress in the terminal;
- `devpulse --version`.

### 5.6 CLI on PATH (my call)

Settings has an **"Install command line tool"** button, offered on first launch too, like VS
Code's "Install 'code' command in PATH".
- It creates the symlink `/usr/local/bin/devpulse` → `DevPulse.app/Contents/MacOS/devpulse` (or
  `Helpers/`), with one admin prompt.
- It creates `/usr/local/bin` if it is missing. On Apple Silicon `/usr/local/bin` is in the default
  `PATH`.
- Because it is a symlink into the bundle, every app update also updates the CLI. No separate
  install or upgrade step is needed.

### 5.6a Look ("Lookout", since 0.14)

The popover and the launcher share one visual language (designed with Codex, proposal kept outside
the repo): every row shows its kind on the left (icon and label in an identity colour: Jira blue,
PR violet, Review magenta, Claude cyan) and its state on the right as a shape plus a word
(`StatusBadge` in the core); a PR's CI and review state are separate badges. Colours come in light
and dark values (`Lookout` in the app); Settings › General › Appearance (System / Light / Dark, since
0.15) sets `NSApp.appearance`. A session waiting for input gets an amber bar and wash.
The launcher is a borderless Spotlight-like panel (1040 pt wide): the DevPulse mark and the search
field on a Liquid Glass bar (since 0.15), the results on an opaque card below it; once something is typed, results (with a count), the detail (heading, state, name,
identifier, an "Open in …" button, sections joined by a tree line) and a key line naming where
Enter goes.

### 5.7 Quick launcher (approach X, chosen)

A floating, non-activating panel (`NSPanel`) opens on a global hotkey. The default is ⌥Space; it is
configurable in Settings and must not collide with the system Spotlight shortcut.

Two panes (since 0.13): the results on the left, the detail of the selected result on the right. The
results never move under the selection: for one query they are only appended (`LauncherState`), and a
guess (a bare number's PR in each repository, ticket in each project) shows only once GitHub or Jira
confirms it, with "Searching Jira and GitHub…" below meanwhile. What the query names outright
(`gh <n>`'s first repository, `jira <KEY>`, `jira <n>`'s first project) shows at once. The detail:
for a ticket its PRs (mine and review requests linked to it, plus one GitHub search
`"KEY" in:title,body is:pr repo:…` over the repositories) and related tickets; for a PR or a session
its ticket (looked up when unknown) and that ticket's related tickets; up to 10 rows each, with
"Loading…" until Jira or GitHub answers and a note when they cannot be reached. Tab / Shift-Tab (and → / ←, which otherwise move the caret: → only when the detail has rows,
← only from the detail) move between the panes; Esc leaves the detail, then closes. The mouse selects only when it really moves.
A ticket moved to another project shows its new key with "Moved from <asked key>". A lookup that
fails (not one cut off because the selection moved on) shows the guess as "Open …" with "Jira / GitHub
could not be reached"; a source switched off in Settings is never asked.

| Typed | Result |
|---|---|
| `<number>` | everything with that number: my PRs and review requests in any repo, my tickets and my PRs' tickets in any project, sessions whose key or folder has it; then the PR in each of the Settings' GitHub repositories and the ticket in each of its Jira projects (up to 10 each; empty = the repos of my PRs / projects of my tickets). Those rows are looked up after a 300 ms typing pause (one Jira bulk fetch for all keys, one GitHub GraphQL request with an aliased `repository { pullRequest }` per repo, answers cached 5 min) to show title and state; ones that do not exist are dropped |
| `<words>` | (from two characters, not a prefix or a bare number) the known PRs, review requests, tickets (mine and my PRs') and sessions with every word (folded: no case, no diacritics) in title, key, repository or folder; then one Jira search (`project in (…) AND (summary ~ "w1 w2" OR summary ~ "w1 w2*")`: analysed words, or the last one as a prefix; words are trimmed of leading/trailing `-_.` so no operator gets through) and one GitHub search (`<words> in:title is:pr repo:…`), cached 5 min, appended; a failed search says "Jira or GitHub could not be searched" |
| `gh` | my PRs and review requests; arrows select, `Enter` opens |
| `gh <text>` | filters by title or repo |
| `gh <number>` | known PRs with that number, then PR `<number>` in each repository from Settings (looked up like a bare number's rows); the first repository's row stays as "Not found on GitHub" when the PR does not exist. Without repositories: those of my PRs, most PRs first. |
| `gh <repo> <number>` | opens that PR in that repo. `<repo>` is the name of a repository from Settings or of a known PR (e.g. `webapp`), or a full `owner/name`. |
| `jira` | my tickets |
| `jira <text>` | filters by summary |
| `jira <KEY-123>` | opens that ticket, even if it is not in my list; looked up like a bare number's rows, and "Not found in Jira" when it does not exist |
| `jira <123>` | ticket 123 of each Jira project in Settings; the first project's row stays (as "Not found") when it does not exist. Without projects: those of my tickets, most tickets first. |
| `Esc` | leaves the detail, then closes the panel |
| `⌘Enter` | opens the linked Jira ticket of a PR |

## 6. Approaches considered

**Architecture of the TUI:**

| | Approach | Trade-off | Decision |
|---|---|---|---|
| A | Everything in Swift; `devpulse` is the same binary in terminal mode | One language and build. No mature Swift TUI library, so panels, scrolling, resize, mouse and Unicode width are all custom work, and reaching lazygit polish is slow. | rejected |
| **B** | Swift menu bar app + Rust/ratatui TUI as a thin client over a local socket | Mature TUI stack, best polish, very low resource use. Costs two languages and two signed binaries. | **chosen** by the user |
| C | TUI and app fetch independently | Doubles the network traffic and duplicates notifications | dropped (anti-goal) |

**Quick search:**

| | Approach | Trade-off | Decision |
|---|---|---|---|
| **X** | Own launcher panel on a hotkey | Exactly the requested flow (`gh`/`jira` prefixes, arrows, numbers) and fully under our control | **chosen** for v1 |
| Y | System Spotlight via App Intents (macOS 27) | Native, but Apple controls the behavior. The `gh` prefix and arbitrary numbers are unverified. | **later**, after a spike |

## 7. Left to the builder

- Jira comment detection: whether the JQL search with the `comment` field is enough, or a cheap
  per-ticket check is needed only when `updated` changes. As on GitHub, compare comment IDs with
  the "seen" set rather than looking only at the latest comment.
- Whether to skip a Claude notification when that session's Ghostty window is already frontmost
  (nice to have, depends on what Ghostty exposes).
- GraphQL query shape and pagination limits. Assume tens of PRs, not hundreds.
- The socket path, e.g. under `~/Library/Application Support/DevPulse/`, with permissions 0600.
- How exactly to focus a specific Ghostty window. Check Ghostty's AppleScript/automation support;
  the fallback is to activate Ghostty.
- Where the Rust binary lives in the bundle, and how `build.sh` builds and signs it. It is
  arm64-only, given macOS 27; verify that macOS 27 has no Intel support.
- Persisting "seen" state, e.g. a small JSON file in Application Support.
- Bundle ID, repo questions, license and site languages: settled by the `new-macos-app` skill's
  own questions at scaffold time.
- The project directory already exists and holds this spec. The scaffold must cope with a
  non-empty target directory.
