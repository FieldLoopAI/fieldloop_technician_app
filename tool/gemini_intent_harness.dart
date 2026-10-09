// Build 176 Step 8 — GEMINI INTENT CHECK measurement harness.
//
// DEBUG ONLY: a dev-machine Dart script under tool/, never part of the APK,
// never called by the app, not wired into the live voice path. It opens
// its own Gemini Live session and sends 20 clean, correctly transcribed
// phrases through the SAME classification instruction the app's
// GEMINI INTENT CHECK sends (`_maybeStartGeminiIntentCheck` in
// lib/screens/gemini_live_test_screen.dart), then logs, per phrase, the
// intent Gemini reported, whether it matched the expected one, how it
// answered (toolCall / spoken call / no answer) and the latency, plus a
// summary: accuracy, p50/p90 latency, answered-within-1.8s count.
//
// Run (PowerShell or Git Bash, from the repo root):
//   dart run tool/gemini_intent_harness.dart --api-key=<GEMINI_API_KEY>
//   dart run tool/gemini_intent_harness.dart --token=<ephemeral token from get-gemini-token>
// Options: --timeout-ms=5000 (default; the app gives up at 1800)
//          --mode=ANY|AUTO (functionCallingConfig; the app uses ANY)
//          --context=open_camera|capture_photo (default open_camera)
//
// Running it once with --api-key and once with --token is the A/B that
// tells whether the token's liveConnectConstraints drop the client's tools
// (b175: 0 toolCalls in 171 turns, 4/4 intent checks unanswered).
//
// Differences from the app, on purpose: only the classification function
// is declared (the app declares 17), a one-line system instruction (the
// app's is ~9k chars), text in / audio out with no mic audio. Latency is
// measured from sending the instruction to the first toolCall or the
// complete spoken call.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String model = 'gemini-3.1-flash-live-preview';
const String functionName = 'classify_camera_intent';

/// The 20 phrases and the intent a correct classification gives, with the
/// camera closed on Job Detail (context open_camera). In context
/// capture_photo every photo request expects capture_photo instead.
const List<(String, String)> phrases = [
  ('can you get a shot of that for me', 'photo'),
  ('get a shot of that', 'photo'),
  ('take a picture of the water heater', 'photo'),
  ('I need a photo of this panel', 'photo'),
  ('snap one of the roof for me', 'photo'),
  ('let me get a pic of the damage', 'photo'),
  ('could you photograph the leak under the sink', 'photo'),
  ('grab an image of the meter', 'photo'),
  ('document this with a photo please', 'photo'),
  ('toma una foto del techo', 'photo'),
  ("I've changed my mind, forget the picture", 'none'),
  ("I don't want to take a photo", 'none'),
  ('hold on, forget the photo for now', 'none'),
  ("what's the customer called", 'none'),
  ('what was on the estimate', 'none'),
  ('how long have we been here', 'none'),
  ('show me the invoice', 'none'),
  ('go back to the home screen', 'none'),
  ('the camera on my phone is different', 'none'),
  ('how do I reset a tripped breaker', 'none'),
];

/// Same text as the app's instruction (no previous-turn line).
String buildIntentCheckInstruction(String heard, String context) {
  final contextLine = context == 'capture_photo'
      ? 'Right now the camera is open with a live preview, ready to shoot: if they want a picture taken, in any '
            'wording, the intent is capture_photo.'
      : 'Right now the camera is not open: if they want to take a picture, in any wording, the intent is '
            'open_camera.';
  return 'Answer this only by calling $functionName, without saying anything out loud. A field '
      'technician just said: "${heard.replaceAll('"', "'")}". This is automatic speech recognition, so it may be '
      'misspelled, cut short, heavily accented, informal, or partly in another language such as Spanish. '
      '$contextLine Call $functionName exactly once with intent "open_camera", '
      '"capture_photo", or "none", and your confidence. Use "none" for questions, remarks, or anything that is '
      'not asking for a photo. Do not call any other function.';
}

/// Same declaration as the app's.
const Map<String, Object> functionDeclaration = {
  'name': functionName,
  'description':
      'Classification step. ONLY call this when a message explicitly asks you to classify what the technician '
      'said — never on your own. Reports whether it means they want the camera opened, a photo taken right '
      'now, or neither.',
  'behavior': 'NON_BLOCKING',
  'parameters': {
    'type': 'OBJECT',
    'properties': {
      'intent': {
        'type': 'STRING',
        'enum': ['open_camera', 'capture_photo', 'none'],
        'description': 'open_camera, capture_photo, or none.',
      },
      'confidence': {'type': 'NUMBER', 'description': 'How sure you are, from 0.0 to 1.0.'},
    },
    'required': ['intent', 'confidence'],
  },
};

final RegExp _spokenCall = RegExp(r'classify[\s_]*camera[\s_]*intent\s*\(([^)]*)\)', caseSensitive: false);
final RegExp _spokenArg = RegExp(r'''(\w+)\s*[=:]\s*["']?([\w.]+)["']?''');

/// Expected intent for [label] in [context].
String expectedIntent(String label, String context) => label == 'none' ? 'none' : context;

