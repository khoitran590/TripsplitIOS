// Authenticated, privileged account deletion. The gateway verifies the caller's JWT;
// this function resolves that JWT to its user, prepares application data transactionally,
// removes user-owned Storage objects, and deletes the Auth account last.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STORAGE_BUCKET = "receipts";

type AuthUser = { id: string; email?: string | null };

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error(JSON.stringify({ function: "delete-account", outcome: "missing_configuration" }));
    return json({ error: "Account deletion is temporarily unavailable." }, 503);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "Unauthorized" }, 401);

  const user = await currentUser(authorization);
  if (!user) return json({ error: "Unauthorized" }, 401);

  try {
    await prepareApplicationData(user);
    await removeStoragePrefix(user.id);
    await deleteAuthUser(user.id);
    console.log(JSON.stringify({ function: "delete-account", outcome: "success" }));
    return new Response(null, { status: 204 });
  } catch (error) {
    console.error(JSON.stringify({
      function: "delete-account",
      outcome: "failure",
      error: error instanceof Error ? error.message : "unknown",
    }));
    // The Auth user is deliberately deleted last, so a failed request can be retried.
    return json({ error: "Account deletion could not be completed. Please try again." }, 500);
  }
});

async function currentUser(authorization: string): Promise<AuthUser | null> {
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: authorization, apikey: SUPABASE_ANON_KEY },
  });
  if (!response.ok) return null;
  const value = await response.json().catch(() => null);
  return typeof value?.id === "string"
    ? { id: value.id, email: typeof value.email === "string" ? value.email : null }
    : null;
}

async function prepareApplicationData(user: AuthUser): Promise<void> {
  const response = await serviceFetch("/rest/v1/rpc/prepare_account_deletion", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ p_user_id: user.id, p_email: user.email ?? null }),
  });
  if (!response.ok) throw new Error(`prepare_application_data_${response.status}`);
  const value = await response.json().catch(() => null);
  if (value?.prepared !== true) throw new Error("prepare_application_data_invalid_response");
}

async function removeStoragePrefix(userId: string): Promise<void> {
  // Paths are flat under `<auth.uid()>/`, but delete in bounded batches so the workflow
  // remains retry-safe if an account has many files.
  for (let batch = 0; batch < 100; batch += 1) {
    const listed = await serviceFetch(`/storage/v1/object/list/${STORAGE_BUCKET}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        prefix: userId,
        limit: 100,
        offset: 0,
        sortBy: { column: "name", order: "asc" },
      }),
    });
    if (!listed.ok) throw new Error(`storage_list_${listed.status}`);
    const entries = await listed.json().catch(() => null);
    if (!Array.isArray(entries)) throw new Error("storage_list_invalid_response");

    const prefixes = entries
      .filter((entry) => typeof entry?.name === "string" && entry.id != null)
      .map((entry) => `${userId}/${entry.name}`);
    if (prefixes.length === 0) return;

    const removed = await serviceFetch(`/storage/v1/object/${STORAGE_BUCKET}`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prefixes }),
    });
    if (!removed.ok) throw new Error(`storage_remove_${removed.status}`);
  }
  throw new Error("storage_delete_batch_limit");
}

async function deleteAuthUser(userId: string): Promise<void> {
  const response = await serviceFetch(
    `/auth/v1/admin/users/${encodeURIComponent(userId)}?should_soft_delete=false`,
    { method: "DELETE" },
  );
  if (!response.ok && response.status !== 404) throw new Error(`auth_delete_${response.status}`);
}

function serviceFetch(path: string, init: RequestInit): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`);
  headers.set("apikey", SUPABASE_SERVICE_ROLE_KEY);
  return fetch(`${SUPABASE_URL}${path}`, { ...init, headers });
}

function json(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}
