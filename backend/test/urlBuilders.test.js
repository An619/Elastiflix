import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { redisUrl, rabbitmqUrl } from "../src/Backend.js";

const snapshot = { ...process.env };
beforeEach(() => {
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("REDIS_") || key.startsWith("RABBITMQ_")) delete process.env[key];
  }
});
afterEach(() => {
  process.env = { ...snapshot };
});

describe("redisUrl", () => {
  it("returns undefined when nothing is configured", () => {
    assert.equal(redisUrl(), undefined);
  });
  it("prefers REDIS_URL when set", () => {
    process.env.REDIS_URL = "redis://example:6379";
    process.env.REDIS_HOST = "other";
    assert.equal(redisUrl(), "redis://example:6379");
  });
  it("builds host-only URL without password", () => {
    process.env.REDIS_HOST = "redis.infra";
    assert.equal(redisUrl(), "redis://redis.infra:6379");
  });
  it("builds authenticated URL and percent-encodes the password", () => {
    process.env.REDIS_HOST = "redis.infra";
    process.env.REDIS_PASSWORD = "p@ss:word";
    assert.equal(redisUrl(), "redis://:p%40ss%3Aword@redis.infra:6379");
  });
  it("reads the password from the allowlisted mounted secret file", () => {
    process.env.REDIS_HOST = "redis.infra";
    process.env.REDIS_PASSWORD_FILE = "/run/secrets/elastiflix/redis-password";
    const readSecretFile = (path, encoding) => {
      assert.equal(path, process.env.REDIS_PASSWORD_FILE);
      assert.equal(encoding, "utf8");
      return "p@ss:word\n";
    };
    assert.equal(redisUrl(readSecretFile), "redis://:p%40ss%3Aword@redis.infra:6379");
  });
  it("rejects arbitrary secret file paths and does not fall back to plaintext", () => {
    process.env.REDIS_HOST = "redis.infra";
    process.env.REDIS_PASSWORD = "must-not-be-used";
    process.env.REDIS_PASSWORD_FILE = "/etc/passwd";
    let readAttempted = false;
    assert.equal(redisUrl(() => { readAttempted = true; }), "redis://redis.infra:6379");
    assert.equal(readAttempted, false);
  });
  it("does not fall back to a plaintext password when the mounted secret is missing", () => {
    process.env.REDIS_HOST = "redis.infra";
    process.env.REDIS_PASSWORD = "must-not-be-used";
    process.env.REDIS_PASSWORD_FILE = "/run/secrets/elastiflix/redis-password";
    const readSecretFile = () => {
      const error = new Error("missing secret file");
      error.code = "ENOENT";
      throw error;
    };
    assert.equal(redisUrl(readSecretFile), "redis://redis.infra:6379");
  });
});

describe("rabbitmqUrl", () => {
  it("returns undefined when nothing is configured", () => {
    assert.equal(rabbitmqUrl(), undefined);
  });
  it("prefers RABBITMQ_URL when set", () => {
    process.env.RABBITMQ_URL = "amqp://example:5672";
    assert.equal(rabbitmqUrl(), "amqp://example:5672");
  });
  it("builds user-only URL without password", () => {
    process.env.RABBITMQ_HOST = "rabbitmq.infra";
    assert.equal(rabbitmqUrl(), "amqp://user@rabbitmq.infra:5672");
  });
  it("builds authenticated URL and percent-encodes credentials", () => {
    process.env.RABBITMQ_HOST = "rabbitmq.infra";
    process.env.RABBITMQ_USER = "user@corp";
    process.env.RABBITMQ_PASSWORD = "p@ss:word";
    assert.equal(rabbitmqUrl(), "amqp://user%40corp:p%40ss%3Aword@rabbitmq.infra:5672");
  });
  it("reads the password from the allowlisted mounted secret file", () => {
    process.env.RABBITMQ_HOST = "rabbitmq.infra";
    process.env.RABBITMQ_USER = "user@corp";
    process.env.RABBITMQ_PASSWORD_FILE = "/run/secrets/elastiflix/rabbitmq-password";
    const readSecretFile = (path, encoding) => {
      assert.equal(path, process.env.RABBITMQ_PASSWORD_FILE);
      assert.equal(encoding, "utf8");
      return "p@ss:word\n";
    };
    assert.equal(rabbitmqUrl(readSecretFile), "amqp://user%40corp:p%40ss%3Aword@rabbitmq.infra:5672");
  });
});
