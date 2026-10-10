# Releasing Glance Fork

The fork has a separate identity from upstream:

| Resource | Fork value |
| --- | --- |
| App | `Glance Fork.app` |
| Bundle ID and Keychain service | `io.github.hhh2210.glance` |
| Encrypted face data | `~/Library/Application Support/glance-hhh2210/face-identities.enc` |
| Release repository | `hhh2210/glance` |
| Homebrew Cask | `hhh2210/tap/glance-face-unlock` |

Do not restore the upstream Sparkle feed, public key, signing team, Keychain service, or face-store path when syncing upstream changes. Do not copy users' credentials or enrollment data between the two apps.

## Validate and publish

1. Update both Xcode configurations' `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Keep the deployment target at the oldest version actually supported by the source.
2. Run `./tools/enrollment_selftest.sh` and `./tools/package-release.sh --version <version>` on the release commit. Inspect the artifact checks and retain the build output.
3. Push a `v<version>` tag to this fork. The release workflow runs the tests and builds a universal Apple Silicon/Intel ZIP on the pinned Xcode runner, then publishes the ZIP and checksum file.
4. Verify the completed workflow and download the published artifact to confirm its checksum, bundle identifier, version, architecture, and signature. A successful upload alone is not installation verification.

The release script currently produces ad-hoc signatures. These are integrity signatures, not Developer ID or Apple notarization. Never remove quarantine or disable Gatekeeper in the Cask. Signed and notarized distribution requires a separately configured Developer ID identity and notarization credentials; no secrets belong in this repository.

## Update Homebrew

The Cask lives in [hhh2210/homebrew-tap](https://github.com/hhh2210/homebrew-tap), at `Casks/glance-face-unlock.rb`.

1. Update `version` and `sha256` to the exact published ZIP. Use immutable versioned release URLs.
2. Run `brew style --cask hhh2210/tap/glance-face-unlock` and `brew audit --cask --strict --online hhh2210/tap/glance-face-unlock` against the changed Cask.
3. Test installation with a task-specific `--appdir` to avoid replacing an existing app. This changes the destination directory only; Homebrew still records a real installation in its Caskroom.
4. Verify the installed bundle and clean up the test installation, retaining user data. A normal custom-tap audit does not prove Gatekeeper approval or notarization.

Do not add a `zap` for the upstream app or for saved face/credential data. The fork's login item belongs to `SMAppService.mainApp`; do not guess an upstream launchd label.

## Manual enrollment verification

Use a separate test identity and do not record camera images or passwords in bug reports. Test the built-in and an external camera where available, normal and dim lighting, diagonal poses, interrupted holds, and leaving/restarting enrollment while a frame is processing. Record completion time and the visible blocking messages. Keep machine-state tests, real-camera enrollment, and unlock spoof-resistance results separate.
