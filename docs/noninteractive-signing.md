# Noninteractive Release Signing

`tools/with-hermit-signing.py` uses the existing dedicated
`~/Library/Keychains/hermit-distribution.keychain-db`. It never imports or
recreates certificates, changes access-control lists or trust settings, changes
the default/search-list keychains, or accesses the personal login keychain.

The credential is read from the `keychain` field of the existing local
`~/.config/hermit/signing/keychain-passwords.json`. Its directory must be owned
by the user with mode 0700 and the file with mode 0600. Do not commit this file,
print its contents, or pass the password as an argument. This is an automation
secret, not a request for a Mac login or Apple account password. Any process
that can read it and access the keychain can use the signing identity; these
file permissions do not isolate other processes running as the same user.

## Required Execution Context

Run the helper through an existing, batch-only SSH login to the signing Mac,
including loopback SSH when already on that Mac. Pin the host key against the
Mac's local SSH host public key and use `BatchMode=yes`, `UseKeychain=no`,
`IdentityAgent=none`, `IdentitiesOnly=yes`, and `StrictHostKeyChecking=yes`.
Do not create a tunnel or change SSH authorization for a release.

The helper checks `SessionGetInfo` before reading credentials and refuses a
security session with `sessionHasGraphicAccess`. This restriction matters:
disabling keychain UI in the Python process alone does not disable UI in its
`codesign` subprocesses. In the non-graphical SSH security session, missing
interactive authorization fails instead of showing a desktop dialog.

First run `--check-context`, then `--check-locked --identity SHA1` while the
dedicated keychain is locked, then `--probe --identity SHA1`. The locked probe
must fail to sign a disposable copy of `/usr/bin/true`; the unlocked probe must
succeed. Both are bounded to 15 seconds. A failed probe blocks the release.
The script does not repair permissions or fall back to an interactive flow.

## Release Commands

Through that same batch-only SSH path, run:

```sh
python3 tools/with-hermit-signing.py --timeout 1200 -- xcodebuild ... archive
python3 tools/with-hermit-signing.py --timeout 600 -- xcodebuild -exportArchive ...
```

Use absolute paths when SSH's working directory differs from the repository.
Pin the distribution identity and dedicated keychain in the local signing
xcconfig. Keep automatic provisioning off when using the existing valid manual
profile. The normal archive/export/signature/credential-scan checks still apply.
Upload the resulting IPA with the existing App Store Connect API key; never
embed that key in the app, commit it, or replace it with an Apple account login.

The helper serializes its signing jobs, supplies no child stdin, enforces a
timeout, and relocks the dedicated keychain in `finally`, including command
failure and SIGINT/SIGTERM/SIGHUP. Timeout/cancellation terminates only the
owned subprocess group. SIGKILL cannot run cleanup, so verify the dedicated
keychain's lock state after an externally forced process kill. Do not leave
the keychain unlocked permanently as a workaround.

Apple references:
- [Noninteractive signing and keychain alerts](https://developer.apple.com/forums/thread/712005)
- [Security session attributes](https://developer.apple.com/documentation/security/sessionattributebits)
- [API-authenticated build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
