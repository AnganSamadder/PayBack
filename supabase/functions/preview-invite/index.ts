import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Read token from request body (POST) or search params (GET)
    const url = new URL(req.url);
    let token = url.searchParams.get("token");

    if (!token && req.method === "POST") {
      try {
        const body = await req.json();
        token = body.token;
      } catch (e) {
        // ignore JSON parse error, token might be null
      }
    }

    if (!token) {
      throw new Error("Missing token parameter");
    }

    // 1. Validate Token
    const { data: tokens, error: tokenError } = await supabaseClient
      .from("invite_tokens")
      .select("*")
      .eq("id", token)
      .limit(1);

    if (tokenError) throw tokenError;
    if (!tokens || tokens.length === 0) throw new Error("Invalid token");

    const inviteToken = tokens[0];

    // Check expiry/claimed
    // Note: Clients handle this logic too, but good to enforce here.
    // However, for valid token but expired, we might still want to return data with error flag?
    // Let's just return the data and let client decide validation status,
    // OR enforce here. Enforcing here is safer.
    if (new Date(inviteToken.expires_at) <= new Date()) throw new Error("Invite link has expired");
    if (inviteToken.claimed_by) throw new Error("Invite link already claimed");

    const targetMemberId = inviteToken.target_member_id;

    // 2. Fetch Expenses involving this member
    // Logic: involved_member_ids contains targetMemberId OR paid_by_member_id == targetMemberId
    const { data: expenses, error: expenseError } = await supabaseClient
      .from("expenses")
      .select("*")
      .or(`involved_member_ids.cs.{${targetMemberId}},paid_by_member_id.eq.${targetMemberId}`);

    if (expenseError) throw expenseError;

    // 3. Fetch Groups for names and type (direct vs group)
    // We need group IDs from expenses
    const groupIds = [...new Set(expenses.map((e: any) => e.group_id))];

    let groups: any[] = [];
    if (groupIds.length > 0) {
      const { data: groupData, error: groupError } = await supabaseClient
        .from("groups") // Table name check: usually 'groups' or 'spending_groups'?
        // In schema.sql it is 'groups'.
        .select("id, name, is_direct")
        .in("id", groupIds);
      if (groupError) throw groupError;
      groups = groupData;
    }

    return new Response(
      JSON.stringify({
        token: inviteToken,
        expenses: expenses,
        groups: groups
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      }
    );
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" }
    });
  }
});