int? _percentile(List<int> v, double p) {
  if (v.isEmpty) return null;
  final s = [...v]..sort();
  var r = (p / 100 * s.length).ceil();
  if (r < 1) r = 1;
  return s[r - 1];
}

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final hit = args.where((a) => a.startsWith('--$name=')).firstOrNull;
    return hit?.substring(name.length + 3);
  }

  final apiKey = arg('api-key') ?? Platform.environment['GEMINI_API_KEY'];
  final token = arg('token');
  final timeoutMs = int.tryParse(arg('timeout-ms') ?? '') ?? 5000;
  final mode = (arg('mode') ?? 'ANY').toUpperCase();
  final context = arg('context') ?? 'open_camera';
  if ((apiKey == null || apiKey.isEmpty) && (token == null || token.isEmpty)) {
    stderr.writeln('Give --api-key=<key> (or GEMINI_API_KEY) or --token=<ephemeral token>.');
    exit(2);
  }
  final uri = token != null && token.isNotEmpty
      ? Uri.parse('wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.'
            'GenerativeService.BidiGenerateContentConstrained?access_token=${Uri.encodeQueryComponent(token)}')
      : Uri.parse('wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.'
            'GenerativeService.BidiGenerateContent?key=${Uri.encodeQueryComponent(apiKey!)}');
  final auth = token != null && token.isNotEmpty ? 'ephemeral token' : 'API key';
  stdout.writeln('INTENT HARNESS: model=$model auth=$auth mode=$mode context=$context timeoutMs=$timeoutMs '
      '(the app times out at 1800ms)');

  final ws = await WebSocket.connect(uri.toString());
  final messages = StreamController<Map<String, dynamic>>.broadcast();
  ws.listen(
    (data) {
      final text = data is String ? data : utf8.decode(data as List<int>);
      messages.add(jsonDecode(text) as Map<String, dynamic>);
    },
    onDone: () => messages.close(),
  );

  ws.add(jsonEncode({
    'setup': {
      'model': 'models/$model',
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'temperature': 0.2,
      },
      'systemInstruction': {
        'parts': [
          {'text': 'You are a voice assistant for field technicians. Follow each message exactly.'},
        ],
      },
      'tools': [
        {
          'functionDeclarations': [functionDeclaration],
        },
      ],
      'toolConfig': {
        'functionCallingConfig': {'mode': mode},
      },
      'outputAudioTranscription': <String, Object>{},
    },
  }));
  await messages.stream.firstWhere((m) => m.containsKey('setupComplete')).timeout(const Duration(seconds: 15));
  stdout.writeln('INTENT HARNESS: setupComplete');

  final latencies = <int>[];
  var correct = 0;
  var answered = 0;
  var within1800 = 0;
  for (var i = 0; i < phrases.length; i++) {
    final (heard, label) = phrases[i];
    final expected = expectedIntent(label, context);
    final sw = Stopwatch()..start();
    final spoken = StringBuffer();
    String? intent;
    String? confidence;
    var via = 'no answer';
    final done = Completer<void>();
    final sub = messages.stream.listen((m) {
      final call = (m['toolCall'] as Map?)?['functionCalls'] as List?;
      if (call != null && intent == null) {
        for (final c in call.cast<Map>()) {
          final callArgs = (c['args'] as Map?) ?? const {};
          intent = '${callArgs['intent'] ?? '?'}';
          confidence = '${callArgs['confidence'] ?? '?'}';
          via = 'toolCall ${c['name']}';
          // NON_BLOCKING calls still get a response so the turn can end.
          ws.add(jsonEncode({
            'toolResponse': {
              'functionResponses': [
                {'id': c['id'], 'name': c['name'], 'response': {'result': 'ok'}, 'scheduling': 'SILENT'},
              ],
            },
          }));
        }
      }
      final out = ((m['serverContent'] as Map?)?['outputTranscription'] as Map?)?['text'];
      if (out is String) {
        spoken.write(out);
        final match = _spokenCall.firstMatch(spoken.toString());
        if (match != null && intent == null) {
          final a = {for (final x in _spokenArg.allMatches(match.group(1) ?? '')) x.group(1)!.toLowerCase(): x.group(2)!};
          intent = a['intent'] ?? '?';
          confidence = a['confidence'] ?? '?';
          via = 'spoken call';
        }
      }
      if (intent != null && !done.isCompleted) done.complete();
      if ((m['serverContent'] as Map?)?['turnComplete'] == true && !done.isCompleted) done.complete();
    });
    ws.add(jsonEncode({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': buildIntentCheckInstruction(heard, context)},
            ],
          },
        ],
        'turnComplete': true,
      },
    }));
    try {
      await done.future.timeout(Duration(milliseconds: timeoutMs));
    } on TimeoutException {
      // reported as "no answer"
    }
    final ms = sw.elapsedMilliseconds;
    await sub.cancel();
    final got = intent ?? 'none (no answer)';
    final ok = (intent ?? 'none') == expected;
    if (intent != null) {
      answered++;
      latencies.add(ms);
      if (ms <= 1800) within1800++;
    }
    if (ok) correct++;
    stdout.writeln('INTENT HARNESS [${i + 1}/${phrases.length}] heard="$heard" expected=$expected got=$got '
        'confidence=${confidence ?? '-'} ${ok ? 'OK' : 'WRONG'} ${ms}ms via=$via'
        '${spoken.isEmpty ? '' : ' spoken="${spoken.toString().trim()}"'}');
    // Let the turn finish before the next one so answers can't cross.
    await messages.stream
        .firstWhere((m) => (m['serverContent'] as Map?)?['turnComplete'] == true)
        .timeout(const Duration(seconds: 6), onTimeout: () => const {});
  }
  stdout.writeln('INTENT HARNESS SUMMARY: auth=$auth mode=$mode context=$context accuracy=$correct/${phrases.length} '
      'answered=$answered/${phrases.length} answered_within_1800ms=$within1800 '
      'latency p50=${_percentile(latencies, 50) ?? '-'}ms p90=${_percentile(latencies, 90) ?? '-'}ms '
      '(answered calls only)');
  await ws.close();
  exit(0);
}
