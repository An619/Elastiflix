// Covers the LOCAL dev branch (CORS middleware) which is compiled out of the
// production import path. Runs in its own process under `node --test`, so the
// env vars set here do not affect other test files.
import { describe, it } from "node:test";
import assert from "node:assert/strict";

process.env.LOCAL = "1";
process.env.PUBLIC_HOST = "example.local";
delete process.env.REDIS_URL;
delete process.env.REDIS_HOST;
delete process.env.RABBITMQ_URL;
delete process.env.RABBITMQ_HOST;

const { app } = await import("../src/Backend.js");
const { default: request } = await import("supertest");

describe("Backend in LOCAL mode", () => {
  it("reflects an allowed dev origin via CORS headers", async () => {
    const res = await request(app).get("/healthz").set("Origin", "http://example.local:3000");
    assert.equal(res.status, 200);
    assert.equal(res.headers["access-control-allow-origin"], "http://example.local:3000");
  });

  it("allows the generic localhost dev origin too", async () => {
    const res = await request(app).get("/healthz").set("Origin", "http://localhost:3000");
    assert.equal(res.headers["access-control-allow-origin"], "http://localhost:3000");
  });
});
