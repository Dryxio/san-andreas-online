import { z } from "zod";

import { OFFICIAL_NEON_ISSUER, OFFICIAL_NEON_TICKET_KEY_ID, OFFICIAL_NEON_TICKET_PUBLIC_KEY } from "./official-trust.js";

export const SERVER_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

const androidPolicySchema = z.object({
    key_id: z.string().min(1).max(128),
    server_ids: z.array(z.string().regex(SERVER_ID_PATTERN)).min(1),
    package_name: z.string().regex(/^[a-zA-Z]\w*(\.[a-zA-Z]\w*)+$/),
    signer_sha256: z.string().regex(/^[a-f0-9]{64}$/),
    minimum_version: z.number().int().positive().max(2147483647),
    verifier: z.string().startsWith("/"),
}).strict();

export type AndroidPolicy = z.infer<typeof androidPolicySchema>;

const androidInstallSchema = androidPolicySchema.pick({ package_name: true, signer_sha256: true, minimum_version: true }).extend({
    play_project_number: z.string().regex(/^[1-9][0-9]{0,15}$/),
    ca_cert_file: z.string().startsWith("/"),
    ca_key_file: z.string().startsWith("/"),
}).strict();
export type AndroidInstallPolicy = z.infer<typeof androidInstallSchema>;

export function isCanonicalIpv4Endpoint(value: string): boolean {
    const match = /^([^:]+):([0-9]{1,5})$/.exec(value);
    if (!match) return false;
    const address = match[1];
    const portText = match[2];
    if (!address || !portText || !/^[1-9][0-9]*$/.test(portText)) return false;
    const octets = address.split(".");
    if (octets.length !== 4) return false;
    const validAddress = octets.every(
        (octet) => /^(0|[1-9][0-9]{0,2})$/.test(octet) && Number(octet) >= 0 && Number(octet) <= 255,
    );
    const port = Number(portText);
    return validAddress && port >= 1 && port <= 65_535;
}

const booleanFromString = z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true");

const environmentSchema = z.object({
    NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
    HOST: z.string().default("127.0.0.1"),
    PORT: z.coerce.number().int().min(1).max(65535).default(8080),
    PUBLIC_BASE_URL: z.url(),
    DATABASE_URL: z.string().min(1),
    DATABASE_SSL: booleanFromString,
    DISCORD_CLIENT_ID: z.string().regex(/^\d+$/),
    DISCORD_CLIENT_SECRET: z.string().min(16),
    DISCORD_REDIRECT_URI: z.url(),
    DISCORD_API_BASE_URL: z.url().default("https://discord.com/api/v10"),
    DISCORD_REQUIRED_GUILD_ID: z.string().regex(/^\d+$/).optional().or(z.literal("")),
    DISCORD_REQUIRED_ROLE_IDS: z.string().optional().default(""),
    DISCORD_BOT_TOKEN: z.string().optional().or(z.literal("")),
    DISCORD_REQUIRE_COMPLETED_SCREENING: z
        .enum(["true", "false"])
        .default("true")
        .transform((value) => value === "true"),
    NEON_ANDROID_TICKET_PRIVATE_JWK: z.string().optional(),
    NEON_ANDROID_ADMISSION: z.string().optional(),
    NEON_ANDROID_INSTALL_ENROLLMENT: z.string().optional(),
    NEON_ISSUER: z.url(),
    NEON_SERVER_REGISTRY: z.string().min(1),
    NEON_TICKET_KEY_ID: z.string().min(1).max(128),
    NEON_TICKET_PRIVATE_JWK: z.string().min(1),
    OAUTH_COOKIE_KEY: z.string().min(1),
    OAUTH_FLOW_TTL_SECONDS: z.coerce.number().int().min(60).max(900).default(300),
    SESSION_TTL_SECONDS: z.coerce.number().int().min(3600).max(31_536_000).default(2_592_000),
    TICKET_TTL_SECONDS: z.coerce.number().int().min(30).max(60).default(45),
    TRUST_PROXY: booleanFromString,
});

