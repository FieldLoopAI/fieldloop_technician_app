/// Build 180 item A — scripted replies play from cached clips.
///
/// b179 (part 4): every decline "Okay." went through Gemini — 1.3–1.7s from
/// the action to the first audio byte, against 0–11ms for a reply played
/// from a clip — because the `decline` reason is not in the cacheable
/// tables of `confirmation_clip.dart`, and the store had no "Okay." clip at
/// all on that device ("CONFIRMATION CLIP: none cached yet for "Okay."").
///
/// Two additions, both behind [kScriptedReplyClips]:
///  1. [scriptedReplyClipLines] — fixed lines that may be cached and played
///     from a clip whatever reason asked for them (the text is the same
///     audio either way). Keyed by EXACT text, so a variable line can never
///     match. The existing reason/text tables are untouched.
///  2. Seed clips — WAV files shipped under `assets/clips/`, named by
///     `clipFileKey(text)` (optionally with the store's own
///     `confirmation_clip_` prefix, as pulled from a device), are copied into
///     the clip store on first run for any key the store does not already
///     hold. No assets -> nothing happens.
///
/// The save rules are unchanged: a clip is still only recorded after a clean
/// play whose transcript is exactly the line, 600ms–8s long; with no clip the
/// line still goes through Gemini.
library;

import 'dart:io';
import 'dart:typed_data';

import 'confirmation_clip.dart';
import 'job_facts.dart' show outOfScopeReply;
import 'local_close_command.dart' show localCloseClosingLine, localCloseConfirmQuestion;
import 'wake_greeting_clip.dart';

/// `--dart-define=SCRIPTED_REPLY_CLIPS=false` turns item A off (the old
/// tables only, no seeding).
const bool kScriptedReplyClips = bool.fromEnvironment('SCRIPTED_REPLY_CLIPS', defaultValue: true);

/// Where seed clips live in the app bundle.
const String scriptedClipAssetDir = 'assets/clips/';

/// One scripted reply the voice flow speaks: its exact text and the reason
/// strings it is requested under (`_informGeminiToSpeakVerbatim`).
class ScriptedReplyLine {
  const ScriptedReplyLine(this.text, this.reasons);
  final String text;
  final List<String> reasons;
}

/// Every fixed reply the voice flow can speak that build 180 makes
/// clip-cacheable, word for word as the screen speaks it.
const List<ScriptedReplyLine> scriptedReplyLines = [
  ScriptedReplyLine('Okay.', [
    'decline',
    'decline_close_camera',
    'negation_guard',
    'local_close_declined',
    'wait_hold',
  ]),
  ScriptedReplyLine('Sorry, can you say that again?', ['garbled_quick_repeat', 'clarify_fallback', 'intent_weak_match']),
  ScriptedReplyLine("I didn't quite catch that — could you repeat it?", ['clarify_fallback', 'intent_weak_match']),
  ScriptedReplyLine('Sorry, I missed that. What do you need?', ['clarify_fallback', 'intent_weak_match']),
  ScriptedReplyLine('Sorry, still not catching that.', ['clarify_fallback', 'intent_weak_match', 'transcript_never_arrived']),
  ScriptedReplyLine(outOfScopeReply, ['out_of_scope_fast', 'deterministic get_kb_answer', 'deterministic get_kb_answer error']),
  ScriptedReplyLine(localCloseConfirmQuestion, ['local_close_confirm']),
  ScriptedReplyLine(localCloseClosingLine, ['local_close']),
  ScriptedReplyLine("The camera's still opening — give it a moment.", [
    'open_camera_guard_failed_still_opening',
    'capture_guard_failed_still_opening',
    'clarify_fallback',
  ]),
  ScriptedReplyLine("The camera's just closing — give it a second, then ask again.", ['open_camera_guard_failed_closing']),
  ScriptedReplyLine(
    "The camera's already open — say 'ready' or 'capture it' when you want the photo.",
    ['open_camera_guard_failed_already_open'],
  ),
  ScriptedReplyLine(
    "You've got a photo waiting — do you want to keep it, or retake it?",
    ['open_camera_guard_failed_photo_pending'],
  ),
  ScriptedReplyLine(
    "Sorry, I missed that — say 'ready' or 'capture it' when you want the photo.",
    ['clarify_fallback', 'intent_weak_match'],
  ),
  ScriptedReplyLine(
    "I didn't catch that. The camera's open — say 'capture it' when you're set.",
    ['clarify_fallback', 'intent_weak_match'],
  ),
  ScriptedReplyLine(
    'Sorry, I missed that — do you want to keep this photo, or retake it?',
    ['clarify_fallback', 'intent_weak_match'],
  ),
  ScriptedReplyLine(
    "I didn't catch that. Say 'keep it' to save the photo, or 'retake' to shoot it again.",
    ['clarify_fallback', 'intent_weak_match'],
  ),
  ScriptedReplyLine("Okay, I've taken you back.", ['deterministic go_back']),
  ScriptedReplyLine("Got it — I've taken the photo. Keep it, or retake it?", ['deterministic capture_photo']),
];

