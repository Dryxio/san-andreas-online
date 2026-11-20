import "reflect-metadata";
import { BasicConstraintsExtension, KeyUsageFlags, KeyUsagesExtension, X509CertificateGenerator } from "@peculiar/x509";
import { createHash, generateKeyPairSync, sign, X509Certificate } from "node:crypto";
import Fastify from "fastify";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { installTranscript, registerInstallEnrollment, type DecodeInstallToken } from "../src/android-install.js";
import type { AndroidInstallPolicy } from "../src/config.js";
import { InstallCertificateAuthority } from "../src/install-certificate.js";
import { MemoryIdentityStore } from "../src/memory-store.js";

const issuer = "https://identity.example";
const policy: AndroidInstallPolicy = {
    package_name: "org.example.launcher", signer_sha256: "f1".repeat(32), minimum_version: 12,
    play_project_number: "123456789", ca_cert_file: "/unused/ca.pem", ca_key_file: "/unused/key.pem",
};
const signerDigest = Buffer.from(policy.signer_sha256, "hex").toString("base64url");
const initialTime = Date.UTC(2026, 0, 1);
const installKey = generateKeyPairSync("ec", { namedCurve: "P-256" });
const publicDer = installKey.publicKey.export({ type: "spki", format: "der" });
const public_key = publicDer.toString("base64");

