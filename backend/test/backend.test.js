import { describe, it } from "node:test";
import assert from "node:assert/strict";
import request from "supertest";
import { app } from "../src/Backend.js";

describe("Backend API", () => {
  it("GET /healthz returns 200 OK", async () => {
    const res = await request(app).get("/healthz");
    assert.equal(res.status, 200);
    assert.equal(res.text, "OK");
  });

  it("GET / returns hello", async () => {
    const res = await request(app).get("/");
    assert.equal(res.status, 200);
    assert.match(res.text, /Hello from the backend/);
  });

  it("GET /metrics exposes Prometheus counters", async () => {
    const res = await request(app).get("/metrics");
    assert.equal(res.status, 200);
    assert.match(res.text, /elastiflix_http_requests_total/);
    assert.match(res.text, /elastiflix_search_requests_total/);
  });

  it("POST /api/search with empty body does not crash (no req.body)", async () => {
    // Regression: `req.body.state` threw when body was undefined and
    // crashed the process under Express 4 async middleware.
    const res = await request(app)
      .post("/api/search")
      .set("Content-Type", "application/json")
      .send({});
    // Without Elasticsearch this returns 500 search_failed, but it must
    // be a handled response, not a process crash / hang.
    assert.ok([200, 500].includes(res.status), `unexpected status ${res.status}`);
    if (res.status === 500) {
      assert.equal(res.body.error, "search_failed");
      // Must not leak internal ES error details to the client.
      assert.equal(res.body.message, undefined);
    }
  });

  it("POST /api/autocomplete with empty body is handled", async () => {
    const res = await request(app)
      .post("/api/autocomplete")
      .set("Content-Type", "application/json")
      .send({});
    assert.ok([200, 500].includes(res.status), `unexpected status ${res.status}`);
  });
});
