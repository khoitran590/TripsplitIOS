// parse-receipt — server-side proxy for the receipt-parsing LLM call.
//
// Why this exists: the app must NOT ship provider API keys. The client sends the receipt
// image plus the signed-in user's Supabase JWT; this function authenticates the user,
// reserves a feature-local quota slot, calls Claude first and Gemini only as a fallback,
// commits usage once provider work is attempted, validates the model output, and returns
// structured JSON.
//
// Security posture:
//  - Auth: platform `verify_jwt = true` AND an explicit `/auth/v1/user` check, so only a
//    real signed-in user (not the anon key) is accepted.
//  - Rate limit: 15 paid provider attempts per user per 60 seconds. Capacity is reserved
//    atomically by a service-role-only RPC and is not refunded for invalid/error output.
//  - Input: JSON body must contain either an image payload or legacy OCR `text`, under caps.
//  - Secrets: Anthropic/Gemini keys are read from env and never logged or returned.
//  - Output: the model's JSON is re-validated/normalized before it reaches the client.
//  - No dependencies: plain fetch only, to minimize supply-chain surface.
//  - Privacy: receipt images/text are never logged.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// `ANTHROPIC_API_KEY` is canonical. `Claude Key` supports the initial Dashboard label so
// the configured secret can be used without copying its value into source or chat.
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("Claude Key");
const CLAUDE_MODEL = Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-5";
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";

const MAX_IMAGE_BYTES = 4_000_000;  // Keep JSON/base64 requests bounded.
const MAX_TEXT_BYTES = 20_000;      // Legacy OCR text is small; reject oversized input.
const MAX_ITEMS = 200;              // Clamp a runaway model response.
const RATE_LIMIT = 15;              // Max paid provider attempts ...
const RATE_WINDOW_SECONDS = 60;     // ... per user per this window.
const RATE_KIND = "parse";
const CONSENT_PURPOSE = "receipt_processing";
const CONSENT_VERSION = "2026-08-05";
const LEGACY_GOOGLE_CONSENT_VERSION = "2026-08-02";

const JSON_HEADERS = { "Content-Type": "application/json" };

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...headers } });
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
  // A legacy Google-only grant can continue using Gemini during app rollout, but can
  // never authorize sending the image to Anthropic. New clients collect the current
  // version before Claude becomes eligible.
  const hasCurrentConsent = await hasAIConsent(token, CONSENT_PURPOSE, CONSENT_VERSION);
  const hasLegacyGoogleConsent = hasCurrentConsent
    ? false
    : await hasAIConsent(token, CONSENT_PURPOSE, LEGACY_GOOGLE_CONSENT_VERSION);
  if (!hasCurrentConsent && !hasLegacyGoogleConsent) {
    return jsonResponse({ error: "Current AI consent is required." }, 403);
  }

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
  if (new TextEncoder().encode(text).length > MAX_TEXT_BYTES) {
    return jsonResponse({ error: "Receipt text too large" }, 413);
  }

  // 3. At least one cloud provider must be configured before reserving quota: our own
  // configuration outage is never charged. Claude is primary whenever its key exists.
  if ((!hasCurrentConsent || !ANTHROPIC_API_KEY) && !GEMINI_API_KEY) {
    return jsonResponse({ error: "Receipt parsing is not configured." }, 503);
  }

  // 4. Reserve this feature's capacity atomically. The reservation prevents concurrent
  // requests from exceeding the bucket. Once a provider is called, the attempt is charged
  // even when the provider returns an error or unusable output.
  let usage: UsageReservation;
  try {
    usage = await reserveUsage(user.id);
  } catch {
    logUsage("rate_check_failure", 500);
    return jsonResponse({ error: "Rate limit check failed" }, 500);
  }
  if (!usage.allowed || !usage.reservationId) {
    logUsage("rate_limited", 429, usage);
    return rateLimitResponse(usage);
  }

  // 5. Ask Claude to read and structure the receipt directly from the image. If Claude is
  // unavailable, rejects the request, or returns an unusable/collapsed receipt, try Gemini.
  // Apple Vision remains entirely client-side and runs only if this function fails.
  const prompt = buildPrompt(text || null, Boolean(image));
  let provider: "claude" | "gemini" | undefined;
  let receipt = hasCurrentConsent && ANTHROPIC_API_KEY ? await callClaude(prompt, image) : null;
  if (isUsableReceipt(receipt)) {
    provider = "claude";
  } else if (hasCurrentConsent && ANTHROPIC_API_KEY && GEMINI_API_KEY) {
    console.log(JSON.stringify({ function: "parse-receipt", outcome: "provider_fallback", from: "claude", to: "gemini" }));
  }

  if (!provider && GEMINI_API_KEY) {
    const parts = image?.data
      ? [
        { text: prompt },
        { inline_data: { mime_type: image.mimeType, data: image.data } },
      ]
      : [{ text: prompt }];
    receipt = await callGemini(parts);

    // Gemini's known failure mode is a single pseudo-item equal to the total. Re-ask once
    // with corrective feedback and keep the retry only when it finds more real items.
    if (receipt && isCollapsed(receipt)) {
      const retry = await callGemini([
        ...parts,
        {
          text:
            "IMPORTANT CORRECTION: your previous answer collapsed this receipt into a single item whose price equals the grand total. That is wrong. Look again at the item section of the receipt and list each individual line item with its own printed name and per-unit price. Do not include subtotal, tax, tip, or total rows as items.",
        },
      ]);
      if (retry && (retry.items as unknown[]).length > (receipt.items as unknown[]).length) {
        receipt = retry;
      }
    }
    // A real receipt may contain exactly one purchase. After the corrective retry, retain
    // Gemini's normalized item instead of forcing a needless on-device scan solely because
    // one line plus tax happens to equal the printed total.
    if (hasReceiptItems(receipt)) provider = "gemini";
  }

  if (!receipt || !provider) {
    await completeUsage(usage.reservationId, true);
    logUsage("post_call_failure", 502);
    return jsonResponse({ error: "Parsing service error" }, 502);
  }
  await completeUsage(usage.reservationId, true);
  logUsage("success", 200, usage, provider);
  return jsonResponse(receipt, 200);
});

