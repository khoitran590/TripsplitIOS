import { withTiming } from "../_shared/request-timing.ts";
// suggest-itinerary — server-side proxy for the AI day-by-day itinerary planner.
//
// Why this exists: the app must NOT ship provider API keys (same posture as
// parse-receipt). The client sends the trip's destination, day count, budget, and any
// already-planned stops with the signed-in user's Supabase JWT; this function
// authenticates the user, reserves feature-local capacity, asks Claude first (Gemini
// only as a fallback) for a structured day-by-day plan, validates the model output, and
// returns JSON the app can render and apply.
//
// Both providers get the same brief: reason about neighborhoods, meals, and route order
// before writing anything, and research the live web for places that are still open and
// currently well-reviewed. Claude does that with adaptive thinking plus the server-side
// web_search tool; Gemini with Google Search grounding.
//
// Security posture (mirrors parse-receipt):
//  - Auth: platform `verify_jwt = true` AND an explicit `/auth/v1/user` check.
//  - Rate limit: 10 paid provider attempts per user per 300 seconds. Capacity is
//    reserved atomically and is not refunded for invalid/error provider output.
//  - Secrets: the Anthropic/Gemini keys are read from env and never logged or returned.
//  - Output: the model's JSON is re-validated/normalized before it reaches the client.
//  - No dependencies: plain fetch only.

import { localProviderMocksEnabled } from "../_shared/local-provider-mock.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// `ANTHROPIC_API_KEY` is canonical. `Claude Key` supports the initial Dashboard label so
// the configured secret can be used without copying its value into source or chat.
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("Claude Key");
const CLAUDE_MODEL = Deno.env.get("CLAUDE_SUGGEST_MODEL") ?? "claude-sonnet-5";
// Adaptive thinking is on for this model; effort is the depth/latency dial. Sonnet is
// fast enough to research and reason at `high` and still answer inside the client's 150s
// timeout, so plan quality doesn't have to be traded away here.
const CLAUDE_EFFORT = Deno.env.get("CLAUDE_SUGGEST_EFFORT") ?? "high";
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
// Preferred model for planning; falls back to the receipt model if the id is unknown
// to the API (e.g. regional availability), so the feature degrades instead of breaking.
const SUGGEST_MODEL = Deno.env.get("GEMINI_SUGGEST_MODEL") ?? "gemini-3.5-flash";
const FALLBACK_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";

const MAX_DAYS = 30;
const MAX_STOPS_PER_DAY = 10;
const MAX_EXISTING_CHARS = 4_000;
// The planner spends against only this fraction of the traveler's stated budget,
// holding the rest back as a cushion for taxes, tips, transit, and the extra charges a
// plan on paper never captures. Kept server-side so the client keeps showing and
// splitting the full budget the user set while the model targets the reduced figure.
const BUDGET_PLANNING_RATIO = 0.8;
const RATE_LIMIT = 10; // Max plan generations ...
const RATE_WINDOW_SECONDS = 300; // ... per user per this window.
const RATE_KIND = "itinerary";
const CONSENT_PURPOSE = "itinerary_generation";
const CONSENT_VERSION = "2026-08-06";
const LEGACY_GOOGLE_CONSENT_VERSION = "2026-08-02";

const CLAUDE_MAX_TOKENS = 32_000; // Covers thinking + a 30-day plan.
const CLAUDE_SEARCH_MAX_USES = 6; // Bounds search cost and latency.
// Supabase's hosted request idle limit and the app's resource timeout are both 150s.
// Keep a hard deadline below that platform limit, then give every provider attempt a
// slice of the same budget. This prevents a slow Claude call followed by an unbounded
// Gemini fallback from letting Supabase terminate the worker with a 546/504 response.
const REQUEST_BUDGET_MS = 120_000;
const RESPONSE_RESERVE_MS = 8_000;
const GEMINI_FALLBACK_RESERVE_MS = 55_000;
const GEMINI_SEARCH_BUDGET_MS = 30_000;
const GEMINI_PLAIN_BUDGET_MS = 40_000;
const GEMINI_MODEL_FALLBACK_BUDGET_MS = 25_000;
const MIN_PROVIDER_ATTEMPT_MS = 3_000;

