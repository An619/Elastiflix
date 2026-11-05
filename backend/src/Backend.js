import express from "express";
import cors from "cors";
import SearchConnector from "./SearchConnector.js";
import RerankConnector from "./RerankConnector.js";
import SemanticConnector from "./SemanticConnector.js";
import HybridConnector from "./HybridConnector.js";
import { log, logged } from "./logger.js";

import { createClient } from "redis";
import amqp from "amqplib";

const app = express();
if (process.env.LOCAL) {
  app.use(
    cors({
      origin: `http://${process.env.PUBLIC_HOST || "localhost"}:3000`,
      credentials: true
    })
  );
}
app.use(express.json());

// --- REDIS SETUP ---
const redisClient = createClient({ url: process.env.REDIS_URL });
redisClient.on("error", (err) => log.error({ event: "redis_error", error: err.message }));
await redisClient.connect().catch((err) => log.error({ event: "redis_connect_fail", error: err.message }));

// --- RABBITMQ SETUP ---
let rabbitChannel;
async function connectRabbitMQ() {
  try {
    const connection = await amqp.connect(process.env.RABBITMQ_URL);
    rabbitChannel = await connection.createChannel();
    await rabbitChannel.assertQueue("search_events", { durable: true });
    log.info({ event: "rabbitmq_connected" });
  } catch (err) {
    log.error({ event: "rabbitmq_fail", error: err.message });
  }
}
connectRabbitMQ();

// --- CACHING WRAPPER ---
const cachedSearch = async (req, res, next) => {
  const { searchTerm } = req.body.state || {};
  if (!searchTerm) return next(); // Only cache if there is a search term

  const cacheKey = `search:${searchTerm}`;
  try {
    const cachedData = await redisClient.get(cacheKey);
    if (cachedData) {
      log.info({ event: "cache_hit", searchTerm });
      return res.json(JSON.parse(cachedData));
    }
  } catch (err) {
    log.error({ event: "cache_error", error: err.message });
  }

  // Intercept res.json to save the result to cache and send to RabbitMQ
  const originalJson = res.json.bind(res);
  res.json = (body) => {
    if (body && body.results) {
      redisClient.setEx(cacheKey, 300, JSON.stringify(body)).catch(() => { });

      if (rabbitChannel) {
        const message = JSON.stringify({ term: searchTerm, count: body.results.length, timestamp: new Date() });
        rabbitChannel.sendToQueue("search_events", Buffer.from(message));
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
    log.error({ event: "autocomplete_failed", error: err?.message ?? String(err) });
    res.status(500).json({ error: "autocomplete_failed" });
  }
});

app.get("/", (req, res) => {
  res.send("Hello from the backend!");
});

app.listen(17700, () => {
  log.info({ event: "startup", port: 17700, index: process.env.ES_INDEX });
});