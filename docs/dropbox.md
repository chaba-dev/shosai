# Dropbox library connections

Dropbox is a direct device-to-provider connection. Metadata discovery uses
`files/list_folder` and its continuation cursor; it does not download books.
Opening or keeping a book fetches only that file into the existing bounded
content cache. Book identities, notes, folder migrations and device-local
locators still belong to the existing application core. There is no Shōsai
book server.

## App registration and builds

A distribution owner must register a **scoped Full Dropbox** app in the
[Dropbox App Console](https://www.dropbox.com/developers/apps). Full Dropbox
access is necessary to select an existing library (including folders populated
by book publishers), rather than only an app-specific folder. Enable:

- `files.metadata.read`
- `files.content.read`
- `files.content.write`

Supply its real public app key using the Flutter build define
`SHOSAI_DROPBOX_APP_KEY` (or a local `--dart-define-from-file` configuration).
There is deliberately no default app key. A build without registration shows
an explanatory dialog and leaves device-folder connections usable. No client
secret is used, and none should be included in build configuration.

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
Dropbox**, approve access in the browser, and enter the displayed code. Select
the resulting connection, choose **Change source folder**, browse the paged
folder list, and select **Use this folder**. The Dropbox root is the initial
source until changed. Different connections have independent configuration and
credential keys, even when authorized with the same account.

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
and notes surviving disconnect. Dialog tests exercise English desktop and
Japanese phone-width code entry, disabled/enabled actions and cancellation.

Linux builds can be checked in the Nix shell. Linux, macOS, Android and iPhone
are implementation targets, **not claims of real-account acceptance**. Live
authorization, secure-store persistence across restart, token expiry/revocation,
folder selection, real uploads and kept-book offline use must still be accepted
on each device with a registered app and consenting test account. No Windows
Flutter host exists in this repository; a future host would also need native
acceptance. Do not use an Android browser viewport as evidence of native Android
acceptance.
