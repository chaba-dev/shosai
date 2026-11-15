# Portable build credentials

Shōsai fetches official Google application registrations from **Google Secret
Manager**, not from encrypted files in the public repository. Local developers
sign in to Google; Amp orbs and trusted GitHub release jobs use short-lived OIDC
credentials. No exported service-account key or shared age identity is required.

Provision the resources below before using the helper. Development and release
have distinct secrets, workload identity pools and secret-level IAM grants:

| Caller | Authentication | Allowed build configuration |
| --- | --- | --- |
| Local runner | Its developer's `gcloud auth login` | Only the secrets granted to that Google account |
| Amp project `chaba/shosai` | Amp OIDC → development identity pool | Development only |
| Trusted GitHub `RELEASE` job | GitHub OIDC → release identity pool | Release only |

IAM administrators can grant themselves access to both environments. This is
an access boundary between build identities, not a restriction on administrators.
Separate storage also does not create separate Google OAuth projects: the
existing development/release registrations initially contain the same values.

**Release signing is separate.** No production Android keystore is provisioned
here, and Android's existing release target still debug-signs. Never publish that
as production-signed. Register the actual package/certificate SHA-1 with Google.

## Build-helper contract

Run in the pinned Nix shell (`.agents/dev` for the default shell, or
`nix develop .#ci` for host-only jobs). Both include `gcloud`, Python and Bash.
Set `SHOSAI_SECRETS_PROJECT` explicitly; the helper never falls back to an
unrelated default Google Cloud project.

```sh
export SHOSAI_SECRETS_PROJECT='<secret-manager-project-id>'
gcloud auth login
.agents/dev ./scripts/with-build-secrets.sh development \
  'flutter build apk --profile --dart-define-from-file="{}"'
```

`with-build-secrets.sh <development|release> '<foreground shell command>'`:

- Runs from the repository root and fetches
  `shosai-<environment>-build-defines` from `SHOSAI_SECRETS_PROJECT`.
- Uses version `latest` unless `SHOSAI_BUILD_SECRET_VERSION` specifies an exact
  version. Pin the version for reproducible release inputs.
- Fetches a JSON object of string defines into a mode-`0600` file inside a private
  mode-`0700` temporary directory. A failed/invalid fetch never runs the command.
- Replaces `{}` with that file's path. Quote `"{}"` in the command; the helper
  expands the path as data, not shell source. Standard input is preserved.
- Uses existing gcloud authentication, including
  `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` exported by GitHub's auth action.
- When `SHOSAI_AMP_WORKLOAD_IDENTITY_PROVIDER` is set, creates a temporary
  executable-credential configuration using `scripts/amp-gcp-identity.py`.
  `SHOSAI_AMP_OIDC_AUDIENCE` must match the development provider's audience.
  This path only permits `development`; Google IAM is the actual access control.
- Returns nonzero on failure. Stops the command's process group and removes
  temporary defines/federation files on success, failure, SIGINT or SIGTERM.
  Startup cancellation waits for PID registration. Cleanup allows about one
  second after TERM, then sends KILL before reaping, even for a suspended leader.
  Commands must stay in the foreground. SIGKILL of the supervisor and power loss
  cannot run cleanup.

The environment selects configuration, not Flutter build mode or signing.
An optimized test build can use `development`. For Linux/macOS, substitute
`flutter build linux --release` or `flutter build macos --release`.
iOS also requires the public `GOOGLE_DRIVE_IOS_CALLBACK_SCHEME` **Xcode build
setting** described in [google-drive.md](google-drive.md); Dart JSON does not
configure it. macOS Drive uses a desktop loopback flow and needs no iOS callback
setting. Dropbox needs no separate Apple callback setting; see [dropbox.md](dropbox.md).

Do not fetch secrets during Nix evaluation, `.agents/setup`, snapshot creation,
dependency caching or ordinary PR/test jobs. Fetch only for an authorized build.
Never log tokens/defines, enable shell tracing around credentials, or upload
credentials or temporary files in artifacts. The Amp credential executable's
stdout is a private protocol consumed by gcloud, **not a diagnostic command**.
Do not run it just to display its output.

## Payload and rotation

