import 'package:shared_preferences/shared_preferences.dart';

/// A real platform TTS voice, exactly as reported live by flutter_tts's
/// `getVoices` on THIS device — [name]/[locale] are whatever the installed
/// engine actually calls it. There is no fixed, cross-device/cross-platform
/// set of these (see `VoiceSettingsScreen`), so this pair is the only thing
/// that reliably identifies a voice — a position or a friendly label does
/// not.
class TtsVoice {
  const TtsVoice({required this.name, required this.locale});

  final String name;
  final String locale;

  @override
  bool operator ==(Object other) =>
      other is TtsVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);

  @override
  String toString() => 'TtsVoice(name: $name, locale: $locale)';
}

const _selectedTtsVoiceNameKey = 'selected_tts_voice_name';
const _selectedTtsVoiceLocaleKey = 'selected_tts_voice_locale';

/// Called from `VoiceSettingsScreen` when the technician taps a voice row.
/// Persists the real underlying voice identity (name+locale) — never a
/// friendly label like "Voice 1", which means a different voice on every
/// device.
Future<void> saveSelectedTtsVoice(TtsVoice voice) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_selectedTtsVoiceNameKey, voice.name);
  await prefs.setString(_selectedTtsVoiceLocaleKey, voice.locale);
}

/// The technician's saved voice, or `null` if nothing's been picked yet.
/// Callers must re-verify this still exists in a live `getVoices()` result
/// before applying it (see `GlobalVoiceService._configureTts`) — the engine
/// that produced it may no longer be installed (reinstall, OEM update),
/// and a stale name+locale pair does not necessarily resolve to anything.
Future<TtsVoice?> getSelectedTtsVoice() async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString(_selectedTtsVoiceNameKey);
  final locale = prefs.getString(_selectedTtsVoiceLocaleKey);
  if (name == null || locale == null) return null;
  return TtsVoice(name: name, locale: locale);
}
