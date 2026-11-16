# Audio Box From Jaani

Text-to-speech studio by **Nigraan TV**. Type text, get audio — the same
Gemini voices the website uses (Aoede / Charon) plus the free Edge voices
(Asad / Uzma). Earn coins by watching Unity rewarded ads, spend coins on
audio generation.

- Package: `com.nigraantv.audiobox`
- App name: **Audio Box From Jaani**
- Developer: Nigraan TV
- Default language: English, Urdu second (same as nigraantv.xyz)
- Version: 1.0.3+4
- **v1.0.3 (15 Nov 2026): Google sign-in required — coins are tied to a real Google account** (anonymous sessions are linked onto the same user, so existing coins survive; see "Supabase" below). Login screen appears before the app until a Google-linked session exists.
- **v1.0.3: remote-controlled ribbon bar under the Home news ticker** (`ribbon` block in `audio-box.json`: enabled / color / text / height; empty text = solid bar).
- **v1.0.3 batch 2 (15 Nov 2026): Audio & Video tools** — a dark RTL
  "آواز و ویڈیو ٹولز" screen (Home tools grid) with 4 cards: Text to
  Speech + Audio Converter (existing screens, linked) and two NEW
  caption tools — AI Caption Generator and Video Caption Maker (AI) —
  both transcribing via the proxy's new `POST /transcribe`. See
  "Audio & Video tools" below.

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
| One caption transcription (~1 minute of media) | −50 (same coins-per-minute rate, rounded up to whole minutes, min 50) |
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
  "ticker": { "direction": "from_left" },
  "ribbon": { "enabled": true, "color": "#3D5AFE", "text": "", "height": 36 }
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
- `ribbon` — the bar directly under the Home news ticker (above the
  sponsored card). `enabled` (default true), `color` hex (default
  `"#3D5AFE"`, invalid hex falls back to `#3D5AFE`), `text` (default
  `""` = solid bar only; non-empty = centered white text), `height`
  in pixels (default 36). Changeable from the website, no rebuild.
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

## Audio & Video tools (v1.0.3 batch 2)

Home tools grid → **Audio & Video Tools** (`lib/screens/audio_video_tools_screen.dart`):
dark theme, RTL layout, header "آواز و ویڈیو ٹولز", section label
"AUDIO & VIDEO", 4 dark cards (dark-red icon square, English title +
Urdu subtitle). One Unity banner, zone `tools`.

| Card | Opens |
|---|---|
| Text to Speech — متن کو آواز میں بدلیں | Existing TTS Studio screen |
| Audio Converter — آڈیو کو WAV میں بدلیں | Existing MP3 Converter screen |
| AI Caption Generator — ویڈیو کے خودکار کیپشنز + 10 اسٹائل | `caption_generator_screen.dart` |
| Video Caption Maker (AI) — خودکار کیپشن + 10 اسٹائل + SRT/ASS — ویڈیو پر پیش نظارہ | `video_caption_maker_screen.dart` |

**AI Caption Generator** — pick an audio/video file (`file_picker`;
mp3/wav/m4a/aac/ogg/flac/mp4/mov/mkv/webm/m4v), transcribe via
`POST /transcribe`, show captions with timestamps, copy them, save
as SRT. **Video Caption Maker (AI)** — pick a video (`file_picker`,
video types), same transcription, captions list + SRT download +
in-player caption preview: the video plays (`video_player`) with the
current caption line overlaid, synced to playback
position (play/pause + seek slider).

