/**
 * Cloudflare Worker — email open tracking
 *
 * Routes:
 *   GET /o/{token}          → returns 1x1 transparent GIF, logs open to KV
 *   GET /opens?token=SECRET → returns JSON array of all opens (for sync script)
 *
 * Required:
 *   KV namespace bound as OPENS_KV in Worker settings
 *   STATS_TOKEN secret — a password to protect the /opens endpoint
 *
 * Setup: see workers/DEPLOY.md
 */

// 1x1 transparent GIF (base64)
const PIXEL_B64 =
  "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";

function b64toBytes(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // ── GET /o/{token} — tracking pixel ──────────────────────────────────
    if (request.method === "GET" && path.startsWith("/o/")) {
      const token = path.slice(3);
      if (token && env.OPENS_KV) {
        try {
          const existing = await env.OPENS_KV.get(token, { type: "json" });
          const now = new Date().toISOString();
          await env.OPENS_KV.put(
            token,
            JSON.stringify({
              first_open: existing?.first_open ?? now,
              last_open:  now,
              count:      (existing?.count ?? 0) + 1,
            }),
            { expirationTtl: 60 * 60 * 24 * 365 } // 1 year
          );
        } catch (e) {
          console.error("KV write error:", e);
        }
      }

      return new Response(b64toBytes(PIXEL_B64), {
        status: 200,
        headers: {
          "Content-Type":  "image/gif",
          "Cache-Control": "no-store, no-cache, must-revalidate",
          "Pragma":        "no-cache",
        },
      });
    }

    // ── GET /opens?token=SECRET — stats export ────────────────────────────
    if (request.method === "GET" && path === "/opens") {
      const providedToken = url.searchParams.get("token") || "";
      const statsToken    = env.STATS_TOKEN || "";

      if (!statsToken || providedToken !== statsToken) {
        return new Response("Unauthorized", { status: 401 });
      }

      if (!env.OPENS_KV) {
        return new Response(JSON.stringify([]), {
          headers: { "Content-Type": "application/json" },
        });
      }

      try {
        const list = await env.OPENS_KV.list();
        const results = [];
        for (const key of list.keys) {
          const val = await env.OPENS_KV.get(key.name, { type: "json" });
          results.push({ token: key.name, ...val });
        }
        return new Response(JSON.stringify(results, null, 2), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: String(e) }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    return new Response("Not Found", { status: 404 });
  },
};
