import { readFileSync } from "node:fs";

// Secrets are mounted as files at fixed paths. The `<NAME>_FILE` environment
// variable only *selects* one of these allowlisted mounts; it can never point
// the helper at an arbitrary path, so this cannot become a file-read primitive.
const SECRET_FILE_PATHS = Object.freeze({
  REDIS_PASSWORD: Object.freeze(["/run/secrets/elastiflix/redis-password"]),
  RABBITMQ_PASSWORD: Object.freeze(["/run/secrets/elastiflix/rabbitmq-password"]),
});

/**
 * Resolve a secret value from a mounted file, falling back to the plain
 * environment variable only when no file is configured (local development).
 * A missing mounted file returns undefined rather than silently falling back
 * to plaintext, which would mask a broken Secret mount.
 */
export function secretValue(name, readSecretFile = readFileSync) {
  const configuredPath = process.env[`${name}_FILE`];
  if (configuredPath) {
    if (!SECRET_FILE_PATHS[name]?.includes(configuredPath)) return undefined;
    try {
      return readSecretFile(configuredPath, "utf8").replace(/\r?\n$/, "");
    } catch (error) {
      if (error?.code === "ENOENT") return undefined;
      throw error;
    }
  }
  return process.env[name];
}
