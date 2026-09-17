#!/bin/bash
# Builds build/Shallot.app and dist/Shallot.dmg (arm64, ad-hoc signed).
# Set SHALLOT_TOR_BIN to bundle an existing shallot-tor binary instead of building tor/.
set -euo pipefail
cd "$(dirname "$0")"

app=build/Shallot.app
tor_bin=${SHALLOT_TOR_BIN:-}

if [[ -z $tor_bin ]]; then
    cargo build --release --manifest-path tor/Cargo.toml
    tor_bin=tor/target/release/shallot-tor
fi

rm -rf build dist/Shallot.dmg
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/dmg dist

swiftc -O -target arm64-apple-macos13 app/main.swift -o "$app/Contents/MacOS/Shallot"
cp "$tor_bin" "$app/Contents/Resources/shallot-tor"
cp app/Info.plist "$app/Contents/Info.plist"

codesign --force --sign - "$app/Contents/Resources/shallot-tor"
codesign --force --sign - "$app"

cp -R "$app" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Shallot -srcfolder build/dmg -format UDZO dist/Shallot.dmg
