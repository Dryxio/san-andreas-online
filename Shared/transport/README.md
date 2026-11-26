# Native Neon UDP transport

This package provides mutual TLS over QUIC for Windows, Android and Linux. Ordered streams carry reliable messages. QUIC datagrams carry disposable updates on the same UDP endpoint. Both carry a one-byte message kind, a four-byte big-endian bit count and the payload bytes. An explicit bit count preserves partially filled final bytes. Each stream frame is limited to 256 KiB. Datagram senders must also respect the negotiated datagram size.

The server verifies a client certificate against its configured client CA before returning a connection. Neon Identity can issue client certificates to Play-recognized Android installs and publish its dedicated client CA. `AndroidInstallRoots` retrieves the official issuer's public CA over HTTPS. A listener using `peercheck -listen` fetches that CA when `-ca` is omitted. The game host supplies its own server certificate. The classic endpoint uses its existing network module. The separate gameplay listener uses the same install CA policy as the diagnostic. [Android install enrollment](../../Services/neon-identity/README.md#android-install-credentials-for-quic)

## Mobile integrity on the QUIC listener

Leave `<mobile_integrity></mobile_integrity>` blank (default) to accept standard install credentials. Set `<mobile_integrity>yes</mobile_integrity>` to require a client certificate from the trusted install CA with a signed Play device-integrity claim. The issuer adds the URI `https://identity.mta-neon.com/claims/play-device-integrity-v1` to the leaf certificate only when the same verified Play response covers the recognized app, enrollment challenge, install key and `MEETS_DEVICE_INTEGRITY`. This URI is a claim identifier. Phones with an older or app-only certificate need a newly issued qualifying certificate. Rooted devices and devices running uncertified custom ROMs may be unable to qualify.

Pass the actual server configuration file to the diagnostic listener with `-config /path/to/mtaserver.conf`. It reads the setting at startup. The game host supplies its own host key and certificate and trusts the publisher’s dedicated install CA for client certificates. A configured listener rejects unqualified peers during TLS, before accepting application frames. Blank disables the extra device check and still requires mutual TLS.

The classic UDP game port continues to use stock anticheat for every compatible classic client. Its network module supplies no authenticated platform identity. A mixed server that keeps this port open for existing desktop clients cannot enforce the QUIC policy on phones using the classic protocol.

### Enable Android gameplay on a second UDP port

1. Build the deathmatch server from this branch. In `Shared/transport`, run `go build -buildmode=c-shared -o libneon_gameplay.so ./native` on Linux. For Windows x64, use a Go-compatible C compiler, set `CGO_ENABLED=1`, and change the output filename to `neon_gameplay.dll`. Place the library in `mods/deathmatch`.
2. Put the server certificate and any intermediate certificates in `mods/deathmatch/quic-server.pem`, and the matching private key in `mods/deathmatch/quic-server.key`. Restrict the key to the server account. The certificate must cover the hostname players enter and chain to a CA trusted by Android.
3. Add the settings below to the active server configuration. Open the chosen UDP port and the usual HTTP resource port. Restart and look for `QUIC gameplay listening` in the server log.

```xml
<mobile_quic_address>0.0.0.0:22010</mobile_quic_address>
<mobile_integrity></mobile_integrity>
```

4. In the updated Android launcher, open **Favorites → Add**, enter `quic://game.example.org` as the host and `22010` as the port, then connect. Use the host name on the server certificate. A failed QUIC connection ends the attempt. Desktop players continue to use their existing host and classic game port.

With a blank integrity setting, the listener still requires possession of the key for an install certificate. With `yes`, it also requires the issuer's device-integrity claim. The default install CA comes from Neon Identity. Operators of a separate issuer can set `<mobile_quic_client_ca>install-ca.pem</mobile_quic_client_ca>` to a dedicated public Android install CA file under `mods/deathmatch`. An issuer trusted here can authorize clients and assert device integrity, so use a dedicated issuer that enforces the intended enrollment policy. The game derives an install serial from the authenticated public key. A reinstall can generate a different key.

## Test a connection

Build with the Go version in `go.mod`. Run `go test -race ./...` and `go build ./cmd/peercheck`. For an Android ARM64 diagnostic executable, set `CGO_ENABLED=0 GOOS=android GOARCH=arm64` when building. The diagnostic is separate from the game APK.

Use a test server certificate with the intended DNS name and server-auth usage, and a separate client certificate with client-auth usage. Keep the issuing CA private key offline. On a test machine where the chosen UDP address is available, run:

```sh
peercheck -listen -address 192.0.2.1:22003 -cert host.pem -key host.key -ca client-ca.pem
```

On the client, run:

```sh
peercheck -address 192.0.2.1:22003 -server-name game.example.org -cert client.pem -key client.key -ca server-ca.pem
```

The diagnostic checks a random challenge over an ordered stream, a datagram response and a final acknowledgement. It exits after one connection or a timeout. Use a separate test host or bind address when a classic server already owns the endpoint.
