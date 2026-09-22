import client from "prom-client";

const PRODUCTS = [
  { id: "p-100", name: "Mechanical keyboard", price: 129.0, stock: 42 },
  { id: "p-101", name: "USB-C dock", price: 89.5, stock: 17 },
  { id: "p-102", name: "4K monitor", price: 399.0, stock: 5 },
  { id: "p-103", name: "Noise-cancelling headphones", price: 249.0, stock: 0 },
];

export function createApp({ service, version }) {
  const registry = new client.Registry();
  registry.setDefaultLabels({ service });
  client.collectDefaultMetrics({ register: registry });

  const httpRequests = new client.Counter({
    name: "http_requests_total",
    help: "HTTP requests",
    labelNames: ["method", "route", "status"],
    registers: [registry],
  });
  const httpDuration = new client.Histogram({
    name: "http_request_duration_seconds",
    help: "HTTP request latency",
    labelNames: ["method", "route", "status"],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    registers: [registry],
  });
  const inflight = new client.Gauge({ name: "http_inflight_requests", help: "In-flight requests", registers: [registry] });
  new client.Gauge({
    name: "products_in_stock",
    help: "Products with stock > 0",
    registers: [registry],
    collect() { this.set(PRODUCTS.filter((p) => p.stock > 0).length); },
  });

  let ready = true;

  async function handler(req, res) {
    const start = process.hrtime.bigint();
    const url = new URL(req.url, "http://localhost");
    inflight.inc();

    const send = (status, body, route, headers = {}) => {
      const payload = typeof body === "string" ? body : JSON.stringify(body);
      res.writeHead(status, { "content-type": typeof body === "string" ? "text/plain; version=0.0.4" : "application/json", ...headers });
      res.end(payload);
      const seconds = Number(process.hrtime.bigint() - start) / 1e9;
      httpRequests.inc({ method: req.method, route, status });
      httpDuration.observe({ method: req.method, route, status }, seconds);
      inflight.dec();
    };

    try {
      if (url.pathname === "/healthz") return send(200, { status: "ok" }, "/healthz");
      if (url.pathname === "/readyz") return send(ready ? 200 : 503, { ready }, "/readyz");
      if (url.pathname === "/metrics") return send(200, await registry.metrics(), "/metrics");
      if (url.pathname === "/version") return send(200, { service, version }, "/version");

      if (url.pathname === "/products" && req.method === "GET") {
        return send(200, { items: PRODUCTS }, "/products");
      }
      // chaos endpoint for testing alerts: /fail?rate=0.5 (also reachable via gateway as /api/products/fail)
      if (url.pathname === "/fail" || url.pathname === "/products/fail") {
        const rate = Number(url.searchParams.get("rate") ?? 1);
        return Math.random() < rate ? send(500, { error: "injected failure" }, "/fail") : send(200, { ok: true }, "/fail");
      }
      const m = url.pathname.match(/^\/products\/([^/]+)$/);
      if (m && req.method === "GET") {
        const p = PRODUCTS.find((x) => x.id === m[1]);
        return p ? send(200, p, "/products/:id") : send(404, { error: "not found" }, "/products/:id");
      }
      return send(404, { error: "not found" }, "unknown");
    } catch (err) {
      return send(500, { error: err.message }, "error");
    }
  }

  return { handler, shutdown: () => { ready = false; } };
}
