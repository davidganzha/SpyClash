import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  AIProviderUnavailableError,
  invokeAIProviderWithRetry,
  isTransientAIProviderError,
} from "./ai-provider-resilience.ts";

function httpError(status: number, message = `HTTP ${status}`) {
  return Object.assign(new Error(message), { status });
}

Deno.test("AI provider retries 503 twice and succeeds on the third attempt", async () => {
  let calls = 0;
  const delays: number[] = [];
  const retryAttempts: number[] = [];

  const result = await invokeAIProviderWithRetry({
    operation: () => {
      calls += 1;
      if (calls <= 2) throw httpError(503, `provider secret ${calls}`);
      return Promise.resolve("ready");
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    onRetry: ({ attempt }) => {
      retryAttempts.push(attempt);
    },
  });

  assertEquals(result, "ready");
  assertEquals(calls, 3);
  assertEquals(delays, [250, 750]);
  assertEquals(retryAttempts, [1, 2]);
});

Deno.test("exhausted transient failures throw a sanitized provider error", async () => {
  let calls = 0;
  const error = await assertRejects(
    () =>
      invokeAIProviderWithRetry({
        operation: () => {
          calls += 1;
          throw httpError(503, "raw upstream credential and provider details");
        },
        delays: [0, 0],
        delay: () => Promise.resolve(),
      }),
    AIProviderUnavailableError,
  );

  assertEquals(calls, 3);
  assertEquals(error.status, 503);
  assertEquals(error.code, "ai_provider_unavailable");
  assertEquals(error.retryable, true);
  assertEquals(
    error.message,
    "AI provider is temporarily unavailable. Try again shortly.",
  );
  assert(!error.message.includes("credential"));
  assert(!("cause" in error));
});

Deno.test("non-retryable HTTP errors preserve the original error", async () => {
  for (const status of [400, 401, 403]) {
    let calls = 0;
    let delayCalls = 0;
    const original = httpError(status, `status ${status}`);

    try {
      await invokeAIProviderWithRetry({
        operation: () => {
          calls += 1;
          throw original;
        },
        delay: () => {
          delayCalls += 1;
          return Promise.resolve();
        },
      });
      throw new Error(`status ${status} unexpectedly succeeded`);
    } catch (error) {
      assertEquals(error, original);
    }

    assertEquals(calls, 1, `status ${status}`);
    assertEquals(delayCalls, 0, `status ${status}`);
  }
});

Deno.test("transient classification accepts provider status shapes and transport messages", () => {
  const transient: unknown[] = [
    { status: 408 },
    { statusCode: "425" },
    { status_code: 429 },
    { response: { status: 500 } },
    { cause: { httpStatus: 502 } },
    new Error("Request failed with status code 503"),
    { code: "504" },
    Object.assign(new Error("socket hang up"), { code: "ECONNRESET" }),
    Object.assign(new Error("provider timed out"), { name: "TimeoutError" }),
    new TypeError("Failed to fetch"),
    new Error("Service Unavailable"),
  ];

  for (const error of transient) {
    assertEquals(isTransientAIProviderError(error), true, String(error));
  }

  const nonTransient: unknown[] = [
    { status: 400, cause: { status: 503 } },
    { statusCode: 401 },
    { response: { status: 403 } },
    { status: 501 },
    Object.assign(new Error("HTTP 400 validation failed"), {
      cause: { status: 503 },
    }),
    new Error("Provider response failed validation"),
  ];

  for (const error of nonTransient) {
    assertEquals(isTransientAIProviderError(error), false, String(error));
  }
});

Deno.test("custom retry delays and callback metadata are deterministic", async () => {
  let calls = 0;
  const delays: number[] = [];
  const events: string[] = [];

  const result = await invokeAIProviderWithRetry({
    delays: [5.9, -1, 15],
    operation: (attempt) => {
      calls += 1;
      events.push(`attempt-${attempt}`);
      if (attempt < 4) throw new Error("network request failed");
      return Promise.resolve(42);
    },
    onRetry: ({ attempt, nextAttempt, delayMilliseconds }) => {
      events.push(`retry-${attempt}-${nextAttempt}-${delayMilliseconds}`);
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      events.push(`delay-${milliseconds}`);
      return Promise.resolve();
    },
  });

  assertEquals(result, 42);
  assertEquals(calls, 4);
  assertEquals(delays, [5, 0, 15]);
  assertEquals(events, [
    "attempt-1",
    "retry-1-2-5",
    "delay-5",
    "attempt-2",
    "retry-2-3-0",
    "delay-0",
    "attempt-3",
    "retry-3-4-15",
    "delay-15",
    "attempt-4",
  ]);
});
