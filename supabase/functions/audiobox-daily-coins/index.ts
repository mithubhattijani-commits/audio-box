import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

/// Claim the daily 100 free coins (Audio Box).
///
/// Server-side (service role): credits 100 coins once per calendar day.
/// Idempotent via idempotency_key — a second call the same day returns
/// { ok: true, already_claimed: true } instead of crediting again.
///
/// Deploy (follow-up step — not deployed yet):
///   supabase functions deploy audiobox-daily-coins --project-ref znyaxxkhhopdqrvxhxmb
/// Requires: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY in the project.
/// App_config keys (optional): audiobox_daily_coins (default 100).
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

  const { data: cfgRows } = await supabase
    .from('app_config')
    .select('key, value')
    .in('key', ['audiobox_daily_coins']);
  const cfg: Record<string, string> = {};
  for (const r of cfgRows ?? []) cfg[r.key] = r.value;
  const dailyCoins = parseInt(cfg['audiobox_daily_coins'] ?? '100', 10);

  const today = new Date().toISOString().split('T')[0];
  const idemKey = `audiobox_daily:${user.id}:${today}`;

  const { data, error } = await supabase
    .from('ledger')
    .insert({
      user_id: user.id,
      amount_coins: dailyCoins,
      type: 'audiobox_daily',
      provider: 'audio_box',
      ref_id: `daily:${today}`,
      idempotency_key: idemKey,
    })
    .select('id')
    .single();

  if (error) {
    // 23505 = unique violation on idempotency_key: already claimed today.
    if ((error as { code?: string }).code === '23505') {
      return json({ ok: true, coins: 0, already_claimed: true }, 200);
    }
    return json({ error: 'db_error' }, 500);
  }

  return json({ ok: true, coins: dailyCoins, id: data.id }, 200);
});
