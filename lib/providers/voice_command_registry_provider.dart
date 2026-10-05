import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One registered voice command. [matches] is checked against the
/// lowercased recognized text; [handler] receives the original
/// (non-lowercased) matched text, available for handlers that want it —
/// though most (including "help"/"ask"/"question", which greets and then
/// listens for the actual question separately — see
/// `handleAskQuestionCommand`) don't need it and ignore it.
class VoiceCommand {
  const VoiceCommand({required this.id, required this.matches, required this.handler, this.pauseWindow});

  /// Stable identifier for this command — used only to unregister exactly
  /// this command later (see [VoiceCommandRegistry.unregisterAll]).
  /// Different screens commonly register a command under the same id (e.g.
  /// `'arrived'`), since only one screen's registration for a given id is
  /// ever active at a time in practice.
  final String id;
  final bool Function(String lowerText) matches;
  final Future<void> Function(String rawText) handler;

  /// Overrides `GlobalVoiceService`'s default command-settle pause window
  /// for just this command — set on short, single-word commands (e.g.
  /// "confirm", "retake") so they finalize as soon as the word is
  /// recognized, instead of waiting out the longer default tuned for
  /// multi-word phrases like "job complete" or "site condition".
  /// `null` (the default) uses the shared value. `GlobalVoiceService`
  /// applies this dynamically — as soon as the in-progress transcript
  /// matches a command with a shorter window, the settle timer (and the
  /// recognizer's own `pauseFor`) switches to it — so a single screen can
  /// freely mix short and long commands (e.g. Photo Preview's "confirm"/
  /// "retake" alongside the shared, longer `jobLifecycleVoiceCommands`)
  /// without the short override ever clipping the long ones.
  final Duration? pauseWindow;
}

/// Shared short pause window for single-word commands — see
/// [VoiceCommand.pauseWindow]. Centralized so every short command tunes to
/// the same value rather than each screen picking its own.
const Duration shortCommandPauseWindow = Duration(milliseconds: 700);

/// The single source of truth for "what can the technician say right now."
/// Screens add their available commands to this map while they're the
/// active/visible screen (see `VoiceCommandRegistrarMixin`) and remove them
/// when they're not, so `GlobalVoiceService` (which owns the actual
/// recognizer) never needs to know anything about screens, navigation, or
/// job-specific business logic — it only ever asks "does anything in this
/// map match what was just said?"
class VoiceCommandRegistry extends StateNotifier<Map<String, VoiceCommand>> {
  VoiceCommandRegistry() : super(const {});

  /// DIAGNOSTIC (voice-going-stale investigation) — when the immediately
  /// PREVIOUS registry change (register or unregister, from ANY screen)
  /// happened. This is the single shared registry instance for the whole
  /// app, so this sees every screen's swaps in true chronological order —
  /// unlike `VoiceCommandRegistrarMixin`'s own per-screen debugPrint,
  /// which only knows about that one screen's own calls.
  DateTime? _lastChangeAt;

  /// Read-only, for dispatch-time diagnostics (the Gemini session's VOICE
  /// PIPELINE log) — when the registry last changed.
  DateTime? get lastChangeAt => _lastChangeAt;

  /// Below this gap between two consecutive registry changes, they're
  /// flagged as a "rapid swap" — the suspected trigger for voice going
  /// stale after quick screen transitions (e.g. Photo Preview's
  /// confirm/retake immediately unregistering right as Job Detail
  /// re-registers on the way back).
  static const Duration _rapidSwapThreshold = Duration(seconds: 1);

  void _logChange(String action, Iterable<String> ids) {
    final now = DateTime.now();
    final last = _lastChangeAt;
    _lastChangeAt = now;
    final tsMs = now.millisecondsSinceEpoch;
    if (last == null) {
      debugPrint('VOICE REGISTRY [t=$tsMs]: $action [${ids.join(', ')}] (first registry change this session)');
      return;
    }
    final deltaMs = now.difference(last).inMilliseconds;
    if (Duration(milliseconds: deltaMs) < _rapidSwapThreshold) {
      debugPrint(
        'VOICE REGISTRY [t=$tsMs]: $action [${ids.join(', ')}] *** RAPID SWAP: only ${deltaMs}ms '
        'since the previous registry change *** (suspected trigger for voice going stale)',
      );
    } else {
      debugPrint('VOICE REGISTRY [t=$tsMs]: $action [${ids.join(', ')}] (${deltaMs}ms since previous change)');
    }
  }

  /// Per-screen voice policy, registered alongside each screen's command
  /// set by `VoiceCommandRegistrarMixin` (see its `kbFallbackEnabled`):
  /// which registrar screen is currently the active one, and whether an
  /// utterance nothing else matched may fall back to the knowledge base
  /// there (Job Detail only) or must get a clarification question instead.
  /// Plain fields, not part of [state] — a policy change never needs to
  /// rebuild anything; the Gemini session reads it at routing time.
  String? _activeScreen;
  bool _activeScreenKbFallbackEnabled = false;

  String? get activeScreen => _activeScreen;
  bool get activeScreenKbFallbackEnabled => _activeScreenKbFallbackEnabled;

  void setActiveScreen(String screen, {required bool kbFallbackEnabled}) {
    _activeScreen = screen;
    _activeScreenKbFallbackEnabled = kbFallbackEnabled;
  }

  /// Only clears if [screen] is still the one recorded — a newer screen's
  /// registration that already landed must not be wiped by an older
  /// screen's late unregister.
  void clearActiveScreen(String screen) {
    if (_activeScreen != screen) return;
    _activeScreen = null;
    _activeScreenKbFallbackEnabled = false;
  }

  void registerAll(Iterable<VoiceCommand> commands) {
    if (!mounted) return;
    final next = Map<String, VoiceCommand>.of(state);
    for (final command in commands) {
      next[command.id] = command;
    }
    _logChange('registerAll', commands.map((c) => c.id));
    state = next;
  }

  void unregisterAll(Iterable<String> ids) {
    if (!mounted) return;
    final next = Map<String, VoiceCommand>.of(state);
    for (final id in ids) {
      next.remove(id);
    }
    _logChange('unregisterAll', ids);
    state = next;
  }
}

final voiceCommandRegistryProvider =
    StateNotifierProvider<VoiceCommandRegistry, Map<String, VoiceCommand>>(
      (ref) => VoiceCommandRegistry(),
    );