export interface ServiceConfig {
    nodeEnv: "development" | "test" | "production";
    host: string;
    port: number;
    publicBaseUrl: URL;
    databaseUrl: string;
    databaseSsl: boolean;
    discord: {
        clientId: string;
        clientSecret: string;
        redirectUri: string;
        apiBaseUrl: string;
        requiredGuildId: string | null;
        requiredRoleIds: string[];
        botToken: string | null;
        requireCompletedScreening: boolean;
    };
    androidAdmission?: AndroidPolicy;
    androidInstall?: AndroidInstallPolicy;
    androidTicketPrivateJwk?: JsonWebKey;
    issuer: string;
    serverRegistry: ReadonlyMap<string, ReadonlySet<string>>;
    ticketKeyId: string;
    ticketPrivateJwk: JsonWebKey;
    oauthCookieKey: Buffer;
    flowTtlSeconds: number;
    sessionTtlSeconds: number;
    ticketTtlSeconds: number;
    trustProxy: boolean;
}

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): ServiceConfig {
    const parsed = environmentSchema.parse(environment);
    const publicBaseUrl = new URL(parsed.PUBLIC_BASE_URL);
    const redirectUri = new URL(parsed.DISCORD_REDIRECT_URI);
    const expectedRedirectUri = new URL("/v1/auth/discord/callback", publicBaseUrl);
    const oauthCookieKey = Buffer.from(parsed.OAUTH_COOKIE_KEY, "base64url");

    if (parsed.NODE_ENV === "production" && publicBaseUrl.protocol !== "https:") {
        throw new Error("PUBLIC_BASE_URL must use HTTPS in production");
    }
    if (redirectUri.href !== expectedRedirectUri.href) {
        throw new Error(`DISCORD_REDIRECT_URI must be ${expectedRedirectUri.href}`);
    }
    if (oauthCookieKey.length !== 32) {
        throw new Error("OAUTH_COOKIE_KEY must decode to exactly 32 bytes");
    }
    const serverRegistry = parseServerRegistry(parsed.NEON_SERVER_REGISTRY);

    let ticketPrivateJwk: JsonWebKey;
    try {
        ticketPrivateJwk = JSON.parse(parsed.NEON_TICKET_PRIVATE_JWK) as JsonWebKey;
    } catch {
        throw new Error("NEON_TICKET_PRIVATE_JWK must be valid JSON");
    }
    if (ticketPrivateJwk.kty !== "OKP" || ticketPrivateJwk.crv !== "Ed25519" || !ticketPrivateJwk.d) {
        throw new Error("NEON_TICKET_PRIVATE_JWK must be a private Ed25519 JWK");
    }
    const androidAdmission = parsed.NEON_ANDROID_ADMISSION === undefined ? undefined :
        androidPolicySchema.parse(JSON.parse(parsed.NEON_ANDROID_ADMISSION));
    const androidInstall = parsed.NEON_ANDROID_INSTALL_ENROLLMENT === undefined ? undefined :
        androidInstallSchema.parse(JSON.parse(parsed.NEON_ANDROID_INSTALL_ENROLLMENT));
    let androidTicketPrivateJwk: JsonWebKey | undefined;
    if (androidAdmission) {
        androidTicketPrivateJwk = z.object({
            kty: z.literal("OKP"), crv: z.literal("Ed25519"),
            d: z.string().regex(/^[A-Za-z0-9_-]{43}$/), x: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
        }).parse(JSON.parse(parsed.NEON_ANDROID_TICKET_PRIVATE_JWK ?? "null"));
        if (androidTicketPrivateJwk.x === ticketPrivateJwk.x || androidTicketPrivateJwk.d === ticketPrivateJwk.d ||
            androidAdmission.key_id === parsed.NEON_TICKET_KEY_ID) {
            throw new Error("Android admission requires a dedicated signing key and key ID");
        }
    }

    const issuer = parsed.NEON_ISSUER.replace(/\/$/, "");
    if (
        parsed.NODE_ENV === "production" &&
        issuer === OFFICIAL_NEON_ISSUER &&
        (parsed.NEON_TICKET_KEY_ID !== OFFICIAL_NEON_TICKET_KEY_ID || ticketPrivateJwk.x !== OFFICIAL_NEON_TICKET_PUBLIC_KEY)
    ) {
        throw new Error("The official Neon issuer must use the ticket key embedded in automatic servers");
    }

    const requiredGuildId = parsed.DISCORD_REQUIRED_GUILD_ID || null;
    const botToken = parsed.DISCORD_BOT_TOKEN || null;
    if (requiredGuildId && !botToken) {
        throw new Error("DISCORD_BOT_TOKEN is required when DISCORD_REQUIRED_GUILD_ID is set");
    }

    return {
        ...(androidAdmission && androidTicketPrivateJwk ? { androidAdmission, androidTicketPrivateJwk } : {}),
        ...(androidInstall ? { androidInstall } : {}),
        nodeEnv: parsed.NODE_ENV,
        host: parsed.HOST,
        port: parsed.PORT,
        publicBaseUrl,
        databaseUrl: parsed.DATABASE_URL,
        databaseSsl: parsed.DATABASE_SSL,
        discord: {
            clientId: parsed.DISCORD_CLIENT_ID,
            clientSecret: parsed.DISCORD_CLIENT_SECRET,
            redirectUri: redirectUri.href,
            apiBaseUrl: parsed.DISCORD_API_BASE_URL.replace(/\/$/, ""),
            requiredGuildId,
            requiredRoleIds: parsed.DISCORD_REQUIRED_ROLE_IDS.split(",")
                .map((value) => value.trim())
                .filter(Boolean),
            botToken,
            requireCompletedScreening: parsed.DISCORD_REQUIRE_COMPLETED_SCREENING,
        },
        issuer,
        serverRegistry,
        ticketKeyId: parsed.NEON_TICKET_KEY_ID,
        ticketPrivateJwk,
        oauthCookieKey,
        flowTtlSeconds: parsed.OAUTH_FLOW_TTL_SECONDS,
        sessionTtlSeconds: parsed.SESSION_TTL_SECONDS,
        ticketTtlSeconds: parsed.TICKET_TTL_SECONDS,
        trustProxy: parsed.TRUST_PROXY,
    };
}

