// parse-receipt — server-side proxy for the receipt-parsing LLM call.
//
// Why this exists: the app must NOT ship the Gemini API key. The client sends the receipt
// image plus the signed-in user's Supabase JWT; this function authenticates the user,
// rate-limits them, calls Gemini with the key held in a Supabase secret, validates the
// model output, and returns structured JSON.
//
// Security posture:
//  - Auth: platform `verify_jwt = true` AND an explicit `/auth/v1/user` check, so only a
//    real signed-in user (not the anon key) is accepted.
//  - Rate limit: per-user, enforced atomically by the `record_receipt_scan` RPC.
//  - Input: JSON body must contain either an image payload or legacy OCR `text`, under caps.
//  - Secret: the Gemini key is read from env and never logged or returned.
//  - Output: the model's JSON is re-validated/normalized before it reaches the client.
//  - No dependencies: plain fetch only, to minimize supply-chain surface.
//  - Privacy: receipt images/text are never logged.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";

const MAX_IMAGE_BYTES = 4_000_000;  // Keep JSON/base64 requests bounded.
const MAX_TEXT_BYTES = 20_000;      // Legacy OCR text is small; reject oversized input.
const MAX_ITEMS = 200;              // Clamp a runaway model response.
const RATE_LIMIT = 20;              // Max scans ...
const RATE_WINDOW_SECONDS = 60;     // ... per user per this window.

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
  let payload: { imageBase64?: unknown; mimeType?: unknown; text?: unknown };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const image = parseImagePayload(payload);
  const text = typeof payload.text === "string" ? payload.text.trim() : "";
  if (!image && !text) return jsonResponse({ error: "Missing receipt image or text" }, 400);
  if (image?.error) return jsonResponse({ error: image.error }, image.status);
  if (!image && new TextEncoder().encode(text).length > MAX_TEXT_BYTES) {
    return jsonResponse({ error: "Receipt text too large" }, 413);
  }

  // 3. Per-user rate limit (atomic check-and-record in Postgres).
  let allowed: boolean;
  try {
    allowed = await recordScan(token);
  } catch {
    return jsonResponse({ error: "Rate limit check failed" }, 500);
  }
  if (!allowed) {
    return jsonResponse({ error: "Rate limit exceeded. Try again shortly." }, 429);
  }

  // 4. The key must be configured server-side.
  if (!GEMINI_API_KEY) {
    return jsonResponse({ error: "Receipt parsing is not configured." }, 503);
  }

  // 5. Call Gemini with the server-side key.
  const prompt = buildPrompt(image ? null : text);
  const parts = image?.data
    ? [
      { text: prompt },
      { inline_data: { mime_type: image.mimeType, data: image.data } },
    ]
    : [{ text: prompt }];
  let geminiResponse: Response;
  try {
    geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify({
          contents: [{ parts }],
          generationConfig: { responseMimeType: "application/json", temperature: 0 },
        }),
      },
    );
  } catch {
    return jsonResponse({ error: "Upstream request failed" }, 502);
  }
  if (!geminiResponse.ok) {
    // Log status only — never the upstream body (avoid leaking key-adjacent detail).
    console.error("Gemini call failed:", geminiResponse.status);
    return jsonResponse({ error: "Parsing service error" }, 502);
  }

  const geminiJson = await geminiResponse.json().catch(() => null);
  const rawText = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (typeof rawText !== "string") {
    return jsonResponse({ error: "Empty parsing result" }, 502);
  }

  // 6. Re-validate/normalize the model output before handing it to the client.
  let parsed: unknown;
  try {
    parsed = JSON.parse(stripFences(rawText));
  } catch {
    return jsonResponse({ error: "Malformed parsing result" }, 502);
  }
  return jsonResponse(normalizeReceipt(parsed), 200);
});

async function getUser(token: string): Promise<{ id: string } | null> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!res.ok) return null;
  const user = await res.json().catch(() => null);
  return typeof user?.id === "string" ? { id: user.id } : null;
}

async function recordScan(token: string): Promise<boolean> {
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

function buildPrompt(text: string | null): string {
  const source = text
    ? `Receipt text:\n${text}`
    : "Receipt image: scan the attached receipt image directly.";

  return `Extract structured data from this receipt. Respond with ONLY valid JSON, no markdown fences, no commentary, matching exactly this schema:

{
  "merchant": string,
  "date": string or null,
  "items": [{"name": string, "price": number, "quantity": integer}],
  "tax": number,
  "tip": number,
  "total": number
}

Rules:
- If a field is missing on the receipt, use 0 for numbers or null for date.
- Merge duplicate line items by summing quantity.
- "price" is the per-item price, not the line total.
- Exclude subtotal, total, tax, tip, and payment lines from "items".

${source}`;
}

type ImagePayload =
  | { data: string; mimeType: string; status: 200 }
  | { error: string; status: 400 | 413 | 415 };

function parseImagePayload(payload: { imageBase64?: unknown; mimeType?: unknown }): ImagePayload | null {
  if (typeof payload.imageBase64 !== "string") return null;

  const data = payload.imageBase64.replace(/\s/g, "");
  const mimeType = typeof payload.mimeType === "string" ? payload.mimeType : "image/jpeg";
  if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
    return { error: "Unsupported receipt image type", status: 415 };
  }
  if (!data || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
    return { error: "Invalid receipt image", status: 400 };
  }

  let byteLength = 0;
  try {
    byteLength = atob(data).length;
  } catch {
    return { error: "Invalid receipt image", status: 400 };
  }
  if (byteLength > MAX_IMAGE_BYTES) {
    return { error: "Receipt image too large", status: 413 };
  }

  return { data, mimeType, status: 200 };
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

// Coerce the model's output into the exact shape the client decodes, clamping sizes so a
// malicious or malformed response can't produce an unbounded payload.
function normalizeReceipt(input: unknown): Record<string, unknown> {
  const obj = (input && typeof input === "object") ? input as Record<string, unknown> : {};
  const itemsIn = Array.isArray(obj.items) ? obj.items : [];
  const items = itemsIn.slice(0, MAX_ITEMS).map((raw) => {
    const item = (raw && typeof raw === "object") ? raw as Record<string, unknown> : {};
    return {
      name: typeof item.name === "string" ? item.name.slice(0, 200) : "",
      price: toNumber(item.price),
      quantity: Math.max(1, Math.min(50, Math.round(toNumber(item.quantity) || 1))),
    };
  });
  return {
    merchant: typeof obj.merchant === "string" ? obj.merchant.slice(0, 200) : "",
    date: typeof obj.date === "string" ? obj.date : null,
    items,
    tax: toNumber(obj.tax),
    tip: toNumber(obj.tip),
    total: toNumber(obj.total),
  };
}
