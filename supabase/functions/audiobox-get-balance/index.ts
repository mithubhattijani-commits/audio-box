import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

/// Server balance for Audio Box (SUM of the caller's ledger rows).
/// The app uses this as the source of truth once the functions are
/// deployed; until then it runs on its local balance.
///
/// Deploy (follow-up step — not deployed yet):
///   supabase functions deploy audiobox-get-balance --project-ref znyaxxkhhopdqrvxhxmb
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const authHeader = req.headers.get('Authorization') ?? '';
  const { data: { user }, error: authError } = await supabase.auth.getUser(
    authHeader.replace('Bearer ', ''),
  );
  if (authError || !user) {
    return json({ error: 'unauthorized' }, 401);
  }

  const { data: rows, error } = await supabase
    .from('ledger')
    .select('amount_coins')
    .eq('user_id', user.id);
  if (error) {
    return json({ error: 'db_error' }, 500);
  }

  const balance = (rows ?? []).reduce(
    (sum: number, r: { amount_coins: number }) => sum + r.amount_coins,
    0,
  );
  return json({ balance_coins: balance }, 200);
});