/// The texts of [scriptedReplyLines].
final Set<String> scriptedReplyClipLines = {for (final line in scriptedReplyLines) line.text};

/// Whether [text] is a build 180 scripted line (exact text only).
bool isScriptedReplyClipLine(String text, {bool enabled = kScriptedReplyClips}) =>
    enabled && scriptedReplyClipLines.contains(text);

/// The clip-eligibility rule the screen applies: the existing tables
/// (`isCacheableReplyLine`, unchanged), plus the scripted lines when
/// [scriptedEnabled].
bool isClipEligibleReply(
  String reason,
  String text, {
  required bool includeFixedLines,
  bool scriptedEnabled = kScriptedReplyClips,
}) =>
    isCacheableReplyLine(reason, text, includeFixedLines: includeFixedLines) ||
    isScriptedReplyClipLine(text, enabled: scriptedEnabled);

/// The clip key a seed asset's file name stands for: `<key>.wav` or
/// `confirmation_clip_<key>.wav` (as found on a device), anywhere under
/// [scriptedClipAssetDir]. `null` for anything else.
String? seedAssetClipKey(String assetPath) {
  if (!assetPath.startsWith(scriptedClipAssetDir)) return null;
  var name = assetPath.substring(assetPath.lastIndexOf('/') + 1);
  if (!name.toLowerCase().endsWith('.wav')) return null;
  name = name.substring(0, name.length - 4);
  if (name.startsWith(ConfirmationClipStore.filePrefix)) {
    name = name.substring(ConfirmationClipStore.filePrefix.length);
  }
  return RegExp(r'^[0-9a-f]{8}$').hasMatch(name) ? name : null;
}

/// Why a seed WAV is refused, or `null` when it is a plausible clip: a
/// 44-byte PCM header, mono 16-bit at the playback rate, and the same
/// 600ms–8s length bound saved clips must meet.
String? seedWavRejection(Uint8List wav) {
  if (wav.length <= 44) return 'too short to be a WAV';
  final header = ByteData.sublistView(wav, 0, 44);
  String ascii(int offset, int length) => String.fromCharCodes(wav.sublist(offset, offset + length));
  if (ascii(0, 4) != 'RIFF' || ascii(8, 4) != 'WAVE' || ascii(36, 4) != 'data') return 'not a plain PCM WAV';
  if (header.getUint16(20, Endian.little) != 1) return 'not PCM';
  if (header.getUint16(22, Endian.little) != 1) return 'not mono';
  if (header.getUint32(24, Endian.little) != kWakeGreetingSampleRateHz) return 'sample rate is not $kWakeGreetingSampleRateHz';
  if (header.getUint16(34, Endian.little) != 16) return 'not 16-bit';
  final samples = (wav.length - 44) ~/ 2;
  final duration = Duration(microseconds: samples * 1000000 ~/ kWakeGreetingSampleRateHz);
  if (duration < ConfirmationClipStore.minClip || duration > ConfirmationClipStore.maxClip) {
    return 'length ${duration.inMilliseconds}ms outside ${ConfirmationClipStore.minClip.inMilliseconds}-'
        '${ConfirmationClipStore.maxClip.inMilliseconds}ms';
  }
  return null;
}

/// Outcome of [seedClipStore].
class SeedResult {
  const SeedResult({required this.seeded, required this.skippedExisting, required this.rejected});
  final int seeded;
  final int skippedExisting;

  /// asset path -> reason it was not used.
  final Map<String, String> rejected;
}

/// Copies seed WAVs into [directory] as `confirmation_clip_<key>.wav` for
/// every key the directory does not already hold. Existing clips are never
/// overwritten. [assetPaths] is the bundle's asset list; [loadAsset] reads
/// one. No matching assets -> a no-op.
Future<SeedResult> seedClipStore({
  required Directory directory,
  required Iterable<String> assetPaths,
  required Future<Uint8List> Function(String assetPath) loadAsset,
}) async {
  var seeded = 0;
  var skipped = 0;
  final rejected = <String, String>{};
  for (final path in assetPaths) {
    final key = seedAssetClipKey(path);
    if (key == null) continue;
    final target = File('${directory.path}${Platform.pathSeparator}${ConfirmationClipStore.filePrefix}$key.wav');
    if (await target.exists()) {
      skipped++;
      continue;
    }
    final Uint8List bytes;
    try {
      bytes = await loadAsset(path);
    } catch (e) {
      rejected[path] = 'could not read ($e)';
      continue;
    }
    final rejection = seedWavRejection(bytes);
    if (rejection != null) {
      rejected[path] = rejection;
      continue;
    }
    if (!await directory.exists()) await directory.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
    seeded++;
  }
  return SeedResult(seeded: seeded, skippedExisting: skipped, rejected: rejected);
}
