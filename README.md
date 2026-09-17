# Shallot

A macOS menu-bar app that runs a Tor SOCKS5 proxy on `127.0.0.1:9050`. Click to turn it on or
off; the icon shows whether it is off, bootstrapping, connected or failed. Apple silicon,
macOS 13 or later.

It does what `brew services start tor` does, without Homebrew, a launchd service or a `torrc`.

## Why Arti rather than a tor daemon

[Arti](https://arti.torproject.org) is the Tor Project's Rust implementation of Tor. It is a
library, so Shallot ships as one app with Tor compiled in: nothing else to install, nothing
left running when you quit, and the app reads bootstrap progress from Arti directly instead of
parsing a daemon's log.

The cost: Arti is younger than C tor and has had less scrutiny, and Shallot does not support
bridges or pluggable transports. If you need those, or your threat model calls for the
most-reviewed implementation, run `tor`.

## Install

1. Download `Shallot.dmg` from the [latest release](https://github.com/den200/shallot/releases/latest).
2. Open it and drag Shallot to Applications.
3. Clear the Gatekeeper block (next section), then open Shallot. It appears in the menu bar only.

## Gatekeeper

Shallot is ad-hoc signed and not notarized — there is no Apple Developer ID behind it — so
macOS refuses to open it the first time. Either:

```sh
xattr -dr com.apple.quarantine /Applications/Shallot.app
```

or open Shallot, dismiss the warning with **Done**, go to **System Settings → Privacy &
Security**, scroll to "Shallot was blocked…", click **Open Anyway** and confirm. Control-click →
Open no longer works on macOS 15 and later.

If you would rather not trust a binary from a stranger, build it yourself (below); a local
build is never quarantined.

## Updates

**Check for Updates…** in the menu asks GitHub for the latest release and, if it is newer,
downloads the DMG, replaces the app and relaunches it. Nothing is checked in the background.
An update is trusted exactly as much as your first download was: it comes from this
repository's releases over HTTPS and carries no other signature.

## Point an app at it

Use a SOCKS5 proxy with host `127.0.0.1` and port `9050`. The menu has an item that copies
`127.0.0.1:9050` to the clipboard. `.onion` addresses work.

- **Sparrow Wallet:** Settings → Server → Use Proxy, URL `127.0.0.1`, port `9050`.
- **curl:** `curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip`
  returns `"IsTor":true` while Shallot is on and fails to connect while it is off.

Use `--socks5-hostname` (or `socks5h://`) so that DNS lookups go through Tor as well.

"Connected" is measured, not assumed: every 20 seconds Shallot resolves `www.torproject.org`
through a Tor circuit, and two failures in a row turn the icon to failed until a check succeeds
again. That lookup is the only traffic Shallot generates on its own.

The port can be changed from the menu. The listener binds to `127.0.0.1` only and there is no
setting to change that. Tor state is kept in `~/Library/Application Support/Shallot` and
`~/Library/Caches/Shallot`.

## Build

Needs Rust and the Xcode Command Line Tools.

```sh
./build.sh          # produces dist/Shallot.dmg
```

`tor/` is the Rust proxy (`arti-client` plus a SOCKS5 listener). `app/` is the Swift menu-bar
app, which bundles that binary and runs it as a child process.

## Licence

MIT or Apache-2.0, at your option. See [LICENSE-MIT](LICENSE-MIT) and
[LICENSE-APACHE](LICENSE-APACHE).
