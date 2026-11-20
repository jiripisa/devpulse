# DevPulse — Development Workflow, Build & Distribution

## 1. Toolchain & Project Layout

- Xcode (Swift 6), macOS 27+. The Command Line Tools alone are not enough,
  because `actool`, which compiles the app icon and the asset catalog, comes
  with Xcode. No Xcode project: Swift Package Manager builds the code,
  `build.sh` assembles the `.app` bundle.
- A Rust toolchain (`rustup`, stable) for the terminal client in `tui/`;
  `build.sh` runs `cargo build` for it.

```
devpulse/
├── Package.swift
├── Sources/DevPulse/          # SwiftUI app (thin layer)
├── Sources/DevPulseCore/      # logic without UI, tested
├── tui/                     # Rust terminal client `devpulse` (cargo)
├── Tests/DevPulseCoreTests/   # Swift Testing
├── Resources/               # Info.plist, entitlements, AppIcon.png (1024 px master),
│                            # AppIcon.icon, Assets.xcassets (menu bar icon)
├── scripts/make_appcast.py  # Sparkle feed, called by build.sh dist
├── scripts/artwork/generate.swift  # draws the icon and menu bar glyph: swift … <dir>, by hand only
├── scripts/artwork/compose.swift   # website hero + og-image from the screenshots, by hand only
├── docs/                    # GitHub Pages website + manual
├── build.sh                 # debug | release | dist | clean
└── run.sh                   # debug (logs in terminal) | release (open .app)
```

## 2. Build (`build.sh`)

| Command | Result |
|---|---|
| `./build.sh` / `./build.sh debug` | `swift build` → `build/debug/DevPulse.app` (ad-hoc signed) |
| `./build.sh release` | same with `-c release` → `build/release/DevPulse.app` |
| `./build.sh dist` | release build → **Developer ID signing (hardened runtime)** → notarized + stapled app → **DMG** → notarized + stapled DMG → `docs/appcast.xml` |
| `./build.sh clean` | removes `build/` and `.build/` |

### 2.1 App-bundle assembly (all modes)

Executable → `Contents/MacOS`, `Resources/Info.plist` → `Contents/`, the app
icon and the asset catalog → `Contents/Resources/Assets.car` and a fallback
`AppIcon.icns` (see 2.1.1), Sparkle.framework →
`Contents/Frameworks` (XPC services removed; the app is unsandboxed), PkgInfo,
the terminal client → `Contents/Helpers/devpulse` (`cargo build` of `tui/` with
`DEVPULSE_VERSION` from `Info.plist`; debug profile in `debug`, `--release`
otherwise; never in `Contents/MacOS`, where the name would collide with the
`DevPulse` executable on a case-insensitive volume), then an ad-hoc signature
for the helper and for the app with the entitlements. In `dist` the helper is
signed with the Developer ID identity (hardened runtime, timestamp) before the
app. Settings › General links the helper to `/usr/local/bin/devpulse`. New
resource files must be copied in `build.sh` explicitly.

### 2.1.1 App icon and asset catalog (actool)

- `Resources/AppIcon.png` is the master: 1024 px, full bleed and opaque (no
  transparent corners, no own squircle). macOS 27 masks it to the icon shape.
  A plain `.icns` that does not fill the shape is put small on a light tile,
  which is why the icon is no longer built with `sips` + `iconutil`.
- `Resources/AppIcon.icon` is an Icon Composer document (`icon.json`: one
  layer, glass, shadow, translucency and specular off) that holds no image in
  the repo. `build.sh` copies it to a temporary folder and puts the master in
  as `Assets/AppIcon.png`; actool does not follow a symlink there.
- `Resources/Assets.xcassets` holds `MenuBarIcon.imageset`: an 18 pt vector
  PDF, Render As: Template (`template-rendering-intent`), loaded with
  `Image("MenuBarIcon")`. Further images and colours for the app go here too.
- One actool call compiles both into `Contents/Resources/Assets.car` and a
  fallback `AppIcon.icns` before anything is signed, in every mode:
  ```
  xcrun actool <tmp>/AppIcon.icon Resources/Assets.xcassets --compile <tmp>/out \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist <tmp>/partial.plist \
    --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
    --development-region en --target-device mac --minimum-deployment-target 27.0 \
    --platform macosx
  ```
  `Info.plist` carries what the partial plist asks for: `CFBundleIconName`
  and `CFBundleIconFile`, both `AppIcon`. Without Xcode (only the Command
  Line Tools selected) the build stops with a hint to run
  `sudo xcode-select -s /Applications/Xcode.app`.
- `docs/assets/icon.png` (256 px, squircle mask applied) is drawn from the
  same artwork; regenerate it when the master changes.

### 2.2 Distribution (`dist`)

1. Sign Sparkle's parts inside-out, then the app with the first "Developer ID
   Application" identity in the Keychain, hardened runtime, timestamp.
2. Notarize the zipped app (`notarytool --keychain-profile notary --wait`), staple it.
3. Build `build/DevPulse.dmg` (app + Applications symlink), sign, notarize, staple.
4. `scripts/make_appcast.py` signs the stapled DMG with Sparkle's `sign_update`
   (EdDSA private key from the login Keychain) and writes `docs/appcast.xml`:
   version, release notes from the CHANGELOG section, the GitHub Release
   download URL, length and signature. Create the GitHub Release (DMG uploaded
   as `DevPulse-<version>.dmg`) **before** pushing the appcast, so the feed
   never points at a missing file.