// Claude is the quality-first provider, but it cannot own most of the request window.
// Clamp a dashboard override so an old 80s setting cannot reintroduce the production
// wall-clock failure. A mistyped override must not become NaN either.
const CLAUDE_BUDGET_MS = (() => {
  const configured = Number(Deno.env.get("CLAUDE_SUGGEST_BUDGET_MS"));
  const requested = Number.isFinite(configured) && configured > 0 ? configured : 40_000;
  return Math.min(Math.max(requested, 10_000), 50_000);
})();
// Server tools can pause a turn mid-search; each resume costs one round trip.
const CLAUDE_MAX_TURNS = 4;

const JSON_HEADERS = { "Content-Type": "application/json" };

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...headers } });
}

function attemptDeadline(overallDeadline: number, attemptBudgetMs: number): number {
  return Math.min(overallDeadline, Date.now() + attemptBudgetMs);
}

function timedOut(error: unknown, deadline: number): boolean {
  if (Date.now() >= deadline) return true;
  return error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError");
}

function logProviderTimeout(
  provider: "claude" | "gemini",
  detail: Record<string, unknown>,
): void {
  console.error(JSON.stringify({
    function: "suggest-itinerary",
    outcome: "provider_timeout",
    provider,
    ...detail,
  }));
}

Deno.serve(withTiming("suggest-itinerary", async (req, timing) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }
  const requestDeadline = Date.now() + REQUEST_BUDGET_MS;

  // 1. Require a valid, signed-in user (not just any project JWT such as the anon key).
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return jsonResponse({ error: "Unauthorized" }, 401);
  const user = await timing.measure("auth", () => getUser(token));
  if (!user) return jsonResponse({ error: "Unauthorized" }, 401);
  // A legacy Google-only grant can continue using Gemini during app rollout, but can
  // never authorize sending the trip context to Anthropic. New clients collect the
  // current version before Claude becomes eligible.
  const hasCurrentConsent = await timing.measure("consent", () => hasAIConsent(token, CONSENT_PURPOSE, CONSENT_VERSION));
  const hasLegacyGoogleConsent = hasCurrentConsent
    ? false
    : await timing.measure("consent", () => hasAIConsent(token, CONSENT_PURPOSE, LEGACY_GOOGLE_CONSENT_VERSION));
  if (!hasCurrentConsent && !hasLegacyGoogleConsent) {
    return jsonResponse({ error: "Current AI consent is required." }, 403);
  }

  // 2. Validate input.
  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const location = typeof payload.location === "string" ? payload.location.trim().slice(0, 200) : "";
  if (!location) return jsonResponse({ error: "Missing destination" }, 400);
  const days = Math.min(Math.max(Math.round(toNumber(payload.days) || 1), 1), MAX_DAYS);
  const currency = typeof payload.currency === "string" ? payload.currency.slice(0, 8) : "USD";
  const totalBudget = Math.max(toNumber(payload.totalBudget), 0);
  const startDate = typeof payload.startDate === "string" ? payload.startDate.slice(0, 40) : "";
  const existingPlan = typeof payload.existingPlan === "string"
    ? payload.existingPlan.slice(0, MAX_EXISTING_CHARS)
    : "";

  // 3. At least one provider must be usable before reserving quota: our own
  // configuration outage is never charged. Claude is primary whenever its key exists and
  // the user granted the current, Anthropic-inclusive consent.
  const mocksEnabled = localProviderMocksEnabled();
  if ((!hasCurrentConsent || !ANTHROPIC_API_KEY) && !GEMINI_API_KEY && !mocksEnabled) {
    return jsonResponse({ error: "AI suggestions are not configured." }, 503);
  }

  // 4. Reserve this feature's capacity atomically. Once a provider is called, the attempt
  // remains charged even if every variant returns invalid/error output.
  let usage: UsageReservation;
  try {
    usage = await timing.measure("quota", () => reserveUsage(user.id));
  } catch {
    logUsage("rate_check_failure", 500);
    return jsonResponse({ error: "Rate limit check failed" }, 500);
  }
  if (!usage.allowed || !usage.reservationId) {
    logUsage("rate_limited", 429, usage);
    return rateLimitResponse(usage);
  }
  const reservationId = usage.reservationId;

  if (mocksEnabled) {
    const plan = normalizePlan({
      days: [{
        title: `Day 1 in ${location}`,
        stops: [{
          kind: "activity",
          name: "Local smoke-test stop",
          time: "09:00",
          notes: "Deterministic local provider mock",
          cost: 0,
        }],
      }],
    });
    await timing.measure("completion", () => completeUsage(reservationId, true));
    logUsage("local_mock_success", 200, usage, "gemini");
    return jsonResponse(plan, 200);
  }

  const prompt = buildPrompt({ location, days, currency, totalBudget, startDate, existingPlan });
  let plan: Record<string, unknown> | null = null;
  let provider: "claude" | "gemini" | undefined;
  let quotaExhausted = false;
  let providerTimedOut = false;
  let claudeAttempted = false;

  // 5. Claude first: adaptive thinking plans the geography and the route, the web_search
  // tool checks that the places are real, open, and currently priced as claimed.
  if (hasCurrentConsent && ANTHROPIC_API_KEY) {
    claudeAttempted = true;
    // Set this once and reuse it for the optional compatibility retry. Giving each
    // retry a fresh timeout was the path that could consume the entire worker lifetime.
    const claudeDeadline = Math.min(
      Date.now() + CLAUDE_BUDGET_MS,
      requestDeadline - (GEMINI_API_KEY ? GEMINI_FALLBACK_RESERVE_MS : RESPONSE_RESERVE_MS),
    );
    const first = await timing.measure("claude", () => callClaude(prompt, { structured: true }, claudeDeadline));
    plan = first.plan;
    providerTimedOut ||= first.timedOut;
    if (!plan && first.status === 400) {
      // Constrained decoding can be rejected in combination with server tools on some
      // models. The prompt already specifies the exact shape, so retry unconstrained
      // before writing Claude off — `normalizePlan` re-validates either way.
      const retry = await timing.measure("claude", () => callClaude(prompt, { structured: false }, claudeDeadline));
      plan = retry.plan;
      providerTimedOut ||= retry.timedOut;
      quotaExhausted ||= retry.status === 429;
    } else {
      quotaExhausted ||= first.status === 429;
    }
    if (plan) {
      provider = "claude";
    } else if (GEMINI_API_KEY) {
      console.log(JSON.stringify({ function: "suggest-itinerary", outcome: "provider_fallback", from: "claude", to: "gemini" }));
    }
  }

  // 6. Gemini fallback. Best case first: the preferred model grounded with Google Search.
  // Degrade gracefully — same model without search (older models reject the search-tool +
  // JSON-schema combination), then the fallback model — but don't burn retries when the
  // failure was quota (429): that hits every variant alike.
  if (!plan && GEMINI_API_KEY) {
    const geminiDeadline = requestDeadline - RESPONSE_RESERVE_MS;
    // Claude already performed the quality-first research attempt. If it timed out or
    // returned invalid output, prefer a fast constrained Gemini response over starting
    // another slow web-search turn. Gemini remains search-grounded when it is primary.
    const useSearch = !claudeAttempted;
    const first = await timing.measure("gemini", () => callGemini(
      SUGGEST_MODEL,
      prompt,
      { useSearch },
      attemptDeadline(geminiDeadline, useSearch ? GEMINI_SEARCH_BUDGET_MS : GEMINI_PLAIN_BUDGET_MS),
    ));
    plan = first.plan;
    let upstreamStatus = first.status;
    providerTimedOut ||= first.timedOut;
    if (!plan && upstreamStatus !== 429 && useSearch) {
      const second = await timing.measure("gemini", () => callGemini(
        SUGGEST_MODEL,
        prompt,
        { useSearch: false },
        attemptDeadline(geminiDeadline, GEMINI_PLAIN_BUDGET_MS),
      ));
      plan = second.plan;
      providerTimedOut ||= second.timedOut;
      if (!plan) upstreamStatus = second.status;
    }
    if (!plan && upstreamStatus !== 429 && SUGGEST_MODEL !== FALLBACK_MODEL) {
      const third = await timing.measure("gemini", () => callGemini(
        FALLBACK_MODEL,
        prompt,
        { useSearch: false },
        attemptDeadline(geminiDeadline, GEMINI_MODEL_FALLBACK_BUDGET_MS),
      ));
      plan = third.plan;
      providerTimedOut ||= third.timedOut;
      if (!plan) upstreamStatus = third.status;
    }
    if (plan) provider = "gemini";
    else if (upstreamStatus === 429) quotaExhausted = true;
  }

  if (!plan || !provider) {
    await timing.measure("completion", () => completeUsage(reservationId, true));
    logUsage("post_call_failure", quotaExhausted ? 503 : providerTimedOut ? 504 : 502);
    // Surface quota exhaustion distinctly — it's an account/billing condition the
    // owner must fix (or wait out), not a transient service bug.
    if (quotaExhausted) {
      return jsonResponse(
        { error: "The AI planner is over its usage limit right now. Try again later." },
        503,
      );
    }
    if (providerTimedOut) {
      return jsonResponse(
        { error: "The AI planner took too long to respond. Try again." },
        504,
      );
    }
    return jsonResponse({ error: "Suggestion service error" }, 502);
  }
  await timing.measure("completion", () => completeUsage(reservationId, true));
  logUsage("success", 200, usage, provider);
  return jsonResponse(plan, 200);
}));

