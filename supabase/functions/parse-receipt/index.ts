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
  if (new TextEncoder().encode(text).length > MAX_TEXT_BYTES) {
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

  // 5. Call Gemini with the server-side key. When the client sends both the photo and
  // on-device OCR text, both go to the model — the OCR text helps it recover faint or
  // skewed line items it might otherwise miss in the image.
  const prompt = buildPrompt(text || null, Boolean(image));
  const parts = image?.data
    ? [
      { text: prompt },
      { inline_data: { mime_type: image.mimeType, data: image.data } },
    ]
    : [{ text: prompt }];
  let receipt = await callGemini(parts);
  if (!receipt) return jsonResponse({ error: "Parsing service error" }, 502);

  // The known failure mode: the model "summarizes" the receipt as a single item whose
  // price is the grand total. Re-ask once with explicit corrective feedback — the second
  // pass almost always itemizes properly. Only kept if it actually finds more items.
  if (isCollapsed(receipt)) {
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
  return jsonResponse(receipt, 200);
});

// One item whose price (alone, or plus tax/tip) matches the total = a collapsed summary.
function isCollapsed(receipt: Record<string, unknown>): boolean {
  const items = receipt.items as { price: number; quantity: number }[];
  const total = receipt.total as number;
  if (items.length !== 1 || !(total > 0)) return false;
  const line = items[0].price * items[0].quantity;
  const withTaxTip = line + (receipt.tax as number) + (receipt.tip as number);
  return Math.abs(line - total) < 0.02 || Math.abs(withTaxTip - total) < 0.02;
}

// Calls Gemini once and returns the normalized receipt, or null on any failure.
async function callGemini(parts: unknown[]): Promise<Record<string, unknown> | null> {
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
