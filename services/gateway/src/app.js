// gateway: single public entry point that reverse-proxies /api/products/* and /api/orders/*
import client from "prom-client";

export function createApp({ service, version, upstreams, fetchImpl = fetch }) {
  const registry = new client.Registry();
  registry.setDefaultLabels({ service });
  client.collectDefaultMetrics({ register: registry });

  const httpRequests = new client.Counter({ name: "http_requests_total", help: "HTTP requests", labelNames: ["method", "route", "status"], registers: [registry] });
  const httpDuration = new client.Histogram({
    name: "http_request_duration_seconds", help: "HTTP request latency", labelNames: ["method", "route", "status"],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5], registers: [registry],
  });
  const upstreamDuration = new client.Histogram({
    name: "upstream_request_duration_seconds", help: "Upstream latency", labelNames: ["upstream", "status"],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5], registers: [registry],
  });

  let ready = true;

  async function proxy(name, base, req, res, path, start, route) {
    const body = ["GET", "HEAD"].includes(req.method) ? undefined : await readBody(req);
    const t0 = process.hrtime.bigint();
    let status = "error";
    try {
      const up = await fetchImpl(`${base}${path}`, {
        method: req.method,
        headers: { "content-type": req.headers["content-type"] ?? "application/json", "x-request-id": req.headers["x-request-id"] ?? crypto.randomUUID() },
        body,
        signal: AbortSignal.timeout(5000),
      });
      status = String(up.status);
      const text = await up.text();
      res.writeHead(up.status, { "content-type": up.headers.get("content-type") ?? "application/json", "x-upstream": name });
      res.end(text);
      record(req, route, up.status, start);
    } catch (err) {
      const code = err.name === "TimeoutError" ? 504 : 502;
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: `upstream ${name} unavailable`, detail: err.message }));
      record(req, route, code, start);
    } finally {
      upstreamDuration.observe({ upstream: name, status }, Number(process.hrtime.bigint() - t0) / 1e9);
    }
  }

  function record(req, route, status, start) {
    const s = Number(process.hrtime.bigint() - start) / 1e9;
    httpRequests.inc({ method: req.method, route, status });
    httpDuration.observe({ method: req.method, route, status }, s);
  }

  async function handler(req, res) {
    const start = process.hrtime.bigint();
    const url = new URL(req.url, "http://localhost");
    const send = (status, body, route) => {
      const payload = typeof body === "string" ? body : JSON.stringify(body);
      res.writeHead(status, { "content-type": typeof body === "string" ? "text/plain; version=0.0.4" : "application/json" });
      res.end(payload);
      record(req, route, status, start);
    };

    if (url.pathname === "/healthz") return send(200, { status: "ok" }, "/healthz");
    if (url.pathname === "/readyz") return send(ready ? 200 : 503, { ready }, "/readyz");
    if (url.pathname === "/metrics") return send(200, await registry.metrics(), "/metrics");
    if (url.pathname === "/version") return send(200, { service, version }, "/version");
    if (url.pathname === "/") return send(200, { service, routes: Object.keys(upstreams).map((u) => `/api/${u}`) }, "/");

    const m = url.pathname.match(/^\/api\/(products|orders)(\/.*)?$/);
    if (m && upstreams[m[1]]) {
      const path = `/${m[1]}${m[2] ?? ""}${url.search}`;
      return proxy(m[1], upstreams[m[1]], req, res, path, start, `/api/${m[1]}`);
    }
    return send(404, { error: "not found" }, "unknown");
  }

  return { handler, shutdown: () => { ready = false; } };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}
