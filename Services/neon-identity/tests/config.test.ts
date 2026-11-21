import { describe, expect, it } from "vitest";

import { loadConfig } from "../src/config.js";
import { OFFICIAL_NEON_ISSUER, OFFICIAL_NEON_TICKET_KEY_ID, OFFICIAL_NEON_TICKET_PUBLIC_KEY } from "../src/official-trust.js";

function validEnvironment(): NodeJS.ProcessEnv {
    return {
        NODE_ENV: "test",
        PUBLIC_BASE_URL: "http://identity.test",
        DATABASE_URL: "postgres://unused",
        DISCORD_CLIENT_ID: "123456789012345678",
        DISCORD_CLIENT_SECRET: "test-client-secret-long-enough",
        DISCORD_REDIRECT_URI: "http://identity.test/v1/auth/discord/callback",
        NEON_ISSUER: "https://identity.neon.test",
        NEON_SERVER_REGISTRY: JSON.stringify({
            "blitz-production": ["203.0.113.10:22003", "203.0.113.11:22003", "203.0.113.10:22003"],
            "neon-staging": ["127.0.0.1:22003"],
        }),
        NEON_TICKET_KEY_ID: "test-key-v1",
        NEON_TICKET_PRIVATE_JWK: JSON.stringify({
            kty: "OKP",
            crv: "Ed25519",
            x: "test-public-coordinate",
            d: "test-private-coordinate",
        }),
        OAUTH_COOKIE_KEY: Buffer.alloc(32, 9).toString("base64url"),
    };
}

describe("static server registry configuration", () => {
    it("loads and deduplicates a non-empty server-to-endpoint registry", () => {
        const config = loadConfig(validEnvironment());
        expect([...config.serverRegistry]).toEqual([
            ["blitz-production", new Set(["203.0.113.10:22003", "203.0.113.11:22003"])],
            ["neon-staging", new Set(["127.0.0.1:22003"])],
        ]);
    });

    it("rejects empty and malformed server registries", () => {
        expect(() => loadConfig({ ...validEnvironment(), NEON_SERVER_REGISTRY: "{}" })).toThrow(
            "must contain at least one server",
        );
        expect(() => loadConfig({ ...validEnvironment(), NEON_SERVER_REGISTRY: '{"not allowed":["127.0.0.1:22003"]}' })).toThrow(
            "contains an invalid server ID",
        );
        expect(() => loadConfig({ ...validEnvironment(), NEON_SERVER_REGISTRY: '{"valid":["127.00.0.1:22003"]}' })).toThrow(
            "contains an invalid IPv4:port endpoint",
        );
    });

    it("refuses to start the official production issuer with a key automatic servers do not trust", () => {
        const environment = {
            ...validEnvironment(),
            NODE_ENV: "production",
            PUBLIC_BASE_URL: OFFICIAL_NEON_ISSUER,
            DISCORD_REDIRECT_URI: `${OFFICIAL_NEON_ISSUER}/v1/auth/discord/callback`,
            NEON_ISSUER: OFFICIAL_NEON_ISSUER,
            NEON_TICKET_KEY_ID: OFFICIAL_NEON_TICKET_KEY_ID,
        };
        expect(() => loadConfig(environment)).toThrow("ticket key embedded in automatic servers");
        expect(() => loadConfig({
            ...environment,
            NEON_TICKET_PRIVATE_JWK: JSON.stringify({
                kty: "OKP",
                crv: "Ed25519",
                x: OFFICIAL_NEON_TICKET_PUBLIC_KEY,
                d: "production-secret-placeholder",
            }),
        })).not.toThrow();
    });
});


it("requires a complete Android policy only when the operator enables it", () => {
    expect(loadConfig(validEnvironment()).androidAdmission).toBeUndefined();
    const policy = {
        key_id: "mobile", server_ids: ["neon-staging"], package_name: "com.example.game",
        minimum_version: 1, signer_sha256: "a".repeat(64), verifier: "/opt/verifier",
    };
    const config = (candidate: object) => loadConfig({
        ...validEnvironment(), NEON_ANDROID_ADMISSION: JSON.stringify(candidate),
        NEON_ANDROID_TICKET_PRIVATE_JWK: JSON.stringify({ kty: "OKP", crv: "Ed25519", x: "a".repeat(43), d: "b".repeat(43) }),
    });
    expect(config(policy).androidAdmission).toEqual(policy);
    expect(() => config({ ...policy, key_id: "test-key-v1" })).toThrow();
    expect(() => config({ ...policy, signer_sha256: "typo" })).toThrow();
    expect(() => config({ ...policy, server_ids: [] })).toThrow();
});

it("configures a publisher project independently of optional hardware admission", () => {
    const install = { package_name: "com.saonline.neonlauncher", signer_sha256: "a".repeat(64), minimum_version: 1,
        play_project_number: "123456789", ca_cert_file: "/etc/neon/install.pem", ca_key_file: "/etc/neon/private/install.key" };
    const environment = validEnvironment();
    expect(loadConfig(environment).androidInstall).toBeUndefined();
    const parse = (value: object) => loadConfig({ ...environment, NEON_ANDROID_INSTALL_ENROLLMENT: JSON.stringify(value) });
    expect(parse(install).androidInstall).toEqual(install);
    expect(parse(install).androidAdmission).toBeUndefined();
    expect(() => parse({ ...install, play_project_number: "unknown" })).toThrow();
    expect(() => parse({ ...install, ca_key_file: "" })).toThrow();
});
