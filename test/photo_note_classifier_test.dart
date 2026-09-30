import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/photo_note_classifier.dart';

/// The voice photo-description flow's text decisions (see
/// `photo_note_classifier.dart`): a decline or an interrupting command must
/// never be saved as a note, and a real note must never be mistaken for a
/// decline just because it starts with "no".
void main() {
  group('classifyPhotoNoteReply', () {
    void expectKind(String text, PhotoNoteReplyKind kind) =>
        expect(classifyPhotoNoteReply(text).kind, kind, reason: '"$text"');

    test('clear declines', () {
      for (final text in [
        'No.',
        'no thanks',
        'No thank you.',
        'Skip.',
        'skip it',
        'Nothing.',
        "That's fine.",
        'thats fine',
        "No, I'm good.",
        'Nope.',
        'Never mind.',
        'thanks',
      ]) {
        expectKind(text, PhotoNoteReplyKind.decline);
      }
    });

    test('a note that merely starts with "no" is still a note', () {
      final reply = classifyPhotoNoteReply('No leaks visible at the service valve.');
      expect(reply.kind, PhotoNoteReplyKind.description);
      expect(reply.text, 'No leaks visible at the service valve.');
    });

    test('new capture / navigation commands interrupt instead of being saved', () {
      for (final text in [
        'Take another photo.',
        'take another one',
        'Take a picture.',
        'Open the camera.',
        'go back',
      ]) {
        expectKind(text, PhotoNoteReplyKind.interruptCommand);
      }
    });

    test('a note that mentions taking another LOOK is not a capture command', () {
      expectKind('Need to take another look at the coil next visit.', PhotoNoteReplyKind.description);
    });

    test('cancel phrases decline before any note', () {
      for (final text in ['Cancel.', 'Forget it.', "Don't save it.", 'No, never mind.']) {
        expectKind(text, PhotoNoteReplyKind.decline);
      }
    });

    test('declines in the technician\'s own words are declines, never read back (flutter_run_log 6038bc76)', () {
      for (final text in [
        "No, I don't want to add notes.",
        "I don't want to add a note.",
        "Don't want notes.",
        "I don't need one.",
        'Not now.',
        'No need.',
        "I don't want to",
      ]) {
        expectKind(text, PhotoNoteReplyKind.decline);
      }
    });

    test('a real note containing "don\'t want"/"don\'t need" stays a note', () {
      for (final text in [
        "We don't want to lose the capacitor, it's the original part.",
        "Don't need to replace the filter.",
      ]) {
        expectKind(text, PhotoNoteReplyKind.description);
      }
    });

    test('"go back" exits even after a leading "no" (flutter_run_log 6038bc76)', () {
      for (final text in ['No, go back.', 'No Go back.', 'Okay, go back.']) {
        expectKind(text, PhotoNoteReplyKind.interruptCommand);
        expect(classifyPhotoNoteConfirmation(text).kind, PhotoNoteConfirmationKind.interruptCommand, reason: '"$text"');
        expect(photoNoteInterruptCommand(text)?.toLowerCase(), startsWith('go back'), reason: '"$text"');
      }
      // A real negation inside the command still vetoes it.
      expect(photoNoteInterruptCommand("Don't go back."), isNull);
    });

    test('redo before the first note just keeps listening', () {
      expectKind('Let me start over.', PhotoNoteReplyKind.redo);
    });

    test('bare yes waits for the note', () {
      for (final text in ['Yes.', 'yeah', 'Sure.', 'Okay.', 'yes please']) {
        expectKind(text, PhotoNoteReplyKind.affirmOnly);
      }
    });

    test('leading yes/filler is trimmed off the note, content untouched', () {
      final reply = classifyPhotoNoteReply('Yeah, um, condenser coil is iced over on the north side.');
      expect(reply.kind, PhotoNoteReplyKind.description);
      expect(reply.text, 'Condenser coil is iced over on the north side.');
    });

    test('content words that look like filler are kept', () {
      expect(classifyPhotoNoteReply('Right side panel is loose.').text, 'Right side panel is loose.');
      expect(classifyPhotoNoteReply('well pump pressure is low').text, 'Well pump pressure is low');
    });
  });

  group('looksLikeRequestOrQuestion (break-out gate)', () {
    test('requests and questions from flutter_run_log 97579c46 pass the gate', () {
      for (final text in [
        'Can you tell me which screen we are',
        'Which screen are we on?',
        'Show me the job history.',
        'No, wait — what screen is this',
        'Pull up the invoice.',
      ]) {
        expect(looksLikeRequestOrQuestion(text), isTrue, reason: '"$text"');
      }
    });

    test('declarative notes that contain command words do not', () {
      for (final text in [
        'The estimate for the compressor is high, show the customer.',
        'Condenser coil is iced over on the north side.',
        'Invoice copy taped inside the panel door.',
        "It's the left valve, not the right one.",
      ]) {
        expect(looksLikeRequestOrQuestion(text), isFalse, reason: '"$text"');
      }
    });
  });

  group('classifyPhotoNoteConfirmation', () {
    void expectKind(String text, PhotoNoteConfirmationKind kind) =>
        expect(classifyPhotoNoteConfirmation(text).kind, kind, reason: '"$text"');

    test('confirmations', () {
      for (final text in ['Yes.', "Yes, that's right.", 'Correct.', 'save it', 'Sounds good.', 'Thank you.', 'ok']) {
        expectKind(text, PhotoNoteConfirmationKind.confirm);
      }
    });

    test('discards', () {
      for (final text in ['Cancel.', 'never mind', 'Forget it.', "Don't save it.", 'scratch that']) {
        expectKind(text, PhotoNoteConfirmationKind.discard);
      }
    });

    test('bare no asks again rather than guessing', () {
      for (final text in ['No.', 'nope', "That's wrong."]) {
        expectKind(text, PhotoNoteConfirmationKind.reask);
      }
    });

    test('a correction replaces the note, lead-in stripped', () {
      final result = classifyPhotoNoteConfirmation("No, it's the left valve, not the right one.");
      expect(result.kind, PhotoNoteConfirmationKind.correction);
      expect(result.text, "It's the left valve, not the right one.");
    });

    test('"and also" extends the note', () {
      final result = classifyPhotoNoteConfirmation('Yes, and also the fan is noisy.');
      expect(result.kind, PhotoNoteConfirmationKind.addition);
      expect(result.text, 'The fan is noisy.');
    });

    test('non-answers are unclear, not read back as a new note', () {
      for (final text in ['Hmm.', 'um', 'What?', 'Sorry?', 'Say again.', 'Hold on.', 'let me think']) {
        expectKind(text, PhotoNoteConfirmationKind.unclear);
      }
    });

    test('a new capture command interrupts', () {
      expectKind('Take another photo.', PhotoNoteConfirmationKind.interruptCommand);
      // flutter_run_log 97579c46: swallowed as note text.
      expectKind('Go back.', PhotoNoteConfirmationKind.interruptCommand);
    });

    test('cancel phrases discard — with or without a leading "no"', () {
      for (final text in [
        'Never mind.',
        'Cancel.',
        'Forget it.',
        'Skip.',
        'No thanks.',
        "Don't save it.",
        'No, cancel that.',
        'Nope, forget it.',
      ]) {
        expectKind(text, PhotoNoteConfirmationKind.discard);
      }
    });

    test('redo requests re-record instead of becoming the note (flutter_run_log 97579c46)', () {
      for (final text in [
        'No, I want to say it again.',
        'Let me redo it.',
        'Start over.',
        'let me try again',
      ]) {
        expectKind(text, PhotoNoteConfirmationKind.redo);
      }
    });

    test('a long note that happens to say "start over" is still a correction', () {
      expectKind(
        'No, the tech had to start over the whole install because the line set was kinked near the wall.',
        PhotoNoteConfirmationKind.correction,
      );
    });

    test('"say that again" asks the app to repeat itself — unclear, not redo', () {
      expectKind('Say that again?', PhotoNoteConfirmationKind.unclear);
    });

    test('"that\'s not it" means say the note again — redo, never read back as the note', () {
      for (final text in [
        "No, that's not it.",
        "That's not it.",
        'No, I want to say it again.',
        'Let me redo that.',
        "That's wrong, try again.",
        'No, try again.',
        "No, that's not what I said.",
        'Let me say it again.',
      ]) {
        expectKind(text, PhotoNoteConfirmationKind.redo);
      }
    });

    test('"don\'t add a note" means no note at all — discard, never redo or a correction', () {
      for (final text in [
        "No, don't add a note.",
        "Don't save the note.",
        'Skip the note.',
        'No note.',
        'Never mind the note.',
        'No, skip the note.',
      ]) {
        expectKind(text, PhotoNoteConfirmationKind.discard);
      }
    });

    test('a negated redo is not a redo', () {
      expect(classifyPhotoNoteConfirmation("No, don't try again.").kind, isNot(PhotoNoteConfirmationKind.redo));
    });
  });

  group('the two intents before the first note too', () {
    test('"don\'t add a note" declines', () {
      for (final text in ["No, don't add a note.", "Don't add a note.", 'Skip the note.', 'Never mind the note.']) {
        expect(classifyPhotoNoteReply(text).kind, PhotoNoteReplyKind.decline, reason: '"$text"');
      }
    });

    test('a short real note starting "don\'t add" stays a note', () {
      expect(classifyPhotoNoteReply("Don't add refrigerant.").kind, PhotoNoteReplyKind.description);
    });
  });
}
