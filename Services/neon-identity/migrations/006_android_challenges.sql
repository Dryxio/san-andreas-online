CREATE TABLE neon_android_challenges (
    binding BYTEA PRIMARY KEY,
    challenge TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX neon_android_challenges_expiry ON neon_android_challenges (expires_at);
