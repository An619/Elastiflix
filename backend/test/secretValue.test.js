import { afterEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { secretValue } from "../src/secretValue.js";

const snapshot = { ...process.env };
afterEach(() => {
  process.env = { ...snapshot };
});

describe("secretValue", () => {
  it("reads a mounted secret file and strips the trailing newline", () => {
    process.env.REDIS_PASSWORD_FILE = "/run/secrets/elastiflix/redis-password";
    const readSecretFile = (path, encoding) => {
      assert.equal(path, "/run/secrets/elastiflix/redis-password");
      assert.equal(encoding, "utf8");
      return "mounted-secret\n";
    };
    assert.equal(secretValue("REDIS_PASSWORD", readSecretFile), "mounted-secret");
  });

  it("refuses a path outside the allowlist instead of reading it", () => {
    process.env.REDIS_PASSWORD = "must-not-be-used";
    process.env.REDIS_PASSWORD_FILE = "/etc/passwd";
    let readAttempted = false;
    const value = secretValue("REDIS_PASSWORD", () => {
      readAttempted = true;
      return "leaked";
    });
    assert.equal(value, undefined);
    assert.equal(readAttempted, false);
  });

  it("does not fall back to plaintext when the mounted file is missing", () => {
    process.env.RABBITMQ_PASSWORD = "must-not-be-used";
    process.env.RABBITMQ_PASSWORD_FILE = "/run/secrets/elastiflix/rabbitmq-password";
    const readSecretFile = () => {
      const error = new Error("not mounted");
      error.code = "ENOENT";
      throw error;
    };
    assert.equal(secretValue("RABBITMQ_PASSWORD", readSecretFile), undefined);
  });

  it("propagates read errors other than a missing file", () => {
    process.env.REDIS_PASSWORD_FILE = "/run/secrets/elastiflix/redis-password";
    const permissionError = new Error("permission denied");
    permissionError.code = "EACCES";
    assert.throws(
      () =>
        secretValue("REDIS_PASSWORD", () => {
          throw permissionError;
        }),
      permissionError
    );
  });

  it("uses a local environment value only when no file is configured", () => {
    process.env.REDIS_PASSWORD = "local-dev-password";
    delete process.env.REDIS_PASSWORD_FILE;
    assert.equal(secretValue("REDIS_PASSWORD"), "local-dev-password");
  });
});
