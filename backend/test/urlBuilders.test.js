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
  it("reads the password from the mounted Secret file when one is configured", () => {
    process.env.REDIS_HOST = "redis.infra";
    process.env.REDIS_PASSWORD = "should-not-be-used";
    process.env.REDIS_PASSWORD_FILE = "/run/secrets/elastiflix/redis-password";
    const readSecretFile = () => "file-secret\n";
    assert.equal(redisUrl(readSecretFile), "redis://:file-secret@redis.infra:6379");
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
  it("reads the password from the mounted Secret file when one is configured", () => {
    process.env.RABBITMQ_HOST = "rabbitmq.infra";
    process.env.RABBITMQ_USER = "user";
    process.env.RABBITMQ_PASSWORD = "should-not-be-used";
    process.env.RABBITMQ_PASSWORD_FILE = "/run/secrets/elastiflix/rabbitmq-password";
    const readSecretFile = () => "file-secret\n";
    assert.equal(rabbitmqUrl(readSecretFile), "amqp://user:file-secret@rabbitmq.infra:5672");
  });
});
