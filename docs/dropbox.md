# Dropbox library connections

Dropbox is a direct device-to-provider connection. Metadata discovery uses
`files/list_folder` and its continuation cursor; it does not download books.
Opening or keeping a book fetches only that file into the existing bounded
content cache. Book identities, notes, folder migrations and device-local
locators still belong to the existing application core. There is no Shōsai
book server.

## App registration and builds

Official builds use Shōsai's registered **Scoped access → App folder** app by
default (public app key `3yy8xd4pncextkh`). No build define is needed. Forks
using their own registration must choose **App folder**, not Full Dropbox, in
the [Dropbox App Console](https://www.dropbox.com/developers/apps).
Dropbox creates a dedicated folder under `Apps/<app folder name>` and
enforces access to that folder only. Users add books by copying or moving them
there; photos and other files elsewhere in their account are outside the app's
access. See Dropbox's [app permissions guide](https://www.dropbox.com/developers/reference/developer-guide).
The folder name defaults to the app name and is shown in the console's Settings.
Enable:

- `files.metadata.read`
- `files.content.read`
- `files.content.write`

Override the public app key for a fork or test build using the Flutter build
define `SHOSAI_DROPBOX_APP_KEY` (or `--dart-define-from-file`). An explicitly
empty `--dart-define=SHOSAI_DROPBOX_APP_KEY=` disables new Dropbox connections,
shows an explanatory dialog and leaves device-folder connections usable.
Existing connections retain their registered public key for token renewal.
The single build default lives in `DropboxConnectionProvider.defaultClientId`;
the setup UI uses the same value. No client secret is used, and none should be
included in build configuration. Public app keys are not credentials.

The registered app was in Development status at acceptance: the owner's account
can authorize it, but including its public key does not grant Dropbox production
approval or access for all users. Manage development users and request production
approval in the App Console before general distribution.

The App folder restriction is a property of the registered app, not an OAuth
scope or client-side path filter. Supplying a Full Dropbox app key would grant
broader access; Shōsai does not infer or verify the registration's access type.
If an app was already registered as Full Dropbox, create an App folder
registration, replace the build key, and reconnect with that app. Disconnect
the old connection and revoke its authorization in Dropbox's Connected apps
settings to withdraw the old grant.

Authorization uses the system browser, S256 PKCE and `token_access_type=offline`.
Dropbox's documented
[no-redirect authorization-code flow](https://docs.dropboxapi.com/dropbox-api/docs/get-started/authorization)
displays a one-use code on dropbox.com; the reader pastes it into the masked
in-app field. No callback URL, embedded browser, Shōsai service or client secret
is required. The verifier stays in memory until the exchange completes. Do not
paste authorization codes, refresh tokens or access tokens into issue reports,
chat, fixtures or logs.

## Use and recovery

In Settings → Library connections → Manage connections, choose **Connect
Dropbox**, approve access in the browser, and enter the displayed code. Copy or
move your books into `Apps/<app folder name>` in Dropbox. That app folder
is shown as **Dropbox app folder**, not automatically saved as a source. Before
a new connection is saved, select **Use this folder** there or browse to a
subfolder and confirm it. Until confirmation, no connection is adopted or scanned.
Cancel, Back from the app folder, or closing releases only the unused local
credential, not the account-wide app authorization. Existing saved connections
remain unchanged; use **Change source folder** to reconfigure them.
The picker cannot browse the rest of the account with an App folder token.
Different connections have independent configuration and credential keys,
even when authorized with the same account.

API paths are relative to the token's app-folder root: `""` lists that root and
`/Book.epub` writes inside it. Do not prefix paths with `/Apps/<app name>` or
set an account-root namespace header. File IDs returned inside the app folder
remain the existing stable locators; they do not bypass Dropbox's permissions.
Dropbox's [getting-started guide](https://www.dropbox.com/developers/reference/getting-started)
documents this token-relative root.

Only the refresh token is persisted, through `PlatformConnectionCredentialStore`:
Keychain on Apple, Keystore-backed encrypted storage on Android, and Secret
Service on Linux. There is no plaintext fallback. Linux needs an unlocked
Secret Service/keyring; failure to store a credential fails setup. Android
backup and device-transfer rules exclude only the secure-storage preferences
and wrapping-key/configuration preferences, not the library database or notes.
macOS uses the nonsharing Keychain, avoiding a Keychain Sharing provisioning
requirement. Connection records contain an opaque credential key and public
app key, never a token.

Access tokens are memory-only, renewed on demand with a single shared refresh
per connection; a rejected token is retried once before any response bytes are
published. Refresh failures do not delete credentials, so offline failures can
be retried. Disconnect deletes only this connection's local credential, not
the account-wide app authorization or any source files. A kept verified copy
continues to use the existing cache-first path; books and notes survive removal.
To withdraw the app's account-wide authorization, use Dropbox's Connected apps
settings. Reconnect a revoked connection to authorize access again.

Reads stream with backpressure, validate exclusive-end byte ranges and refuse
an ignored range. Requests own cancellable sockets with a 60-second deadline;
token exchanges have a 30-second deadline. Large writes use 4-MiB upload-session
chunks and publish only at finish. There are no automatic retries for ambiguous
transport failures during a write.

## Verification and acceptance limits

`test/core/dropbox_test.dart` runs the actual HTTP adapter against a local
protocol fixture, not a Dropbox account. It covers PKCE, renewal, per-connection
release, metadata paging, whole/ranged reads, typed failures, cancellation,
deadlines, exact/over-boundary session uploads, lazy EPUB admission, cache/Keep,
and notes surviving disconnect. The fixture checks token-relative root and
subfolder requests, root uploads, and missing failures for out-of-folder paths
and IDs; it models App folder semantics but cannot prove Dropbox's enforcement.
Dialog tests exercise English desktop and Japanese phone-width code entry,
disabled/enabled actions and cancellation.

For live App folder acceptance, authorize the registered App folder app and
confirm Dropbox's consent describes only its dedicated folder. Add a test EPUB
inside that folder and a decoy outside it. Verify that root/subfolder discovery
and opening the EPUB work, the decoy is absent, and a direct out-of-folder
metadata/read attempt is rejected. Verify a test upload appears inside the app
folder, then restart/refresh and test Keep while offline.

Scoped native Linux acceptance was performed on Framework on 2026-10-26 with
the registered App folder app and an isolated profile. The owner confirmed
app-folder-only consent. Root/subfolder discovery and selection, dedicated EPUB
whole/ranged reads, root/subfolder uploads with byte readback, native vault
renewal across restart, and fresh-process kept-book opening with HTTP creation
blocked passed. No personal book bytes were read or changed. The independent
test vault key reused the same refresh grant; this was not a second OAuth
authorization. Offline testing did not disable the system network. An external
decoy path returned missing, but its remote existence and file ID were not
independently confirmed, so this does not prove external file-ID denial.

Linux builds can be checked in the Nix shell. These scoped Linux checks are
**not blanket device acceptance**: live revocation and independently authorized
multiple connections remain unverified. macOS, Android and iPhone still need
native real-account acceptance of authorization, vault persistence, renewal,
revocation, transfers and offline use. No Windows Flutter host exists in this
repository; a future host would also need native acceptance. Do not use an
Android browser viewport as evidence of native Android acceptance.
