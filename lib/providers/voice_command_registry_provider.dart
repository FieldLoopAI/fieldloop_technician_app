import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One registered voice command. [matches] is checked against the
/// lowercased recognized text; [handler] receives the original
/// (non-lowercased) text — e.g. the troubleshoot command sends the
/// technician's actual question to the Lambda.
class VoiceCommand {
  const VoiceCommand({required this.id, required this.matches, required this.handler});

  /// Stable identifier for this command — used only to unregister exactly
  /// this command later (see [VoiceCommandRegistry.unregisterAll]).
  /// Different screens commonly register a command under the same id (e.g.
  /// `'arrived'`), since only one screen's registration for a given id is
  /// ever active at a time in practice.
  final String id;
  final bool Function(String lowerText) matches;
  final Future<void> Function(String rawText) handler;
}

/// The single source of truth for "what can the technician say right now."
/// Screens add their available commands to this map while they're the
/// active/visible screen (see `VoiceCommandRegistrarMixin`) and remove them
/// when they're not, so `GlobalVoiceService` (which owns the actual
/// recognizer) never needs to know anything about screens, navigation, or
/// job-specific business logic — it only ever asks "does anything in this
/// map match what was just said?"
class VoiceCommandRegistry extends StateNotifier<Map<String, VoiceCommand>> {
  VoiceCommandRegistry() : super(const {});

  void registerAll(Iterable<VoiceCommand> commands) {
    if (!mounted) return;
    final next = Map<String, VoiceCommand>.of(state);
    for (final command in commands) {
      next[command.id] = command;
    }
    state = next;
  }

  void unregisterAll(Iterable<String> ids) {
    if (!mounted) return;
    final next = Map<String, VoiceCommand>.of(state);
    for (final id in ids) {
      next.remove(id);
    }
    state = next;
  }
}

final voiceCommandRegistryProvider =
    StateNotifierProvider<VoiceCommandRegistry, Map<String, VoiceCommand>>(
      (ref) => VoiceCommandRegistry(),
    );
