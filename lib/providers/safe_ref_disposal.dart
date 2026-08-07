import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mix into any `ConsumerState` that writes to provider state from
/// `dispose()`, or from an async callback that might resolve after the
/// widget is gone. This is the ONE place that safety pattern lives —
/// previously it was hand-rolled per file (capture-the-notifier-early in
/// one screen, a bare `if (!mounted)` in another), which is exactly how the
/// same "set provider state after dispose" crash reappeared in a second
/// file after already being fixed once in the first. Every screen that
/// touches provider state from `dispose()` (or after an `await`) should
/// route through [safeWrite] instead of writing its own guard.
mixin SafeRefDisposal<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Reads a Notifier/StateController from a provider right now, for safe
  /// use later — including from `dispose()`, where a *fresh* `ref.read()`
  /// call is not safe: by the time `dispose()` runs, this widget's Element
  /// is already detached from the tree even though `mounted` can briefly
  /// still read true. Call [capture] only from `initState`/`build`, before
  /// any disposal has started, then use the returned object (never `ref`
  /// itself) later.
  N capture<N>(N Function(WidgetRef ref) read) => read(ref);

  /// Runs [write] only while this State is still mounted — call after any
  /// `await` (a fresh `ref.read()`/`ref.watch()` inside [write] is fine
  /// here: if `mounted` is true, the Element is still fully live) instead
  /// of a manual `if (!mounted)` guard.
  ///
  /// From `dispose()` specifically, [write] must only touch objects
  /// obtained earlier via [capture] — never a fresh `ref.read()` — since by
  /// the time `dispose()` runs, this widget's Element is already detached
  /// from the tree even though `mounted` can briefly still read true, so
  /// [mounted] alone doesn't make a `ref` call safe from inside `dispose()`.
  void safeWrite(VoidCallback write) {
    if (!mounted) return;
    write();
  }
}