**Caption styles (v1.0.6):** both tools share one style system
(`lib/services/caption_styles.dart` + `lib/widgets/
caption_style_picker.dart` + `lib/widgets/styled_caption_text.dart`) —
11 CapCut-style looks: Nigraan Karaoke (the channel's own reel style:
the spoken word turns green #3AEC70, exactly like the Nigraan TV
reels), Bold Pop, Pop Up (the spoken word pops up big), Karaoke Fill,
Highlight Box, Typewriter, One Word, Classic, News Ticker, Spotlight,
Minimal. English + Urdu (Urdu renders RTL).
Each style card shows a LIVE animated preview; controls for position
(Top / Middle / Bottom), size (S / M / L) and highlight colour
(green / yellow / white / cyan / red / blue). The in-player preview
and the generator's preview card render the chosen style with the
spoken word highlighted. Word-by-word styles use even-split timing
(each word gets an equal share of its line — the /transcribe
endpoint returns line-level segments only, no word timestamps).
Caption lines can be edited (fix misheard words) or deleted.
Exports: plain SRT + a styled ASS file (`CaptionService.buildAss`)
that opens in CapCut and any ASS-capable editor with the chosen
colours / size / position / font (karaoke styles use ASS `{\kf}`
timing).

**Caption fonts (v1.0.6):** bundled in `assets/fonts/`, picked in the
same controls row (each font chip is labelled IN that font):
Urdu — Jameel Noori Nastaleeq Kasheeda (the channel's house font,
the same file the reel renderer uses; auto-selected when the
language is Urdu) + the phone's system font; English — Bebas Neue,
Anton, Montserrat Black, Poppins Bold + system font. The chosen font
applies to the preview and to the ASS file's Fontname. Bundled fonts
add ~14 MB to the APK (the Jameel font alone is ~13 MB).

**Coins (both caption tools, identical):** 50 coins per minute of
media — same rate as TTS generation (`tts.coins_per_minute`, remote
config, default 50), rounded UP to whole minutes, minimum 50 coins.
Charged through the EXISTING `audiobox-spend-coins` function BEFORE
transcribing (`CaptionService.transcribeCharged`); if transcription
then fails, the spend is refunded in full. Too few coins → a message
pointing the user to the Coins tab (watch ads to earn). Duration comes
from the file itself (video_player for video, audioplayers/WAV header
for audio, file-size estimate as a last resort); the cost preview
shows before the user taps Transcribe.

**Ads (both caption tools, identical):** the SRT/ASS file delivery goes
through the `AudioDownloadService` TWO-ad gate
(`downloadBytesWithTwoAds`, same private gate as `downloadWithAd`,
run twice): 2 rewarded video ads play back-to-back and BOTH must be
watched fully, then the `.srt`/`.ass` saves to the phone's Download
folder; fail-soft only when ads are off or no ad loads; if the user
skips EITHER ad, nothing is delivered and they must tap download
again and watch both ads again from the start. A notice above the
download buttons says so in the user's words: "ویڈیو ڈاؤن لوڈ کرنے
کے لیے ایڈ کو مکمل دیکھیں — اگر ایک ایڈ دیکھی اور دوسری نہ دیکھی تو
ویڈیو ڈاؤن لوڈ نہیں ہوگی۔" Copying captions is free (no ad). Viewing
the captions and the in-player preview costs no ad.

**Advertising banner + WhatsApp help (v1.0.6):** the home screen
shows an advertising banner with the chairman's photo
(`assets/images/owner.jpg`) and the line "ایڈورٹائزنگ کروانے کے لیے
رابطہ کریں" + a WhatsApp button (Rai Ghulam Jilani Bhatti,
03090808180 → https://wa.me/923090808180). A "For Help" row with
the same WhatsApp button sits at the very END of the home screen and
both caption screens, for users who need any guideline.

**MP3 Converter delivery (v1.0.3 batch 2):** conversion itself is
still free (Edge re-generation, no coins, no ad). Downloading a
converted MP3 now goes through the existing
`AudioDownloadService.downloadWithAd` — the converter screen lists
its MP3 files with a Download button each (1 rewarded ad, then the
file saves; fail-soft; skip = no delivery). No second ad flow was
written: the gate lives in one private helper (`_playRewardedAdGate`)
shared by `downloadWithAd` and `downloadBytesWithAd`.

**HONEST LIMIT — NO BURN-IN (follow-up):** neither caption tool
burns captions INTO the video file. Burning captions into video needs
server-side ffmpeg, which Cloudflare Workers cannot run. What ships
in v1.0.3–v1.0.6 is captions + SRT file + styled ASS file + styled
in-player preview only. A burned-in captioned video file needs a
server with ffmpeg (a small transcode service or a VPS/worker with
ffmpeg) — that is a separate infrastructure follow-up, not part of
this build.

