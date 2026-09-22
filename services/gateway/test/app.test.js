import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createApp } from "../src/app.js";

const fakeFetch = async (url) => {
  if (url.includes("/products")) return new Response(JSON.stringify({ items: [] }), { status: 200, headers: { "content-type": "application/json" } });
  throw Object.assign(new Error("ECONNREFUSED"), { name: "Error" });
};

async function withServer(fn) {
  const { handler } = createApp({ service: "gateway", version: "test", upstreams: { products: "http://p", orders: "http://o" }, fetchImpl: fakeFetch });
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn(base); } finally { server.close(); }
}

test("proxies to products", () =>
  withServer(async (base) => {
    const res = await fetch(`${base}/api/products`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("x-upstream"), "products");
  }));

test("returns 502 when upstream is down", () =>
  withServer(async (base) => {
    assert.equal((await fetch(`${base}/api/orders`)).status, 502);
  }));

test("unknown route is 404 and upstream metrics recorded", () =>
  withServer(async (base) => {
    assert.equal((await fetch(`${base}/nope`)).status, 404);
    await fetch(`${base}/api/products`);
    const text = await (await fetch(`${base}/metrics`)).text();
    assert.match(text, /http_requests_total\{.*route="unknown".*status="404".*\} 1/);
    assert.match(text, /upstream_request_duration_seconds_count\{.*upstream="products"/);
  }));
