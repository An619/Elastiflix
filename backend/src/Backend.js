import express from "express";
import cors from "cors";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import SearchConnector from "./SearchConnector.js";
import RerankConnector from "./RerankConnector.js";
import SemanticConnector from "./SemanticConnector.js";
import HybridConnector from "./HybridConnector.js";
import { log, logged } from "./logger.js";

import { createClient } from "redis";
import amqp from "amqplib";

const app = express();
if (process.env.LOCAL) {
  const publicHost = process.env.PUBLIC_HOST || "localhost";
  app.use(
    cors({
      origin: [
        `http://${publicHost}:3000`,
        `http://${publicHost}`,
        "http://localhost:3000",
      ],
      credentials: true,
    })
  );
}
app.use(express.json());

// --- URL helpers: allow password-only envs (K8s Secrets) ---
function redisUrl() {
  if (process.env.REDIS_URL) return process.env.REDIS_URL;
  const host = process.env.REDIS_HOST;
  if (!host) return undefined;
  const port = process.env.REDIS_PORT || "6379";
  const pass = process.env.REDIS_PASSWORD;
  return pass ? `redis://:${encodeURIComponent(pass)}@${host}:${port}` : `redis://${host}:${port}`;
}

function rabbitmqUrl() {
  if (process.env.RABBITMQ_URL) return process.env.RABBITMQ_URL;
  const host = process.env.RABBITMQ_HOST;
  if (!host) return undefined;
  const port = process.env.RABBITMQ_PORT || "5672";
  const user = process.env.RABBITMQ_USER || "user";
  const pass = process.env.RABBITMQ_PASSWORD;
  return pass
    ? `amqp://${encodeURIComponent(user)}:${encodeURIComponent(pass)}@${host}:${port}`
    : `amqp://${encodeURIComponent(user)}@${host}:${port}`;
}

// --- REDIS SETUP (optional: skipped when no URL configured) ---
let redisClient = null;
const redisURL = redisUrl();
if (redisURL) {
  redisClient = createClient({ url: redisURL });
  redisClient.on("error", (err) => log.error({ event: "redis_error", error: err.message }));
  await redisClient.connect().catch((err) => log.error({ event: "redis_connect_fail", error: err.message }));
} else {
  log.info({ event: "redis_disabled", message: "REDIS_URL/REDIS_HOST not set; caching disabled" });
}

// --- RABBITMQ SETUP (optional, with reconnect-safe handlers) ---
let rabbitChannel = null;
let rabbitConnection = null;
async function connectRabbitMQ() {
  const url = rabbitmqUrl();
  if (!url) {
    log.info({ event: "rabbitmq_disabled", message: "RABBITMQ_URL/RABBITMQ_HOST not set; events disabled" });
    return;
  }
  try {
    rabbitConnection = await amqp.connect(url);
    rabbitConnection.on("error", (err) => {
      log.error({ event: "rabbitmq_connection_error", error: err.message });
      rabbitChannel = null;
    });
    rabbitConnection.on("close", () => {
      log.error({ event: "rabbitmq_connection_closed" });
      rabbitChannel = null;
      rabbitConnection = null;
    });
    rabbitChannel = await rabbitConnection.createChannel();
    rabbitChannel.on("error", (err) => {
      log.error({ event: "rabbitmq_channel_error", error: err.message });
      rabbitChannel = null;
    });
    rabbitChannel.on("close", () => {
      log.error({ event: "rabbitmq_channel_closed" });
      rabbitChannel = null;
    });
    // TTL + max-length so an unconsumed queue cannot grow forever.
    await rabbitChannel.assertQueue("search_events", {
      durable: true,
      arguments: {
        "x-message-ttl": 1000 * 60 * 60 * 24, // 24h
        "x-max-length": 10000,
        "x-overflow": "drop-head",
      },
    });
    log.info({ event: "rabbitmq_connected" });
  } catch (err) {
    log.error({ event: "rabbitmq_fail", error: err.message });
  }
}
// AWAIT the connection before starting the app
await connectRabbitMQ();

