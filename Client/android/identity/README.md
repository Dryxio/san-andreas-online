# Sideloaded launcher integration

The [companion Android launcher](https://github.com/samuk190/mta-sa-neon-android/pull/6) implements the current game protocol, gameplay fixes and optional ticket client. For ordinary PC and Android play, use the [default server configuration](../../../Services/neon-identity/README.md#configure-the-game-server). The details below apply to verified Android-only servers.

The proof helper uses the `org.mtamobile.identity` Kotlin package. Configure the issuer with the installed APK’s application ID and signer. The launcher contacts its trusted identity issuer using its existing session. HTTP 428 with `android_proof_required` starts one Keystore attestation on a worker thread. The client signs the domain string `neon-android-ticket-v1`, one zero byte and the raw 32-byte challenge with the fresh P-256 key. It sends the challenge, the leaf-first DER certificate chain and the DER ECDSA signature in one retry. Certificate and signature fields use ordinary padded Base64. The challenge uses unpadded Base64url. The launcher deletes the temporary key after producing the proof.

The launcher pins the issuer base URL in `NeonIdentityApi.BASE`. A private deployment needs a build configured for its own trusted HTTPS issuer and a session opened with that issuer. Never send a session token to a URL advertised by a game server.

See the [issuer configuration](../../../Services/neon-identity/README.md#sideloaded-android-ticket-policy) and the [gameplay test](../../../test-resources/android-session-test/README.md).

## Physical-device proof test

The optional `androidTest/DeviceProofTest.kt` instrumentation runs the same proof generator in the installed application's context. In a debug checkout, copy it into `app/src/androidTest/java/org/mtamobile/identity/test/` and set `testInstrumentationRunner = "org.mtamobile.identity.test.DeviceProofTest"` in the test build's `defaultConfig`. Build and install the debug app and its Android test APK with the same development signing identity.

For a private issuer test, set `APP_ID` and `TEST_APP_ID` to your installed launcher and instrumentation APK application IDs. Request a ticket with a test login, save the challenge from the 428 response, then run

```sh
adb shell am instrument -w -e challenge "$CHALLENGE" "$TEST_APP_ID/org.mtamobile.identity.test.DeviceProofTest"
adb exec-out run-as "$APP_ID" cat cache/neon-proof-test.json > proof.json
adb shell run-as "$APP_ID" rm -f cache/neon-proof-test.json
```

Submit the contents of `proof.json` as the `android_proof` object on the same authenticated ticket request before the challenge expires. Keep the raw certificate chain, proof and ticket private. The instrumented path tests issuance separately from the gameplay test.
