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
      label: 'Aoede',
      gender: 'Female',
      engine: TtsEngine.gemini,
      apiVoice: 'Aoede',
      isPremium: true,
    ),
    TtsVoice(
      id: 'charon',
      label: 'Charon',
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
  ];

  static TtsVoice byId(String id) =>
      all.firstWhere((v) => v.id == id, orElse: () => all.first);
}
