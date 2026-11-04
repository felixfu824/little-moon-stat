# Releasing Little Moon

Adapted from Lamitype's `docs/RELEASING.md`. Public artifacts use bundle ID `com.felixfu.MacMonitorPanel` (kept from
the working title so settings and tour state carry over) and the pinned identity
**Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)**.

Never put signing keys, notary passwords, API keys (`*.p8`), machine logs or screenshots of a real desktop in Git.
`NOTARY_PROFILE` is the name of a `notarytool` keychain profile (`littlemoon-notary` on Felix's MacBook Pro), never a
password. Create it once, by hand, in a real terminal:

```sh
xcrun notarytool store-credentials littlemoon-notary --apple-id <Apple ID> --team-id 8Z5RQYC6M5
```

The app-specific password comes from account.apple.com → Sign-In and Security → App-Specific Passwords.

## 1. Prepare the exact source

1. Start from a clean `main`: `git status --short` must be empty.
2. Bump `Resources/Info.plist`: `CFBundleShortVersionString` (0.x, no 1.0 until Felix calls it finished) and
   `CFBundleVersion` (+1 every release). Commit.
3. Run the checks (unsandboxed; IOKit, `ps` and the app do not work inside a sandbox):

```sh
swift test
Scripts/verify_app.sh          # GUI cases report UNVERIFIED when the session is locked: run unlocked for a release
git diff --check
```

4. Write the user-facing notes in `docs/release-notes/github-v<version>.md` (what you get, install, good to know,
   SHA-256 filled in at step 3). No em dashes in published copy.

## 2. Build, sign and notarize the app

```sh
NOTARY_PROFILE=littlemoon-notary Scripts/release.sh
```

This builds `build/release/Little Moon.app`, signs it with hardened runtime and a secure timestamp, submits it to
the notary service, staples the ticket and runs Gatekeeper. Stop if the submission is not **Accepted**; read its log
(`xcrun notarytool log <id> --keychain-profile littlemoon-notary`) instead of continuing.

Check the signature:

```sh
codesign -dv --verbose=4 "build/release/Little Moon.app"   # Authority=Developer ID…, TeamIdentifier=8Z5RQYC6M5, flags=runtime, Timestamp
codesign -d -r- "build/release/Little Moon.app"
```

Hardened runtime must not block sampling. When sampler code changed, sign `EngineDump` the same way and run it for
a few seconds: temperatures, GPU, processes (incl. `ps`), memory and disk must read live.

## 3. Package the DMG

```sh
NOTARY_PROFILE=littlemoon-notary Scripts/make-dmg.sh
```

It stages the app with an Applications link, creates `LittleMoon-v<version>.dmg` (UDZO), signs it, notarizes and
staples it, runs `spctl --type open` and `hdiutil verify`, then mounts it and re-verifies the app inside
(deep-strict codesign, staple, Gatekeeper). Copy the printed SHA-256 into the release notes. Nothing may modify the
signed app after signing; stapling is expected.

## 4. Install check on real Macs

On the MacBook Pro and the MacBook Air: quit the running copy, install from the final DMG (drag to Applications or
`ditto` the app out of the mounted image), launch, and confirm:

- Gatekeeper accepts it on first open (no "damaged" or "unidentified developer" prompt).
- Settings and tour state carried over from the previous version (same bundle ID).
- Moons, popover and desktop panel show live values; the About window shows the new version.
- `spctl --assess --type execute -v "/Applications/Little Moon.app"` reports "Notarized Developer ID".

## 5. Publish

1. Tag and push: `git tag -a v<version> -m "..." && git push origin main v<version>`.
2. Create the GitHub release with the DMG (repo `felixfu824/little-moon-stat`):

```sh
gh release create v<version> "build/release/LittleMoon-v<version>.dmg" \
  --repo felixfu824/little-moon-stat --title "Little Moon v<version>" \
  --notes-file <notes without the H1 title line>
gh release view v<version> --repo felixfu824/little-moon-stat --json assets --jq '.assets[] | .name + " " + .digest'
```

The asset digest must equal the local SHA-256.

3. Update the README install line if the DMG name pattern changed, and the product page at byfkc.com/little-moon/
   if it names a version.

## 6. Never

- Distribute an ad-hoc (`Scripts/build.sh`) or Apple Development signed build.
- Change the bundle ID or reset permissions to work around a failed upgrade.
- Publish before both notarizations (app and DMG) are Accepted.
