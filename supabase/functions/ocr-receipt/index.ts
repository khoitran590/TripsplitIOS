// ocr-receipt — server-side proxy for Google Cloud Vision OCR.
//
// Why this exists: the app must NOT ship the Google Cloud Vision API key. The client
// sends the receipt image plus the signed-in user's Supabase JWT; this function
// authenticates the user, rate-limits them, calls Cloud Vision with the key held in a
// Supabase secret, and returns the recognized text grouped into receipt rows.
//
// Security posture (mirrors parse-receipt):
//  - Auth: platform `verify_jwt = true` AND an explicit `/auth/v1/user` check, so only a
//    real signed-in user (not the anon key) is accepted.
//  - Rate limit: per-user, enforced atomically by the `record_receipt_scan` RPC.
//  - Input: JSON body must contain an image payload under the size cap.
//  - Secret: the Vision key is read from env and never logged or returned.
//  - No dependencies: plain fetch only, to minimize supply-chain surface.
//  - Privacy: receipt images/text are never logged.
//
// Deploy: supabase functions deploy ocr-receipt
// Secret: supabase secrets set GOOGLE_VISION_API_KEY=<key>

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GOOGLE_VISION_API_KEY = Deno.env.get("GOOGLE_VISION_API_KEY");

const MAX_IMAGE_BYTES = 4_000_000; // Keep JSON/base64 requests bounded.
const MAX_LINES = 400;             // Clamp a runaway response.
const RATE_LIMIT = 20;             // Max scans ...
const RATE_WINDOW_SECONDS = 60;    // ... per user per this window.

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
  let payload: { imageBase64?: unknown; mimeType?: unknown };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }
  const image = parseImagePayload(payload);
  if (!image) return jsonResponse({ error: "Missing receipt image" }, 400);
  if ("error" in image) return jsonResponse({ error: image.error }, image.status);

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
  if (!GOOGLE_VISION_API_KEY) {
    return jsonResponse({ error: "Receipt OCR is not configured." }, 503);
  }

  // 5. Call Cloud Vision with the server-side key. DOCUMENT_TEXT_DETECTION is the dense-
  // text model, which reads receipt print better than plain TEXT_DETECTION.
  let visionResponse: Response;
  try {
    visionResponse = await fetch(
      `https://vision.googleapis.com/v1/images:annotate?key=${GOOGLE_VISION_API_KEY}`,
      {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify({
          requests: [{
            image: { content: image.data },
            features: [{ type: "DOCUMENT_TEXT_DETECTION" }],
          }],
        }),
      },
    );
  } catch {
    return jsonResponse({ error: "OCR service error" }, 502);
  }
  if (!visionResponse.ok) {
    // Log status only — never the upstream body (avoid leaking key-adjacent detail).
    console.error("Cloud Vision call failed:", visionResponse.status);
    return jsonResponse({ error: "OCR service error" }, 502);
  }

  const visionJson = await visionResponse.json().catch(() => null);
  const annotation = visionJson?.responses?.[0];
  if (!annotation || annotation.error) {
    console.error("Cloud Vision annotation error:", annotation?.error?.code ?? "empty");
    return jsonResponse({ error: "OCR service error" }, 502);
  }

  const fullText: string = typeof annotation.fullTextAnnotation?.text === "string"
    ? annotation.fullTextAnnotation.text
    : "";
  const lines = groupWordsIntoRows(annotation.textAnnotations).slice(0, MAX_LINES);

  return jsonResponse({ text: fullText.slice(0, 20_000), lines }, 200);
});

// Cloud Vision returns each word as a separate annotation (element 0 is the whole-image
// blob, the rest are words with pixel bounding boxes). Receipts print names and prices in
// separate columns, so regroup words that sit on the same printed line into one string in
// reading order — the same idea as the client's `groupIntoRows`, so a name and its price
// land on one logical line for the heuristic parser.
//
// Rotation-aware: receipts are often photographed lying SIDEWAYS in the frame. Cloud
// Vision orders each word's vertices relative to the TEXT (top-left, top-right,
// bottom-right, bottom-left of the glyphs, whatever way the image is turned), so the
// average v0→v1 vector is the reading direction and v0→v3 points down the page. Words
// are grouped and sorted along those axes instead of raw image x/y, which handles
// upright, sideways, and slightly tilted receipts with the same code path.
function groupWordsIntoRows(annotations: unknown): string[] {
  if (!Array.isArray(annotations) || annotations.length < 2) return [];

  type Word = { text: string; cx: number; cy: number; height: number };
  const words: Word[] = [];
  let alongX = 0, alongY = 0, downX = 0, downY = 0;
  for (const raw of annotations.slice(1)) {
    const a = raw as { description?: unknown; boundingPoly?: { vertices?: { x?: number; y?: number }[] } };
    if (typeof a.description !== "string" || !a.description.trim()) continue;
    const v = a.boundingPoly?.vertices ?? [];
    if (v.length < 4) continue;
    const px = (i: number) => v[i].x ?? 0;
    const py = (i: number) => v[i].y ?? 0;
    alongX += px(1) - px(0);
    alongY += py(1) - py(0);
    downX += px(3) - px(0);
    downY += py(3) - py(0);
    words.push({
      text: a.description,
      cx: (px(0) + px(1) + px(2) + px(3)) / 4,
      cy: (py(0) + py(1) + py(2) + py(3)) / 4,
      height: Math.hypot(px(3) - px(0), py(3) - py(0)),
    });
  }
  if (words.length === 0) return [];

  // Normalized text axes (fall back to upright if degenerate).
  const alongLen = Math.hypot(alongX, alongY);
  const downLen = Math.hypot(downX, downY);
  const along = alongLen > 0 ? [alongX / alongLen, alongY / alongLen] : [1, 0];
  const down = downLen > 0 ? [downX / downLen, downY / downLen] : [0, 1];
  // Position of each word along the reading direction and down the page.
  const pos = (w: Word) => w.cx * along[0] + w.cy * along[1];
  const line = (w: Word) => w.cx * down[0] + w.cy * down[1];

  // Same-row tolerance from the receipt's actual print size: half the median word height
  // tracks the framing (close-up vs far away) instead of a fixed pixel count.
  const heights = words.map((w) => w.height).sort((a, b) => a - b);
  const medianHeight = heights[Math.floor(heights.length / 2)];
  const rowTolerance = Math.max(4, medianHeight * 0.5);

  // Top of the page to the bottom. Compare against the running average of the row so a
  // slightly tilted receipt doesn't fragment one printed line into several rows.
  words.sort((a, b) => line(a) - line(b));
  const rows: Word[][] = [];
  for (const word of words) {
    const row = rows[rows.length - 1];
    if (row) {
      const rowLine = row.reduce((sum, w) => sum + line(w), 0) / row.length;
      if (Math.abs(rowLine - line(word)) < rowTolerance) {
        row.push(word);
        continue;
      }
    }
    rows.push([word]);
  }

  return rows.map((row) =>
    row.sort((a, b) => pos(a) - pos(b)).map((w) => w.text).join(" ")
  );
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

type ImagePayload =
  | { data: string; mimeType: string }
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

  return { data, mimeType };
}
