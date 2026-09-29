import 'package:flutter/foundation.dart';

import '../models/sep24_models.dart';

/// Phases of the [Sep24Loading] state.
enum Sep24LoadingPhase {
  /// Asking the backend/anchor for the interactive URL.
  requestingAnchorUrl,

  /// Confirming the final transaction status with the backend.
  verifyingTransaction,
}

/// States of the SEP-24 anchor deposit state machine.
///
/// ```text
/// Initial ──startDeposit──▶ Loading ──▶ WebViewOpen ──▶ Success
///                              │              │  ▲
///                              │              ▼  │ (non-terminal callbacks)
///                              └──────────▶ Error ◀┘ (terminal failure)
/// ```
sealed class Sep24State {
  const Sep24State();

  /// The deposit parameters that produced this state, when a flow is active.
  Sep24DepositRequest? get request;

  /// True while the machine is waiting on the network or the anchor.
  bool get isBusy;

  /// Anchor transaction id, once the flow has one.
  String? get transactionId;
}

/// Nothing has been started yet, or the flow was reset.
@immutable
class Sep24Initial extends Sep24State {
  const Sep24Initial();

  @override
  Sep24DepositRequest? get request => null;

  @override
  bool get isBusy => false;

  @override
  String? get transactionId => null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Sep24Initial;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'Sep24Initial()';
}

/// A network/anchor call is in flight.
@immutable
class Sep24Loading extends Sep24State {
  const Sep24Loading({
    required this.phase,
    this.request,
    this.transactionId,
    this.message,
  });

  @override
  final Sep24DepositRequest? request;

  final Sep24LoadingPhase phase;

  @override
  final String? transactionId;

  /// Optional label to render next to the spinner.
  final String? message;

  @override
  bool get isBusy => true;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Sep24Loading &&
            other.phase == phase &&
            other.request == request &&
            other.transactionId == transactionId &&
            other.message == message;
  }

  @override
  int get hashCode => Object.hash(phase, request, transactionId, message);

  @override
  String toString() => 'Sep24Loading(${phase.name}, message: $message)';
}

/// The anchor's interactive page is (or is about to be) open in the WebView.
///
/// Non-terminal status callbacks update [status]/[statusMessage] in place so
/// the UI can show real-time progress without leaving the page.
@immutable
class Sep24WebViewOpen extends Sep24State {
  const Sep24WebViewOpen({
    required this.url,
    this.request,
    this.transactionId,
    this.status = Sep24TransactionStatus.unknown,
    this.statusMessage,
    this.isVerifyingStatus = false,
    this.lastCallback,
  });

  /// The interactive URL to load in the WebView.
  final Uri url;

  @override
  final Sep24DepositRequest? request;

  @override
  final String? transactionId;

  /// Latest status reported by the anchor for this transaction.
  final Sep24TransactionStatus status;

  /// Human readable description of [status].
  final String? statusMessage;

  /// True while a background status poll is running.
  final bool isVerifyingStatus;

  /// The callback that last moved this state, useful for debugging/UI.
  final Sep24Callback? lastCallback;

  @override
  bool get isBusy => true;

  /// Label rendered in the WebView status banner.
  String get statusLabel => statusMessage ?? status.label;

  /// Returns a copy with the tracked status fields replaced.
  Sep24WebViewOpen copyWith({
    Uri? url,
    Sep24DepositRequest? request,
    String? transactionId,
    Sep24TransactionStatus? status,
    String? statusMessage,
    bool? isVerifyingStatus,
    Sep24Callback? lastCallback,
  }) {
    return Sep24WebViewOpen(
      url: url ?? this.url,
      request: request ?? this.request,
      transactionId: transactionId ?? this.transactionId,
      status: status ?? this.status,
      statusMessage: statusMessage ?? this.statusMessage,
      isVerifyingStatus: isVerifyingStatus ?? this.isVerifyingStatus,
      lastCallback: lastCallback ?? this.lastCallback,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Sep24WebViewOpen &&
            other.url == url &&
            other.request == request &&
            other.transactionId == transactionId &&
            other.status == status &&
            other.statusMessage == statusMessage &&
            other.isVerifyingStatus == isVerifyingStatus &&
            other.lastCallback == lastCallback;
  }

  @override
  int get hashCode => Object.hash(
    url,
    request,
    transactionId,
    status,
    statusMessage,
    isVerifyingStatus,
    lastCallback,
  );

  @override
  String toString() =>
      'Sep24WebViewOpen(url: $url, status: ${status.name}, id: $transactionId)';
}

/// The deposit completed; USDC is on the way to (or already on) the account.
@immutable
class Sep24Success extends Sep24State {
  const Sep24Success({
    required this.status,
    this.request,
    this.transactionId,
    this.amountIn,
    this.assetCode,
    this.message,
  });

  @override
  final Sep24DepositRequest? request;

  @override
  final String? transactionId;

  /// Always [Sep24TransactionStatus.completed] in practice.
  final Sep24TransactionStatus status;

  final String? amountIn;
  final String? assetCode;
  final String? message;

  @override
  bool get isBusy => false;

  /// Message to surface to the user (snackbar/dialog).
  String get userMessage {
    final provided = message;
    if (provided != null && provided.isNotEmpty) {
      return provided;
    }
    final amount = amountIn;
    if (amount == null || amount.isEmpty) {
      return 'Deposit completed.';
    }
    return 'Deposit of $amount ${assetCode ?? Sep24DepositRequest.defaultAsset} completed.';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Sep24Success &&
            other.status == status &&
            other.request == request &&
            other.transactionId == transactionId &&
            other.amountIn == amountIn &&
            other.assetCode == assetCode &&
            other.message == message;
  }

  @override
  int get hashCode =>
      Object.hash(status, request, transactionId, amountIn, assetCode, message);

  @override
  String toString() =>
      'Sep24Success(id: $transactionId, amount: $amountIn ${assetCode ?? ''})';
}

/// The flow failed, either while requesting the anchor URL or from a terminal
/// anchor status. The user can retry with the same parameters.
@immutable
class Sep24Error extends Sep24State {
  const Sep24Error({
    required this.message,
    this.request,
    this.transactionId,
    this.status,
    this.recoverable = true,
  });

  @override
  final Sep24DepositRequest? request;

  @override
  final String? transactionId;

  /// User-facing reason for the failure.
  final String message;

  /// Terminal anchor status, when the failure came from one.
  final Sep24TransactionStatus? status;

  /// Whether a retry makes sense (vs. e.g. an anchor refusal to trade).
  final bool recoverable;

  @override
  bool get isBusy => false;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Sep24Error &&
            other.message == message &&
            other.request == request &&
            other.transactionId == transactionId &&
            other.status == status &&
            other.recoverable == recoverable;
  }

  @override
  int get hashCode =>
      Object.hash(message, request, transactionId, status, recoverable);

  @override
  String toString() => 'Sep24Error($message, recoverable: $recoverable)';
}
