/// The four voices offered by the app.
///
/// Gemini voices go through the proxy's POST /tts endpoint (Aoede/Charon,
/// max 2000 chars per call). Edge voices go through POST /edge-tts
/// (ur-PK-AsadNeural / ur-PK-UzmaNeural, max 600 chars ≈ 1 minute, free).
enum TtsEngine { gemini, edge }

class TtsVoice {
  final String id;
  final String label;
  final String gender;
  final TtsEngine engine;

  /// The exact voice value sent to the proxy.
  final String apiVoice;

  /// Gemini voices are the premium ones (quota-limited); Edge voices are
  /// free. v1 charges the same 50 coins per chunk for both — the price
  /// difference is a follow-up tuning knob, not a v1 blocker.
  final bool isPremium;

  const TtsVoice({
    required this.id,
    required this.label,
    required this.gender,
    required this.engine,
    required this.apiVoice,
    required this.isPremium,
  });

  static const List<TtsVoice> all = [
    TtsVoice(
      id: 'aoede',
      label: 'Billo',
      gender: 'Female',
      engine: TtsEngine.gemini,
      apiVoice: 'Aoede',
      isPremium: true,
    ),
    TtsVoice(
      id: 'charon',
      label: 'Jaani',
      gender: 'Male',
      engine: TtsEngine.gemini,
      apiVoice: 'Charon',
      isPremium: true,
    ),
    TtsVoice(
      id: 'asad',
      label: 'Asad',
      gender: 'Male',
      engine: TtsEngine.edge,
      apiVoice: 'ur-PK-AsadNeural',
      isPremium: false,
    ),
    TtsVoice(
      id: 'uzma',
      label: 'Uzma',
      gender: 'Female',
      engine: TtsEngine.edge,
      apiVoice: 'ur-PK-UzmaNeural',
      isPremium: false,
    ),
    // v1.0.8 — more Gemini voices. GATE: these only appear once BOTH
    // (a) the TTS proxy Worker's ALLOWED_VOICES includes the voice
    // name (today it allows only Aoede/Charon — a one-line Worker
    // change, no new keys) AND (b) the remote config tts.voices lists
    // the id (audio-box.json). Until then availableVoices() filters
    // them out, so they are invisible and cannot fail. Display labels
    // are person names only — no provider/model names in the UI.
    TtsVoice(
      id: 'kore',
      label: 'Noor',
      gender: 'Female',
      engine: TtsEngine.gemini,
      apiVoice: 'Kore',
      isPremium: true,
    ),
    TtsVoice(
      id: 'fenrir',
      label: 'Veer',
      gender: 'Male',
      engine: TtsEngine.gemini,
      apiVoice: 'Fenrir',
      isPremium: true,
    ),
    TtsVoice(
      id: 'puck',
      label: 'Chand',
      gender: 'Male',
      engine: TtsEngine.gemini,
      apiVoice: 'Puck',
      isPremium: true,
    ),
    TtsVoice(
      id: 'zephyr',
      label: 'Hawa',
      gender: 'Female',
      engine: TtsEngine.gemini,
      apiVoice: 'Zephyr',
      isPremium: true,
    ),
  ];

  static TtsVoice byId(String id) =>
      all.firstWhere((v) => v.id == id, orElse: () => all.first);
}
