# OditBridge

A macOS companion app for [odit.et](https://odit.et/) (the Ethiopian
bank-SMS finance tracker). Reads bank SMS from `~/Library/Messages/chat.db`
on Macs that have iPhone SMS forwarding enabled, uploads them to your odit
server, and shows the parsed transactions, daily charts, and an activity
heatmap.

OditBridge is essentially a thin client on top of the odit API — bring
your own backend (or self-host one) to make it useful.

## Build

You need Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```
xcodegen generate
open OditBridge.xcodeproj
```

Press `⌘B` to build. By default the project signs **ad-hoc** (no developer
team needed) — that's enough for Xcode runs but the resulting `.app` will
trip Gatekeeper if you copy it elsewhere.

### Signing with your own developer cert

Create `Configs/Local.xcconfig` (gitignored) with your values:

```
CODE_SIGN_IDENTITY = Apple Development: Your Name (XXXXXXXXXX)
DEVELOPMENT_TEAM = XXXXXXXXXX
```

Re-run `xcodegen generate` and you'll get proper signing. The same cert
across rebuilds means Full Disk Access grants persist between builds.

### Auto-install to `/Applications` after every build

If you're iterating with Full Disk Access on the `/Applications/OditBridge.app`
copy, opt into the post-build install step in `Configs/Local.xcconfig`:

```
ODIT_LOCAL_INSTALL = YES
```

With this set, every Debug build replaces `/Applications/OditBridge.app`.
Off by default so contributors don't get surprise installs.

## Install (pre-built)

If someone hands you a pre-built `.app` (e.g., GitHub Release):

1. Drag `OditBridge.app` to `/Applications/`.
2. **macOS will refuse to open it** because it's not notarized. In Finder:
   right-click → Open → Open Anyway. *(Or, in Terminal:
   `xattr -dr com.apple.quarantine /Applications/OditBridge.app`.)*
3. Open the app once so macOS registers the bundle.
4. System Settings → Privacy & Security → **Full Disk Access** → add
   OditBridge.app and enable it.
5. In the app: Settings → Server → set your API base URL.
6. Copy your Device ID from Settings (or the link banner) and paste it into
   the odit web app's **Devices → Link a Mac** dialog while signed in.
7. Switch to the **Staged** tab → Load now → review → Sync now.

The app's own **Help → Getting Started** menu walks through the same steps
with copy buttons.

## Bundle ID

`com.robi.OditBridge`. Change in `project.yml` if you want a separate
identity; remember that Full Disk Access keys grants by bundle ID + code
signature, so changing the ID is the same as installing a fresh app from
TCC's perspective.

## License

MIT. See `LICENSE`.