async function getUser(token: string): Promise<{ id: string } | null> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!res.ok) return null;
  const user = await res.json().catch(() => null);
  return typeof user?.id === "string" ? { id: user.id } : null;
}

async function hasAIConsent(token: string, purpose: string, version: string): Promise<boolean> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/has_ai_consent`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      apikey: SUPABASE_ANON_KEY,
    },
    body: JSON.stringify({ p_purpose: purpose, p_consent_version: version }),
  });
  if (!response.ok) {
    console.error(JSON.stringify({ function: "suggest-itinerary", outcome: "consent_check_failure", status: response.status }));
    return false;
  }
  return (await response.json().catch(() => false)) === true;
}

type UsageReservation = {
  allowed: boolean;
  reservationId?: string;
  feature: string;
  limit: number;
  remaining: number;
  windowSeconds: number;
  retryAfterSeconds: number;
};

async function reserveUsage(userId: string): Promise<UsageReservation> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/reserve_ai_usage`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: SUPABASE_SERVICE_ROLE_KEY,
    },
    body: JSON.stringify({
      p_user_id: userId,
      p_kind: RATE_KIND,
      p_limit: RATE_LIMIT,
      p_window_seconds: RATE_WINDOW_SECONDS,
    }),
  });
  if (!res.ok) throw new Error(`rpc ${res.status}`);
  const value = await res.json().catch(() => null);
  if (!value || typeof value.allowed !== "boolean") throw new Error("invalid rpc response");
  return value as UsageReservation;
}

