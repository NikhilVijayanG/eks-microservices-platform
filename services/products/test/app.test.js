import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createApp } from "../src/app.js";

async function withServer(fn) {
  const { handler } = createApp({ service: "products", version: "test" });
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn(base); } finally { server.close(); }
}

test("lists products", () =>
  withServer(async (base) => {
    const res = await fetch(`${base}/products`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(body.items.length >= 3);
  }));

test("404 for unknown product", () =>
  withServer(async (base) => {
    assert.equal((await fetch(`${base}/products/nope`)).status, 404);
  }));

test("exposes prometheus metrics", () =>
  withServer(async (base) => {
    await fetch(`${base}/products`);
    const text = await (await fetch(`${base}/metrics`)).text();
    assert.match(text, /http_requests_total\{.*route="\/products".*\} 1/);
    assert.match(text, /products_in_stock/);
  }));

test("health probes", () =>
  withServer(async (base) => {
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    assert.equal((await fetch(`${base}/readyz`)).status, 200);
  }));
