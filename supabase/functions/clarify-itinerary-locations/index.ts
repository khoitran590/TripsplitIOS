// Claude turns vague itinerary labels into structured search hints. It never returns
// coordinates: the iOS client sends these hints to MapKit, which remains the location
// authority and supplies the persisted Apple place identifier.
import { localProviderMocksEnabled } from "../_shared/local-provider-mock.ts";
import { withTiming } from "../_shared/request-timing.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("Claude Key");
const CLAUDE_MODEL = Deno.env.get("CLAUDE_PIN_MODEL")
  ?? Deno.env.get("CLAUDE_SUGGEST_MODEL")
  ?? "claude-sonnet-5";
const CONSENT_PURPOSE = "itinerary_generation";
const CONSENT_VERSION = "2026-08-06";
const RATE_KIND = "itinerary";
const RATE_LIMIT = 10;
const RATE_WINDOW_SECONDS = 300;
const MAX_STOPS = 10;
const REQUEST_BUDGET_MS = 45_000;
const MAX_TURNS = 2;

type StopInput = {
  stopID: string;
  name: string;
  kind: "location" | "activity" | "restaurant";
  area: string;
  address: string;
};

type LocationHint = {
  stopID: string;
  canonicalName: string;
  area: string | null;
  address: string | null;
  aliases: string[];
  confidence: number;
};

type UsageReservation = {
  allowed: boolean;
  reservationId?: string;
  limit: number;
  remaining: number;
  windowSeconds: number;
  retryAfterSeconds: number;
};

const HINT_SCHEMA = {
  type: "object",
  properties: {
    hints: {
      type: "array",
      items: {
        type: "object",
        properties: {
          stopID: { type: "string" },
          canonicalName: { type: "string" },
          area: { type: ["string", "null"] },
          address: { type: ["string", "null"] },
          aliases: { type: "array", items: { type: "string" } },
          confidence: { type: "number" },
        },
        required: ["stopID", "canonicalName", "area", "address", "aliases", "confidence"],
        additionalProperties: false,
      },
    },
  },
  required: ["hints"],
  additionalProperties: false,
};

Deno.serve(withTiming("clarify-itinerary-locations", async (req, timing) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return jsonResponse({ error: "Unauthorized" }, 401);

  let user: { id: string } | null;
  try {
    user = await timing.measure("auth", () => getUser(token));
    if (!user) return jsonResponse({ error: "Unauthorized" }, 401);
    const consent = await timing.measure(
      "consent",
      () => hasAIConsent(token, CONSENT_PURPOSE, CONSENT_VERSION),
    );
    if (!consent) return jsonResponse({ error: "Current AI consent is required." }, 403);
  } catch {
    return jsonResponse({ error: "AI location help could not connect. Please try again." }, 503);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }
  const destination = cleanString(payload.destination, 200);
  const stops = normalizeStops(payload.stops);
  if (!destination) return jsonResponse({ error: "Missing destination" }, 400);
  if (stops.length === 0) return jsonResponse({ error: "No valid stops" }, 400);

  const mocksEnabled = localProviderMocksEnabled();
  if (!ANTHROPIC_API_KEY && !mocksEnabled) {
    return jsonResponse({ error: "Claude location help is not configured." }, 503);
  }

  let usage: UsageReservation;
  try {
    usage = await timing.measure("quota", () => reserveUsage(user.id));
  } catch {
    return jsonResponse({ error: "Rate limit check failed" }, 500);
  }
  if (!usage.allowed || !usage.reservationId) return rateLimitResponse(usage);

  if (mocksEnabled) {
    const hints = stops.map((stop) => ({
      stopID: stop.stopID,
      canonicalName: stop.name,
      area: stop.area || destination,
      address: stop.address || null,
      aliases: [],
      confidence: 0.9,
    }));
    await timing.measure("completion", () => completeUsage(usage.reservationId!, true));
    return jsonResponse({ hints }, 200);
  }

  const deadline = Date.now() + REQUEST_BUDGET_MS;
  const result = await timing.measure(
    "claude",
    () => callClaude(buildPrompt(destination, stops), deadline),
  );
  // A provider attempt consumes quota even when its answer is unusable.
  await timing.measure("completion", () => completeUsage(usage.reservationId!, true));
  if (!result.hints) {
    if (result.status === 429) return jsonResponse({ error: "Claude is temporarily busy." }, 503);
    if (result.timedOut) return jsonResponse({ error: "Claude took too long. Try again." }, 504);
    return jsonResponse({ error: "Claude could not clarify these locations." }, 502);
  }
  return jsonResponse({ hints: normalizeHints(result.hints, stops) }, 200);
}));

