# Audio Box From Jaani

Text-to-speech studio by **Nigraan TV**. Type text, get audio — the same
Gemini voices the website uses (Aoede / Charon) plus the free Edge voices
(Asad / Uzma). Earn coins by watching Unity rewarded ads, spend coins on
audio generation.

- Package: `com.nigraantv.audiobox`
- App name: **Audio Box From Jaani**
- Developer: Nigraan TV
- Default language: English, Urdu second (same as nigraantv.xyz)
- Version: 1.0.0+1

## The strategy (read this first)

These apps exist to **grow the nigraantv.xyz audience**. Audio Box funnels
users to website articles:

1. The app shows a **live news ticker** and a **latest-articles list** from
   the site's RSS feed.
2. Tapping an article opens the **FULL article page**
   (`nigraantv.xyz/article/<id>/`) in an in-app WebView — the real page,
   JavaScript fully enabled, **including the website's own banner ads**.
   No reader mode, nothing stripped. The visit counts as a genuine website
   visit and the site earns from those banner impressions.
3. **Reading earns the user NOTHING — no coins for reading news** (unlike
   TJ Earn). Reading is free value that sends traffic to the website.
   Only *generating* audio (TTS) costs coins, because generation consumes
   Gemini quota.

## Coin economy

| Action | Coins |
|---|---|
| Daily free claim (once per day) | +100 |
| One audio generation (~1 minute chunk) | −50 (coins per minute, remote config) |
| Watch rewarded ads (one tap, ads back-to-back) | +50 for 2 ads (default option) |

- Rewarded options come from the remote config — new options are addable
  later without a rebuild (each option: `label`, `ads_required`, `coins`).
