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
    assert.match(res.text, /elastiflix_http_responses_total/);
    assert.match(res.text, /elastiflix_http_request_duration_seconds_bucket/);
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

  it("POST /api/search with a searchTerm exercises the search pipeline (500 without ES)", async () => {
    const res = await request(app)
      .post("/api/search")
      .set("Content-Type", "application/json")
      .send({
        state: { searchTerm: "encanto", current: 1, resultsPerPage: 10 },
        queryConfig: { search_fields: { title: { weight: 3 } }, result_fields: { title: { snippet: {} } } },
      });
    assert.equal(res.status, 500); // no Elasticsearch in this environment
    assert.equal(res.body.error, "search_failed");
    assert.equal(res.body.message, undefined); // no internal detail leaked
  });

  for (const path of ["/api/rerank/search", "/api/semantic/search", "/api/hybrid/search"]) {
    it(`POST ${path} is handled (500 without ES, no crash)`, async () => {
      const res = await request(app)
        .post(path)
        .set("Content-Type", "application/json")
        .send({ state: { searchTerm: "encanto" }, queryConfig: {} });
      assert.equal(res.status, 500);
      assert.equal(res.body.error, "search_failed");
    });
  }

  it("GET /metrics reflects application requests", async () => {
    const res = await request(app).get("/metrics");
    assert.match(res.text, /elastiflix_http_requests_total [1-9]/);
  });

  it("records bounded route/status and latency metrics without exposing raw paths", async () => {
    await request(app).get("/api/users/private-id?query=private-query");
    const res = await request(app).get("/metrics");
    assert.match(res.text, /elastiflix_http_responses_total\{route="\/api\/other",status_class="4xx"\} \d+/);
    assert.match(res.text, /elastiflix_http_request_duration_seconds_bucket\{route="\/api\/other",le="\+Inf"\} \d+/);
    assert.doesNotMatch(res.text, /private-id|private-query/);
  });

  it("counts every completed 5xx response in the error counter", async () => {
    const beforeResponse = await request(app).get("/metrics");
    const before = Number(beforeResponse.text.match(/^elastiflix_errors_total (\d+)$/m)?.[1]);
    const failed = await request(app)
      .post("/api/search")
      .set("Content-Type", "application/json")
      .send({ state: { searchTerm: "slo-error-probe" }, queryConfig: {} });
    assert.equal(failed.status, 500);
    const afterResponse = await request(app).get("/metrics");
    const after = Number(afterResponse.text.match(/^elastiflix_errors_total (\d+)$/m)?.[1]);
    assert.equal(after, before + 1);
  });

  it("Prometheus scrapes do not increment application request counters", async () => {
    const readCount = async () => {
      const res = await request(app).get("/metrics");
      const match = res.text.match(/^elastiflix_http_requests_total (\d+)$/m);
      assert.ok(match, "HTTP request counter should be exported");
      return Number(match[1]);
    };

    const before = await readCount();
    await request(app).get("/metrics");
    const after = await readCount();
    assert.equal(after, before);
  });
});
