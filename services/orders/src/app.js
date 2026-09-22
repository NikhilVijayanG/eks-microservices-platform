import client from "prom-client";
import { randomUUID } from "node:crypto";

export function createApp({ service, version, productsUrl, fetchImpl = fetch }) {
  const registry = new client.Registry();
  registry.setDefaultLabels({ service });
  client.collectDefaultMetrics({ register: registry });

  const httpRequests = new client.Counter({ name: "http_requests_total", help: "HTTP requests", labelNames: ["method", "route", "status"], registers: [registry] });
  const httpDuration = new client.Histogram({
    name: "http_request_duration_seconds", help: "HTTP request latency", labelNames: ["method", "route", "status"],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5], registers: [registry],
  });
  const upstreamDuration = new client.Histogram({
    name: "upstream_request_duration_seconds", help: "Latency of calls to upstream services", labelNames: ["upstream", "status"],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5], registers: [registry],
  });
  const ordersCreated = new client.Counter({ name: "orders_created_total", help: "Orders created", labelNames: ["result"], registers: [registry] });
  const orderValue = new client.Summary({ name: "order_value_dollars", help: "Order value", percentiles: [0.5, 0.9, 0.99], registers: [registry] });

  const orders = new Map();
  let ready = true;

  async function getProduct(id) {
    const start = process.hrtime.bigint();
    let status = "error";
    try {
      const res = await fetchImpl(`${productsUrl}/products/${id}`, { signal: AbortSignal.timeout(2000) });
      status = String(res.status);
      return res.ok ? res.json() : null;
    } finally {
      upstreamDuration.observe({ upstream: "products", status }, Number(process.hrtime.bigint() - start) / 1e9);
    }
  }

  async function handler(req, res) {
    const start = process.hrtime.bigint();
    const url = new URL(req.url, "http://localhost");
    const send = (status, body, route) => {
      const payload = typeof body === "string" ? body : JSON.stringify(body);
      res.writeHead(status, { "content-type": typeof body === "string" ? "text/plain; version=0.0.4" : "application/json" });
      res.end(payload);
      const s = Number(process.hrtime.bigint() - start) / 1e9;
      httpRequests.inc({ method: req.method, route, status });
      httpDuration.observe({ method: req.method, route, status }, s);
    };

    try {
      if (url.pathname === "/healthz") return send(200, { status: "ok" }, "/healthz");
      if (url.pathname === "/readyz") return send(ready ? 200 : 503, { ready }, "/readyz");
      if (url.pathname === "/metrics") return send(200, await registry.metrics(), "/metrics");
      if (url.pathname === "/version") return send(200, { service, version }, "/version");

      if (url.pathname === "/orders" && req.method === "GET") return send(200, { items: [...orders.values()] }, "/orders");

      if (url.pathname === "/orders" && req.method === "POST") {
        const body = JSON.parse((await readBody(req)) || "{}");
        if (!body.productId || !Number.isInteger(body.quantity) || body.quantity < 1) {
          ordersCreated.inc({ result: "invalid" });
          return send(400, { error: "productId and positive integer quantity required" }, "/orders");
        }
        const product = await getProduct(body.productId);
        if (!product) { ordersCreated.inc({ result: "unknown_product" }); return send(404, { error: "unknown product" }, "/orders"); }
        if (product.stock < body.quantity) { ordersCreated.inc({ result: "out_of_stock" }); return send(409, { error: "insufficient stock" }, "/orders"); }
        const order = { id: randomUUID(), productId: product.id, quantity: body.quantity, total: +(product.price * body.quantity).toFixed(2), createdAt: new Date().toISOString() };
        orders.set(order.id, order);
        ordersCreated.inc({ result: "created" });
        orderValue.observe(order.total);
        return send(201, order, "/orders");
      }

      const m = url.pathname.match(/^\/orders\/([^/]+)$/);
      if (m && req.method === "GET") {
        const o = orders.get(m[1]);
        return o ? send(200, o, "/orders/:id") : send(404, { error: "not found" }, "/orders/:id");
      }
      return send(404, { error: "not found" }, "unknown");
    } catch (err) {
      const status = err.name === "TimeoutError" ? 504 : 500;
      return send(status, { error: err.message }, "error");
    }
  }

  return { handler, shutdown: () => { ready = false; } };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > 1e6) reject(new Error("payload too large")); });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}
