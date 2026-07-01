# parse-receipt Edge Function

Server-side proxy for the receipt-parsing LLM call. The app sends only the OCR'd receipt
text plus the signed-in user's Supabase JWT; this function authenticates the user,
rate-limits them, calls Gemini with a **server-side** key, and returns structured JSON. The
Gemini API key is never in the app binary.

## One-time setup

1. **Install & link the CLI** (from the repo root):
   ```sh
   brew install supabase/tap/supabase        # or see supabase.com/docs/guides/cli
   supabase login
   supabase link --project-ref ttgwzwvlochpvtxrxkoz
   ```

2. **Store the Gemini key as a secret** (this is the only place the key lives — use the
   rotated key, not the old exposed one):
   ```sh
   supabase secrets set GEMINI_API_KEY=your_rotated_gemini_key
   # optional: pin a model (defaults to gemini-2.5-flash)
   supabase secrets set GEMINI_MODEL=gemini-2.5-flash
   ```
   `SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected automatically — do not set them.

3. **Apply the rate-limit table + function.** Run the "Receipt-scan rate limiting" section
   of `supabase_schema.sql` in the SQL editor (or re-run the whole file — it's idempotent).

4. **Deploy the function** (`verify_jwt = true` is enforced via `supabase/config.toml`):
   ```sh
   supabase functions deploy parse-receipt
   ```

## Verify

```sh
# Should be 401 (no user token):
curl -i -X POST "https://ttgwzwvlochpvtxrxkoz.supabase.co/functions/v1/parse-receipt" \
  -H "apikey: <anon-key>" -H "Content-Type: application/json" \
  -d '{"text":"COFFEE 3.50"}'
```
A signed-in request from the app returns the structured receipt JSON. If anything fails
(401/429/5xx/network), the app silently falls back to on-device parsing.

## Security notes
- Only a real signed-in user is accepted (`verify_jwt` + explicit `/auth/v1/user` check —
  the anon key alone is rejected).
- Per-user rate limit: `RATE_LIMIT` scans per `RATE_WINDOW_SECONDS`, enforced atomically by
  the `record_receipt_scan` Postgres function.
- Input is size-capped; receipt text is never logged; the upstream error body is never
  echoed to clients.