A notarization `HTTP status code: 403. A required agreement is missing or has
expired` is an account issue: accept the updated agreement at
developer.apple.com/account.

### 2.3 One-time signing setup (per machine)

1. A **Developer ID Application** certificate in the login keychain.
2. A stored notarization profile named `notary` (or set `NOTARY_PROFILE`):
   ```
   xcrun notarytool store-credentials notary \
     --apple-id <apple-id-email> --team-id <TEAMID> --password <app-specific-password>
   ```
3. The Sparkle EdDSA key: `.build/artifacts/sparkle/Sparkle/bin/generate_keys`
   keeps the private key in the login Keychain and prints the public key that
   lives in `Info.plist` (`SUPublicEDKey`). Back it up
   (`generate_keys -x <file>`, kept offline): without it no update can ever be
   signed for existing installs again.

### 2.4 Entitlements & sandbox policy

The app ships **unsandboxed** (`com.apple.security.app-sandbox = false`),
which is fine for Developer ID / DMG distribution; Gatekeeper needs the
hardened runtime and notarization. Add entitlements to
`Resources/DevPulse.entitlements` only when a feature needs them.

## 3. Run (`run.sh`)

- `./run.sh debug` *(default)* — rebuilds when anything under `Sources/` or
  `Resources/` is newer than the binary, registers the bundle with Launch
  Services, then runs the binary in the terminal: logs stream live, Ctrl+C quits.
- `./run.sh release` — rebuilds if stale, then `open`s the app.

### Demo data for screenshots

Debug builds take `-DevPulseDemoSnapshot <path>`: the app shows that snapshot (protocol v1
JSON, like `protocol/fixtures/snapshot-v1.json`) in the popover, the launcher and on the
socket, so the TUI shows it too. It fetches nothing, does not watch Claude Code sessions,
posts no notifications and never reads or saves the real settings. Sparkle does not start, so
it never checks for updates, and `devpulse upgrade` fails with "Not available in demo
mode.". Every date is moved so that `generatedAt` is the launch time. Release builds ignore
the argument.

A demo runs next to an installed DevPulse without touching it:

- It serves its own socket, `~/Library/Application Support/DevPulse/devpulse-demo.sock`, and
  registers no launcher hotkey.
- Its settings live in the defaults suite `io.jp4.devpulse.demo`, filled at every launch with
  example values (Jira site `acme.atlassian.net`, e-mail `alice@acme.example`, default
  repository `acmecorp/webapp`). The Jira tab shows a saved token without touching the
  Keychain; Save and Test Connection refuse. General shows launch at login on and the command
  line tool installed. Remove the suite afterwards: `defaults delete io.jp4.devpulse.demo`.
- `-DevPulseDemoOpen <what>` opens a window right after launch, so no hotkey or menu bar click
  is needed: `launcher:<query>` (the launcher with the query typed in), `popover` (the popover's
  content in a plain window at its real size) or `settings:<tab>` (`general`, `github`,
  `jira`, `notifications`, `updates`).
- The terminal client of a debug build connects to the socket in `DEVPULSE_SOCKET` and then
  never launches the app. Release builds ignore the variable.

```
./build.sh debug
build/debug/DevPulse.app/Contents/MacOS/DevPulse -DevPulseDemoSnapshot "$PWD/scripts/demo-snapshot.json" \
  -DevPulseDemoOpen launcher:gh
DEVPULSE_SOCKET="$HOME/Library/Application Support/DevPulse/devpulse-demo.sock" \
  build/debug/DevPulse.app/Contents/Helpers/devpulse
```

`scripts/demo-snapshot.json` holds neutral example data for the website; never put real PRs,
tickets or sessions in it. Capture screenshots by window ID of the demo's own process
(`screencapture -l <id>`), never the whole screen.

When DevPulse is installed, take the shots from a scratch copy of the debug build with its own
bundle id (`io.jp4.devpulse.shots`, re-signed ad hoc). The debug build has the app's bundle
id: AppKit would save its window frames into the app's `io.jp4.devpulse` domain, and Launch
Services would know two `io.jp4.devpulse` apps. Afterwards `defaults delete io.jp4.devpulse.shots`
and unregister the copy (`lsregister -u <copy>`) before removing it.
After new screenshots in `docs/assets/manual/`, `swift scripts/artwork/compose.swift` (from the
repository root) redraws `docs/assets/hero.png` and `docs/assets/og-image.png`.

## 4. Development Methodology

- Logic goes into `DevPulseCore`, test first (`swift test`); the UI is checked
  by running the app.
- Conventional Commits with a scope: `feat(core): …`, `fix(ui): …`,
  `docs(manual): …`, `chore(release): v1.2.0 — …`.
- `main` is always green: builds, tests pass, the app launches.

### Versioning & releases

- The version lives in `Resources/Info.plist` (`CFBundleShortVersionString`
  and `CFBundleVersion`), semantic versioning, starting at 0.1.0.
- Releases follow the project skill `.claude/skills/release/SKILL.md`.
- Pushes to GitHub happen only after explicit confirmation.