async function completeUsage(reservationId: string, succeeded: boolean): Promise<void> {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/complete_ai_usage`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
      body: JSON.stringify({ p_reservation_id: reservationId, p_succeeded: succeeded }),
    });
    if (!res.ok || (await res.json().catch(() => false)) !== true) {
      console.error(JSON.stringify({ function: "suggest-itinerary", kind: RATE_KIND, outcome: "accounting_failure" }));
    }
  } catch {
    console.error(JSON.stringify({ function: "suggest-itinerary", kind: RATE_KIND, outcome: "accounting_failure" }));
  }
}

function rateLimitResponse(usage: UsageReservation): Response {
  const retry = Math.max(1, Math.ceil(usage.retryAfterSeconds || RATE_WINDOW_SECONDS));
  return jsonResponse({
    error: "Rate limit exceeded",
    feature: RATE_KIND,
    limit: usage.limit || RATE_LIMIT,
    remaining: 0,
    windowSeconds: usage.windowSeconds || RATE_WINDOW_SECONDS,
    retryAfterSeconds: retry,
  }, 429, { "Retry-After": String(retry) });
}

function logUsage(
  outcome: string,
  status: number,
  usage?: Partial<UsageReservation>,
  provider?: "claude" | "gemini",
): void {
  console.log(JSON.stringify({
    function: "suggest-itinerary",
    kind: RATE_KIND,
    outcome,
    status,
    limit: usage?.limit ?? RATE_LIMIT,
    remaining: usage?.remaining,
    windowSeconds: usage?.windowSeconds ?? RATE_WINDOW_SECONDS,
    provider,
  }));
}

function buildPrompt(input: {
  location: string;
  days: number;
  currency: string;
  totalBudget: number;
  startDate: string;
  existingPlan: string;
}): string {
  const hasBudget = input.totalBudget > 0;
  const targetPct = Math.round(BUDGET_PLANNING_RATIO * 100); // 80
  const reservePct = 100 - targetPct; // 20
  const planningBudget = input.totalBudget * BUDGET_PLANNING_RATIO;
  const perDayTarget = hasBudget ? planningBudget / input.days : 0;
  const budgetLine = hasBudget
    ? `Budget: the traveler set aside ${input.totalBudget.toFixed(2)} ${input.currency} for this trip. Plan comfortably within about ${planningBudget.toFixed(2)} ${input.currency} — roughly ${targetPct}%, or about ${perDayTarget.toFixed(2)} ${input.currency} per day, per person — keeping the other ~${reservePct}% as a buffer for taxes, tips, transit, and surprises. Use that ${targetPct}% as a realistic guide, not a quota: where the budget comfortably allows, favor genuinely better experiences over the cheapest option, but keep every price real. It is completely fine to land under the target when that is what an honest, well-chosen plan actually costs; just never exceed ${planningBudget.toFixed(2)} ${input.currency}.`
    : `No fixed budget — still keep costs reasonable and realistic.`;
  const budgetDisciplineLine = hasBudget
    ? `- Budget discipline: keep the trip's total estimated cost within about ${planningBudget.toFixed(2)} ${input.currency} (~${targetPct}% of the ${input.totalBudget.toFixed(2)} ${input.currency} budget) — around ${perDayTarget.toFixed(2)} ${input.currency} per day, per person — without going over. Where the budget comfortably allows, prefer quality (a standout restaurant, a worthwhile paid tour, a cooking class, a day trip) over bare-bones picks, so a generous budget isn't spent on a needlessly cheap plan. But realism wins: every cost must be a real current price for a real place — never inflate prices or add stops just to spend more, and landing under the target is fine when that is what a genuinely good plan costs.`
    : `- Budget discipline: keep each day's combined stop costs reasonable and realistic for ${input.location}; don't pad the plan with unnecessary paid stops.`;
  const dateLine = input.startDate ? `The trip starts on ${input.startDate}.` : "";
  const existingBlock = input.existingPlan
    ? `Already planned by the traveler (do NOT suggest these again — schedule around them):\n${input.existingPlan}`
    : "";

  return `You are an expert professional travel planner with deep first-hand knowledge of ${input.location}: its neighborhoods, opening hours, local food scene, transit, and realistic prices. A client hired you to plan their trip. Plan it the way you would for a paying client — realistic, well-paced, and genuinely good, not a generic tourist checklist.

TRIP BRIEF
Destination: ${input.location}
Number of days: ${input.days}
${budgetLine}
${dateLine}
${existingBlock}

THINK IT THROUGH BEFORE YOU ANSWER
Work the plan out first; only write the JSON once you know it holds together.
- Break ${input.location} into the areas worth a day each, and decide which area gets which day so the trip covers the best of it without backtracking.
- Choose each day's meals first — lunch near where the client will be at midday, dinner near where the day ends — then fill the sights and activities around them.
- Order every day's stops as a route someone actually walks or rides: each stop next to the one before it, no crossing the city twice, and travel time between stops that fits the clock.
- Check the day against reality before committing: opening days and hours, the per-day budget, and how tired the client will be by evening. If something doesn't work, change the order or the picks, not the timings.

RESEARCH — you have a web search tool; use it
- Before choosing stops, search for the currently best-reviewed restaurants, attractions, and things to do in ${input.location}, including well-loved local spots that aren't in every guidebook.
- Verify every place you include still exists and is open — skip anything permanently or temporarily closed, and prefer what you find in search results over memory.
- Check current opening days/hours, entry fees, and typical meal prices, and use those real numbers for "time" feasibility and "cost".

OUTPUT RULES
- Reply with the JSON object and nothing else — no prose before or after, no explanation of your reasoning.
- Shape: {"days": [{"title": string, "stops": [{"kind": string, "name": string, "time": string, "notes": string, "cost": number}]}]}
- Output exactly ${input.days} days, in order.
- Give each day a short theme title, 2–4 words (e.g. "Old town & markets").
- 4 to 6 stops per day. Every stop must be a real, verifiable place — never invent names. Use the place's common name only, no street address.
- "kind" must be exactly one of: "location" (a sight, viewpoint, neighborhood, or landmark to go see), "activity" (a museum, show, tour, class, hike, or experience to do), "restaurant" (anywhere to eat or drink).
- "time" is 24-hour "HH:mm", strictly increasing within each day.
- "notes" is ONE short sentence (under 15 words): the single best reason to go, or the one tip that matters most (book ahead, go at sunset, cash only). No filler like "a must-see".
- "cost" is a realistic per-person price in ${input.currency} for that stop (entry fee, typical meal price, or tour price; 0 for free). Use real current price levels for ${input.location}, not global averages.

PLANNING RULES — how a professional builds a day
- Cluster geographically: each day stays in one area or route of the city/region so the client isn't criss-crossing; consecutive stops must be close to each other in the order visited.
- Pace: start around 09:00, finish by about 21:00 with dinner. Include lunch (12:00–13:30) and dinner (18:30–20:30) restaurants every day; add a breakfast or café stop only when it's genuinely special.
- Respect reality: don't schedule museums on their typical closing days, night markets in the morning, or sunrise/sunset spots at the wrong time.
- Meals: vary cuisine and price level across the trip — never suggest the same restaurant twice, and don't make every meal a famous tourist spot; include local favorites.
- Balance each day: roughly 2–3 sights/locations, 1–2 activities, 2 meals. Never a full day of only museums or only food.
${budgetDisciplineLine}
- Trip arc: put the unmissable icons in the first two-thirds of the trip; for trips of 5+ days, make the first day slightly lighter (arrival) and vary the rhythm — a packed day followed by a gentler one. For long trips (8+ days), include at least one slower "local life" day (parks, neighborhoods, cafés) and consider a classic day trip out of the city if there is an obvious one.
- If stops are already planned (listed above), never repeat them; fill the same day's remaining hours around their times and keep that day's geography coherent with them.`;
}

// The exact shape the client decodes, as a strict JSON Schema for constrained decoding.
const PLAN_JSON_SCHEMA = {
  type: "object",
  properties: {
    days: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          stops: {
            type: "array",
            items: {
              type: "object",
              properties: {
                kind: { type: "string", enum: ["location", "activity", "restaurant"] },
                name: { type: "string" },
                time: { type: "string" },
                notes: { type: "string" },
                cost: { type: "number" },
              },
              required: ["kind", "name", "time", "notes", "cost"],
              additionalProperties: false,
            },
          },
        },
        required: ["title", "stops"],
        additionalProperties: false,
      },
    },
  },
  required: ["days"],
  additionalProperties: false,
};

// Calls Anthropic's Messages API with adaptive thinking (so the model reasons about
// geography, meals, and route order before answering) and the server-side web_search tool
// (so the places are real and currently open). Server tools can end a turn with
// `pause_turn`; resuming means echoing the assistant turn back unchanged. Returns the
// normalized plan, or a null plan plus the upstream HTTP status so quota and
// configuration errors can be told apart.
async function callClaude(
  prompt: string,
  options: { structured: boolean },
  deadline: number,
): Promise<{ plan: Record<string, unknown> | null; status: number; timedOut: boolean }> {
  if (!ANTHROPIC_API_KEY) return { plan: null, status: 0, timedOut: false };

  const messages: unknown[] = [{ role: "user", content: prompt }];

  for (let turn = 0; turn < CLAUDE_MAX_TURNS; turn++) {
    const remainingMs = deadline - Date.now();
    // Too little left to be worth a round trip — hand over to the fallback instead.
    if (remainingMs < MIN_PROVIDER_ATTEMPT_MS) {
      logProviderTimeout("claude", { model: CLAUDE_MODEL, turn, phase: "before_fetch" });
      return { plan: null, status: 0, timedOut: true };
    }

    let response: Response;
    try {
      response = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          ...JSON_HEADERS,
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        signal: AbortSignal.timeout(remainingMs),
        body: JSON.stringify({
          model: CLAUDE_MODEL,
          max_tokens: CLAUDE_MAX_TOKENS,
          thinking: { type: "adaptive" },
          tools: [{
            type: "web_search_20260209",
            name: "web_search",
            max_uses: CLAUDE_SEARCH_MAX_USES,
          }],
          output_config: options.structured
            ? { effort: CLAUDE_EFFORT, format: { type: "json_schema", schema: PLAN_JSON_SCHEMA } }
            : { effort: CLAUDE_EFFORT },
          messages,
        }),
      });
    } catch (error) {
      const didTimeOut = timedOut(error, deadline);
      if (didTimeOut) {
        logProviderTimeout("claude", { model: CLAUDE_MODEL, turn, phase: "fetch" });
      }
      return { plan: null, status: 0, timedOut: didTimeOut };
    }
    if (!response.ok) {
      // Log status only — never the upstream body (avoid leaking key-adjacent detail).
      console.error("Claude call failed:", CLAUDE_MODEL, response.status);
      return { plan: null, status: response.status, timedOut: false };
    }

    const body = await response.json().catch(() => null);
    if (!body || !Array.isArray(body.content)) return { plan: null, status: 200, timedOut: false };
    // Safety classifiers can decline (HTTP 200) — there is no plan to read.
    if (body.stop_reason === "refusal") return { plan: null, status: 200, timedOut: false };
    // The server-side search loop hit its iteration limit: echo the turn back to resume.
    if (body.stop_reason === "pause_turn") {
      messages.push({ role: "assistant", content: body.content });
      continue;
    }

    const rawText = body.content
      .filter((block: unknown) =>
        Boolean(block && typeof block === "object" && (block as Record<string, unknown>).type === "text")
      )
      .map((block: Record<string, unknown>) => (typeof block.text === "string" ? block.text : ""))
      .join("");
    if (rawText.length === 0) return { plan: null, status: 200, timedOut: false };

    try {
      return { plan: normalizePlan(JSON.parse(stripFences(rawText))), status: 200, timedOut: false };
    } catch {
      return { plan: null, status: 200, timedOut: false };
    }
  }
  return { plan: null, status: 0, timedOut: false };
}

// Calls Gemini once with constrained JSON decoding, optionally grounded with Google
// Search so the plan draws on live web results (real opening hours, current prices,
// still-open restaurants). Returns the normalized plan, or a null plan plus the
// upstream HTTP status so quota errors can be reported distinctly.
async function callGemini(
  model: string,
  prompt: string,
  options: { useSearch: boolean },
  deadline: number,
): Promise<{ plan: Record<string, unknown> | null; status: number; timedOut: boolean }> {
  const remainingMs = deadline - Date.now();
  if (remainingMs < MIN_PROVIDER_ATTEMPT_MS) {
    logProviderTimeout("gemini", { model, useSearch: options.useSearch, phase: "before_fetch" });
    return { plan: null, status: 0, timedOut: true };
  }

  let geminiResponse: Response;
  try {
    geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: "POST",
        headers: JSON_HEADERS,
        signal: AbortSignal.timeout(remainingMs),
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          ...(options.useSearch ? { tools: [{ google_search: {} }] } : {}),
          generationConfig: {
            responseMimeType: "application/json",
            temperature: 0.7,
            responseSchema: {
              type: "OBJECT",
              properties: {
                days: {
                  type: "ARRAY",
                  items: {
                    type: "OBJECT",
                    properties: {
                      title: { type: "STRING" },
                      stops: {
                        type: "ARRAY",
                        items: {
                          type: "OBJECT",
                          properties: {
                            kind: { type: "STRING" },
                            name: { type: "STRING" },
                            time: { type: "STRING" },
                            notes: { type: "STRING" },
                            cost: { type: "NUMBER" },
                          },
                          required: ["kind", "name", "time"],
                        },
                      },
                    },
                    required: ["title", "stops"],
                  },
                },
              },
              required: ["days"],
            },
          },
        }),
      },
    );
  } catch (error) {
    const didTimeOut = timedOut(error, deadline);
    if (didTimeOut) {
      logProviderTimeout("gemini", { model, useSearch: options.useSearch, phase: "fetch" });
    }
    return { plan: null, status: 0, timedOut: didTimeOut };
  }
  if (!geminiResponse.ok) {
    // Log status only — never the upstream body (avoid leaking key-adjacent detail).
    console.error("Gemini call failed:", model, geminiResponse.status);
    return { plan: null, status: geminiResponse.status, timedOut: false };
  }

  const geminiJson = await geminiResponse.json().catch(() => null);
  // Grounded responses can split the answer across several parts; join every text part.
  const parts = geminiJson?.candidates?.[0]?.content?.parts;
  const rawText = Array.isArray(parts)
    ? parts.map((p) => (typeof p?.text === "string" ? p.text : "")).join("")
    : null;
  if (typeof rawText !== "string" || rawText.length === 0) {
    return { plan: null, status: 200, timedOut: false };
  }

  try {
    return { plan: normalizePlan(JSON.parse(stripFences(rawText))), status: 200, timedOut: false };
  } catch {
    return { plan: null, status: 200, timedOut: false };
  }
}

function stripFences(text: string): string {
  const trimmed = text.trim();
  if (!trimmed.startsWith("```")) return trimmed;
  return trimmed.replace(/^```[a-zA-Z]*\s*/, "").replace(/```\s*$/, "").trim();
}

