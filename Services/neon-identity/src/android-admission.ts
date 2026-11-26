import { execFile } from "node:child_process";
import { z } from "zod";

import type { AndroidPolicy } from "./config.js";

export const androidProofSchema = z.object({
    challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
    chain: z.array(z.base64().max(8192)).min(2).max(8),
    signature: z.base64().min(8).max(128),
}).strict();

export type AndroidProof = z.infer<typeof androidProofSchema>;

let activeChecks = 0;
export async function verifyAndroidProof(policy: AndroidPolicy, proof: AndroidProof): Promise<boolean> {
    if (activeChecks >= 4) throw new Error("Android verifier busy");
    activeChecks++;
    try {
        return await new Promise<boolean>((resolve, reject) => {
            const args = [policy.package_name, policy.signer_sha256, String(policy.minimum_version)];
            const verifier = execFile(policy.verifier, args, { timeout: 12_000, maxBuffer: 4096, killSignal: "SIGKILL" },
                (error, stdout) => {
                    if (error?.code === 3) resolve(false);
                    else if (error) reject(new Error("Android verifier unavailable"));
                    else resolve(stdout.trim() === "verified");
                });
            verifier.stdin?.on("error", reject);
            verifier.stdin?.end(JSON.stringify(proof));
        });
    } finally {
        activeChecks--;
    }
}
