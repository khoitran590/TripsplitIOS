// Deterministic provider responses for local Edge Function smoke tests.
//
// This switch is deliberately ignored unless Supabase exposes an HTTP-only local
// runtime origin. A mistakenly deployed LOCAL_PROVIDER_MOCKS=true therefore cannot
// replace paid providers in a hosted HTTPS environment.
export function localProviderMocksEnabled(): boolean {
  if (Deno.env.get("LOCAL_PROVIDER_MOCKS") !== "true") return false;

  const rawURL = Deno.env.get("SUPABASE_URL") ?? "";
  try {
    const url = new URL(rawURL);
    const localHosts = new Set([
      "127.0.0.1",
      "localhost",
      "::1",
      "host.docker.internal",
      "kong",
      "supabase_kong_tripsplit",
    ]);
    return url.protocol === "http:" && localHosts.has(url.hostname);
  } catch {
    return false;
  }
}
