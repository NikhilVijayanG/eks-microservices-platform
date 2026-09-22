// orders-service: creates orders after validating stock with the products service.
import http from "node:http";
import { createApp } from "./app.js";

const PORT = Number(process.env.PORT ?? 8080);
const SERVICE = "orders";

const { handler, shutdown } = createApp({
  service: SERVICE,
  version: process.env.APP_VERSION ?? "dev",
  productsUrl: process.env.PRODUCTS_URL ?? "http://products:8080",
});
const server = http.createServer(handler);
server.listen(PORT, () => log("info", "listening", { port: PORT, productsUrl: process.env.PRODUCTS_URL }));

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    log("info", "shutdown requested", { signal: sig });
    shutdown();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10_000).unref();
  });
}

function log(level, msg, extra = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, service: SERVICE, msg, ...extra }));
}
