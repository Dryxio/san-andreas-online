import { createHash, verify } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { GoogleAuth } from "google-auth-library";
import { z } from "zod";

import type { AndroidInstallPolicy } from "./config.js";
import { randomToken } from "./crypto.js";
import { InstallCertificateAuthority, installPublicKey } from "./install-certificate.js";
import type { IdentityStore } from "./model.js";

const challengeTtlMs = 90_000;
const keyRequest = z.object({ public_key: z.base64().min(32).max(256) }).strict();
const enrollmentRequest = keyRequest.extend({
    challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
    signature: z.base64().min(8).max(128),
    integrity_token: z.string().min(1).max(12_000).regex(/^[A-Za-z0-9_.=-]+$/),
});
const verdictSchema = z.object({
    tokenPayloadExternal: z.object({
        requestDetails: z.object({
            requestHash: z.string(), requestPackageName: z.string(), timestampMillis: z.string().regex(/^[0-9]{1,15}$/),
        }),
        appIntegrity: z.object({
            appRecognitionVerdict: z.literal("PLAY_RECOGNIZED"), packageName: z.string(),
            certificateSha256Digest: z.array(z.string()).min(1), versionCode: z.string().regex(/^[1-9][0-9]{0,9}$/),
        }),
        testingDetails: z.object({ isTestingResponse: z.boolean().optional() }).optional(),
        deviceIntegrity: z.object({ deviceRecognitionVerdict: z.array(z.string()).optional() }).optional(),
    }),
});

/** Both the platform verdict and key signature cover the locally constructed enrollment request. */
export function installTranscript(issuer: string, challenge: string, publicKey: Uint8Array): Buffer {
    const fingerprint = createHash("sha256").update(publicKey).digest("base64url");
    return Buffer.from(["neon-android-install-v1", issuer, challenge, fingerprint].join("\0"), "utf8");
}

export type DecodeInstallToken = (token: string, packageName: string) => Promise<unknown>;
export function playIntegrityDecoder(): DecodeInstallToken {
    const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/playintegrity"] });
    return async (token, packageName) => {
        const response = await auth.request<unknown>({
            method: "POST", url: "https://playintegrity.googleapis.com/v1/" + encodeURIComponent(packageName) + ":decodeIntegrityToken",
            data: { integrityToken: token }, timeout: 8_000, retry: false, redirect: "error",
            validateStatus: (status) => status === 200 || status === 400,
        });
        return response.status === 200 ? response.data : null;
    };
}

function verifiedInstall(value: unknown, policy: AndroidInstallPolicy, expectedHash: string, now: Date): { deviceIntegrity: boolean } | null {
    const result = verdictSchema.safeParse(value);
    if (!result.success) return null;
    const { requestDetails, appIntegrity, testingDetails, deviceIntegrity } = result.data.tokenPayloadExternal;
    // Overridden tester responses and Play Games for PC must never authorize the Android game path.
    if (testingDetails?.isTestingResponse || deviceIntegrity?.deviceRecognitionVerdict?.includes("MEETS_VIRTUAL_INTEGRITY")) return null;
    const age = now.getTime() - Number(requestDetails.timestampMillis);
    const signer = Buffer.from(policy.signer_sha256, "hex").toString("base64url");
    const recognized = requestDetails.requestPackageName === policy.package_name && requestDetails.requestHash === expectedHash &&
        age >= -5_000 && age <= challengeTtlMs && appIntegrity.packageName === policy.package_name &&
        appIntegrity.certificateSha256Digest.length === 1 && appIntegrity.certificateSha256Digest[0]?.replace(/=$/, "") === signer &&
        Number(appIntegrity.versionCode) >= policy.minimum_version;
    if (!recognized) return null;
    return { deviceIntegrity: deviceIntegrity?.deviceRecognitionVerdict?.includes("MEETS_DEVICE_INTEGRITY") === true };
}

export function registerInstallEnrollment(app: FastifyInstance, store: IdentityStore, issuer: string,
    policy: AndroidInstallPolicy, ca: InstallCertificateAuthority, decode: DecodeInstallToken, now: () => Date): void {
    const limit = { config: { rateLimit: { max: 12, timeWindow: "1 minute" } } };
    let pendingChecks = 0;
    app.post("/v1/android/installs/challenge", limit, async (request, reply) => {
        const parsed = keyRequest.safeParse(request.body);
        const key = parsed.success && installPublicKey(parsed.data.public_key);
        if (!key) return reply.code(400).send({ error: "invalid_install_key" });
        const challenge = randomToken();
        const issued = now();
        const expires = new Date(issued.getTime() + challengeTtlMs);
        const binding = createHash("sha256").update(installTranscript(issuer, challenge, key)).digest();
        await store.setAndroidChallenge(binding, challenge, expires, issued);
        return { challenge, expires_at: expires.toISOString(), play_project_number: policy.play_project_number };
    });
    app.post("/v1/android/installs/enroll", limit, async (request, reply) => {
        const parsed = enrollmentRequest.safeParse(request.body);
        if (!parsed.success) return reply.code(400).send({ error: "invalid_install_request" });
        const { public_key, challenge, signature, integrity_token } = parsed.data;
        const key = installPublicKey(public_key);
        if (!key) return reply.code(400).send({ error: "invalid_install_key" });
        const message = installTranscript(issuer, challenge, key);
        if (!verify("sha256", message, { key: Buffer.from(key), format: "der", type: "spki" }, Buffer.from(signature, "base64"))) {
            return reply.code(403).send({ error: "invalid_install_signature" });
        }
        if (pendingChecks >= 4) return reply.code(503).send({ error: "install_verifier_busy" });
        pendingChecks++;
        try {
            const binding = createHash("sha256").update(message).digest();
            if (!await store.takeAndroidChallenge(binding, challenge, now())) {
                return reply.code(403).send({ error: "invalid_install_challenge" });
            }
            const verdict = await decode(integrity_token, policy.package_name);
            const verifiedAt = now();
            const install = verifiedInstall(verdict, policy, binding.toString("base64url"), verifiedAt);
            if (!install) {
                return reply.code(403).send({ error: "install_not_verified" });
            }
            return reply.code(201).send(await ca.issue(key, verifiedAt, install.deviceIntegrity));
        } catch {
            // Provider errors can contain tokens or authorization headers. Keep them out of the request logger.
            return reply.code(503).send({ error: "install_enrollment_unavailable" });
        } finally {
            pendingChecks--;
        }
    });
}
