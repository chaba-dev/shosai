# Portable build credentials

Shōsai keeps its Google application registrations in SOPS-encrypted JSON:
`secrets/development.enc.json` and `secrets/release.enc.json`. Their age recipient
sets are disjoint. A development identity cannot decrypt the release file, or
vice versa. `.sops.yaml` contains only public recipients and no fallback rule.

Both files initially contain the same existing Google registrations: Android's
public Web client ID, the Desktop client ID and companion, the iOS client ID and
callback scheme. Separate encryption does not invent separate Google projects
or change provider consent settings. Dropbox's public key already defaults in
the app; it needs no secret. Never add end-user access/refresh tokens here.

**Release signing is not configured by this change.** No production Android
keystore was found or generated. The current Android release target still uses
debug signing. Do not publish it as production-signed. Register each development
certificate's package/SHA-1 with Google; a real release signing certificate will
need its own registration too.

## Build-helper contract

Run from the Nix shell, or prefix with `.agents/dev`:

```sh
.agents/dev ./scripts/with-build-secrets.sh development \
  'flutter build apk --profile --dart-define-from-file="{}"'
```

`with-build-secrets.sh <development|release> '<shell command>'`:

- Runs the command from the repository root, only after successful decryption.
- Replaces `{}` with a temporary JSON file. Quote `"{}"` inside the command.
- Uses SOPS's `exec-file --no-fifo` inside a private per-invocation temporary
  directory. The helper removes it after success, failure, `SIGINT` or `SIGTERM`.
  Cancellation during startup is deferred until the child PID is registered;
  cleanup sends TERM to the command's process group, allows up to about one
  second for SOPS to exit, then sends KILL before reaping and deleting the
  directory. Commands must stay in the foreground. As with other cleanup
  handlers, `SIGKILL` or power loss cannot be caught; temporary-file cleanup does
  not cover those cases.
- Returns nonzero if decryption or the command fails. It never prints plaintext.
- Accepts standard `SOPS_AGE_KEY`, `SOPS_AGE_KEY_FILE` or `SOPS_AGE_KEY_CMD` identity
  inputs. With none set, it selects
  `${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/shosai/<environment>.txt`.
  These inputs supplement SOPS's default age keyring; they do not disable it.
  Separate recipients enforce access based on all identities available to SOPS,
  not solely the selected file. A process holding both sets can decrypt both.

The JSON is directly usable with Flutter's `--dart-define-from-file` on Android
and desktop. For example, substitute `flutter build linux --release` for the
Android command above. The credential environment is independent of Flutter's
build mode: testing an optimized build can use `development`; choosing
`release` selects release **configuration**, not production signing.

iOS builds also need the public `GOOGLE_DRIVE_IOS_CALLBACK_SCHEME` Xcode build
setting described in [google-drive.md](google-drive.md). Putting it in Dart
JSON does not set the Xcode build setting. macOS Drive uses the desktop loopback
flow and needs no iOS callback setting. Dropbox needs no separate Apple callback
build setting; see [dropbox.md](dropbox.md). This helper does not configure Apple
provisioning or signing.

Decryption is deliberately opt-in; ordinary tests/builds need no identity.
Never decrypt during Nix evaluation, `.agents/setup`, snapshot creation, or
dependency caching. Do not log the temporary file, enable shell tracing around
credentials, run the command in the background, or upload plaintext/keys in
artifacts. Flutter embeds registration material in its output and may retain it
in ignored build caches: temporary-file cleanup is not build-output sanitization.
Google's Desktop companion is extractable public-client registration material,
not a confidential server secret.

## Identity locations and access

| Context | Identity | Access |
| --- | --- | --- |
| Framework local development | `~/.config/sops/age/shosai/development.txt` | Development only |
| Mac lab local development | Machine-local `~/.config/sops/age/shosai/development.txt` | Development only |
| Owner's local release/recovery | `~/.config/sops/age/shosai/release.txt` | Release only |
| Amp project `chaba/shosai` | Project secret `SOPS_AGE_KEY` | Development only |
| GitHub `chaba-dev/shosai`, environment `RELEASE` | Environment secret `SOPS_AGE_KEY` | Release only |

The local files have mode `0600` in a `0700` directory. The automation identities
are separate from both local identities; they are not copies of the owner's
personal age keyring. Keep an offline, encrypted recovery backup of the local
identities. Amp secrets are injected into new project orbs; an already-running
orb needs a secret refresh/restart. Local runner sessions do not automatically
receive project secrets: provision their own identity instead.

For another local machine, generate an identity there with `age-keygen`, keep
its private key local, and add only its public recipient to the appropriate rule.
An authorized holder of that environment's current key then runs
`sops updatekeys secrets/<environment>.enc.json`. Never send the private key
through chat or copy the complete personal age keyring between machines.

The individual Google variables already saved in Amp remain for compatibility;
this helper reads the encrypted file instead, so those variables do not override
it. Update the encrypted file as the source of truth, not both paths indefinitely.

## Contract for the future release workflow

No release workflow is added or triggered here. A future trusted release build
job should select `environment: RELEASE`, map that environment's
`secrets.SOPS_AGE_KEY` to the step's `SOPS_AGE_KEY`, enter the pinned Nix shell,
and call:

```sh
.agents/dev ./scripts/with-build-secrets.sh release \
  'flutter build apk --release --dart-define-from-file="{}"'
```

This command supplies OAuth registration only. Restoring the artifact workflow
must separately supply a real signing identity and remove the debug-signing
fallback before publishing. Do not give release keys to pull-request/test jobs.
These JSON files are passed to Dart: never add signing passwords or keystore
bytes to them. Future signing assets need their own encrypted file and release
recipient rule, outside the Dart defines.

**`RELEASE` allows only the `main` branch and tags matching `v*`.** The policies
are ref-type-specific: a branch named `v0.1.0` is not an allowed version tag.
There are no required reviewers or wait timer, so release PR creation, tagging,
and future builds remain automatic on eligible refs. This reuses the existing
environment and its secrets; there is no separate signing environment.

The tag pattern is not semantic-version validation; the release workflow must
still validate the version. Environment restrictions check the workflow ref,
not arbitrary code a step subsequently checks out. In particular,
`pull_request_target` runs against the base branch: preserve the existing
same-repository release-PR guards, never execute untrusted PR code with these
secrets, and keep normal PR/test jobs outside `RELEASE`. Production signing
still requires an actual signing identity and trusted release workflow.
KMS with workload identity/OIDC can later replace stored automation age keys
without distributing a long-lived decryption key.

## Editing and rotation

Use the appropriate identity with the pinned SOPS editor:

```sh
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/shosai/development.txt" \
  .agents/dev sops edit secrets/development.enc.json
```

For release edits, select `release.txt` and `release.enc.json` instead. Treat any
editor swap/backup files as plaintext. Keep only ciphertext in version control.
When changing recipients, use `sops updatekeys`; when rotating the file's data
key, use `sops rotate --in-place`. Removing a recipient does not revoke access
to ciphertext already present in repository history: rotate the underlying
credential too when revocation is required.

See [SOPS age identities](https://getsops.io/docs/usage/identities/age) and
[Amp secret handling](https://ampcode.com/docs/orbs/handling-secrets).
