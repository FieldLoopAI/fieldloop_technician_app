import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_voice_service_provider.dart';
import '../providers/tts_voice_preference.dart';
import '../theme/app_theme.dart';

/// Lets a technician choose which TTS voice reads wake-word prompts and
/// confirmations. Friendly display names only — the real underlying
/// platform voice name+locale never appears on screen.
///
/// The voice list is NOT a fixed, hardcoded set: real voice names/codes
/// differ completely by platform, OS version, and installed TTS engine (an
/// 8-entry Android/Google-TTS-only list previously lived here and silently
/// produced nothing playable on iOS or on Android devices with a different
/// engine active). Instead this screen calls flutter_tts's `getVoices()`
/// live on THIS device every time it opens (see
/// [GlobalVoiceService.discoverEnUsVoices]) and labels whatever it finds
/// "Voice 1", "Voice 2", ... by POSITION in that live result — the labels
/// are just a stable, friendly way to refer to voice N in this list, they
/// don't mean the same physical voice across devices.
///
/// Tapping a row selects and applies that voice immediately (see
/// [GlobalVoiceService.setActiveVoice]) and persists it (see
/// `tts_voice_preference.dart`) so it's still active next launch. Each
/// row's Play button only previews (see [GlobalVoiceService.previewVoice])
/// without changing the saved selection.
class VoiceSettingsScreen extends ConsumerStatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  ConsumerState<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

const _sampleText =
    'Hi Jose, your estimate for two hundred ten dollars has been sent to the customer for approval.';

class _VoiceSettingsScreenState extends ConsumerState<VoiceSettingsScreen> {
  List<TtsVoice> _voices = const [];
  TtsVoice? _selectedVoice;
  TtsVoice? _playingVoice;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(globalVoiceServiceProvider.notifier);
    // Both calls hit this device live — the discovered list and the saved
    // preference are resolved independently, then matched by name+locale
    // below, exactly like GlobalVoiceService._configureTts does at startup.
    final results = await Future.wait([
      service.discoverEnUsVoices(),
      getSelectedTtsVoice(),
    ]);
    if (!mounted) return;
    final voices = results[0] as List<TtsVoice>;
    final saved = results[1] as TtsVoice?;
    setState(() {
      _voices = voices;
      _selectedVoice = saved != null && voices.contains(saved) ? saved : null;
      _loading = false;
    });
  }

  Future<void> _play(TtsVoice voice) async {
    setState(() => _playingVoice = voice);
    await ref.read(globalVoiceServiceProvider.notifier).previewVoice(
      name: voice.name,
      locale: voice.locale,
      sampleText: _sampleText,
    );
    if (!mounted) return;
    setState(() => _playingVoice = null);
  }

  Future<void> _select(TtsVoice voice) async {
    if (_selectedVoice == voice) return;
    setState(() => _selectedVoice = voice);
    await ref.read(globalVoiceServiceProvider.notifier).setActiveVoice(name: voice.name, locale: voice.locale);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Voice Settings'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen))
            : LayoutBuilder(
                builder: (context, constraints) {
                  final isTablet = constraints.maxWidth > 600;
                  final horizontalPadding = isTablet ? constraints.maxWidth * 0.15 : 20.0;

                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _headerText(),
                          style: const TextStyle(fontSize: 13.5, color: AppColors.neutralGrey, height: 1.4),
                        ),
                        const SizedBox(height: 20),
                        _buildBody(),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  String _headerText() {
    if (_voices.isEmpty) {
      return 'No compatible voices were found on this device.';
    }
    if (_voices.length == 1) {
      return 'This device has only one compatible voice available. Tap Play to hear it.';
    }
    return 'Choose the voice used for spoken prompts and confirmations. '
        'Tap a voice to select it, or Play to preview first.';
  }

  Widget _buildBody() {
    if (_voices.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Text(
          'This device did not report any usable en-US voices. The app will use the '
          "device's default voice for spoken prompts.",
          style: TextStyle(fontSize: 14, color: AppColors.textDark),
        ),
      );
    }

    // Exactly one real option: nothing meaningful to choose between, so no
    // selectable list — just let the technician hear it.
    if (_voices.length == 1) {
      final voice = _voices.first;
      final playing = _playingVoice == voice;
      return Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, 6)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Voice 1',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
              ),
            ),
            OutlinedButton.icon(
              onPressed: playing ? null : () => _play(voice),
              icon: playing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryGreen),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Play'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryGreenDark,
                side: const BorderSide(color: AppColors.primaryGreen),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < _voices.length; i++)
            _VoiceRow(
              label: 'Voice ${i + 1}',
              selected: _selectedVoice == _voices[i],
              playing: _playingVoice == _voices[i],
              playDisabled: _playingVoice != null,
              isFirst: i == 0,
              isLast: i == _voices.length - 1,
              onSelect: () => _select(_voices[i]),
              onPlay: () => _play(_voices[i]),
            ),
        ],
      ),
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.label,
    required this.selected,
    required this.playing,
    required this.playDisabled,
    required this.isFirst,
    required this.isLast,
    required this.onSelect,
    required this.onPlay,
  });

  final String label;
  final bool selected;
  final bool playing;
  final bool playDisabled;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onSelect;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.vertical(
        top: isFirst ? const Radius.circular(16) : Radius.zero,
        bottom: isLast ? const Radius.circular(16) : Radius.zero,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: isLast ? null : const Border(bottom: BorderSide(color: AppColors.borderGrey, width: 1)),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.primaryGreen : Colors.transparent,
                border: Border.all(
                  color: selected ? AppColors.primaryGreen : AppColors.borderGrey,
                  width: 1.5,
                ),
              ),
              child: selected ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: playDisabled ? null : onPlay,
              icon: playing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryGreen),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Play'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryGreenDark,
                side: const BorderSide(color: AppColors.primaryGreen),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
