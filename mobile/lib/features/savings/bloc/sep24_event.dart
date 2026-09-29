import 'package:flutter/foundation.dart';

import '../models/sep24_models.dart';

/// Events accepted by `Sep24Bloc`.
///
/// The bloc translates these events into `Sep24State` transitions; the UI
/// never talks to the repository directly.
sealed class Sep24Event {
  const Sep24Event();
}

/// Kick off a fiat-to-USDC deposit: capture parameters, ask the backend for
/// the anchor's interactive URL and open the WebView.
@immutable
class StartSep24Deposit extends Sep24Event {
  const StartSep24Deposit(this.request);

  /// Amount, asset and user details for the anchor deposit.
  final Sep24DepositRequest request;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StartSep24Deposit && other.request == request;

  @override
  int get hashCode => request.hashCode;

  @override
  String toString() => 'StartSep24Deposit($request)';
}

/// A URL the WebView tried to navigate to. The bloc decides whether it is an
/// anchor status callback or ordinary page navigation.
@immutable
class Sep24WebViewNavigation extends Sep24Event {
  const Sep24WebViewNavigation(this.url);

  /// The raw navigation target (`onNavigationRequest`/`onPageFinished`).
  final String url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Sep24WebViewNavigation && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'Sep24WebViewNavigation($url)';
}

/// Ask the backend for the current status of the in-flight transaction.
@immutable
class Sep24StatusRefreshRequested extends Sep24Event {
  const Sep24StatusRefreshRequested({this.fromTimer = false});

  /// True when the request came from the periodic poller (as opposed to a
  /// manual "check status" tap).
  final bool fromTimer;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Sep24StatusRefreshRequested && other.fromTimer == fromTimer;

  @override
  int get hashCode => fromTimer.hashCode;

  @override
  String toString() => 'Sep24StatusRefreshRequested(fromTimer: $fromTimer)';
}

/// The user dismissed the anchor page before finishing the flow.
@immutable
class Sep24DepositCancelled extends Sep24Event {
  const Sep24DepositCancelled();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Sep24DepositCancelled;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'Sep24DepositCancelled()';
}

/// Clear the machine back to [Sep24Initial].
@immutable
class Sep24DepositReset extends Sep24Event {
  const Sep24DepositReset();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Sep24DepositReset;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'Sep24DepositReset()';
}
