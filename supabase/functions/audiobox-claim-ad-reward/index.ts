import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

/// Claim coins for completing Unity rewarded video ads (Audio Box).
///
/// The app shows the ads via the Unity Ads SDK (placements from the
/// Audio Box Unity project). When ALL ads of one option complete, the
/// app calls this function. Coins are credited server-side (service
/// role) — the app never writes to the ledger.
///
/// Rewards are coins (virtual currency spent on in-app audio), never
/// cash — per Unity policy.
///
/// Anti-abuse (same pattern as TJ Earn's claim-unity-reward):
/// - JWT auth (401 if invalid)
/// - Reward amount from app_config audiobox_reward_coins (default 50)
///   — the amount NEVER comes from the client
/// - Daily cap from app_config audiobox_reward_daily_cap (default 50)
/// - Minimum 30 seconds between claims (429 if too soon)
/// - Idempotent ledger entries via idempotency_key (409 on replay)
///
/// NOTE: the app's rewarded options (remote config) must match
/// audiobox_reward_coins. If the admin adds an option with a different
/// coin amount, update app_config too — the server always wins.
///
/// Deploy (follow-up step — not deployed yet):
///   supabase functions deploy audiobox-claim-ad-reward --project-ref znyaxxkhhopdqrvxhxmb
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
    .in('key', ['audiobox_reward_coins', 'audiobox_reward_daily_cap']);

  const cfg: Record<string, string> = {};
  for (const r of cfgRows ?? []) cfg[r.key] = r.value;

  const rewardCoins = parseInt(cfg['audiobox_reward_coins'] ?? '50', 10);
  const dailyCap = parseInt(cfg['audiobox_reward_daily_cap'] ?? '50', 10);

  if (rewardCoins <= 0) {
    return json({ error: 'disabled' }, 200);
  }

  const today = new Date().toISOString().split('T')[0];
  const now = new Date();

  const { data: todayEntries, error: countError } = await supabase
    .from('ledger')
    .select('id, created_at')
    .eq('user_id', user.id)
    .eq('type', 'audiobox_reward')
    .gte('created_at', `${today}T00:00:00Z`)
    .order('created_at', { ascending: false });

  if (countError) {
    return json({ error: 'db_error' }, 500);
  }

  const usedToday = (todayEntries ?? []).length;
  if (usedToday >= dailyCap) {
    return json({ error: 'cap_reached', remaining: 0, cap: dailyCap }, 409);
  }

  const lastEntry = (todayEntries ?? [])[0];
  if (lastEntry) {
    const elapsedSec =
      (now.getTime() - new Date(lastEntry.created_at).getTime()) / 1000;
    if (elapsedSec < 30) {
      return json({
        error: 'too_soon',
        retry_after_seconds: Math.ceil(30 - elapsedSec),
      }, 429);
    }
  }

  const idemKey =
    `audiobox_reward:${user.id}:${today}:${usedToday + 1}:${Math.floor(now.getTime() / 30000)}`;

  const { data, error: insertError } = await supabase
    .from('ledger')
    .insert({
      user_id: user.id,
      amount_coins: rewardCoins,
      type: 'audiobox_reward',
      provider: 'unity_ads',
      ref_id: 'placement:BP_Rewarded_Android',
      idempotency_key: idemKey,
    })
    .select('id')
    .single();

  if (insertError) {
    if ((insertError as { code?: string }).code === '23505') {
      return json({
        ok: true,
        coins: rewardCoins,
        remaining: dailyCap - usedToday - 1,
        duplicate: true,
      }, 200);
    }
    return json({ error: 'db_error' }, 500);
  }

  return json({
    ok: true,
    coins: rewardCoins,
    remaining: dailyCap - usedToday - 1,
    id: data.id,
  }, 200);
});
