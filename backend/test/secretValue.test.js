import { afterEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { secretValue } from "../src/secretValue.js";

const snapshot = { ...process.env };
afterEach(() => {
  process.env = { ...snapshot };
});

describe("secretValue", () => {
  it("reads the allowlisted mounted Elasticsearch API key", () => {
    process.env.ES_API_KEY_FILE = "/run/secrets/elastiflix/es-api-key";
    const readSecretFile = (path, encoding) => {
      assert.equal(path, process.env.ES_API_KEY_FILE);
      assert.equal(encoding, "utf8");
      return "opaque-key\n";
    };
    assert.equal(secretValue("ES_API_KEY", readSecretFile), "opaque-key");
  });

  it("does not read an arbitrary path or fall back to a plaintext API key", () => {
    process.env.ES_API_KEY = "must-not-be-used";
    process.env.ES_API_KEY_FILE = "/etc/passwd";
    let readAttempted = false;
    assert.equal(secretValue("ES_API_KEY", () => { readAttempted = true; }), undefined);
    assert.equal(readAttempted, false);
  });

  it("does not fall back to plaintext when an allowlisted mounted file is missing", () => {
    process.env.ES_API_KEY = "must-not-be-used";
    process.env.ES_API_KEY_FILE = "/run/secrets/elastiflix/es-api-key";
    const readSecretFile = () => {
      const error = new Error("not mounted");
      error.code = "ENOENT";
      throw error;
    };
    assert.equal(secretValue("ES_API_KEY", readSecretFile), undefined);
  });

  it("propagates mounted secret read errors other than a missing file", () => {
    process.env.ES_API_KEY_FILE = "/run/secrets/elastiflix/es-api-key";
    const permissionError = new Error("permission denied");
    permissionError.code = "EACCES";
    assert.throws(() => secretValue("ES_API_KEY", () => { throw permissionError; }), permissionError);
  });

  it("uses a local environment value only when no file is configured", () => {
    process.env.ES_API_KEY = "local-test-key";
    delete process.env.ES_API_KEY_FILE;
    assert.equal(secretValue("ES_API_KEY"), "local-test-key");
  });
});
