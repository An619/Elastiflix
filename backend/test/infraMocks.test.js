// Infraless tests for the Redis/RabbitMQ integration paths in Backend.js.
// Both services are mocked with node:test's module mock so the connection,
// cache hit/miss/error and publish code paths run without real servers.
// This file runs in its own process under `node --test`, so the env vars set
// before the dynamic import do not leak into the other test files.
import { describe, it, before, mock } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";

process.env.REDIS_URL = "redis://fake-redis:6379";
process.env.RABBITMQ_URL = "amqp://fake-amqp:5672";

// --- In-memory fake Redis ---
const store = new Map();
let failGet = false;
let failInfo = false;
let infoResponse = null;
const fakeClient = {
  on() {},
  async connect() {},
  async quit() {},
  async info() {
    if (failInfo) throw new Error("info unavailable");
    return infoResponse ?? "# Memory\nused_memory:12345\n# Clients\nconnected_clients:7\n";
  },
  async get(key) {
    if (failGet) throw new Error("get boom");
    return store.get(key) ?? null;
  },
  async setEx(key, _ttl, value) {
    store.set(key, value);
  },
};
mock.module("redis", {
  namedExports: { createClient: () => fakeClient },
});

// --- In-memory fake RabbitMQ ---
const sentMessages = [];
let failSend = false;
const fakeChannel = {
  on() {},
  async assertQueue() {
    return {};
  },
  sendToQueue(queue, content, options) {
    if (failSend) throw new Error("send boom");
    sentMessages.push({ queue, content: content.toString(), options });
  },
  async close() {},
};
const fakeConnection = {
  on() {},
  async createChannel() {
    return fakeChannel;
  },
  async close() {},
};
mock.module("amqplib", {
  defaultExport: { connect: async () => fakeConnection },
});

// --- Stub search backend so responses carry a results payload ---
let autocompleteBehavior = "ok";
mock.module("../src/SearchConnector.js", {
  defaultExport: {
    onSearch: async (state) => ({
      results: [{ title: "Mocked Title", id: "1" }],
      totalResults: 1,
      page: { current: state.current ?? 1 },
    }),
    onAutocomplete: async () => {
      if (autocompleteBehavior === "fail") throw new Error("autocomplete boom");
      return { results: ["mocked suggestion"] };
    },
  },
});

const { app, metrics } = await import("../src/Backend.js");

// `supertest` keeps this consistent with backend.test.js.
const { default: request } = await import("supertest");

function cacheKeyFor(state, queryConfig) {
  return (
    "search:" +
    crypto.createHash("sha256").update(JSON.stringify({ state, queryConfig })).digest("hex")
  );
}

describe("Backend with Redis + RabbitMQ (mocked)", () => {
  before(() => {
    store.clear();
    sentMessages.length = 0;
  });

  it("serves a pre-seeded cache entry without hitting the search backend", async () => {
    const state = { searchTerm: "cache-hit-probe", current: 2 };
    const queryConfig = {};
    const cachedBody = { results: [{ title: "From Cache" }], totalResults: 42 };
    store.set(cacheKeyFor(state, queryConfig), JSON.stringify(cachedBody));
    const hitsBefore = metrics.cacheHits;

    const res = await request(app).post("/api/search").send({ state, queryConfig });

    assert.equal(res.status, 200);
    assert.equal(res.body.totalResults, 42);
    assert.equal(res.body.results[0].title, "From Cache");
    assert.equal(metrics.cacheHits, hitsBefore + 1);
  });

  it("populates the cache and publishes a search event on a cache miss", async () => {
    const state = { searchTerm: "cache-miss-probe", current: 1 };
    const queryConfig = {};

    const res = await request(app).post("/api/search").send({ state, queryConfig });

    assert.equal(res.status, 200);
    assert.equal(res.body.results[0].title, "Mocked Title");
    // res.json wrapper stored the body under the hashed key…
    assert.ok(store.has(cacheKeyFor(state, queryConfig)));
    // …and published a search event for Kibana panels.
    assert.equal(sentMessages.length, 1);
    assert.equal(sentMessages[0].queue, "search_events");
    assert.match(sentMessages[0].content, /cache-miss-probe/);
  });

  it("survives a failing cache read and still answers", async () => {
    failGet = true;
    const res = await request(app)
      .post("/api/search")
      .send({ state: { searchTerm: "cache-error-probe" }, queryConfig: {} });
    failGet = false;
    assert.equal(res.status, 200);
    assert.equal(res.body.results[0].title, "Mocked Title");
  });

  it("survives a failing event publish and still answers", async () => {
    failSend = true;
    const res = await request(app)
      .post("/api/search")
      .send({ state: { searchTerm: "publish-error-probe" }, queryConfig: {} });
    failSend = false;
    assert.equal(res.status, 200);
    assert.equal(res.body.results[0].title, "Mocked Title");
  });

  it("exports Redis availability, memory, and connected-client gauges", async () => {
    const res = await request(app).get("/metrics");
    assert.equal(res.status, 200);
    assert.match(res.text, /^elastiflix_redis_up 1$/m);
    assert.match(res.text, /^elastiflix_redis_memory_used_bytes 12345$/m);
    assert.match(res.text, /^elastiflix_redis_connected_clients 7$/m);
  });

  it("omits Redis gauges when INFO fields are missing or malformed", async () => {
    infoResponse = "# Memory\nused_memory:not-a-number\n";
    const res = await request(app).get("/metrics");
    infoResponse = null;
    assert.equal(res.status, 200);
    assert.match(res.text, /^elastiflix_redis_up 1$/m);
    assert.doesNotMatch(res.text, /^elastiflix_redis_memory_used_bytes /m);
    assert.doesNotMatch(res.text, /^elastiflix_redis_connected_clients /m);
  });

  it("keeps application metrics available when Redis INFO fails", async () => {
    failInfo = true;
    const res = await request(app).get("/metrics");
    failInfo = false;
    assert.equal(res.status, 200);
    assert.match(res.text, /^elastiflix_redis_up 0$/m);
    assert.match(res.text, /^elastiflix_http_requests_total \d+$/m);
  });

  it("autocomplete returns suggestions from the search backend", async () => {
    autocompleteBehavior = "ok";
    const res = await request(app)
      .post("/api/autocomplete")
      .send({ state: { searchTerm: "interstellar" }, queryConfig: {} });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.results, ["mocked suggestion"]);
  });

  it("autocomplete failure returns 500 without leaking internals", async () => {
    autocompleteBehavior = "fail";
    const errorsBefore = metrics.errors;
    const res = await request(app)
      .post("/api/autocomplete")
      .send({ state: { searchTerm: "boom" }, queryConfig: {} });
    autocompleteBehavior = "ok";
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "autocomplete_failed");
    assert.equal(metrics.errors, errorsBefore + 1);
  });
});