function normalizeStops(value: unknown): StopInput[] {
  if (!Array.isArray(value)) return [];
  const ids = new Set<string>();
  const stops: StopInput[] = [];
  for (const raw of value.slice(0, MAX_STOPS)) {
    if (!raw || typeof raw !== "object") continue;
    const item = raw as Record<string, unknown>;
    const stopID = cleanString(item.stopID, 60).toLowerCase();
    const name = cleanString(item.name, 180);
    const kind = cleanString(item.kind, 20);
    if (!isUUID(stopID) || !name || ids.has(stopID)
      || !["location", "activity", "restaurant"].includes(kind)) continue;
    ids.add(stopID);
    stops.push({
      stopID,
      name,
      kind: kind as StopInput["kind"],
      area: cleanString(item.area, 180),
      address: cleanString(item.address, 240),
    });
  }
  return stops;
}

function buildPrompt(destination: string, stops: StopInput[]): string {
  return `You resolve travel-itinerary labels into precise search hints for Apple Maps.

DESTINATION
${destination}

UNRESOLVED STOPS
${JSON.stringify(stops)}

Use web search when needed to verify the exact venue or landmark. Return one hint for
each stop you can identify confidently and omit uncertain stops. Never invent a place.

Rules:
- canonicalName is the real venue/landmark name someone should search in Apple Maps.
- A label may describe several places or an experience (for example "Shibuya + Harajuku"
  or "old-quarter walk"). Choose one real, useful navigation anchor that best represents it.
- Keep the result physically in the supplied destination or the stop's more-specific area.
- For restaurants and branches, include the street address when verified. Otherwise use null.
- area is neighborhood, city, and country. aliases are up to five useful local-language,
  romanized, translated, or commonly indexed names.
- Confidence is 0 to 1. Use less than 0.65 when the intended branch/place is unclear.
- Do not return latitude, longitude, map URLs, prose, or a replacement itinerary.
- Preserve stopID exactly.

Return only JSON matching {"hints":[{"stopID":string,"canonicalName":string,
"area":string|null,"address":string|null,"aliases":[string],"confidence":number}]}.`;
}

async function callClaude(
  prompt: string,
  deadline: number,
): Promise<{ hints: unknown[] | null; status: number; timedOut: boolean }> {
  if (!ANTHROPIC_API_KEY) return { hints: null, status: 0, timedOut: false };
  const messages: unknown[] = [{ role: "user", content: prompt }];
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const remaining = deadline - Date.now();
    if (remaining < 3_000) return { hints: null, status: 0, timedOut: true };
    let response: Response;
    try {
      response = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        signal: AbortSignal.timeout(remaining),
        headers: {
          "Content-Type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: CLAUDE_MODEL,
          max_tokens: 4_000,
          thinking: { type: "adaptive" },
          tools: [{ type: "web_search_20260209", name: "web_search", max_uses: 2 }],
          output_config: {
            effort: "medium",
            format: { type: "json_schema", schema: HINT_SCHEMA },
          },
          messages,
        }),
      });
    } catch (error) {
      return {
        hints: null,
        status: 0,
        timedOut: error instanceof DOMException && error.name === "TimeoutError",
      };
    }
    if (!response.ok) return { hints: null, status: response.status, timedOut: false };
    const body = await response.json().catch(() => null);
    if (!body || !Array.isArray(body.content) || body.stop_reason === "refusal") {
      return { hints: null, status: 200, timedOut: false };
    }
    if (body.stop_reason === "pause_turn") {
      messages.push({ role: "assistant", content: body.content });
      continue;
    }
    const text = body.content
      .filter((block: unknown) => block && typeof block === "object"
        && (block as Record<string, unknown>).type === "text")
      .map((block: Record<string, unknown>) => typeof block.text === "string" ? block.text : "")
      .join("");
    try {
      const decoded = JSON.parse(stripFences(text));
      return { hints: Array.isArray(decoded?.hints) ? decoded.hints : null, status: 200, timedOut: false };
    } catch {
      return { hints: null, status: 200, timedOut: false };
    }
  }
  return { hints: null, status: 200, timedOut: false };
}

