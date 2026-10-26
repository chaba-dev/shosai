# Google Drive library connections

The direct connector uses Drive v3 on the device. No Shōsai server receives
books, tokens, or folder metadata. Windows has no Flutter host in this repository;
the desktop authorization path is portable but Windows acceptance is not claimed.

## Distributor registration

Create a Google Cloud project, enable the **Google Drive API**, and configure
Google Auth Platform branding, audience and data access. During development use
**External / Testing** with explicit test accounts. Obtain the account owner's
consent in Google's system-browser/native consent UI, never by collecting their
password. Restricted-scope test refresh tokens can expire after seven days;
testing mode is not production authorization.

| Target | Registration and build configuration |
| --- | --- |
| Linux / macOS | A **Desktop app** OAuth client. Pass its public ID as `--dart-define=GOOGLE_DRIVE_DESKTOP_CLIENT_ID=…`. System browser, random IPv4 loopback port, state, S256 PKCE. No client secret. macOS requires outgoing client and loopback server entitlements (both are included). |
| iPhone / iPad | An **iOS** client for bundle `dev.shosai.shosai-flutter`. Pass `--dart-define=GOOGLE_DRIVE_IOS_CLIENT_ID=…`. Set the Xcode build setting `GOOGLE_DRIVE_IOS_CALLBACK_SCHEME` to that client ID with its dot-separated components reversed. Info.plist registers this scheme. AppAuth uses the system authentication session and PKCE with `/oauthredirect`; no webview or loopback. |
| Android | An **Android** registration for package `dev.shosai.shosai_flutter` and the actual signing certificate's SHA-1. Also create a **Web application** client in the same project and pass its public ID as `--dart-define=GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID=…`. The installed Google Sign-In plugin needs this audience for native Credential Manager sign-in. No web client secret, JS origin, redirect URL, backend, or server auth-code exchange is used. GIS AuthorizationClient requests Drive access and silently renews for the explicitly stored account. |

The Android release configuration currently uses the debug signing configuration
(preexisting); register the actual certificate used by the build, not a guessed
fingerprint. Distribution must use the distributor's signing identity and matching
registration. Debug certificates are machine-local; do not reuse another machine's
fingerprint for a differently signed build.

Client IDs are public identifiers, not credentials. No IDs are invented or checked
in. Configure them in the approved build configuration/secret manager; never paste
client secrets, authorization codes, access tokens or refresh tokens into a chat.
For an iOS archive, both the Dart define and the Xcode callback build setting must
be supplied; neither is inferred from a different platform's client.

## Scope and verification

The connector requests only `https://www.googleapis.com/auth/drive`. This is a
**restricted** scope: the consent permits reading and changing Drive files, even
though Shōsai discovers only user-owned files under the selected source directory.
That source directory is an application boundary, not a Google-enforced OAuth
sandbox. Shared drives, shortcuts, and native Workspace documents are not supported.

`drive.file` alone cannot discover/download all existing books in an arbitrary
user-owned folder. `drive.readonly` suffices for discovery and reads, but cannot
replace an existing book as the writable LibraryLocation contract permits.
`drive.readonly` plus `drive.file` would still restrict modification of arbitrary
existing files. Full `drive` is required for the implemented create/replace
contract; do not advertise it as per-folder consent. A narrower read-only product
would require a different capability decision, not a scope substitution.

Public distribution needs Google's restricted-scope verification, branding and
privacy disclosures. Google specifies a security assessment when restricted data
is stored or transmitted through servers; this implementation does neither, but
the distributor must confirm its complete application's verification obligations.

## Connection and data lifetime

In Settings → Connections, choose **Connect Google Drive**, authorize, then open
the connection and **Change source folder**. Browse folders and choose **Use this
folder**. Until changed, the source is My Drive; discovery is metadata-only and
bounded by the existing library traversal limits. Subfolders are included; book
bytes are fetched only when opened or kept. Each connection can select its own
source folder. Folder IDs, page tokens and revisions never become book identities.

The secure credential store uses Keychain on Apple, Android Keystore-backed
encryption, and Secret Service on Linux. A locked/unavailable vault fails rather
than falling back to plaintext. On macOS the unshared legacy Keychain avoids a
Keychain Sharing provisioning requirement. Android backup rules exclude only the
credential plugin's encrypted preferences/wrapping-key/configuration files, not
books and notes. Preferences store only an opaque authorization-generation key
and the selected directory. Android's Google SDK additionally owns its native
account/token cache; no server refresh token is requested there.

Disconnect deletes only that connection's local credential. It does **not** call
Google's project-wide revocation endpoint, which would invalidate the user's other
independent connections. To revoke all Shōsai access, use the Google Account
third-party connections page. A revoked connection requires explicit reconnection;
network/vault failures can be retried. Existing book identity, notes and kept,
verified offline bytes remain governed by the core's original cache semantics.

Listing and stat fetch bounded metadata pages only. Reads use backpressure and
exclusive-end ranges; ignored ranges fail rather than downloading the whole book.
Writes use resumable 256 KiB chunks and publish success only after final size and
acknowledgement validation. A unique existing name is replaced; ambiguous duplicate
names are rejected rather than arbitrarily overwriting one. In-flight network and
input waits have deadlines and cancellation checks; desktop consent is bounded to
five minutes. Credentials/transport errors exposed to the app contain no raw tokens.

## Acceptance status

Local HTTP fixtures verify pagination, metadata-only listing, Workspace/shortcut
exclusion, exclusive-end/EOF reads, 401 renewal, offline/revoked/missing failures,
network cancellation, exact-boundary and multichunk create/replace writes, desktop
PKCE/state/code exchange/refresh, isolated vault/GIS/timeout failures, alternative
copies and offline Keep after service reopening. These are not Google device tests.

Real Google consent, restart/renewal, multiple-account behavior, revocation and
offline kept-book acceptance remain required on Linux, macOS, Android and iPhone
after registration. This Linux orb cannot verify Apple devices or a real Android
device. A native desktop build alone does not establish that OAuth is configured.

## Official references

- [Google native/desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app): public clients, PKCE, loopback desktop redirect, no Android custom scheme or mobile loopback, no OOB paste flow; client secret is optional.
- [Android authorization](https://developer.android.com/identity/authorization): GIS AuthorizationClient, account-scoped ongoing access and token-cache clearing, distinct from server-side offline access.
- [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth): per-file versus restricted scopes and verification requirements.
- [Drive uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads): resumable upload initiation, 256 KiB chunk alignment, final totals and acknowledgements.
