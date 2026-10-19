# Security and privacy

## Reporting a vulnerability

Use this repository's **Security → Report a vulnerability** feature if available.
Do not open a public issue containing credentials, private media URLs, personal
watch history, signing material, or an exploit against someone's live server.

## What belongs outside Git

Keep the following in local configuration, environment variables, secret stores,
or mounted runtime directories:

- Usenet usernames/passwords and indexer keys.
- TMDb credentials, backend app tokens, and the separate admin access key.
- Codex authentication state and any other provider credentials.
- SQLite databases, viewing history, profiles, logs, and exports.
- Android signing keys, Apple certificates/profiles and App Store API keys,
  and Roku developer passwords.

The clients ship with empty owner-specific credentials and backend defaults.
Configure your own backend and metadata credentials as described in each client
README. A credential supplied to a client is available to the device's owner;
client configuration is not a secret vault.

## Deployment boundaries

Use HTTPS for remote access. Configure the backend's app token before exposing
your installation and enter it in the clients. The app token protects the
routes documented as authenticated; this backend is not a hardened multi-tenant
hosting platform. Streaming and other route-specific authorization behavior is
documented in the backend guide. A reverse proxy or access-controlled network
can provide an additional boundary appropriate to your deployment.

The admin portal uses a separate access key and an HttpOnly session cookie.
Do not give viewers the admin key. Reporting includes profile/device identifiers,
titles, timestamps, and viewing activity; tell people using your server what
you collect. Analytics are stored on your backend, not sent to a project-owner
analytics service. Optional metadata, AI, and media integrations contact the
services you enable.

## Publication audit

The initial public tree was prepared as a clean source snapshot. Private Git
history, local configuration, signed app releases, device inventories, deployment
screenshots, and runtime data are excluded. Source, selected original artifacts,
the backend image filesystem/layers, and the final publication snapshot were
checked for known credentials and owner-specific data. Automated checks do not
prove the absence of every possible secret or vulnerability.

The repository includes a publication guard and secret-scanning workflow to
reduce accidental disclosure in later changes. Review new files and archives
before sharing them; an ignore rule is not an access-control boundary.