// --- METRICS (Prometheus text format, no dependency) ---
const metrics = { requestsTotal: 0, searchRequests: 0, cacheHits: 0, errors: 0 };
app.use((req, res, next) => {
  metrics.requestsTotal += 1;
  if (req.path.startsWith("/api/")) metrics.searchRequests += 1;
  next();
});
app.get("/metrics", (req, res) => {
  res.set("Content-Type", "text/plain; version=0.0.4");
  res.send(
    [
      "# HELP elastiflix_http_requests_total Total HTTP requests",
      "# TYPE elastiflix_http_requests_total counter",
      `elastiflix_http_requests_total ${metrics.requestsTotal}`,
      "# HELP elastiflix_search_requests_total Total search API requests",
      "# TYPE elastiflix_search_requests_total counter",
      `elastiflix_search_requests_total ${metrics.searchRequests}`,
      "# HELP elastiflix_cache_hits_total Cache hits",
      "# TYPE elastiflix_cache_hits_total counter",
      `elastiflix_cache_hits_total ${metrics.cacheHits}`,
      "# HELP elastiflix_errors_total Total errors",
      "# TYPE elastiflix_errors_total counter",
      `elastiflix_errors_total ${metrics.errors}`,
      "",
    ].join("\n")
  );
});

// --- CACHING WRAPPER ---
// Cache key MUST cover the full request (pagination, facets, sort,
// resultsPerPage, queryConfig) — keying on searchTerm alone returns
// page-1/unfiltered results for every later request.
const cachedSearch = async (req, res, next) => {
  const { state = {}, queryConfig = {} } = req.body ?? {};
  const { searchTerm } = state;
  if (!searchTerm) return next();

  const cacheKey = `search:${crypto.createHash("sha256").update(JSON.stringify({ state, queryConfig })).digest("hex")}`;
  if (redisClient) {
    try {
      const cachedData = await redisClient.get(cacheKey);
      if (cachedData) {
        metrics.cacheHits += 1;
        const body = JSON.parse(cachedData);
        // Cache hits still emit the same structured log line as misses
        // so Kibana search panels stay accurate.
        log.info({
          method: req.method,
          path: req.path,
          status: 200,
          duration_ms: 0,
          search_type: "lexical",
          query: searchTerm,
          results: body?.totalResults ?? body?.results?.length ?? 0,
          page: state.current ?? 1,
          cache_hit: true,
        });
        return res.json(body);
      }
    } catch (err) {
      log.error({ event: "cache_error", error: err.message });
    }
  }

  const originalJson = res.json.bind(res);
  res.json = (body) => {
    if (body && body.results) {
      if (redisClient) {
        redisClient.setEx(cacheKey, 300, JSON.stringify(body)).catch(() => { });
      }

      if (rabbitChannel) {
        try {
          const message = JSON.stringify({ term: searchTerm, count: body.results.length, timestamp: new Date() });
          rabbitChannel.sendToQueue("search_events", Buffer.from(message), { persistent: true });
        } catch (err) {
          log.error({ event: "rabbitmq_publish_fail", error: err.message });
        }
      }
    }
    return originalJson(body);
  };
  next();
};

app.post("/api/search", cachedSearch, logged("lexical", (s, q) => SearchConnector.onSearch(s, q)));
app.post("/api/rerank/search", logged("rerank", (s, q) => RerankConnector.onSearch(s, q)));
app.post("/api/semantic/search", logged("semantic", (s, q) => SemanticConnector.onSearch(s, q)));
app.post("/api/hybrid/search", logged("hybrid", (s, q) => HybridConnector.onSearch(s, q)));

app.post("/api/autocomplete", async (req, res) => {
  const { state = {}, queryConfig = {} } = req.body ?? {};
  try {
    res.json(await SearchConnector.onAutocomplete(state, queryConfig));
  } catch (err) {
    metrics.errors += 1;
    log.error({ event: "autocomplete_failed", error: err?.message ?? String(err) });
    res.status(500).json({ error: "autocomplete_failed" });
  }
});

// --- HEALTH CHECK FOR KUBERNETES ---
app.get("/healthz", (req, res) => {
  res.status(200).send("OK");
});

app.get("/", (req, res) => {
  res.send("Hello from the backend!");
});

export { app, metrics };

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
let server = null;
if (isMain) {
  server = app.listen(17700, () => {
    log.info({ event: "startup", port: 17700, index: process.env.ES_INDEX });
  });
}

// --- GRACEFUL SHUTDOWN ---
async function shutdown(signal) {
  log.info({ event: "shutdown", signal, message: "Shutting down gracefully" });
  if (server) {
    await new Promise((resolve) => server.close(resolve));
  }
  try {
    if (redisClient) await redisClient.quit();
  } catch { /* already closed */ }
  try {
    if (rabbitChannel) await rabbitChannel.close();
  } catch { /* already closed */ }
  try {
    if (rabbitConnection) await rabbitConnection.close();
  } catch { /* already closed */ }
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// Exported for unit tests (pure helpers, no side effects).
export { redisUrl, rabbitmqUrl };
