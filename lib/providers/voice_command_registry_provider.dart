import 'package:flutter/widgets.dart';
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
/// Build 175 (RAPID SWAP residual): one navigation that touches several
/// routes over consecutive frames — "go back to home screen" from Invoice
/// with the camera prewarmed pushes `_CameraHostPage` to close the camera
/// (frame A: `-InvoiceScreen +_CameraHostPage`), then pops it and Invoice
/// (frame B) — becomes ONE handoff: the flush waits until
/// [registryCoalesceQuietFrames] end-of-frame ticks pass with no new
/// request (never longer than [registryCoalesceMaxFrames]). b174 logged
/// these as two handoffs 31ms (14:18:52.442) and 48ms (14:31:14.869) apart,
/// each a RAPID SWAP. Two separate navigations still warn. false = flush at
/// the end of the frame of the first request, as in build 174.
const bool coalesceRegistryNavigation = true;
const int registryCoalesceQuietFrames = 3;
const int registryCoalesceMaxFrames = 30;

class VoiceCommandRegistry extends StateNotifier<Map<String, VoiceCommand>> {
  /// [scheduleFlush] runs [callback] at the end of the next frame (the
  /// atomic-handoff flush, see [requestRegister], waits on it); defaults to
  /// a post-frame callback. Tests pass their own, and their own [clock].
  VoiceCommandRegistry({
    void Function(void Function() callback)? scheduleFlush,
    this.coalesceNavigation = coalesceRegistryNavigation,
    DateTime Function()? clock,
  }) : _scheduleFlush = scheduleFlush ?? _endOfFrame,
       _clock = clock ?? DateTime.now,
       super(const {});

  /// See [coalesceRegistryNavigation].
  final bool coalesceNavigation;
  final DateTime Function() _clock;