## POST /transcribe (TTS proxy Worker)

`POST https://nigraan-tv-tts-proxy.mithubhattijani.workers.dev/transcribe`
— added to `~/workspace/nigraan-tv/tts-proxy/worker.js` (NOT deployed
yet — the coordinator deploys it). Same CORS rules and the same
4-key Gemini rotation pattern as `POST /tts`. **No Gemini key is ever
in the app** — keys stay server-side in the Worker only.

**Request — base64 JSON (what the app sends):**

```json
{
  "audio": "<base64 audio/video bytes>",
  "mime_type": "audio/mpeg",
  "file_name": "clip.mp3",
  "lang": "ur",
  "duration_seconds": 132
}
```

`lang` is `ur` or `en` (default `ur`); `duration_seconds` is optional.
**Multipart is also accepted** (form field `file`, optional fields
`lang` / `duration_seconds`) for non-app clients.

**Response (200):**

```json
{
  "segments": [
    {"start": 1.0, "end": 4.5, "text": "Hello world"}
  ],
  "srt": "1\n00:00:01,000 --> 00:00:04,500\nHello world\n\n",
  "duration_seconds": 132,
  "file_name": "clip.mp3",
  "model": "gemini-3.8-flash",
  "language": "ur"
}
```

**How it works:** the Worker sends the audio to a Gemini model
(`gemini-3.8-flash`, fallback `gemini-3.8-flash-lite`, same key
rotation as `/tts`, temperature 0) with a prompt asking for SRT-format
output only; the response is parsed and validated as SRT. If the
model returns plain text instead, the Worker splits it into timed
caption chunks as a fallback (sentences spread evenly over the known
duration, ~5s each when the duration is unknown).

**Limits:** max file **25 MB** (413 `file too large (max 25 MB)`),
max audio **10 minutes** (400 `audio too long (max 10 minutes)` when
`duration_seconds` is supplied and exceeds 600). Errors: 400 invalid
input, 413 too large, 500 server not configured (no keys), 502
transcription failed (all keys/models exhausted — `detail` names the
last model error).

## MP3 Converter

There is no light on-device WAV→MP3 encoder, so v1 converts by
**re-generating the same words via the Edge endpoint, which returns real
MP3 bytes** (same-gender Edge voice). Conversion itself is free (Edge
voices are free); long texts convert into one MP3 per 550-char part.
A future option is an ffmpeg-based encoder (heavy, ~30 MB+); not in v1.

## Screens

| Screen | What it does |
|---|---|
| Login | Google sign-in gate (v1.0.3): one "Sign in with Google" button; shown before MainShell until a Google-linked session exists |
| Home | Live ticker, ribbon, announcement, sponsored card, balance, tools grid, latest articles |
| TTS Studio | Text → audio (voice picker, Urdu/English, cost preview, player) |
| Coins | Balance, daily 100 claim, rewarded options from config |
| My Audio | Saved audios: play, download, share, convert to MP3, delete |
| Article Listen | RSS articles; Read (free, WebView) / Listen (normal coin cost) |
| News Briefing | Hourly briefing audio (`briefing.json` + `briefing.mp3`), free |
| Speech Writer | Topic → easy Urdu speech (v1: local templates), send to TTS Studio |
| MP3 Converter | Convert saved WAV audios to MP3 (Edge re-generation) — conversion free; Download of a converted MP3 plays 1 rewarded ad, then saves |
| Audio & Video Tools | Dark RTL 4-card screen: TTS + Converter (existing) + AI Caption Generator + Video Caption Maker (AI) |
| AI Caption Generator | Audio/video file → timed captions, copy, Save SRT (1 ad); 50 coins/min, charged before transcribing |
| Video Caption Maker (AI) | Video file → captions + SRT + in-player synced caption preview; 50 coins/min; NO burn-in (needs server ffmpeg — follow-up) |

