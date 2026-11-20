import "reflect-metadata";
import {
    BasicConstraintsExtension, ExtendedKeyUsage, ExtendedKeyUsageExtension,
    KeyUsageFlags, KeyUsagesExtension, SubjectAlternativeNameExtension, X509Certificate, X509CertificateGenerator,
} from "@peculiar/x509";
import { createPrivateKey, createPublicKey, randomBytes, X509Certificate as NodeCertificate } from "node:crypto";

const deviceIntegrityURI = "https://identity.mta-neon.com/claims/play-device-integrity-v1";
const p256 = { name: "ECDSA", namedCurve: "P-256" };

/** The mobile transport has its own CA so an account ticket or web server certificate cannot authorize a peer. */
export class InstallCertificateAuthority {
    private constructor(private readonly certificate: X509Certificate, private readonly key: CryptoKey) {}

    get publicCertificate(): string { return this.certificate.toString("pem"); }

    static async create(certificatePem: string, privateKeyPem: string): Promise<InstallCertificateAuthority> {
        const certificate = new X509Certificate(certificatePem);
        const native = new NodeCertificate(certificatePem);
        const key = createPrivateKey(privateKeyPem);
        const usage = certificate.getExtension(KeyUsagesExtension);
        if (!native.ca || !usage || !(usage.usages & KeyUsageFlags.keyCertSign) ||
            !native.checkPrivateKey(key) || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
            throw new Error("Android transport enrollment requires its matching P-256 CA certificate and signing key");
        }
        const pkcs8 = key.export({ type: "pkcs8", format: "der" });
        const signingKey = await crypto.subtle.importKey("pkcs8", new Uint8Array(pkcs8), p256, false, ["sign"]);
        return new InstallCertificateAuthority(certificate, signingKey);
    }

    async issue(publicKeyDer: Uint8Array<ArrayBuffer>, now: Date, deviceIntegrity: boolean): Promise<{ certificate_pem: string; expires_at: string }> {
        if (now < this.certificate.notBefore || now >= this.certificate.notAfter) {
            throw new Error("Android transport CA is outside its validity period");
        }
        const publicKey = await crypto.subtle.importKey("spki", publicKeyDer, p256, true, ["verify"]);
        const serial = randomBytes(16).toString("hex");
        const expiresAt = new Date(Math.min(now.getTime() + 60 * 60_000, this.certificate.notAfter.getTime()));
        const leaf = await X509CertificateGenerator.create({
            issuer: this.certificate.subjectName,
            subject: "CN=Neon Android install",
            serialNumber: "01" + serial,
            notBefore: new Date(Math.max(now.getTime() - 30_000, this.certificate.notBefore.getTime())),
            notAfter: expiresAt,
            publicKey,
            signingKey: this.key,
            signingAlgorithm: { name: "ECDSA", hash: "SHA-256" },
            extensions: [
                new BasicConstraintsExtension(false, undefined, true),
                new KeyUsagesExtension(KeyUsageFlags.digitalSignature, true),
                new ExtendedKeyUsageExtension([ExtendedKeyUsage.clientAuth], true),
                ...(deviceIntegrity ? [new SubjectAlternativeNameExtension([{ type: "url", value: deviceIntegrityURI }])] : []),
            ],
        });
        return { certificate_pem: leaf.toString("pem"), expires_at: leaf.notAfter.toISOString() };
    }
}

/** Canonical DER prevents multiple encodings of one key from opening independent challenges. */
export function installPublicKey(base64: string): Uint8Array<ArrayBuffer> | null {
    try {
        const der = Buffer.from(base64, "base64");
        const key = createPublicKey({ key: der, type: "spki", format: "der" });
        if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1" ||
            key.export({ type: "spki", format: "der" }).toString("base64") !== base64) return null;
        return new Uint8Array(der);
    } catch {
        return null;
    }
}