function normalizeHints(value: unknown[], stops: StopInput[]): LocationHint[] {
  const allowed = new Set(stops.map((stop) => stop.stopID));
  const seen = new Set<string>();
  const hints: LocationHint[] = [];
  for (const raw of value) {
    if (!raw || typeof raw !== "object") continue;
    const item = raw as Record<string, unknown>;
    const stopID = cleanString(item.stopID, 60).toLowerCase();
    const canonicalName = cleanString(item.canonicalName, 180);
    const confidence = Math.min(Math.max(Number(item.confidence) || 0, 0), 1);
    if (!allowed.has(stopID) || seen.has(stopID) || !canonicalName || confidence < 0.65) continue;
    seen.add(stopID);
    const aliases = Array.isArray(item.aliases)
      ? [...new Set(item.aliases.map((alias) => cleanString(alias, 180)).filter(Boolean))].slice(0, 5)
      : [];
    hints.push({
      stopID,
      canonicalName,
      area: cleanString(item.area, 180) || null,
      address: cleanString(item.address, 240) || null,
      aliases,
      confidence,
    });
  }
  return hints;
}

async function getUser(token: string): Promise<{ id: string } | null> {
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    signal: AbortSignal.timeout(5_000),
    headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!response.ok) return null;
  const value = await response.json().catch(() => null);
  return value && typeof value.id === "string" ? { id: value.id } : null;
}

async function hasAIConsent(token: string, purpose: string, version: string): Promise<boolean> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/has_ai_consent`, {
    signal: AbortSignal.timeout(5_000),
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      apikey: SUPABASE_ANON_KEY,
    },
    body: JSON.stringify({ p_purpose: purpose, p_consent_version: version }),
  });
  return response.ok && (await response.json().catch(() => false)) === true;
}

async function reserveUsage(userId: string): Promise<UsageReservation> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/reserve_ai_usage`, {
    signal: AbortSignal.timeout(5_000),
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
  if (!response.ok) throw new Error(`rpc ${response.status}`);
  const value = await response.json().catch(() => null);
  if (!value || typeof value.allowed !== "boolean") throw new Error("invalid rpc response");
  return value as UsageReservation;
}

async function completeUsage(reservationId: string, succeeded: boolean): Promise<void> {
  try {
    const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/complete_ai_usage`, {
      signal: AbortSignal.timeout(5_000),
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
      body: JSON.stringify({ p_reservation_id: reservationId, p_succeeded: succeeded }),
    });
    if (!response.ok || (await response.json().catch(() => false)) !== true) {
      console.error(JSON.stringify({ function: "clarify-itinerary-locations", outcome: "accounting_failure" }));
    }
  } catch {
    console.error(JSON.stringify({ function: "clarify-itinerary-locations", outcome: "accounting_failure" }));
  }
}

function rateLimitResponse(usage: UsageReservation): Response {
  const retry = Math.max(1, Math.ceil(usage.retryAfterSeconds || RATE_WINDOW_SECONDS));
  return jsonResponse({
    error: "Rate limit exceeded",
    retryAfterSeconds: retry,
    limit: usage.limit || RATE_LIMIT,
    remaining: 0,
    windowSeconds: usage.windowSeconds || RATE_WINDOW_SECONDS,
  }, 429, { "Retry-After": String(retry) });
}

function cleanString(value: unknown, limit: number): string {
  return typeof value === "string" ? value.trim().slice(0, limit) : "";
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function stripFences(value: string): string {
  return value.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
}

function jsonResponse(
  body: unknown,
  status: number,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...extraHeaders },
  });
}
