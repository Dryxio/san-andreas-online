# Neon Identity V1

Neon Identity is the platform-owned Discord account link for every Neon server.
It is not a Blitz account system: Blitz can consume the same signed identity as
any other registered Neon server and can add a guild/role policy of its own.

This directory contains the minimal V1 backend contract. It deliberately keeps
the Discord client secret, bot token, OAuth tokens, session hashes, and Ed25519
private key outside the distributed MTA client and server binaries.

## V1 flow

1. The Neon client calls `POST /v1/auth/discord/start`.
2. It stores `flow_id` and `poll_token`, then opens `authorization_url` in the
   system browser. The one-time browser capability is in the URL fragment, so
   it is not sent in HTTP access logs or `Referer` headers.
3. The bridge page posts the capability to the backend. The backend atomically
   starts the flow, sets an encrypted `HttpOnly` OAuth cookie, and redirects to
   Discord with `scope=identify`, a random `state`, and PKCE S256.
4. The callback checks the encrypted cookie, expiry, `state`, and persisted
   state hash before linking the Discord profile. Discord access/refresh tokens
   are never persisted.
5. The client polls `POST /v1/auth/discord/poll`. The successful response
   reveals the opaque Neon session token exactly once.
6. Before joining a server, the client calls `POST /v1/tickets` with that
   session. The backend signs only when `server_id` and endpoint exist in the
   legacy allowlist or have an active, ASE-verified signed server lease. The
   returned Ed25519 JWT is audience-bound to that ID and lives for 30–60
   seconds (45 by default).

The `poll_token`, browser capability, and session token are random 256-bit
values. Only SHA-256 hashes of poll and session tokens are persisted. SHA-256 is
appropriate here because these are high-entropy generated secrets, not user
passwords.