  static void _endOfFrame(void Function() flush) {
    WidgetsBinding.instance.addPostFrameCallback((_) => flush());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

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
    final now = _clock();
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

  // --- Build 174: atomic handoff with owner tokens (RAPID SWAP fix) ---------
  //
  // Old path (above): the leaving screen's unregister applied at once and
  // the arriving screen's register a frame later — two registry changes
  // 8–92ms apart on every screen change, each logged as RAPID SWAP, with
  // no commands registered in between. And an unregister removed ids by
  // name, so a late dispose could remove an id a newer screen had already
  // re-registered.
  //
  // New path: both requests are queued and applied together in ONE flush
  // at the end of the frame — one state write, one log line, no empty gap.
  // Every command is owned by the token of the screen that registered it;
  // an unregister only removes ids that token still owns, so a stale
  // owner's unregister is a no-op once a newer screen owns the registry.
  // Between a release request and its flush (at most one frame) the
  // releasing owner's commands stop matching, exactly as if already gone.

  final void Function(void Function() flush) _scheduleFlush;
  int _lastOwnerToken = 0;
  final Map<String, int> _ownerById = {};
  int? _activeOwner;
  final List<_RegistryOp> _pendingOps = [];
  final Set<int> _releasing = {};
  bool _flushScheduled = false;

  /// A fresh owner token — one per screen instance.
  int newOwnerToken() => ++_lastOwnerToken;

  /// The token owning [id] right now (tests/diagnostics).
  int? ownerOf(String id) => _ownerById[id];

  /// Owner [owner] ([screen]) becomes the active screen with [commands]
  /// as its whole command set, at the next flush.
  void requestRegister(int owner, String screen, List<VoiceCommand> commands, {required bool kbFallbackEnabled}) {
    _releasing.remove(owner);
    _pendingOps.add(_RegistryOp.register(owner, screen, commands, kbFallbackEnabled));
    _ensureFlush();
  }

  /// Owner [owner] gives up its commands at the next flush. A no-op for
  /// any id another owner has taken since.
  void requestUnregister(int owner, String screen) {
    _releasing.add(owner);
    _pendingOps.add(_RegistryOp.unregister(owner, screen));
    _ensureFlush();
  }

  /// Frames ticked since the last request, and since the first pending one
  /// (see [coalesceRegistryNavigation]).
  int _quietFrames = 0;
  int _heldFrames = 0;

  void _ensureFlush() {
    _quietFrames = 0;
    if (_flushScheduled) return;
    _flushScheduled = true;
    _scheduleFlush(_onFrameTick);
  }

  /// End of a frame with requests pending: flush now, or — coalescing —
  /// wait another frame while this navigation is still producing requests.
  void _onFrameTick() {
    _flushScheduled = false;
    if (coalesceNavigation && mounted && _pendingOps.isNotEmpty) {
      _quietFrames++;
      _heldFrames++;
      if (_quietFrames < registryCoalesceQuietFrames && _heldFrames < registryCoalesceMaxFrames) {
        _flushScheduled = true;
        _scheduleFlush(_onFrameTick);
        return;
      }
    }
    flushPending();
  }

  /// Applies every queued request in order, as one change. Public so tests
  /// (and an injected scheduler) can run it directly.
  void flushPending() {
    _flushScheduled = false;
    _quietFrames = 0;
    _heldFrames = 0;
    if (!mounted || _pendingOps.isEmpty) {
      _pendingOps.clear();
      return;
    }
    final ops = List<_RegistryOp>.of(_pendingOps);
    _pendingOps.clear();
    final next = Map<String, VoiceCommand>.of(state);
    final before = {for (final e in _ownerById.entries) e.key: e.value};
    final screens = <String>[];
    for (final op in ops) {
      if (op.isRegister) {
        // A re-register replaces this owner's whole set (double register).
        final keep = {for (final c in op.commands) c.id};
        _ownerById.removeWhere((id, o) {
          final drop = o == op.owner && !keep.contains(id);
          if (drop) next.remove(id);
          return drop;
        });
        for (final c in op.commands) {
          next[c.id] = _owned(c, op.owner);
          _ownerById[c.id] = op.owner;
        }
        _activeOwner = op.owner;
        _activeScreen = op.screen;
        _activeScreenKbFallbackEnabled = op.kbFallbackEnabled;
        screens.add('+${op.screen}#${op.owner}');
      } else {
        _ownerById.removeWhere((id, o) {
          final drop = o == op.owner;
          if (drop) next.remove(id);
          return drop;
        });
        if (_activeOwner == op.owner) {
          _activeOwner = null;
          _activeScreen = null;
          _activeScreenKbFallbackEnabled = false;
        }
        screens.add('-${op.screen}#${op.owner}');
      }
    }
    _releasing.removeWhere((o) => !_ownerById.containsValue(o));
    final removed = [for (final id in before.keys) if (!_ownerById.containsKey(id)) id];
    final added = [for (final e in _ownerById.entries) if (before[e.key] != e.value) e.key];
    // A register always refreshes handlers (fresh closures), even when the
    // id set didn't change; only a flush of nothing but no-ops is skipped.
    final anyRegister = ops.any((op) => op.isRegister && _ownerById.containsValue(op.owner));
    if (removed.isEmpty && added.isEmpty && !anyRegister) {
      debugPrint(
        'VOICE REGISTRY [t=${DateTime.now().millisecondsSinceEpoch}]: handoff ${screens.join(' ')} — no net change '
        '(stale or superseded requests ignored)',
      );
      return;
    }
    _logChange('handoff ${screens.join(' ')} -[${removed.join(', ')}] +', added);
    state = next;
  }

  /// [command] tagged with its owner: it stops matching (and its handler
  /// does nothing) once that owner has asked to release, even before the
  /// flush lands — so a command can never reach a screen that is leaving.
  VoiceCommand _owned(VoiceCommand command, int owner) => VoiceCommand(
    id: command.id,
    pauseWindow: command.pauseWindow,
    matches: (text) => !_releasing.contains(owner) && command.matches(text),
    handler: (raw) {
      if (_releasing.contains(owner) || _ownerById[command.id] != owner) {
        debugPrint('VOICE REGISTRY: "${command.id}" dropped — its screen (#$owner) is leaving');
        return Future.value();
      }
      return command.handler(raw);
    },
  );
}

class _RegistryOp {
  _RegistryOp.register(this.owner, this.screen, this.commands, this.kbFallbackEnabled) : isRegister = true;
  _RegistryOp.unregister(this.owner, this.screen) : isRegister = false, commands = const [], kbFallbackEnabled = false;

  final bool isRegister;
  final int owner;
  final String screen;
  final List<VoiceCommand> commands;
  final bool kbFallbackEnabled;
}

final voiceCommandRegistryProvider =
    StateNotifierProvider<VoiceCommandRegistry, Map<String, VoiceCommand>>(
      (ref) => VoiceCommandRegistry(),
    );
