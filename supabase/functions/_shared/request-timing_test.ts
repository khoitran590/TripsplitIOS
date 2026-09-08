import { strict as assert } from "node:assert";
import { RequestTiming, withTiming } from "./request-timing.ts";

Deno.test("phase timing preserves results and records failed attempts", async () => {
  const timing = new RequestTiming();
  assert.equal(await timing.measure("auth", () => Promise.resolve(42)), 42);
  const secretError = new Error("sensitive provider message");
  await assert.rejects(timing.measure("claude", () => Promise.reject(secretError)), secretError);
  await timing.measure("gemini", () => Promise.resolve(null));
  const summary = timing.summary("parse-receipt", 502);
  assert.deepEqual(summary.phases.map((p) => p.phase), ["auth", "claude", "gemini"]);
  assert.deepEqual(summary.phases.map((p) => p.completed), [true, false, true]);
  assert(summary.phases.every((p) => p.duration_ms >= 0));
  assert(!JSON.stringify(summary).includes(secretError.message));
  assert.match(timing.header(), /claude_1;dur=/);
});

Deno.test("concurrent requests keep timings separate and preserve HTTP responses", async () => {
  const logs: string[] = [];
  const original = console.info;
  console.info = (value: string) => logs.push(value);
  try {
    const auth = withTiming("first", async (_request, timing) => {
      await timing.measure("auth", () => Promise.resolve());
      return new Response("first", { status: 201, headers: { "X-Test": "kept" } });
    });
    const quota = withTiming("second", async (_request, timing) => {
      await timing.measure("quota", () => Promise.resolve());
      return new Response("second", { status: 429 });
    });
    const request = new Request("https://example.test/private?token=secret");
    const [first, second] = await Promise.all([auth(request), quota(request)]);
    assert.equal(first.status, 201);
    assert.equal(first.headers.get("X-Test"), "kept");
    assert.equal(await first.text(), "first");
    assert.equal(second.status, 429);
    assert.match(first.headers.get("Server-Timing")!, /^auth_0;/);
    assert.match(second.headers.get("Server-Timing")!, /^quota_0;/);
    assert.equal(logs.length, 2);
    assert(!logs.join("").includes("secret"));
  } finally { console.info = original; }
});
