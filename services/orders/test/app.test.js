import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createApp } from "../src/app.js";

const fakeProducts = {
  "p-1": { id: "p-1", name: "Thing", price: 10, stock: 5 },
  "p-2": { id: "p-2", name: "Sold out", price: 10, stock: 0 },
};
const fakeFetch = async (url) => {
  const id = url.split("/").pop();
  const p = fakeProducts[id];
  return { ok: !!p, status: p ? 200 : 404, json: async () => p };
};

async function withServer(fn) {
  const { handler } = createApp({ service: "orders", version: "test", productsUrl: "http://fake", fetchImpl: fakeFetch });
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn(base); } finally { server.close(); }
}

const post = (base, body) => fetch(`${base}/orders`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

test("creates an order", () =>
  withServer(async (base) => {
    const res = await post(base, { productId: "p-1", quantity: 2 });
    assert.equal(res.status, 201);
    const order = await res.json();
    assert.equal(order.total, 20);
    assert.equal((await fetch(`${base}/orders/${order.id}`)).status, 200);
  }));

test("rejects invalid, unknown and out-of-stock", () =>
  withServer(async (base) => {
    assert.equal((await post(base, {})).status, 400);
    assert.equal((await post(base, { productId: "nope", quantity: 1 })).status, 404);
    assert.equal((await post(base, { productId: "p-2", quantity: 1 })).status, 409);
  }));

test("records business metrics", () =>
  withServer(async (base) => {
    await post(base, { productId: "p-1", quantity: 1 });
    const text = await (await fetch(`${base}/metrics`)).text();
    assert.match(text, /orders_created_total\{.*result="created".*\} 1/);
    assert.match(text, /upstream_request_duration_seconds_count\{.*upstream="products"/);
  }));