Every screen has a passive Unity banner (bottom, 50px, never covering
content/buttons), gated by its zone key + the master switch. AppOpen ad
on cold start when `app_open_ad.enabled`.

## Unity setup (DONE 15 Nov 2026 — live)

1. Unity project **"Audio Box From Jaani"** (org TJ Earn) — Game ID
   **800438808**. Placements: Rewarded `BP_Rewarded_Android`, Banner
   `BP_Banner_Android`, App Open `BP_Interstitial_Android` (dashboard
   has no separate App Open format — same as TJ Earn).
2. Game ID + placement IDs come from the remote config
   (`audio-box.json`, `unity` block) — changing them needs NO rebuild.
   The bundled defaults in `remote_config_service.dart` are the same
   live values, so ads keep working even if the config is unreachable.
   `testMode = false` in `lib/services/ads_service.dart`.
3. If the IDs were ever unset, the app runs with ads safely inert
   (no crash, no empty banner space) — the banner widget renders
   nothing and the Coins screen explains ads are being set up.

## Supabase (functions deployed live 15 Nov 2026)

- Project: **tj-earn** (`https://znyaxxkhhopdqrvxhxmb.supabase.co`, same
  project as TJ Earn). The app uses the same public anon key as TJ Earn,
  passed at build time:
  `--dart-define=SUPABASE_ANON_KEY=<same value as TJ Earn>`.
  The URL has a built-in default; the anon key must be supplied or the
  app runs local-only (coins on-device, clearly stated in the UI).
- Auth: **Google sign-in (v1.0.3, native flow)** — `google_sign_in`
  v7 (`GoogleSignIn.instance`, `initialize(serverClientId: <Web OAuth
  client ID>)` → `authenticate()` → ID token + access token) →
  Supabase `signInWithIdToken(provider: google)` / `linkIdentityWithIdToken`.
  No web OAuth redirect, no deep-link scheme, no `google-services.json`
  (the Web client ID lives in `lib/config.dart` as
  `googleServerClientId` — set 15 Nov 2026 from the Google Cloud
  OAuth setup, project "Audio Box"; see "Google OAuth setup" below).
  The Android
  OAuth client (package `com.nigraantv.audiobox` + release SHA-1) must
  exist in the same Google Cloud project.
- Anonymous sign-in is NO LONGER automatic: it happens ONLY as the
  pre-link step (sign in anonymously, then immediately link Google
  onto the same user, preserving `user.id` and coins). The login gate
  (`lib/screens/login_screen.dart`, via `_AuthGate` in `main.dart`)
  blocks MainShell and all coin features until a Google-linked session
  exists; cancel/failure shows a message and stays on the login screen.
- Supabase dashboard prerequisites: enable **"Anonymous sign-ins"**
  AND **"Enable Manual Linking"** (Auth → Providers) — without manual
  linking, `linkIdentityWithIdToken` fails and a Google sign-in creates
  a fresh user instead of preserving the anonymous user's coins.
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

## Google OAuth setup (done 15 Nov 2026 — live values in lib/config.dart)

1. In Google Cloud Console, create TWO OAuth 2.0 clients in one project:
   - **Web application** — its client ID is already in `lib/config.dart`
     (`AppConfig.googleServerClientId`; override with
     `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>` if needed).
   - **Android** — package `com.nigraantv.audiobox`, SHA-1
     `F3:72:E2:D9:7A:EF:FC:1B:A7:34:AC:FD:BA:3A:8C:D0:BC:70:BF:05`
     (release keystore). Without it, Android sign-in fails with a
     developer-configuration error. (Also add an Android client for the
     debug key SHA-1 if debug builds must sign in.)
2. In Supabase Dashboard → Auth → Providers: enable **Google** with
   the SAME Web client ID + client secret, and turn on **"Enable
   Manual Linking"** (linking the anonymous user fails without it).
