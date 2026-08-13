import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

/// True if [error] indicates "no network," as opposed to a genuine
/// server-side failure (auth, validation, a bad status code) — those must
/// still surface as real errors to the technician, not silently queue.
/// [http.post]/[http.put] throw [SocketException] (DNS/connect failure) or
/// [http.ClientException] (connection dropped mid-request) for network
/// failures; our own code only ever throws [StateError] for a real
/// (non-2xx) response, which is deliberately NOT included here.
bool isNetworkError(Object error) {
  return error is SocketException || error is TimeoutException || error is http.ClientException;
}

/// True if [results] (from `connectivity_plus`) represents "no usable
/// network" — an empty list, or a list containing only [ConnectivityResult.none].
bool isOfflineResult(List<ConnectivityResult> results) {
  return results.isEmpty || results.every((r) => r == ConnectivityResult.none);
}