function isUsableReceipt(receipt: Record<string, unknown> | null): receipt is Record<string, unknown> {
  return hasReceiptItems(receipt) && !isCollapsed(receipt);
}

function hasReceiptItems(receipt: Record<string, unknown> | null): receipt is Record<string, unknown> {
  return Boolean(receipt && Array.isArray(receipt.items) && receipt.items.length > 0);
}

// One item whose price (alone, or plus tax/tip) matches the total = a collapsed summary.
function isCollapsed(receipt: Record<string, unknown>): boolean {
  const items = receipt.items as { price: number; quantity: number }[];
  const total = receipt.total as number;
  if (items.length !== 1 || !(total > 0)) return false;
  const line = items[0].price * items[0].quantity;
  const withTaxTip = line + (receipt.tax as number) + (receipt.tip as number);
  return Math.abs(line - total) < 0.02 || Math.abs(withTaxTip - total) < 0.02;
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
    console.error(JSON.stringify({ function: "parse-receipt", outcome: "consent_check_failure", status: response.status }));
    return false;
  }
  return (await response.json().catch(() => false)) === true;
}

const RECEIPT_JSON_SCHEMA = {
  type: "object",
  properties: {
    merchant: { type: "string" },
    date: { type: ["string", "null"] },
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          price: { type: "number" },
          quantity: { type: "integer" },
        },
        required: ["name", "price", "quantity"],
        additionalProperties: false,
      },
    },
    tax: { type: "number" },
    tip: { type: "number" },
    total: { type: "number" },
  },
  required: ["merchant", "date", "items", "tax", "tip", "total"],
  additionalProperties: false,
};

// Calls Anthropic's Messages API once. Claude receives the image in-memory as base64;
// TripSplit never gives Anthropic a storage URL or provider credential.
async function callClaude(
  prompt: string,
  image: ImagePayload | null,
): Promise<Record<string, unknown> | null> {
  if (!ANTHROPIC_API_KEY) return null;

  const content: unknown[] = [];
  if (image?.data) {
    content.push({
      type: "image",
      source: { type: "base64", media_type: image.mimeType, data: image.data },
    });
  }
  content.push({ type: "text", text: prompt });

  let response: Response;
  try {
    response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        ...JSON_HEADERS,
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: 4_096,
        thinking: { type: "disabled" },
        messages: [{ role: "user", content }],
        output_config: {
          format: { type: "json_schema", schema: RECEIPT_JSON_SCHEMA },
        },
      }),
    });
  } catch {
    return null;
  }
  if (!response.ok) {
    // Status only: receipt data and upstream response bodies must never reach logs.
    console.error("Claude call failed:", response.status);
    return null;
  }

  const body = await response.json().catch(() => null);
  const textBlock = Array.isArray(body?.content)
    ? body.content.find((block: unknown) =>
      Boolean(block && typeof block === "object" && (block as Record<string, unknown>).type === "text")
    ) as Record<string, unknown> | undefined
    : undefined;
  const rawText = textBlock?.text;
  if (typeof rawText !== "string") return null;

  try {
    return normalizeReceipt(JSON.parse(stripFences(rawText)));
  } catch {
    return null;
  }
}

