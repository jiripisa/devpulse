---
name: release
description: Use when the user wants to release, publish or ship a new version of DevPulse ("udělej release", "vydej novou verzi", "make a release"), or to build the signed and notarized DMG for distribution.
---

# Releasing DevPulse

A release is: version bump → tests → signed + notarized DMG + appcast →
merge + tag → GitHub Release → website → live checks. Every step
below has a check; a step is not done until its check passed.

**Pushing needs the user's explicit OK** (global rule). Before step 5 ask
one bold question that names all three pushes of this release (tag, GitHub
Release, `main`) and, if the repo is still private, making it public,
plus the catalog update of step 7 (a push to `jiripisa/jiripisa.github.io` or a
rebuild of it), unless the user has already said yes to exactly that in the
conversation.

## 1. Prepare

1. `git status` clean, on `main`, up to date. Create the branch `release/vX.Y.Z`.
2. Pick the version. The **first release is 0.1.0** (the version the skeleton
   already carries and the website links point at). After that: patch for
   fixes and small additions, minor for new features or removed UI, major only
   when the user says so. Say which and why.
3. `CHANGELOG.md`: rename `## Unreleased` to `## X.Y.Z — YYYY-MM-DD`. If there
   is no Unreleased section, write the entries from `git log` since the last tag
   first. These lines become the GitHub Release notes and the text of the update
   dialog.
4. Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in
   `Resources/Info.plist`.
5. Replace the old version in the website: `grep -rn "<old version>" docs/*.html docs/cs/*.html`
   (download links `releases/download/v…/DevPulse-….dmg` and version texts).
   Leave `docs/appcast.xml` alone; `build.sh dist` writes it.

Check: `swift test` green (redirect the output to a file, read the summary line).

## 2. Build the DMG

`./build.sh dist` — takes several minutes (two notarizations); run it in the
background and wait for it to finish.

Check, all of them:
- the log shows `status: Accepted` twice and ends with `Done!`;
- `spctl -a -vv build/release/DevPulse.app` says `source=Notarized Developer ID`;
- `git diff docs/appcast.xml` shows the new version, the new download URL
  and a new `sparkle:edSignature`.

A `403 … agreement is missing or has expired` from notarytool means the user
must accept the new Apple agreement at developer.apple.com/account — stop and
tell them.

## 3. Screenshots (when the UI changed)

**Never capture the release build, the installed app or any window that shows
real data** (your PRs, tickets and sessions are an employer's data). Shots come
only from the DEBUG demo with `scripts/demo-snapshot.json`, as
`development_workflow.md` §3 describes:

1. `./build.sh debug`, then copy `build/debug/DevPulse.app` to a scratch folder,
   give the copy its own bundle id (`io.jp4.devpulse.shots`) and re-sign it ad
   hoc, so it never writes into the `io.jp4.devpulse` domain.
2. Start the copy's binary with `-DevPulseDemoSnapshot "$PWD/scripts/demo-snapshot.json"`
   and `-DevPulseDemoOpen <launcher:<query>|popover|settings:<tab>>`; note its PID.
   For the TUI, run the debug `Contents/Helpers/devpulse` in a terminal you start
   yourself, with `DEVPULSE_SOCKET` set to the demo's socket.
3. Pick the window by that PID from `CGWindowListCopyWindowInfo` and capture
   only it: `screencapture -x -o -l <window id>`. Never the whole screen, never
   another process's window. Look at every image.
4. Replace the matching files: `docs/assets/manual/*.png`, then run
   `swift scripts/artwork/compose.swift` for `docs/assets/hero.png` and
   `docs/assets/og-image.png`. Check the manual's marks (`--iw`/`--ih`, `--x`/`--y`)
   in EN and CS when an image changed size.
5. Quit the demo by its PID, then clean up: `defaults delete io.jp4.devpulse.demo`
   and `defaults delete io.jp4.devpulse.shots`, remove the scratch copy (unregister
   it with `lsregister -u` first) and a leftover `devpulse-demo.sock`.

## 4. Commit, merge, tag

1. Update `.planning` if the project uses it (ROADMAP row, STATE line,
   `phases/NN-vX.Y.Z-release/VERIFICATION.md` with the checks above).
2. `git status`, then commit (never with AI attribution trailers): `chore(release): vX.Y.Z — version bump, CHANGELOG, appcast, website`.
3. `git switch main && git merge --no-ff <branch> -m "chore: merge … — vX.Y.Z release"`,
   delete the branch, `git tag vX.Y.Z` (lightweight).

## 5. Publish (order matters)

0. `gh repo view jiripisa/devpulse --json visibility --jq .visibility`. If it says
   `PRIVATE` (the project was kept private until its first release), and the
   user agreed in the bold question:
   `gh repo edit jiripisa/devpulse --visibility public --accept-visibility-change-consequences`,
   then turn on Pages:
   `gh api -X POST repos/jiripisa/devpulse/pages -f "source[branch]=main" -f "source[path]=/docs"`.
1. `git push origin vX.Y.Z`
2. Copy `build/DevPulse.dmg` to a scratch folder as `DevPulse-X.Y.Z.dmg` and run
   `gh release create vX.Y.Z <that file> --title "DevPulse X.Y.Z" --notes-file <CHANGELOG section>`.
3. Check: `curl -sIL -o /dev/null -w "%{http_code}" https://github.com/jiripisa/devpulse/releases/download/vX.Y.Z/DevPulse-X.Y.Z.dmg` → `200`.
4. Only now `git push origin main` (it carries the appcast; the DMG must
   already exist).

## 6. Live checks

1. Wait for the Pages deploy: `gh run list --limit 1`, then `gh run watch <id> --exit-status`.
2. `curl -s "https://jiripisa.github.io/devpulse/?x=$RANDOM" | grep -o "X.Y.Z"` shows the new version;
   the same for `https://jiripisa.github.io/devpulse/cs/`.
3. Download the DMG from the release URL and the live appcast
   (`https://jiripisa.github.io/devpulse/appcast.xml`), then
   `.build/artifacts/sparkle/Sparkle/bin/sign_update --verify <dmg> <edSignature from the live appcast>`
   must print nothing and exit 0 — the feed's signature matches the published bytes.

## 7. Project catalog

Only after the live checks passed: run the global `update-catalog` skill for
vX.Y.Z. It puts DevPulse into the right section of the catalog at
https://jiripisa.github.io/, updates its summary when this release changed what the
app does, and publishes the catalog so the new download shows there.

## Report

Tell the user: the release URL, what was pushed, the results of every check,
the version choice and why, and ask them to confirm that an installed older
version offers the update.