Each secret version contains a JSON object with these string fields:

- `GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID`
- `GOOGLE_DRIVE_DESKTOP_CLIENT_ID`
- `GOOGLE_DRIVE_DESKTOP_CLIENT_SECRET`
- `GOOGLE_DRIVE_IOS_CLIENT_ID`
- `GOOGLE_DRIVE_IOS_CALLBACK_SCHEME`

Keep each platform's settings consistent with its actual registration. Flutter
embeds this material into binaries and may retain it in ignored build caches;
temporary-file cleanup is not output sanitization. Google's Desktop companion is
extractable public-client registration material, not a confidential server secret.
Never put signing keys/passwords, confidential Web client secrets, authorization
codes, or end-user access/refresh tokens in Dart defines. Future signing assets
need separate release-only secrets and a signing-specific consumer.

Update configuration by adding a secret version through an approved private
file/input mechanism (`gcloud secrets versions add ... --data-file=...`). Do not
put values in command arguments or chat. Validate before selecting the new
version; rollback selects the previous enabled version. Disabling a version or
revoking IAM stops future reads, not copies already fetched. Provider credential
revocation still requires rotating/revoking the underlying credential.

## Provisioning: private resources, public trust configuration

A Google Cloud administrator chooses the target project and enables billing/API
access. The Secret Manager project need not own the application's OAuth clients.
Do not silently reuse an unrelated project or create/bill one without agreement.
The commands below are administrative setup, **not build/setup hooks**.

```sh
export SHOSAI_SECRETS_PROJECT='<confirmed-project-id>'
project_number="$(gcloud projects describe "$SHOSAI_SECRETS_PROJECT" --format='value(projectNumber)')"
gcloud services enable secretmanager.googleapis.com iam.googleapis.com \
  sts.googleapis.com --project="$SHOSAI_SECRETS_PROJECT"
for environment in development release; do
  gcloud secrets create "shosai-$environment-build-defines" \
    --project="$SHOSAI_SECRETS_PROJECT" --replication-policy=automatic
  gcloud iam workload-identity-pools create "shosai-$environment" \
    --project="$SHOSAI_SECRETS_PROJECT" --location=global
done
```

These create new resources; if a name exists, inspect its policy rather than
blindly replacing it. Upload the existing registrations privately as version 1
of each secret. Do not remove recovery identities or compatibility secrets until
local, orb and release consumers have passed their respective cutover checks.

### Amp development federation

Trust only exchanged, runtime tokens for this workspace/project, not the whole
Amp issuer or an audience alone. Mapping `thread_id` also fails closed for
project setup tokens that have no runtime thread identity.

```sh
gcloud iam workload-identity-pools providers create-oidc amp-orbs \
  --project="$SHOSAI_SECRETS_PROJECT" --location=global \
  --workload-identity-pool=shosai-development \
  --issuer-uri=https://ampcode.com/api/workload-identity \
  --allowed-audiences=urn:shosai:google-cloud:development \
  --attribute-mapping='google.subject=assertion.thread_id,attribute.workspace_id=assertion.workspace_id,attribute.project_id=assertion.project_id,attribute.token_use=assertion.token_use' \
  --attribute-condition="assertion.workspace_id == '151a5d10-6c37-4a1f-beee-588c0670c2a0' && assertion.project_id == 'ddce7000-d578-4c87-bd90-fecee49092e4' && assertion.token_use == 'exchanged'"
gcloud secrets add-iam-policy-binding shosai-development-build-defines \
  --project="$SHOSAI_SECRETS_PROJECT" --role=roles/secretmanager.secretAccessor \
  --member="principalSet://iam.googleapis.com/projects/$project_number/locations/global/workloadIdentityPools/shosai-development/attribute.project_id/ddce7000-d578-4c87-bd90-fecee49092e4"
```

Set these **non-secret** Amp project variables with `manage_amp`:

- `SHOSAI_SECRETS_PROJECT`: the confirmed project ID.
- `SHOSAI_AMP_WORKLOAD_IDENTITY_PROVIDER`:
  `projects/<number>/locations/global/workloadIdentityPools/shosai-development/providers/amp-orbs`.
