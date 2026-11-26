import { readFileSync } from "node:fs";

const SECRET_FILE_PATHS = Object.freeze({
  REDIS_PASSWORD: Object.freeze([
    "/run/secrets/elastiflix/redis-password",
    "/run/secrets/redis-password",
  ]),
  RABBITMQ_PASSWORD: Object.freeze([
    "/run/secrets/elastiflix/rabbitmq-password",
  ]),
  ES_API_KEY: Object.freeze([
    "/run/secrets/elastiflix/es-api-key",
    "/run/secrets/es-api-key",
  ]),
});

export function secretValue(name, readSecretFile = readFileSync) {
  const configuredPath = process.env[`${name}_FILE`];
  if (configuredPath) {
    // Secret mounts have fixed, allowlisted paths; environment variables must
    // not turn this helper into an arbitrary file-read primitive.
    if (!SECRET_FILE_PATHS[name]?.includes(configuredPath)) return undefined;
    try {
      return readSecretFile(configuredPath, "utf8").replace(/\r?\n$/, "");
    } catch (error) {
      if (error.code === "ENOENT") return undefined;
      throw error;
    }
  }
  return process.env[name];
}