- Coins buy **in-app audio generation only**. They are never cash and can
  never be withdrawn. (That is why this model is Unity-policy-safe, unlike
  TJ Earn's cash-out.)
- Daily generation cap: `tts.daily_cap` (default 10/day, 0 = unlimited).
- Repeat generation of the same text + voice is **free** (on-device cache).

## Remote control — `audio-box.json` (admin panel)

The app fetches its remote config on launch and every ~60s from one fixed
URL (fail-soft: cached config + bundled defaults when offline):

```
https://nigraantv.xyz/apps/config/audio-box.json
```

**Live since 15 Nov 2026** at that URL (deploy c6ebd450). Until the app
can reach it, it runs on the bundled defaults (same values as the
example below). Every key below is changeable from the website with no
app rebuild, and takes effect immediately while the app is online —
except a changed Unity Game ID, which takes effect on the next app
launch (the Unity SDK initialises once at startup).

```json
{
  "ads_enabled": true,
  "banners": {
    "home": true,
    "tts_studio": true,
    "tools": true,
    "briefing": true,
    "speech_writer": true,
    "converter": true,
    "my_audio": true,
    "coins": true
  },
  "app_open_ad": { "enabled": true },
  "rewarded": {
    "enabled": true,
    "options": [
      { "id": "ads2", "label": "Watch 2 ads — get 50 coins", "ads_required": 2, "coins": 50 }
    ]
  },
  "sponsored_ad": {
    "enabled": false,
    "title": "",
    "body": "",
    "action_url": "",
    "image_url": ""
  },
  "announcement": { "enabled": false, "text": "" },
  "tts": {
    "gemini_enabled": true,
    "edge_enabled": true,
    "voices": ["aoede", "charon", "asad", "uzma"],
    "coins_per_minute": 50,
    "daily_cap": 10,
    "proxy_url": "https://nigraan-tv-tts-proxy.mithubhattijani.workers.dev"
  },
  "unity": {
    "game_id": "800438808",
    "rewarded_placement_id": "BP_Rewarded_Android",
    "banner_placement_id": "BP_Banner_Android",
    "app_open_placement_id": "BP_Interstitial_Android"
  },
  "feeds": {
    "rss_url": "https://nigraantv.xyz/rss.xml",
    "briefing_json_url": "https://nigraantv.xyz/briefing.json",
    "briefing_mp3_url": "https://nigraantv.xyz/briefing.mp3"
  },
  "splash": { "image_url": "" },
  "ticker": { "direction": "from_left" }
}
```

Rules:

- `ads_enabled` — master switch for ALL Unity ads.
- `banners.<zone>` — a banner shows only when the master switch is on AND
  its zone key is true (same pattern as TJ Earn/Doner).
- `rewarded.options` — each option plays its `ads_required` ads
  back-to-back from one tap and grants `coins` only if ALL ads complete.
- `sponsored_ad` — the card shows ONLY when `enabled=true` AND `title`
  AND `action_url` are both non-empty (the exact verified TJ Earn rule).
  `image_url` is optional. Tap opens `action_url` in the external browser.
- `announcement` — the bar shows only when `enabled=true` AND `text` is
  non-empty.
- `tts` — which voices are offered, Gemini vs Edge on/off, coins per
  minute, daily cap, and the proxy URL (`proxy_url`). **Gemini API keys
  are NEVER in the app or this config** — they live server-side in the
  TTS proxy Worker only (adding keys 5–6 later is a Worker secret
  update, no app rebuild).
- `unity` — the Unity Game ID and all three placement IDs. Change them
  here, no rebuild. A changed Game ID applies on the next app launch;
  placement IDs on the next ad load.
- `feeds` — the RSS feed and briefing JSON/MP3 URLs (ticker, article
  list, briefing). Change them here, no rebuild.
- `splash` — `image_url` sets a remote splash poster (empty = the
  bundled poster). Applies from the next app launch; the bundled poster
  stays as the offline/broken-link fallback.
- `ticker.direction` — `'from_left'` (default: text enters from the
  left, moves right — the Nigraan Urdu-ticker house style) or
  `'from_right'` (old direction). Applies within seconds while the app
  is online, no rebuild.
- **Version is NOT in this config.** Version checks use the separate fixed
  URL below — one source of truth, same as TJ Earn.

## In-app update — `audio-box-version.json`

The app checks ONE single fixed version URL on **every launch** (TJ Earn's
pattern, copied precisely — same JSON fields, same check-on-launch
behaviour):

```
https://nigraantv.xyz/apps/audio-box-version.json
```

**Live since 15 Nov 2026** at that URL. Same fields as TJ Earn's
`tj-earn-version.json`, plus one additive field for force-update:

```json
{
  "versionCode": 3,
  "versionName": "1.0.2",
  "url": "https://drive.google.com/uc?export=download&id=1ijdr6IG_rSUQLKkM6Z09wo3IERZrLcQ5",
  "notes": "Ticker scrolls from the left; voices renamed to Billo / Jaani with no provider names shown; Download button after generation (1 rewarded ad).",
  "minVersionCode": 1
}
```

The live file points at the Drive download link (the GitHub release
URL is kept for later, once a signed release build exists). The app
opens the URL in the external browser — the browser downloads the APK
and the user taps the finished download to install. Same package +
higher versionCode = update, data kept. From v1.0.1 on, updates arrive
inside the app itself — no more chat links to install.

- `versionCode` / `versionName` / `url` / `notes` — same as TJ Earn.
- `minVersionCode` (optional, default 0 = no force): installed builds
  below it get a **force-update dialog that blocks use** until updated.
  Below latest but above min → optional prompt (Later / Update Now).
  "Later" dismisses that versionCode once; a newer versionCode prompts
  again. Unreachable manifest → silent, app works normally.
- One deliberate deviation from TJ Earn: the download. TJ Earn downloads
  the APK in-app via Android DownloadManager (native MethodChannel +
  receiver). v1 opens the APK URL in the external browser instead — the
  browser downloads it and the user taps the finished download to install
  (same package + higher versionCode = update, data kept). Porting the
  DownloadManager flow is a follow-up; the check, the dialogs and the
  JSON contract are identical.

## News feed (ticker + articles)

- Feed: **`https://nigraantv.xyz/rss.xml`** — declared by the site itself
  (`working-site/index.html` line 13:
  `<link rel="alternate" type="application/rss+xml" title="Nigraan TV News RSS" href="https://nigraantv.xyz/rss.xml" />`,
  `deploy/dist/rss.xml` exists) and verified live (real RSS 2.0,
  title/link/description/pubDate/category per item).
- The ticker, the article list and Article Listen all read this ONE feed.
  The ticker re-fetches every 5 minutes; the article list caches for
  5 minutes.
- Fallback: if the feed is unreachable the ticker shows a placeholder and
  the article list shows "Could not load news right now." — no homepage
  scraping fallback was needed (the feed works).
- Tapping an article opens `ArticleWebViewScreen`: a `webview_flutter`
  WebView with `JavaScriptMode.unrestricted`, loading the real article
  URL. Full page, ads included, no reader mode. External links open in
  the system browser.

## TTS — how it works

- Proxy: `https://nigraan-tv-tts-proxy.mithubhattijani.workers.dev`
  - `POST /tts` — Gemini, voices Aoede/Charon, `{text, voice, lang}`,
    max 2000 chars, returns base64 audio (`wav` or `pcm24k` — PCM gets a
    WAV header, same conversion the website does).
  - `POST /edge-tts` — Edge, voices `ur-PK-AsadNeural` / `ur-PK-UzmaNeural`,
    max 600 chars (~1 min), returns MP3 bytes, 10 min/day per IP cap.
- Chunking: longer text splits into ~1-minute chunks (Gemini 1500 chars,
  Edge 550 chars); each chunk costs the per-minute price.
- **Fallback:** if the Gemini call fails (quota/429/any error) the app
  automatically retries with the same-gender free Edge voice and tells
  the user. If Gemini is disabled remotely, Edge is used directly.
- Cache: same text + voice + language always returns the same file, so
  repeats are free and quota-free.
- **Display names (15 Nov 2026):** the app NEVER shows provider or
  model names — the voices are shown as **Billo** (female), **Jaani**
  (male), **Asad**, **Uzma**. The API voice IDs (Aoede/Charon/AsadNeural/
  UzmaNeural) are internal only.
- **Download (15 Nov 2026):** after generation (TTS Studio results) and
  in My Audio, each audio has a Download button + Share. Download plays
  ONE rewarded video ad first, then saves the file to the phone's
  Download folder. If ads are off or no ad is available, it downloads
  directly; if the user skips the ad, nothing downloads. See
  `lib/services/audio_download_service.dart`.

## MP3 Converter

There is no light on-device WAV→MP3 encoder, so v1 converts by
**re-generating the same words via the Edge endpoint, which returns real
MP3 bytes** (same-gender Edge voice). Conversion itself is free (Edge
voices are free); long texts convert into one MP3 per 550-char part.
A future option is an ffmpeg-based encoder (heavy, ~30 MB+); not in v1.

## Screens

| Screen | What it does |
|---|---|
| Home | Live ticker, announcement, sponsored card, balance, tools grid, latest articles |
| TTS Studio | Text → audio (voice picker, Urdu/English, cost preview, player) |
| Coins | Balance, daily 100 claim, rewarded options from config |
| My Audio | Saved audios: play, download, share, convert to MP3, delete |
| Article Listen | RSS articles; Read (free, WebView) / Listen (normal coin cost) |
| News Briefing | Hourly briefing audio (`briefing.json` + `briefing.mp3`), free |
| Speech Writer | Topic → easy Urdu speech (v1: local templates), send to TTS Studio |
| MP3 Converter | Convert saved WAV audios to MP3 (Edge re-generation) |

Every screen has a passive Unity banner (bottom, 50px, never covering
content/buttons), gated by its zone key + the master switch. AppOpen ad
on cold start when `app_open_ad.enabled`.

## Unity setup (TODO before any public build)

1. Create a NEW Unity project **"Audio Box From Jaani"** at
   https://cloud.unity.com — do NOT reuse TJ Earn's Game ID (800417967).
2. Create placements: Rewarded (e.g. `BP_Rewarded_Android`), Banner
   (e.g. `BP_Banner_Android`), App Open (e.g. `BP_AppOpen_Android`).
3. In `lib/services/ads_service.dart` replace the three `REPLACE_ME`
   constants with the real IDs and set `testMode = false`.
4. Until then the app runs with ads safely inert (no crash, no empty
   banner space) — the banner widget renders nothing and the Coins
   screen explains ads are being set up.

## Supabase (follow-up: deploy the functions)

- Project: **tj-earn** (`https://znyaxxkhhopdqrvxhxmb.supabase.co`, same
  project as TJ Earn). The app uses the same public anon key as TJ Earn,
  passed at build time:
  `--dart-define=SUPABASE_ANON_KEY=<same value as TJ Earn>`.
  The URL has a built-in default; the anon key must be supplied or the
  app runs local-only (coins on-device, clearly stated in the UI).
- Auth: **anonymous sign-in** (no email/password in v1). Enable
  "Anonymous sign-ins" in Supabase Auth → Providers before using the
  server ledger.
- Edge Functions in `supabase/functions/` (code ready, NOT deployed yet):
  `audiobox-daily-coins`, `audiobox-claim-ad-reward`,
  `audiobox-spend-coins`, `audiobox-get-balance` (+ `_shared/cors.ts`).
  They reuse TJ Earn's `ledger` table + `app_config` keys
  (`audiobox_daily_coins`, `audiobox_reward_coins`,
  `audiobox_reward_daily_cap`) and the same anti-abuse rules
  (JWT auth, daily caps, 30s minimum between claims, idempotency keys).
  Deploy with:
  `supabase functions deploy <name> --project-ref znyaxxkhhopdqrvxhxmb`
- v1 behaviour: local balance is the source of truth in the UI; every
  local change is also sent to the server (best-effort) and the server
  balance wins on sync once the functions are live.

## Build

```sh
flutter pub get
flutter analyze
flutter build apk --debug \
  --dart-define=SUPABASE_URL=https://znyaxxkhhopdqrvxhxmb.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<same public anon key as TJ Earn>
```

CI (`.github/workflows/build-apk.yml`): builds a **release APK** on push to
`main` (public repo = free Actions) and uploads it as an artifact.
Release signing is LIVE since 15 Nov 2026: the keystore
(`android/app/audiobox-release.keystore.enc`, AES-256 encrypted, passphrase in the
`KEYSTORE_PASSPHRASE` repo secret) is decrypted in CI and every release
build is signed with the same permanent key — installed apps update
without uninstalling. The plaintext keystore is gitignored and backed up
outside the repo; never commit it.

## Files

```
pubspec.yaml                  deps (same versions as TJ Earn + audioplayers, url_launcher, package_info_plus, webview_flutter)
lib/main.dart                 entry: locale, coins preload, MainShell
lib/config.dart               public URLs + --dart-define config
lib/theme.dart                Nigraan red #EF0017 / blue #3D5AFE
lib/l10n/strings.dart         EN/UR strings (English default)
lib/models/                   tts_voice.dart, audio_item.dart
lib/services/
  tts_service.dart            proxy calls, chunking, PCM→WAV, cache, Gemini→Edge fallback
  coins_service.dart          local balance, daily claim, daily cap, server sync
  ads_service.dart            Unity init/rewarded/AppOpen + zone-gated banner widget
  remote_config_service.dart  audio-box.json: cache -> network, 60s poll
  updater_service.dart        fixed version URL check (TJ Earn pattern)
  supabase_service.dart       init, anonymous auth, function invokes
  audio_library_service.dart  on-device audio library + MP3 conversion
  briefing_service.dart       briefing.json (defensive parse)
  rss_service.dart            rss.xml fetch/parse + relative time
lib/screens/                  main_shell, home, tts, coins, my_audio, converter,
                              article_listen, article_webview, briefing, speech_writer
lib/widgets/                  audio_player_bar, news_ticker
android/                      package com.nigraantv.audiobox, launcher icon
supabase/functions/           audiobox-daily-coins, audiobox-claim-ad-reward,
                              audiobox-spend-coins, audiobox-get-balance
.github/workflows/build-apk.yml
```

## Known v1 limits / follow-ups

- No Flutter SDK on the build VM: code is written against the verified
  plugin APIs (same versions as TJ Earn) but **not compiled yet** — run
  `flutter analyze` + the CI build first; fix whatever it reports.
- Update download opens the APK URL in the browser (see "In-app update").
- Release builds are signed with the permanent key (see "Build") — the
  first release-signed build (v1.0.1) needs a one-time uninstall of any
  debug-signed install, because Android refuses to update an app when
  the signing key changes. After that, in-app updates install directly.
- Supabase Edge Functions written but not deployed; anonymous sign-ins
  must be enabled in the dashboard first.
- Unity Game ID + placements are `REPLACE_ME` (see "Unity setup").
- `audio-box.json` and `audio-box-version.json` do not exist on the
  website yet — create them (schemas above) as a follow-up step.
- Article Listen reads title + RSS excerpt (full article bodies live in
  the site SPA; full-text fetch is a follow-up).
- Speech Writer uses local templates in v1 (AI-written speeches later).
- No tests yet (`flutter test` step intentionally omitted from CI).
- The proxy's Gemini `/tts` path has no per-user daily cap yet — Article
  Listen is coin-gated in the app, but a proxy-side cap is a follow-up.