- `SHOSAI_AMP_OIDC_AUDIENCE`: `urn:shosai:google-cloud:development`.

No `SOPS_AGE_KEY` or Google service-account key is needed. Refresh/restart
already-running orbs after configuration changes. Local runners do not inherit
Amp project variables; use local Google login and the project variable instead.
Grant developers `roles/secretmanager.secretAccessor` on the **development
secret**, not at project level. Any owner/recovery access to release is a separate
explicit secret-level grant to the chosen administrator.

### GitHub release federation

Use a separate pool, restrict immutable repository/owner IDs, require `RELEASE`,
allow only `main`/`v*` tag refs, and reject PR events (including
`pull_request_target`). Do not rely on the subject string's legacy format;
this repository uses GitHub's immutable-ID subject format.

```sh
gcloud iam workload-identity-pools providers create-oidc github \
  --project="$SHOSAI_SECRETS_PROJECT" --location=global \
  --workload-identity-pool=shosai-release \
  --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping='google.subject=assertion.sub,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.environment=assertion.environment,attribute.ref=assertion.ref,attribute.event_name=assertion.event_name' \
  --attribute-condition="assertion.repository_id == '1194321001' && assertion.repository_owner_id == '44737549' && assertion.environment == 'RELEASE' && (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/tags/v')) && assertion.event_name in ['push', 'workflow_dispatch']"
gcloud secrets add-iam-policy-binding shosai-release-build-defines \
  --project="$SHOSAI_SECRETS_PROJECT" --role=roles/secretmanager.secretAccessor \
  --member="principalSet://iam.googleapis.com/projects/$project_number/locations/global/workloadIdentityPools/shosai-release/attribute.repository_id/1194321001"
```

There is no service-account impersonation or exported service-account key.
Never grant either pool access to the other environment's secret. These bindings
are secret-level, not project-level. Keep `RELEASE`'s existing main/version-tag
restrictions and no-manual-approval policy. Ref restrictions are not semver
validation and do not make arbitrary code checked out by a trusted job safe.

## Contract for the release workflow owner

This change does not create/trigger the release workflow. A trusted build job
must use `environment: RELEASE`, `permissions: {contents: read, id-token: write}`,
checkout trusted code, and run `google-github-actions/auth@v3` (pin its reviewed
commit in the actual workflow) with:

```yaml
with:
  project_id: ${{ vars.SHOSAI_SECRETS_PROJECT }}
  workload_identity_provider: ${{ vars.SHOSAI_RELEASE_WORKLOAD_IDENTITY_PROVIDER }}
  create_credentials_file: true
  export_environment_variables: true
```

Configure those two non-secret variables in GitHub's `RELEASE` environment.
Set `SHOSAI_SECRETS_PROJECT` for the build step from the same environment variable,
enter the pinned Nix shell, then call:

```sh
./scripts/with-build-secrets.sh release \
  'flutter build apk --release --dart-define-from-file="{}"'
```

The provider resource is
`projects/<number>/locations/global/workloadIdentityPools/shosai-release/providers/github`.
Run authentication immediately before the fetch, while GitHub's OIDC token is
fresh. Do not set `service_account` or `credentials_json` on the auth action.
Its generated `gha-creds-*.json` is ignored and removed by the action after the
job. Do not upload workspace-wide artifacts that include ignored files.

The release owner must separately supply real signing identities and remove the
Android debug-signing fallback before publishing production-signed artifacts.
Normal PR jobs do not request release credentials. No credentials are fetched
merely to run the script test suite, which uses a synthetic gcloud boundary.

## Migration acceptance

Before retiring SOPS identities/secrets, verify real development reads locally
and from an authorized orb; release reads only from a trusted `RELEASE` job;
and negative cases for development→release, release→development, another Amp
project, PR events, wrong repository, environment and ref. Synthetic tests do
not prove live IAM policy. Keep old recovery material until acceptance and
explicit cleanup approval. Previously published ciphertext remains in Git
history; removing files does not erase it or revoke old age keys.

References: [Amp OIDC](https://ampcode.com/docs/orbs/handling-secrets#oidc),
[Secret Manager authentication](https://cloud.google.com/secret-manager/docs/authentication),
[GitHub federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines).