Discord documents `identify` as access to the basic user profile and documents
the server-side authorization-code exchange and PKCE parameters in its
[OAuth2 documentation](https://docs.discord.com/developers/platform/oauth2-and-permissions)
and [account-linking guide](https://docs.discord.com/developers/discord-social-sdk/development-guides/account-linking-with-discord).

## HTTP contract

Start a link:

```http
POST /v1/auth/discord/start
```

```json
{
  "flow_id": "f2d4f89f-8e84-4019-ae52-a8d940e22035",
  "poll_token": "opaque-one-time-poll-secret",
  "authorization_url": "https://identity.example.com/v1/auth/discord/authorize#...",
  "expires_at": "2026-08-03T12:05:00.000Z"
}
```

Poll while the browser flow is pending:

```http
POST /v1/auth/discord/poll
Content-Type: application/json

{"flow_id":"...","poll_token":"..."}
```

```json
{"status":"pending"}
```

The first successful poll returns the session; subsequent polls return `409`:

```json
{
  "session_token": "ns_v1_...",
  "session_expires_at": "2026-09-02T12:00:00.000Z",
  "account": {
    "id": "Neon account UUID",
    "discord_id": "Discord snowflake",
    "discord_username": "name",
    "discord_display_name": "Display Name",
    "discord_avatar_hash": "hash"
  }
}
```

Issue a game ticket:

```http
POST /v1/tickets
Authorization: Bearer ns_v1_...
Content-Type: application/json

{"server_id":"blitz-production","server_endpoint":"203.0.113.10:22003"}
```

```json
{"ticket":"eyJ...","expires_at":"2026-08-03T12:00:45.000Z"}
```

The session is authenticated before registry membership is disclosed. A valid
session requesting an unregistered server/endpoint pair receives:

```http
HTTP/1.1 403 Forbidden
```

```json
{"error":"server_endpoint_not_allowed"}
```

Discovery and keys are public:

- `GET /.well-known/neon-identity`
- `GET /.well-known/neon-server-registry`
- `GET /.well-known/jwks.json`
- `GET /healthz`

The identity discovery document includes `server_registry_uri`, which points to
the public catalogue consumed by the Neon server browser. The catalogue is a
versioned presentation document rather than an authorization source:

```json
{
  "schema_version": 1,
  "servers": [
    {
      "id": "blitz-production",
      "endpoints": ["213.32.90.138:22004"],
      "name": "MTA:SA Neon - BUST",
      "tagline": "Competitive 1v1 Pursuits - Ranked ON",
      "description": "Ranked 1v1 vehicle pursuits across the open world of San Andreas. Hunt your rival or escape until time runs out, then climb the leaderboard. Every street, shortcut and stunt can decide the match.",
      "countries": ["BR", "GB", "FR", "RU", "PL", "ID", "ES"],
      "languages": ["Portuguese (Brazil)", "English", "French", "Russian", "Polish", "Indonesian", "Spanish"],
      "links": [],
      "logo_url": "https://identity.example.com/v1/server-registry/assets/0123456789abcdef...",
      "banner_url": "https://identity.example.com/v1/server-registry/assets/fedcba9876543210..."
    }
  ]
}
```

The catalogue is populated by public Neon server heartbeats. A heartbeat is
bound by default to the TCP source address inserted by the trusted reverse proxy, then the
service probes the corresponding MTA ASE endpoint (`game_port + 123`) and
requires the current `NeonRegistryProtocol` ASE rule before it publishes
anything. It expires after five minutes without renewal. This makes
all public servers running a heartbeat-capable Neon build discoverable without
manual registration while preventing a server from advertising another public
IP. It is service verification, not binary attestation: a determined operator
can modify an open-source build, so abuse still requires moderation controls.

Names and presentation metadata come from `mtaserver.conf`. Live mode, map,
player count, password state, version, and ping remain sourced from ASE. Public
catalogue responses allow cross-origin reads and use
`Cache-Control: public, max-age=30, stale-if-error=300`.

Optional `logo_url` and `banner_url` heartbeat fields are fetched by Identity,
not exposed directly to players. Every hop must resolve exclusively to public
IP addresses and use HTTPS on the standard port. Redirects, timeouts, response
size, MIME magic, and dimensions are validated. PNG, JPEG, and WebP files up to
2 MiB and 4096×4096 (at most 16 megapixels) are accepted. Valid assets are
content-addressed in PostgreSQL and published through immutable, same-origin
HTTPS URLs. A failed refresh retains an older cached copy when possible and
never removes an otherwise healthy server from discovery.

## Ticket validation contract

The compact JWT header is `alg=EdDSA`, `typ=JWT`, plus the published `kid`.
Claims are:

- `iss`: configured Neon Identity issuer;
- `aud`: exact requested Neon `server_id`;
- `sub`: global Neon account UUID;
- `discord_id`: explicit Discord ID exposure for V1;
- `server_endpoint`: actual IPv4 endpoint joined by the native client;
- `iat`, `nbf`, `exp`: short validity window;
- `jti`: unique ticket ID.

A game server must reject every other algorithm, unknown `kid`, wrong issuer,
wrong audience, missing claim, or expired/not-yet-valid ticket. It must also
cache accepted `jti` values until `exp` and reject replays. Offline signature
validation alone cannot make a JWT one-time-use.

V1 intentionally exposes `discord_id` because this is the agreed integration
contract. A future multi-tenant release should gate that claim behind server
registration and player consent, or replace it with a per-organization
pseudonymous identifier.

## MTA Neon server integration

The custom Neon client reads the identity policy and stable `server_id` from
the initial mod-name handshake. Ordinary MTA servers advertise no policy and
never cause an identity ticket request. The client obtains the endpoint from
its real network connection rather than trusting server metadata. Both the
`server_id` and actual `IPv4:port` pair must be authorized by Identity; this
prevents an arbitrary MTA server from claiming another Neon audience and
capturing a signed-in player's identity ticket.

For an ordinary public Neon server, enable the desired policy directly:

```xml
<neon_auth>required</neon_auth>
```

The server creates `neon-identity.keys`, derives a stable `nsrv_...` audience,
signs its registry heartbeat, and proves the same identity through ASE. Keep
that private file in backups. Complete legacy configuration remains supported
for already provisioned servers and custom Identity deployments.

For the official production issuer, service startup also verifies that the
configured signing `kid` and public JWK coordinate match the trust bundle
compiled into automatic servers. Key rotation therefore requires an overlap
release of the server trust bundle before the backend starts signing with the
new key; a mismatched production deployment fails fast instead of issuing
unusable tickets.

`neon_auth` accepts `disabled`, `optional`, or `required`. Ticket validation
happens before the server allocates a player element. Once accepted, resources
can consume the platform identity through:

```lua
isPlayerNeonAuthenticated(player) -- boolean
getPlayerNeonID(player)            -- global Neon UUID or false
getPlayerDiscordID(player)         -- Discord snowflake string or false
```

Equivalent player methods are `player:isNeonAuthenticated()`,
`player:getNeonID()`, and `player:getDiscordID()`.

Resources that need to apply account or access policy before a player joins can
read the same verified identifiers from the final `onPlayerConnect` arguments:

```lua
addEventHandler("onPlayerConnect", root, function(
    nickname, ip, username, serial, versionNumber, versionString, neonID, discordID
)
    if not accountExistsForNeonID(neonID) then
        cancelEvent(true, "No account is linked to this Neon identity.")
    end
end)
```

`neonID` and `discordID` are strings when their identities were verified and
`false` when unavailable. They are appended to the existing event signature,
so existing handlers remain compatible. With `neon_auth=required`, both values
come from the ticket that was validated before this event runs.

### Automatic public discovery

Public discovery is enabled by default when ordinary MTA ASE publication is
enabled. An administrator can opt out or provide richer browser metadata:

```xml
<neon_registry>1</neon_registry>
<neon_registry_tagline>Competitive 1v1 Pursuits - Ranked ON</neon_registry_tagline>
<neon_registry_description>Ranked 1v1 vehicle pursuits across the open world of San Andreas. Hunt your rival or escape until time runs out, then climb the leaderboard. Every street, shortcut and stunt can decide the match.</neon_registry_description>
<neon_registry_countries>GB, ES, BR, FR</neon_registry_countries>
<neon_registry_languages>English, Spanish, Portuguese (Brazil), French</neon_registry_languages>
<neon_registry_website>https://mta-neon.com</neon_registry_website>
<neon_registry_discord>https://discord.gg/example</neon_registry_discord>
<neon_registry_accent>#9EBCE5</neon_registry_accent>
<neon_registry_logo>https://cdn.example.com/neon/logo.webp</neon_registry_logo>
<neon_registry_banner>https://cdn.example.com/neon/banner.webp</neon_registry_banner>
```

`countries` contains comma-separated ISO 3166-1 alpha-2 codes. Links must use
HTTPS. Artwork is optional and its source URL is replaced by the cached
Identity URL before publication. Empty optional fields receive conservative service defaults. The
official heartbeat URL is compiled as the default; a private deployment can
override it with `<neon_registry_url>`.

## Public domain and owner-managed relays

With automatic Neon Identity enabled (`<neon_auth>optional</neon_auth>` or
`required`, without legacy manual identity fields), set `<neon_registry_public_host>server.example.com</neon_registry_public_host>`
in `mtaserver.conf`. Use a lowercase DNS hostname without a scheme, path or port
(IDNs must use ASCII punycode). Leave it empty to preserve source-IP discovery. Invalid hostnames or a configured
hostname without automatic Identity stop server startup instead of publishing the origin.
Deploy migration `005_server_public_host.sql` and the updated Identity service
before enabling the setting on servers; the updated client/browser displays and
copies the domain. Older clients continue using the published IPv4 endpoint.

The registry resolves the hostname to exactly one public IPv4 and probes ASE at
that address, requiring the same server identity as the signed heartbeat. The
published catalogue and authentication lease contain the verified relay endpoint,
not the heartbeat's source IP. Browser queries, connections, favourites and ticket
requests continue using that verified IPv4; copied links use the domain. DNS is
checked again on each heartbeat. Multiple A records and IPv6-only names are not
supported. Keep the relay's public game/HTTP ports equal to the configured server
ports; ASE uses the game port plus 123. A DNS/probe failure rejects the heartbeat;
the previous listing expires normally rather than falling back to the origin IP.

Owners provide and protect the UDP/TCP relay, route traffic to the origin, and
block direct origin access. An HTTP-only reverse proxy is insufficient. Check
other publication paths separately: the classic MTA master list, external resource
download URLs, other services and historical DNS can still reveal an origin IP.
This setting does not configure networking, suppress those publications or provide
DDoS protection. Neon Identity necessarily sees the heartbeat's source IP, but
does not publish it when the public hostname is verified.

## Local setup

Requirements: Node.js 22+ and PostgreSQL 15+.

```sh
cd Services/neon-identity
npm install
npm run generate-key
cp .env.example .env
```

Create a Discord application and register this exact redirect URL:

```text
https://identity.example.com/v1/auth/discord/callback
```

Fill `.env` with the application ID, client secret, generated private JWK,
generated cookie key, PostgreSQL URL, public origin, issuer, and at least one
registered server endpoint. Never commit `.env`. Then apply migrations and start the
service:

```sh
set -a
. ./.env
set +a
npm run migrate
npm run dev
```

Production requires HTTPS at the public origin. Terminate TLS at a trusted
reverse proxy, forward only the expected host, set `TRUST_PROXY=true` only when
requests can arrive exclusively through that proxy, and keep request query,
cookie, and authorization headers out of proxy logs. The service itself omits
request URLs from structured logs and redacts credential-bearing headers.

## Identity security allowlist

`NEON_SERVER_REGISTRY` remains a required compatibility map for manually
provisioned server IDs and canonical endpoints:

```dotenv
NEON_SERVER_REGISTRY='{"blitz-production":["203.0.113.10:22003","203.0.113.11:22003"],"neon-staging":["127.0.0.1:22003"]}'
```

Every ID must match `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}` and every endpoint must
be canonical `IPv4:port` without leading-zero aliases. Empty or invalid
allowlists fail service startup. Matching heartbeats retain their official ID;
other verified public Neon servers receive a stable endpoint-derived community
ID and appear in discovery, but unsigned V1 heartbeats cannot request Discord
Identity tickets. Signed V2 servers instead receive a key-derived `nsrv_...`
ID and a short endpoint lease after the same ID is observed through ASE.
`POST /v1/tickets` authenticates the session, then checks the exact legacy pair
or active V2 lease before calling the signer. Removal, suspension, or lease
expiry stops new tickets immediately; issued tickets remain valid only until
their short `exp`.

## Optional Discord guild/role policy

Global Neon account linking allows every valid Discord account by default.
The `DiscordIdentityPolicy` interface is the hook point for server- or
deployment-specific admission rules. The included policy can require a guild,
completed membership screening, and one or more roles:

```dotenv
DISCORD_REQUIRED_GUILD_ID=123456789012345678
DISCORD_REQUIRED_ROLE_IDS=234567890123456789,345678901234567890
DISCORD_BOT_TOKEN=backend-only-bot-token
DISCORD_REQUIRE_COMPLETED_SCREENING=true
```

The bot must belong to that guild. Discord's
[`Get Guild Member` endpoint](https://docs.discord.com/developers/resources/guild#get-guild-member)
is called with the backend-only bot token. A missing member, pending screening,
or missing configured role denies the flow. Leave these variables blank for the
platform-wide identity service and evaluate Blitz policy at Blitz ticket time.

## Operations and current V1 boundaries

- Run `npm test` and `npm run build` before deployment.
- Rotate signing keys by publishing old and new public keys concurrently until
  every ticket signed by the old key has expired. The current minimal service
  publishes one active key, so overlap needs to be added before rotation.
- Revoke a session by setting `neon_sessions.revoked_at`; a player-facing
  logout/revocation endpoint is not part of this first native-client checkpoint.
- Periodically delete expired flows and sessions after retaining any required
  security audit interval.
- The heartbeat-backed public registry and Identity authorization use the same
  verified V2 server lease for automatically onboarded servers. Legacy/manual
  server IDs continue to use the static allowlist. There is not yet a
  server-owner portal or moderation console.
- Public server-browser metadata is validated by `src/server-catalog.ts` and
  persisted from verified heartbeats. Signed tickets are issued only for an
  exact legacy allowlisted pair or an active ASE-verified signed server lease.
- Store the signing key and Discord credentials in a secrets manager in
  production, not an environment file on disk.

## Sideloaded Android ticket policy

### Configure the game server

**1. Allow PC and Android players without requiring extra Android proof (default).** Use a launcher that supports the server’s current game protocol. Leave the following setting in `mods/deathmatch/mtaserver.conf` and restart after editing it.

```xml
<neon_auth>disabled</neon_auth>
```

Leave `<disableac></disableac>` empty to keep stock anticheat on. Make the game port (UDP 22003 by default) and the HTTP resource port (TCP 22005 by default) reachable by your players. In a compatible Android launcher, add the game host and port to Favorites, then tap Play. A classic join requires no Google project, issuer setup or per-phone approval. Default servers use the stock game transport and its anticheat. That module can reject an Android connection with AC #4 before the game sees a join. Server passwords, bans and version requirements also apply.

**2. Require Google Play device integrity on QUIC connections.** Leave `mobile_integrity` blank by default. A QUIC listener configured with `<mobile_integrity>yes</mobile_integrity>` requires a trusted install certificate carrying the device-integrity verdict. Neon Identity signs that claim when Google recognizes both the app and device. Rooted devices and devices running uncertified custom ROMs may be unable to connect. A player can still change to another qualifying device. [QUIC listener configuration](../../Shared/transport/README.md#mobile-integrity-on-the-quic-listener) · [Google Play verdicts](https://developer.android.com/google/play/integrity/verdicts#device-integrity-field)

**Classic port limitation.** Existing PC clients use the classic game port with stock anticheat. Compatible Android clients can also use that port, where the server cannot authenticate the client platform or require a Play verdict. To apply the mobile setting, publish the separate QUIC endpoint for Android players. [Configure the endpoint and connect from a phone](../../Shared/transport/README.md#enable-android-gameplay-on-a-second-udp-port) [Server network interface](../../Server/sdk/net/CNetServer.h)

**3. Allow only hardware-verified Android players.** Desktop clients cannot join in `android-required` mode. Every join requires an issuer-signed ticket with the Android hardware-attestation claim. To configure this policy:

1. Use a Neon server build that includes `android-required`. Obtain a dedicated server ID, HTTPS issuer URL, Android ticket key ID and public key from the issuer operator. The issuer must authorize that server ID and its actual game endpoint (`IPv4:port`).
2. Edit the existing settings in `mods/deathmatch/mtaserver.conf`. Replace the example server ID, URL and key details with the issuer’s values.

   ```xml
   <neon_auth>android-required</neon_auth>
   <neon_auth_server_id>neon-mobile</neon_auth_server_id>
   <neon_auth_issuer>https://identity.example.com</neon_auth_issuer>
   <neon_auth_key_id>android-v1</neon_auth_key_id>
   <neon_auth_public_key>REPLACE_WITH_ANDROID_PUBLIC_JWK_X</neon_auth_public_key>
   ```

3. Restart the game server. Players sign in through a launcher configured for the same issuer. Every join on this server requires a hardware-verified Android ticket. The normal anti-cheat checks also apply.

**Choosing the settings**

- **Empty, omitted or `disabled` `neon_auth`** turns off Neon Identity tickets. Android clients can still join if they match the game protocol and pass the server’s usual checks.
- **`optional` or `required`** uses standard Neon account tickets. In optional mode players can join without a ticket. Required mode needs a valid ticket for every join.
- **`android-required`** requires a trusted Android ticket for every player. Use the updated Android launcher with the server’s current game protocol (`0x41E7`). If upgrading from the release 189 test configuration, remove `neon_game_protocol` and update the launcher before connecting.

### Configure the issuer

One HTTPS issuer can serve multiple game servers. Keep the private signing keys and Discord credentials on the issuer. Give game server owners the base64url `x` coordinate of the Android public JWK.

1. Run the service migrations, including `006_android_challenges.sql`.
2. With Gradle 8.14 and JDK 21, run `gradle -p android-verifier installDist` from this service. Install the entire generated `build/install/neon-android-verifier` directory on the issuer host. The service account needs a JDK/JRE 21+, permission to run the installed script and outbound HTTPS access to Google's attestation revocation service.
3. Set the service environment to a JSON object such as the following. Replace the example package name with the approved APK’s actual application ID and the illustrative digest with the SHA-256 of its **signing certificate**, obtained with `apksigner verify --print-certs`. Choose the oldest version code the operator supports. Use separate signers and issuer configuration for development and public deployments.

```json
{"key_id":"android-v1","server_ids":["neon-mobile"],"package_name":"org.example.mtamobile","signer_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","minimum_version":1,"verifier":"/opt/neon-android-verifier/bin/neon-android-verifier"}
```

Set this object as `NEON_ANDROID_ADMISSION`. Generate a separate Ed25519 key pair for Android tickets with the existing key generator. Store its private JWK in `NEON_ANDROID_TICKET_PRIVATE_JWK` in the issuer's secret store. Keep the ordinary ticket key in `NEON_TICKET_PRIVATE_JWK`. Configure only the dedicated public key on the mobile game server and restart the issuer and that server.

Integrate the [launcher ticket client](../../Client/android/identity/README.md) in a build pointed at this issuer. The existing session and endpoint authorization checks run before the issuer creates a challenge. Each challenge expires in 60 seconds. A new request replaces the previous challenge for the same login session, server ID and endpoint. Submitting a matching proof consumes the challenge atomically, including when verification fails. Obtain a fresh challenge to retry. Verifier failure prevents ticket issuance.

The verifier uses Google's Android Key Attestation library 0.4. It checks the chain, revocation, expected package, signer, minimum version, locked verified boot, hardware security level, nonce and possession of the signing key. The same Neon ticket format and game-server checks apply after verification. The proof covers an issuer ticket request. The game transport must independently establish a connection before the server can consume the ticket. [Android hardware key attestation](https://developer.android.com/privacy-and-security/security-key-attestation)

## Android install credentials for QUIC

**When does Play Integrity run?** The companion launcher's main activity checks for an install credential at startup, before a player selects a game server. It reuses a valid cached certificate. When it needs a new one, it asks its Neon Identity issuer for a challenge. A configured issuer returns its public Cloud project number, and the launcher then requests a Play Integrity verdict. An unavailable enrollment service leaves classic gameplay available. [Launcher implementation](https://github.com/samuk190/mta-sa-neon-android/blob/02518806c9fd7aed46b151c83d0e8f3274505fc2/app/src/main/java/com/saonline/neonlauncher/network/AndroidInstallCredential.kt)

| Setting | Where it applies | What it controls |
| --- | --- | --- |
| `neon_auth` disabled, optional or required | Game server | Neon account tickets for classic joins. Each of these modes works independently of Play Integrity. |
| `neon_auth` set to `android-required` | Game server | Every player needs a hardware-backed Android admission ticket. This uses the separate Android Key Attestation verifier described above. |
| `NEON_ANDROID_INSTALL_ENROLLMENT` | Identity service | Enables Play-verified issuance of one-hour QUIC client certificates. The issuer checks app recognition and key possession. It requires neither a hardware verdict nor a player account. |

The following setup is for the **launcher publisher and issuer operator**. One publisher project serves all installations of its release across game servers. The game server verifies the install certificate on its separate QUIC gameplay port. [Transport implementation and diagnostic](../../Shared/transport/README.md)

### Register the launcher release with Google Play

1. In Play Console, select the app with the launcher's application ID. The SA Online launcher uses `com.saonline.neonlauncher`. For an independently published fork, use the package you control. Distribute a signed build through a Play track, such as internal testing, so Google can recognize the package, certificate and version. Record the **app signing key certificate** SHA-256 fingerprint from Play Console and the lowest Android `versionCode` you will accept. The upload key and local debug key can have different fingerprints.
2. Select a Google Cloud project owned by the publisher. If creating one, run `gcloud auth login`, choose a globally unique project ID and use `gcloud projects create "$PROJECT_ID"`. With the chosen `PROJECT_ID` set in your shell, run the following commands. Create the service account once, or use an existing dedicated account from that project.

   ```sh
   gcloud services enable playintegrity.googleapis.com iam.googleapis.com --project="$PROJECT_ID"
   gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)'
   gcloud iam service-accounts create neon-integrity-issuer --project="$PROJECT_ID"
   ```

3. In the app's Play Console, open **Protected with Play → Play Integrity API → Link Cloud project** and select that project. Record the numeric project number for the issuer. Its challenge response supplies the number to the launcher. [Google Play Integrity setup](https://developer.android.com/google/play/integrity/setup)

### Deploy enrollment on Neon Identity

1. Set up the HTTPS identity service and database and run `npm run migrate` with its deployment environment, including migration `006_android_challenges.sql`. For a fresh installation, start with the [identity service setup](#local-setup).
2. Configure **Application Default Credentials** for the running issuer process. On Google Cloud, attach the project's decoder service account to the workload. On an external host, configure Workload Identity Federation to impersonate that account and set `GOOGLE_APPLICATION_CREDENTIALS` in the service environment to the readable external-account configuration file. The service requests the `playintegrity` OAuth scope and calls Google's `decodeIntegrityToken` endpoint for the configured package. Keep Google credentials and the install CA private key on the backend. [Google server-side verification](https://developer.android.com/google/play/integrity/standard#decrypt-verify) · [Application Default Credentials](https://cloud.google.com/docs/authentication/application-default-credentials)
3. For the SA Online package on a configured systemd host, install this branch's `deploy/neon-identity.service`. From `Services/neon-identity`, set the variables below to your project number, app signing fingerprint and minimum version. The helper reads the fingerprint as 64 hex digits, creates a dedicated P-256 CA on first use and preserves it on later runs.

   ```sh
   sudo bash deploy/configure-android-installs.sh "$PROJECT_NUMBER" "$(printf '%s' "$PLAY_SIGNER_SHA256" | tr -d ':')" "$MINIMUM_VERSION_CODE"
   sudo systemctl daemon-reload
   sudo systemctl restart neon-identity
   ```

   **Custom package or deployment.** The helper sets the SA Online package name. For another package, set `NEON_ANDROID_INSTALL_ENROLLMENT` directly in the issuer environment to a JSON object like the following, replacing the example values. The service user needs read access to the matching P-256 CA key and certificate with certificate-signing usage. For a fork, point the launcher's `NeonIdentityApi.BASE` at your HTTPS issuer and configure the QUIC listener to trust your issuer's public client CA. The stock launcher's base URL and transport's default CA URL point to the official issuer.

   ```json
   {
     "package_name": "com.example.launcher",
     "signer_sha256": "<64 lowercase hex digits>",
     "minimum_version": 1,
     "play_project_number": "<numeric project number>",
     "ca_cert_file": "/etc/neon-identity/android-install-ca/cert.pem",
     "ca_key_file": "/etc/neon-identity/android-install-ca/key.pem"
   }
   ```

### Verify enrollment

Set `ISSUER` to the public HTTPS origin of your configured service. Discovery should list the challenge, enrollment and public CA URLs. The second command should print the CA subject and validity dates.

```sh
curl -fsS "$ISSUER/.well-known/neon-identity" | jq -e '.android_install_challenge_endpoint and .android_install_enrollment_endpoint and .android_install_ca_uri'
curl -fsS "$ISSUER/.well-known/neon-android-install-ca.pem" | openssl x509 -noout -subject -dates
```

Install the Play-track build on a tester's phone and open the launcher. Use `adb logcat -s NeonIdentity` to look for `Android install credential ready.` On first enrollment the challenge returns HTTP 200 and enrollment returns HTTP 201. A cached credential also produces the ready message. A missing discovery entry or HTTP 404 on the challenge points to the issuer deployment or enrollment configuration. For HTTP 403 with `install_not_verified`, check the Play-recognized release, package, signing fingerprint and minimum version. For HTTP 503 with `install_enrollment_unavailable`, check the issuer's Google service identity, API access and CA validity. These checks verify credential issuance. Gameplay over QUIC still requires a host certificate and the gameplay adapter.