function parseServerRegistry(serialized: string): ReadonlyMap<string, ReadonlySet<string>> {
    let value: unknown;
    try {
        value = JSON.parse(serialized);
    } catch {
        throw new Error("NEON_SERVER_REGISTRY must be valid JSON");
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("NEON_SERVER_REGISTRY must be a JSON object");
    }

    const registry = new Map<string, ReadonlySet<string>>();
    for (const [serverId, endpoints] of Object.entries(value)) {
        if (!SERVER_ID_PATTERN.test(serverId)) {
            throw new Error(`NEON_SERVER_REGISTRY contains an invalid server ID: ${serverId}`);
        }
        if (!Array.isArray(endpoints) || endpoints.length === 0 || endpoints.some((endpoint) => typeof endpoint !== "string")) {
            throw new Error(`NEON_SERVER_REGISTRY requires a non-empty endpoint list for: ${serverId}`);
        }
        const endpointSet = new Set(endpoints);
        for (const endpoint of endpointSet) {
            if (!isCanonicalIpv4Endpoint(endpoint)) {
                throw new Error(`NEON_SERVER_REGISTRY contains an invalid IPv4:port endpoint: ${endpoint}`);
            }
        }
        registry.set(serverId, endpointSet);
    }
    if (registry.size === 0) {
        throw new Error("NEON_SERVER_REGISTRY must contain at least one server");
    }
    return registry;
}