describe("Android install certificate enrollment", () => {
    const decode = vi.fn<DecodeInstallToken>();
    let service: ReturnType<typeof Fastify>;
    let root: X509Certificate;
    let ca: InstallCertificateAuthority;
    let current: number;

    beforeAll(async () => {
        const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
        const cert = await X509CertificateGenerator.createSelfSigned({
            name: "CN=Enrollment test CA", keys, notBefore: new Date(initialTime - 1_000), notAfter: new Date(initialTime + 3_600_000),
            extensions: [new BasicConstraintsExtension(true, 0, true), new KeyUsagesExtension(KeyUsageFlags.keyCertSign, true)],
        });
        const key = Buffer.from(await crypto.subtle.exportKey("pkcs8", keys.privateKey)).toString("base64");
        root = new X509Certificate(cert.toString("pem"));
        ca = await InstallCertificateAuthority.create(cert.toString("pem"), "-----BEGIN PRIVATE KEY-----\n" + key + "\n-----END PRIVATE KEY-----");
    });
    beforeEach(() => {
        current = initialTime;
        decode.mockReset();
        service = Fastify();
        registerInstallEnrollment(service, new MemoryIdentityStore(), issuer, policy, ca, decode, () => new Date(current));
    });
    afterEach(async () => { await service.close(); });

    async function start() {
        const response = await service.inject({ method: "POST", url: "/v1/android/installs/challenge", payload: { public_key } });
        expect(response.statusCode).toBe(200);
        const { challenge, play_project_number } = response.json();
        expect(play_project_number).toBe(policy.play_project_number);
        // Compute the transcript as a client would, independently of the server helper.
        const hash = (data: Uint8Array) => createHash("sha256").update(data).digest("base64url");
        const transcript = Buffer.from(["neon-android-install-v1", issuer, challenge, hash(publicDer)].join("\0"));
        expect(installTranscript(issuer, challenge, publicDer)).toEqual(transcript);
        const signature = sign("sha256", transcript, installKey.privateKey).toString("base64");
        const payload = { challenge, public_key, signature, integrity_token: "opaque-provider-response" };
        const verdict = {
            requestDetails: { requestPackageName: policy.package_name, requestHash: hash(transcript), timestampMillis: String(current) },
            appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED", packageName: policy.package_name, certificateSha256Digest: [signerDigest], versionCode: "12" },
        };
        return { payload, verdict, submit: (body: object = payload) => service.inject({ method: "POST", url: "/v1/android/installs/enroll", payload: body }) };
    }

    it("issues one client-only certificate under concurrent submission without account or hardware evidence", async () => {
        const { submit, verdict } = await start();
        decode.mockResolvedValue({ tokenPayloadExternal: verdict });
        const responses = await Promise.all([submit(), submit()]);
        expect(responses.map(r => r.statusCode).sort()).toEqual([201, 403]);
        expect(decode).toHaveBeenCalledTimes(1);
        const issued = responses.find(r => r.statusCode === 201)!.json();
        const certificate = new X509Certificate(issued.certificate_pem);
        expect(certificate.verify(root.publicKey)).toBe(true);
        expect(certificate.checkPrivateKey(installKey.privateKey)).toBe(true);
        expect(certificate.ca).toBe(false);
        expect(certificate.keyUsage).toEqual(["1.3.6.1.5.5.7.3.2"]);
        expect(new Date(issued.expires_at).getTime()).toBe(initialTime + 3_600_000);
    });

    it.each([
        { labels: [], marked: false },
        { labels: ["MEETS_BASIC_INTEGRITY"], marked: false },
        { labels: ["MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY"], marked: true },
    ])("signs the device claim only for a verified device verdict ($labels)", async ({ labels, marked }) => {
        const { submit, verdict } = await start();
        decode.mockResolvedValue({ tokenPayloadExternal: { ...verdict, deviceIntegrity: { deviceRecognitionVerdict: labels } } });
        const response = await submit();
        expect(response.statusCode).toBe(201);
        const leaf = new X509Certificate(response.json().certificate_pem);
        expect(leaf.verify(root.publicKey)).toBe(true);
        expect(leaf.subjectAltName).toBe(marked ? "URI:https://identity.mta-neon.com/claims/play-device-integrity-v1" : undefined);
    });

    it.each(["unrecognized", "signer", "app package", "request package", "old app", "other request", "stale", "future", "tester", "PC"])(
        "refuses a decoded verdict with %s", async condition => {
            const { submit, verdict } = await start();
            const extra: Record<string, unknown> = {};
            if (condition === "unrecognized") verdict.appIntegrity.appRecognitionVerdict = "UNRECOGNIZED_VERSION";
            if (condition === "signer") verdict.appIntegrity.certificateSha256Digest = ["another-signer"];
            if (condition === "app package") verdict.appIntegrity.packageName = "other.package";
            if (condition === "request package") verdict.requestDetails.requestPackageName = "other.package";
            if (condition === "old app") verdict.appIntegrity.versionCode = "11";
            if (condition === "other request") verdict.requestDetails.requestHash = "other";
            if (condition === "stale") verdict.requestDetails.timestampMillis = String(current - 100_000);
            if (condition === "future") verdict.requestDetails.timestampMillis = String(current + 20_000);
            if (condition === "tester") extra.testingDetails = { isTestingResponse: true };
            if (condition === "PC") extra.deviceIntegrity = { deviceRecognitionVerdict: ["MEETS_VIRTUAL_INTEGRITY"] };
            decode.mockResolvedValue({ tokenPayloadExternal: { ...verdict, ...extra } });
            expect((await submit()).statusCode).toBe(403);
        });
    it("rejects a different possession key and expires unused challenges before contacting Google", async () => {
        const { submit, payload } = await start();
        const wrongKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({ type: "spki", format: "der" });
        expect((await submit({ ...payload, public_key: wrongKey.toString("base64") })).statusCode).toBe(403);
        current += 90_000;
        expect((await submit()).statusCode).toBe(403);
        expect(decode).not.toHaveBeenCalled();
    });
    it("never issues from a verdict supplied by the client or when Google is unavailable", async () => {
        const { submit, verdict, payload } = await start();
        expect((await submit({ ...payload, tokenPayloadExternal: verdict })).statusCode).toBe(400);
        decode.mockRejectedValue(new Error("provider unavailable"));
        expect((await submit()).statusCode).toBe(503);
        expect((await submit()).statusCode).toBe(403);
    });
});
