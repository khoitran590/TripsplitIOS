# parse-receipt Edge Function

Server-side proxy for the receipt-parsing LLM call. The app sends the receipt image plus
the signed-in user's Supabase JWT; this function authenticates the user, rate-limits them,
calls Gemini with a **server-side** key, and returns structured JSON. The Gemini API key is
never in the app binary. A legacy OCR `text` payload is still accepted for compatibility.
The app normally runs cloud OCR, sends its text plus the image to Gemini, then falls back to
its local/heuristic parser if either online step fails.

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
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are injected
   automatically — do not set or expose them in the app.

3. **Apply the Track D migration.** Run
   `supabase/migrations/20260717000000_track_d_ai_rate_limits.sql` in the SQL editor (or
   re-run `supabase_schema.sql`, which is idempotent).

4. **Deploy all three functions together** after the migration (`verify_jwt = true` is
   enforced via `supabase/config.toml`). The RPC signature and functions are a lockstep
   contract:
   ```sh
   supabase functions deploy parse-receipt ocr-receipt suggest-itinerary
   ```

## Verify

```sh
# Should be 401 (no user token):
curl -i -X POST "https://ttgwzwvlochpvtxrxkoz.supabase.co/functions/v1/parse-receipt" \
  -H "apikey: <anon-key>" -H "Content-Type: application/json" \
  -d '{"imageBase64":"<base64-jpeg>","mimeType":"image/jpeg"}'
```
A signed-in request from the app returns the structured receipt JSON. On 429, the response
contains `feature`, `limit`, `remaining`, `windowSeconds`, and `retryAfterSeconds`, plus a
`Retry-After` header. The app falls back to local receipt parsing and explains that the AI
limit was reached.

## Security notes
- Only a real signed-in user is accepted (`verify_jwt` + explicit `/auth/v1/user` check —
  the anon key alone is rejected).
- Feature-local per-user limits are enforced atomically by service-role-only reservation /
  completion RPCs: OCR is 20 successful calls/minute, receipt parsing is 15 successful
  calls/minute, and itinerary generation is 10 successful calls/5 minutes.
- **Receipt accounting unit:** one function invocation. A normal full scan intentionally
  uses one OCR unit and one parse unit because it performs paid work in both providers, but
  those units live in separate buckets and cannot halve or starve each other's allowance.
- Capacity is reserved before the paid call so concurrent requests cannot exceed a limit.
  The reservation is committed only on success and deleted on upstream/config failure;
  abandoned reservations expire after a short lease.
- The usage RPCs are not executable by `authenticated` or `anon`; only the Edge Functions'
  injected service role can call them after validating the user's JWT.
- Input is size-capped; receipt images/text are never logged; the upstream error body is never
  echoed to clients.
- Edge Functions emit structured JSON logs for `success`, `rate_limited`,
  `rate_check_failure`, `post_call_failure`, and accounting failures. Filter by `function`,
  `kind`, and `outcome` in Supabase logs to retune limits.
