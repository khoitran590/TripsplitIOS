// suggest-itinerary — server-side proxy for the AI day-by-day itinerary planner.
//
// Why this exists: the app must NOT ship the Gemini API key (same posture as
// parse-receipt). The client sends the trip's destination, day count, budget, and any
// already-planned stops with the signed-in user's Supabase JWT; this function
// authenticates the user, rate-limits them, asks Gemini for a structured day-by-day
// plan, validates the model output, and returns JSON the app can render and apply.
//
// Security posture (mirrors parse-receipt):
//  - Auth: platform `verify_jwt = true` AND an explicit `/auth/v1/user` check.
//  - Rate limit: per-user via the same `record_receipt_scan` RPC/table used by receipt
//    scanning — one shared AI-usage bucket, with a tighter window for plan generation.
//  - Secret: the Gemini key is read from env and never logged or returned.
//  - Output: the model's JSON is re-validated/normalized before it reaches the client.
//  - No dependencies: plain fetch only.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
// Preferred model for planning; falls back to the receipt model if the id is unknown
// to the API (e.g. regional availability), so the feature degrades instead of breaking.
const SUGGEST_MODEL = Deno.env.get("GEMINI_SUGGEST_MODEL") ?? "gemini-3.5-flash";
const FALLBACK_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";

const MAX_DAYS = 30;
const MAX_STOPS_PER_DAY = 10;
const MAX_EXISTING_CHARS = 4_000;
const RATE_LIMIT = 10; // Max plan generations ...
const RATE_WINDOW_SECONDS = 300; // ... per user per this window.

const JSON_HEADERS = { "Content-Type": "application/json" };

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // 1. Require a valid, signed-in user (not just any project JWT such as the anon key).
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return jsonResponse({ error: "Unauthorized" }, 401);
  const user = await getUser(token);
  if (!user) return jsonResponse({ error: "Unauthorized" }, 401);

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

  // 3. Per-user rate limit (atomic check-and-record in Postgres).
  let allowed: boolean;
  try {
    allowed = await recordUse(token);
  } catch {
    return jsonResponse({ error: "Rate limit check failed" }, 500);
  }
  if (!allowed) {
    return jsonResponse({ error: "Rate limit exceeded. Try again shortly." }, 429);
  }

  // 4. The key must be configured server-side.
  if (!GEMINI_API_KEY) {
    return jsonResponse({ error: "AI suggestions are not configured." }, 503);
  }

  // 5. Call Gemini with the server-side key; retry once on the fallback model when the
  // preferred model id isn't recognized.
  const prompt = buildPrompt({ location, days, currency, totalBudget, startDate, existingPlan });
  const first = await callGemini(SUGGEST_MODEL, prompt);
  let plan = first.plan;
  let upstreamStatus = first.status;
  if (!plan && SUGGEST_MODEL !== FALLBACK_MODEL) {
    const second = await callGemini(FALLBACK_MODEL, prompt);
    plan = second.plan;
    if (!plan) upstreamStatus = second.status;
  }
  if (!plan) {
    // Surface quota exhaustion distinctly — it's an account/billing condition the
    // owner must fix (or wait out), not a transient service bug.
    if (upstreamStatus === 429) {
      return jsonResponse(
        { error: "The AI planner is over its usage limit right now. Try again later." },
        503,
      );
    }
    return jsonResponse({ error: "Suggestion service error" }, 502);
  }
  return jsonResponse(plan, 200);
});

async function getUser(token: string): Promise<{ id: string } | null> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!res.ok) return null;
  const user = await res.json().catch(() => null);
  return typeof user?.id === "string" ? { id: user.id } : null;
}

async function recordUse(token: string): Promise<boolean> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/record_receipt_scan`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      apikey: SUPABASE_ANON_KEY,
    },
    body: JSON.stringify({ p_limit: RATE_LIMIT, p_window_seconds: RATE_WINDOW_SECONDS }),
  });
  if (!res.ok) throw new Error(`rpc ${res.status}`);
  return (await res.json().catch(() => false)) === true;
}

function buildPrompt(input: {
  location: string;
  days: number;
  currency: string;
  totalBudget: number;
  startDate: string;
  existingPlan: string;
}): string {
  const perDay = input.totalBudget > 0 ? input.totalBudget / input.days : 0;
  const budgetLine = input.totalBudget > 0
    ? `Total budget: ${input.totalBudget.toFixed(2)} ${input.currency} (about ${perDay.toFixed(2)} ${input.currency} per day, per person).`
    : `No fixed budget — still keep costs reasonable and realistic.`;
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

OUTPUT RULES
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
- Budget discipline: keep each day's combined stop costs at or under the per-day amount. Splurge days are fine only if offset by cheaper days, and the whole trip must total at or under the overall budget.
- Trip arc: put the unmissable icons in the first two-thirds of the trip; for trips of 5+ days, make the first day slightly lighter (arrival) and vary the rhythm — a packed day followed by a gentler one. For long trips (8+ days), include at least one slower "local life" day (parks, neighborhoods, cafés) and consider a classic day trip out of the city if there is an obvious one.
- If stops are already planned (listed above), never repeat them; fill the same day's remaining hours around their times and keep that day's geography coherent with them.`;
}

// Calls Gemini once with constrained JSON decoding. Returns the normalized plan, or a
// null plan plus the upstream HTTP status so quota errors can be reported distinctly.
async function callGemini(
  model: string,
  prompt: string,
): Promise<{ plan: Record<string, unknown> | null; status: number }> {
  let geminiResponse: Response;
  try {
    geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
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
  } catch {
    return { plan: null, status: 0 };
  }
  if (!geminiResponse.ok) {
    // Log status only — never the upstream body (avoid leaking key-adjacent detail).
    console.error("Gemini call failed:", model, geminiResponse.status);
    return { plan: null, status: geminiResponse.status };
  }

  const geminiJson = await geminiResponse.json().catch(() => null);
  const rawText = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (typeof rawText !== "string") return { plan: null, status: 200 };

  try {
    return { plan: normalizePlan(JSON.parse(stripFences(rawText))), status: 200 };
  } catch {
    return { plan: null, status: 200 };
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