3. No `google-services.json` and no Gradle plugin change are needed.

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
lib/main.dart                 entry: locale, coins preload, login gate (_AuthGate), MainShell
lib/config.dart               public URLs + --dart-define config + Google Web client ID
lib/theme.dart                Nigraan red #EF0017 / blue #3D5AFE
lib/l10n/strings.dart         EN/UR strings (English default)
lib/models/                   tts_voice.dart, audio_item.dart
lib/services/
  tts_service.dart            proxy calls, chunking, PCM→WAV, cache, Gemini→Edge fallback
  coins_service.dart          local balance, daily claim, daily cap, server sync
  ads_service.dart            Unity init/rewarded/AppOpen + zone-gated banner widget
  remote_config_service.dart  audio-box.json: cache -> network, 60s poll
  updater_service.dart        fixed version URL check (TJ Earn pattern)
  supabase_service.dart       init (no auto-anon since v1.0.3), Google link/sign-in helpers, function invokes
  google_auth_service.dart    native Google sign-in + link-first flow, login-gate check
  audio_library_service.dart  on-device audio library + MP3 conversion
  briefing_service.dart       briefing.json (defensive parse)
  rss_service.dart            rss.xml fetch/parse + relative time
  caption_service.dart        POST /transcribe client, SRT build helpers,
                              coin cost (50/min, round up, min 50), charge-then-transcribe with refund
  audio_download_service.dart one rewarded-ad gate (_playRewardedAdGate) shared by
                              downloadWithAd (audio) + downloadBytesWithAd (SRT/bytes)
lib/screens/                  main_shell, home, tts, coins, my_audio, converter,
                              article_listen, article_webview, briefing, speech_writer,
                              login_screen, audio_video_tools_screen,
                              caption_generator_screen, video_caption_maker_screen
lib/widgets/                  audio_player_bar, news_ticker, news_ribbon
android/                      package com.nigraantv.audiobox, launcher icon
supabase/functions/           audiobox-daily-coins, audiobox-claim-ad-reward,
                              audiobox-spend-coins, audiobox-get-balance
.github/workflows/build-apk.yml
```

## Known v1 limits / follow-ups

- No Flutter SDK on the build VM: code is written against the verified
  plugin APIs (same versions as TJ Earn) but **not compiled yet** — run
  `flutter analyze` + the CI build first; fix whatever it reports.
  New in batch 2: `file_picker` (^8.0.0 caret) + `video_player`
  (^2.10.1 caret) — caret ranges so pub resolves the newest release
  the project SDK allows (file_picker 13.x needs Flutter 3.38+, so it
  is deliberately NOT pinned). The Worker `/transcribe` code WAS
  verified: `node --check` passes and a stubbed-Gemini harness
  confirmed routing, validation, SRT parsing, the plain-text fallback
  and multipart upload — but it has NOT been deployed or tested
  against live Gemini yet.
- **Burn-in follow-up (not in v1.0.3):** burning captions INTO a video
  file needs server-side ffmpeg, which Cloudflare Workers cannot run.
  The caption tools ship captions + SRT + in-player preview only. A
  captioned-video download needs a transcode server (ffmpeg on a VPS
  or a container service) — separate infrastructure work.
- Update download opens the APK URL in the browser (see "In-app update").
- Release builds are signed with the permanent key (see "Build") — the
  first release-signed build (v1.0.1) needs a one-time uninstall of any
  debug-signed install, because Android refuses to update an app when
  the signing key changes. After that, in-app updates install directly.
- Supabase Edge Functions deployed live 15 Nov 2026 (all 4 on tj-earn);
  Google provider enabled with Manual Linking ON, anonymous sign-ins
  still ON (pre-link step — see "Supabase" above).
- Unity Game ID + placements come from the remote config
  (`audio-box.json`); bundled defaults are the live values (see
  "Unity setup").
- `audio-box.json` and `audio-box-version.json` are live on the website
  since 15 Nov 2026 (schemas above).
- Article Listen reads title + RSS excerpt (full article bodies live in
  the site SPA; full-text fetch is a follow-up).
- Speech Writer uses local templates in v1 (AI-written speeches later).
- No tests yet (`flutter test` step intentionally omitted from CI).
- The proxy's Gemini `/tts` path has no per-user daily cap yet — Article
  Listen is coin-gated in the app, but a proxy-side cap is a follow-up.
