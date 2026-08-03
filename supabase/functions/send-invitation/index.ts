// Authenticated invitation email delivery. Raw invitation tokens exist only inside this
// function and the recipient's HTTPS link; the iOS client receives a generic response.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const INVITATION_BASE_URL = Deno.env.get("INVITATION_BASE_URL") ?? "";
const INVITATION_FROM_EMAIL = Deno.env.get("INVITATION_FROM_EMAIL") ?? "";

const JSON_HEADERS = { "Content-Type": "application/json; charset=utf-8" };
const EMAIL_PATTERN = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}$/i;

type DeliveryInvitation = {
  invitation_id: string;
  token: string;
  trip_name: string;
  inviter_name: string;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY ||
      !RESEND_API_KEY || !INVITATION_BASE_URL || !INVITATION_FROM_EMAIL) {
    console.error(JSON.stringify({ function: "send-invitation", outcome: "missing_configuration" }));
    return json({ error: "Invitations are temporarily unavailable." }, 503);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  const actorID = await currentUserID(authorization);
  if (!actorID) return json({ error: "Unauthorized" }, 401);

  let payload: { tripID?: unknown; email?: unknown };
  try {
    payload = await request.json();
  } catch {
    return json({ error: "Invalid request" }, 400);
  }
  const tripID = typeof payload.tripID === "string" ? payload.tripID : "";
  const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
  if (!isUUID(tripID) || email.length > 254 || !EMAIL_PATTERN.test(email)) {
    return json({ error: "Enter a valid email address." }, 400);
  }

  try {
    const invitation = await createInvitation(actorID, tripID, email);
    // A missing row means a block suppressed delivery. Return the same result as a sent
    // message so this endpoint does not expose whether the email belongs to an account.
    if (!invitation) return json({ pending: true }, 202);

    const link = invitationURL(invitation.token);
    const delivered = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: INVITATION_FROM_EMAIL,
        to: [email],
        subject: `${invitation.inviter_name} invited you to ${invitation.trip_name}`,
        text: `${invitation.inviter_name} invited you to join ${invitation.trip_name} in TripSplit. This invitation expires in 72 hours. Open: ${link}`,
        html: invitationHTML(invitation, link),
      }),
    });
    if (!delivered.ok) {
      await revokeInvitation(invitation.invitation_id);
      console.error(JSON.stringify({ function: "send-invitation", outcome: "provider_failure", status: delivered.status }));
      return json({ error: "Invitation could not be sent. Please try again." }, 502);
    }
    console.log(JSON.stringify({ function: "send-invitation", outcome: "success" }));
    return json({ pending: true }, 202);
  } catch (error) {
    console.error(JSON.stringify({
      function: "send-invitation",
      outcome: "failure",
      error: error instanceof Error ? error.message : "unknown",
    }));
    return json({ error: "Invitation could not be sent. Please try again." }, 500);
  }
});

async function currentUserID(authorization: string): Promise<string | null> {
  if (!authorization.startsWith("Bearer ")) return null;
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: authorization, apikey: SUPABASE_ANON_KEY },
  });
  if (!response.ok) return null;
  const user = await response.json().catch(() => null);
  return typeof user?.id === "string" ? user.id : null;
}

async function createInvitation(actorID: string, tripID: string, email: string): Promise<DeliveryInvitation | null> {
  const response = await serviceFetch("/rest/v1/rpc/create_email_invitation_for_delivery", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ p_actor_id: actorID, p_trip_id: tripID, p_email: email }),
  });
  if (!response.ok) throw new Error(`create_invitation_${response.status}`);
  const rows = await response.json().catch(() => null);
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const row = rows[0];
  if (!isUUID(row?.invitation_id) || typeof row?.token !== "string" ||
      typeof row?.trip_name !== "string" || typeof row?.inviter_name !== "string") {
    throw new Error("create_invitation_invalid_response");
  }
  return row as DeliveryInvitation;
}

async function revokeInvitation(invitationID: string): Promise<void> {
  await serviceFetch(`/rest/v1/trip_invitations?id=eq.${encodeURIComponent(invitationID)}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ status: "revoked" }),
  }).catch(() => undefined);
}

function invitationURL(token: string): string {
  const url = new URL(INVITATION_BASE_URL);
  if (url.protocol !== "https:") throw new Error("invitation_base_url_must_be_https");
  url.searchParams.set("token", token);
  return url.toString();
}

function invitationHTML(invitation: DeliveryInvitation, link: string): string {
  return `<!doctype html><html><body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#171717">
    <h2>Join ${escapeHTML(invitation.trip_name)} on TripSplit</h2>
    <p>${escapeHTML(invitation.inviter_name)} invited you to share trip plans and expenses.</p>
    <p><a href="${escapeHTML(link)}" style="display:inline-block;padding:12px 18px;background:#6d5dfc;color:white;text-decoration:none;border-radius:10px">View invitation</a></p>
    <p>This single-use invitation expires in 72 hours. If you did not expect it, you can ignore this email.</p>
  </body></html>`;
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
  })[character] ?? character);
}

function serviceFetch(path: string, init: RequestInit): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`);
  headers.set("apikey", SUPABASE_SERVICE_ROLE_KEY);
  return fetch(`${SUPABASE_URL}${path}`, { ...init, headers });
}

function isUUID(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function json(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), { status, headers: JSON_HEADERS });
}