// Calls Gemini once and returns the normalized receipt, or null on any failure.
async function callGemini(parts: unknown[]): Promise<Record<string, unknown> | null> {
  if (!GEMINI_API_KEY) return null;
  let geminiResponse: Response;
  try {
    geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify({
          contents: [{ parts }],
          generationConfig: {
            responseMimeType: "application/json",
            temperature: 0,
            // Constrained decoding: the model literally cannot emit anything but this
            // shape, which stops the "one item holding the grand total" failure mode
            // where it answered with prose or a collapsed summary object.
            responseSchema: {
              type: "OBJECT",
              properties: {
                merchant: { type: "STRING" },
                date: { type: "STRING", nullable: true },
                items: {
                  type: "ARRAY",
                  items: {
                    type: "OBJECT",
                    properties: {
                      name: { type: "STRING" },
                      price: { type: "NUMBER" },
                      quantity: { type: "INTEGER" },
                    },
                    required: ["name", "price"],
                  },
                },
                tax: { type: "NUMBER" },
                tip: { type: "NUMBER" },
                total: { type: "NUMBER" },
              },
              required: ["merchant", "items", "total"],
            },
          },
        }),
      },
    );
  } catch {
    return null;
  }
  if (!geminiResponse.ok) {
    // Log status only — never the upstream body (avoid leaking key-adjacent detail).
    console.error("Gemini call failed:", geminiResponse.status);
    return null;
  }

  const geminiJson = await geminiResponse.json().catch(() => null);
  const rawText = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (typeof rawText !== "string") return null;

  // Re-validate/normalize the model output before handing it to the client.
  try {
    return normalizeReceipt(JSON.parse(stripFences(rawText)));
  } catch {
    return null;
  }
}

async function getUser(token: string): Promise<{ id: string } | null> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!res.ok) return null;
  const user = await res.json().catch(() => null);
  return typeof user?.id === "string" ? { id: user.id } : null;
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
      console.error(JSON.stringify({ function: "parse-receipt", kind: RATE_KIND, outcome: "accounting_failure" }));
    }
  } catch {
    console.error(JSON.stringify({ function: "parse-receipt", kind: RATE_KIND, outcome: "accounting_failure" }));
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
    function: "parse-receipt",
    kind: RATE_KIND,
    outcome,
    status,
    limit: usage?.limit ?? RATE_LIMIT,
    remaining: usage?.remaining,
    windowSeconds: usage?.windowSeconds ?? RATE_WINDOW_SECONDS,
    provider,
  }));
}

function buildPrompt(text: string | null, hasImage: boolean): string {
  let source: string;
  if (hasImage && text) {
    source =
      `Read the attached receipt image. OCR text extracted from the same receipt is included below — it may contain errors, so cross-check it against the image, but use it to recover any line items that are faint or hard to read in the photo.\n\nOCR text:\n${text}`;
  } else if (hasImage) {
    source = "Read the attached receipt image directly.";
  } else {
    source = `Receipt text (from OCR, may contain errors):\n${text}`;
  }

  return `You are reading a store or restaurant receipt. Extract structured data as JSON:

{
  "merchant": string,
  "date": string or null,
  "items": [{"name": string, "price": number, "quantity": integer}],
  "tax": number,
  "tip": number,
  "total": number
}

Rules for "items" — this is the most important part:
- List EVERY individual purchasable line item printed on the receipt, each with its own name and price. Real receipts usually have several items; go line by line down the item section and do not skip any.
- NEVER collapse the receipt into a single item whose price is the subtotal or grand total. If you can read any distinct line items at all, list each one separately.
- Do NOT include subtotal, total, amount due, tax, tip/gratuity, service charge, discount, change, cash, or card/payment lines as items — those are not purchases.
- "price" is the price of ONE unit. If a line shows a quantity and a line total (e.g. "2 Latte 9.00"), set quantity to 2 and price to the per-unit price (9.00 / 2 = 4.50).
- Use the item name as printed, cleaned up to be human-readable (drop SKU codes and register codes, keep the product name).
- Merge only truly identical repeated lines by increasing quantity.

Other fields:
- "tax" is the total tax/VAT/GST amount, "tip" the tip or service charge; use 0 when absent.
- "total" is the printed grand total. Sanity-check: the sum of price × quantity over all items plus tax and tip should approximately equal the total. If it doesn't, re-read the receipt for items you missed.
- "date" is the purchase date as printed, or null.

${source}`;
}

type ImagePayload =
  | { data: string; mimeType: string; status: 200; error?: never }
  | { error: string; status: 400 | 413 | 415; data?: never; mimeType?: never };

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

// Names that mark a row as a total/tax/payment line rather than a purchase. The prompt
// already forbids these, but the model occasionally emits them anyway — dropping them
// here is what prevents a "Total $53.20" pseudo-item from reaching the client.
const NON_ITEM_NAME =
  /\b(sub\s*-?\s*total|total|amount\s+due|balance(\s+due)?|tax|vat|gst|hst|pst|tip|gratuity|service\s+(charge|chg|fee)|change|cash|tender(ed)?|visa|master\s*card|amex|discover|debit|credit|payment|auth(orization)?|approval)\b/i;

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
  }).filter((item) => item.price > 0 && !NON_ITEM_NAME.test(item.name));
  return {
    merchant: typeof obj.merchant === "string" ? obj.merchant.slice(0, 200) : "",
    date: typeof obj.date === "string" ? obj.date : null,
    items,
    tax: toNumber(obj.tax),
    tip: toNumber(obj.tip),
    total: toNumber(obj.total),
  };
}
