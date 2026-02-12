import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// CORS headers for public access
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const token = url.searchParams.get("token");

  if (!token) {
    return new Response("Missing token parameter", {
      status: 400,
      headers: corsHeaders
    });
  }

  // Validate token format (UUID)
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidRegex.test(token)) {
    return new Response("Invalid token format", {
      status: 400,
      headers: corsHeaders
    });
  }

  const deepLink = `payback://link/claim?token=${token}`;

  // Use 302 redirect directly to the deep link
  // This works on mobile when the app is installed
  return new Response(null, {
    status: 302,
    headers: {
      ...corsHeaders,
      Location: deepLink
    }
  });
});
