import 'package:flutter/services.dart';

/// What the native speech engine reports about one utterance.
enum PdfSpeechState { started, done, error }

/// The PDF reader's text-to-speech bridge.
///
/// The engine lives on the Android side (system `TextToSpeech`); this class only
/// sends `speak`/`stop`/`setRate` and receives the per-utterance lifecycle
/// callbacks on the same channel. Callbacks for an utterance id that is no longer
/// the reader's current one are ignored by the reader, so tapping a second line
/// while the first is still speaking cannot clear the new highlight.
abstract final class PdfSpeech {
  static const MethodChannel _channel = MethodChannel('tablet_browser/pdf_tts');

  /// Latest lifecycle callback; set by the open reader and cleared on dispose.
  static void Function(String utteranceId, PdfSpeechState state)? onEvent;

  static bool _wired = false;

  static void _ensureWired() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      final Map<dynamic, dynamic>? args = call.arguments is Map
          ? call.arguments as Map<dynamic, dynamic>
          : null;
      final String id = args?['id'] as String? ?? '';
      final PdfSpeechState? state = switch (call.method) {
        'onStart' => PdfSpeechState.started,
        'onDone' => PdfSpeechState.done,
        'onError' => PdfSpeechState.error,
        _ => null,
      };
      if (state != null) onEvent?.call(id, state);
      return null;
    });
  }

  /// Starts speaking [text] at [rate] (1.0 = normal) and returns the utterance
  /// id. Throws [PlatformException] when the device has no usable TTS engine.
  static Future<String> speak(String text, {double rate = 1.0}) async {
    _ensureWired();
    final String? id = await _channel.invokeMethod<String>('speak', <String, dynamic>{
      'text': text,
      'rate': rate,
    });
    return id ?? '';
  }

  /// Changes the rate used by the next utterance (and the pending one).
  static Future<void> setRate(double rate) async {
    _ensureWired();
    try {
      await _channel.invokeMethod<void>('setRate', <String, dynamic>{
        'rate': rate,
      });
    } on MissingPluginException {
      // Non-Android hosts / tests have no engine; the UI stays usable.
    } on PlatformException {
      // The next speak() passes the rate again.
    }
  }

  /// Stops the current utterance, if any.
  static Future<void> stop() async {
    _ensureWired();
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing to stop without the native engine.
    } on PlatformException {
      // Stopping is best-effort.
    }
  }
}