function toNumber(value: unknown): number {
  if (typeof value === "number") return isFinite(value) ? value : 0;
  if (typeof value === "string") {
    const n = parseFloat(value.replace(/[^0-9.\-]/g, ""));
    return isFinite(n) ? n : 0;
  }
  return 0;
}

const KINDS = new Set(["location", "activity", "restaurant"]);

// Coerce the model's output into the exact shape the client decodes, clamping sizes so
// a malformed response can't produce an unbounded payload.
function normalizePlan(input: unknown): Record<string, unknown> | null {
  const obj = (input && typeof input === "object") ? input as Record<string, unknown> : {};
  const daysIn = Array.isArray(obj.days) ? obj.days : [];
  const days = daysIn.slice(0, MAX_DAYS).map((rawDay) => {
    const day = (rawDay && typeof rawDay === "object") ? rawDay as Record<string, unknown> : {};
    const stopsIn = Array.isArray(day.stops) ? day.stops : [];
    const stops = stopsIn.slice(0, MAX_STOPS_PER_DAY).map((rawStop) => {
      const stop = (rawStop && typeof rawStop === "object") ? rawStop as Record<string, unknown> : {};
      const kind = typeof stop.kind === "string" && KINDS.has(stop.kind) ? stop.kind : "activity";
      const time = typeof stop.time === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(stop.time.trim())
        ? stop.time.trim()
        : null;
      return {
        kind,
        name: typeof stop.name === "string" ? stop.name.slice(0, 120) : "",
        time,
        notes: typeof stop.notes === "string" ? stop.notes.slice(0, 240) : "",
        cost: Math.min(Math.max(toNumber(stop.cost), 0), 100_000),
      };
    }).filter((stop) => stop.name.trim().length > 0);
    return {
      title: typeof day.title === "string" ? day.title.slice(0, 80) : "",
      stops,
    };
  }).filter((day) => day.stops.length > 0);
  if (days.length === 0) return null;
  return { days };
}
