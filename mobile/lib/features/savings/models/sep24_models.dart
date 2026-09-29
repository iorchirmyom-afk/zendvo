/// Data models for the SEP-24 (anchor) fiat-to-USDC deposit flow.
///
/// The shapes here mirror the [SEP-24 specification](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0024.md)
/// and the backend's `Sep24TransactionStatus` union
/// (`backend/src/server/services/webhookService.ts`) so that a status string
/// produced anywhere in the stack means the same thing on the client.
library;

import 'package:flutter/foundation.dart';

/// Terminal outcome of the interactive anchor flow, derived from a
/// [Sep24TransactionStatus] or a callback URL.
enum Sep24FlowOutcome {
  /// The anchor is still working on the transaction.
  inProgress,

  /// The anchor finished the flow and requested customer information.
  pendingConfirmation,

  /// Funds were credited; the deposit is complete.
  success,

  /// The deposit failed permanently (error/expired/too_small/...).
  failure,

  /// The user walked away from the anchor page before completing it.
  cancelled,
}

/// Status values a SEP-24 anchor reports for a transaction.
enum Sep24TransactionStatus {
  incomplete('incomplete'),
  created('created'),
  pendingUserTransferStart('pending_user_transfer_start'),
  pendingUserTransferComplete('pending_user_transfer_complete'),
  pendingAnchor('pending_anchor'),
  pendingTrust('pending_trust'),
  pendingStellar('pending_stellar'),
  pendingExternal('pending_external'),
  noMarket('no_market'),
  tooSmall('too_small'),
  tooLarge('too_large'),
  completed('completed'),
  refunded('refunded'),
  expired('expired'),
  error('error'),

  /// Anything the client does not recognise; the raw value is kept on
  /// [Sep24Callback.rawStatus] so the UI can still surface it.
  unknown('unknown');

  const Sep24TransactionStatus(this.rawValue);

  /// The value used on the wire by anchors and by the backend webhook.
  final String rawValue;

  /// Parses an anchor status string, tolerating casing/separator variations
  /// and the simplified statuses used by `/transactions` endpoints.
  static Sep24TransactionStatus fromRaw(String? value) {
    if (value == null) {
      return Sep24TransactionStatus.unknown;
    }
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
    if (normalized.isEmpty) {
      return Sep24TransactionStatus.unknown;
    }

    // Aliases that anchors commonly use for the same lifecycle point.
    const aliases = <String, Sep24TransactionStatus>{
      'pending': Sep24TransactionStatus.pendingAnchor,
      'in_review': Sep24TransactionStatus.pendingAnchor,
      'processing': Sep24TransactionStatus.pendingAnchor,
      'ready': Sep24TransactionStatus.pendingUserTransferComplete,
      'ready_to_complete': Sep24TransactionStatus.pendingUserTransferComplete,
      'transaction_completed': Sep24TransactionStatus.completed,
      'complete': Sep24TransactionStatus.completed,
      'success': Sep24TransactionStatus.completed,
      'failed': Sep24TransactionStatus.error,
      'error_occured': Sep24TransactionStatus.error,
      'error_occurred': Sep24TransactionStatus.error,
    };
    final aliased = aliases[normalized];
    if (aliased != null) {
      return aliased;
    }

    for (final status in Sep24TransactionStatus.values) {
      if (status.rawValue == normalized) {
        return status;
      }
    }
    return Sep24TransactionStatus.unknown;
  }

  /// True when no further anchor updates are expected for this status.
  bool get isTerminal => isTerminalSuccess || isTerminalFailure;

  /// The money landed; the deposit can be treated as done.
  bool get isTerminalSuccess => this == Sep24TransactionStatus.completed;

  /// The deposit can no longer succeed (failure or refund).
  bool get isTerminalFailure => const <Sep24TransactionStatus>{
    Sep24TransactionStatus.error,
    Sep24TransactionStatus.expired,
    Sep24TransactionStatus.noMarket,
    Sep24TransactionStatus.tooSmall,
    Sep24TransactionStatus.tooLarge,
    Sep24TransactionStatus.refunded,
  }.contains(this);

  /// Whether this status can be used to drive a UI "spinner" phase.
  bool get isInProgress => !isTerminal;

  /// Short, human readable label for the status (e.g. "Awaiting your transfer").
  String get label {
    switch (this) {
      case Sep24TransactionStatus.incomplete:
        return 'Incomplete';
      case Sep24TransactionStatus.created:
        return 'Created';
      case Sep24TransactionStatus.pendingUserTransferStart:
        return 'Awaiting your transfer';
      case Sep24TransactionStatus.pendingUserTransferComplete:
        return 'Transfer received';
      case Sep24TransactionStatus.pendingAnchor:
        return 'Processing with the anchor';
      case Sep24TransactionStatus.pendingTrust:
        return 'Waiting for your USDC trustline';
      case Sep24TransactionStatus.pendingStellar:
        return 'Waiting for the Stellar network';
      case Sep24TransactionStatus.pendingExternal:
        return 'Waiting for the bank';
      case Sep24TransactionStatus.noMarket:
        return 'No market for this asset';
      case Sep24TransactionStatus.tooSmall:
        return 'Amount below the minimum';
      case Sep24TransactionStatus.tooLarge:
        return 'Amount above the maximum';
      case Sep24TransactionStatus.completed:
        return 'Completed';
      case Sep24TransactionStatus.refunded:
        return 'Refunded';
      case Sep24TransactionStatus.expired:
        return 'Expired';
      case Sep24TransactionStatus.error:
        return 'Failed';
      case Sep24TransactionStatus.unknown:
        return 'Updating';
    }
  }

  /// Message shown to the user when this status ends the flow.
  String? get terminalMessage {
    switch (this) {
      case Sep24TransactionStatus.completed:
        return 'Your deposit has been credited.';
      case Sep24TransactionStatus.refunded:
        return 'The anchor refunded your transfer.';
      case Sep24TransactionStatus.expired:
        return 'The deposit expired before the transfer was received.';
      case Sep24TransactionStatus.noMarket:
        return 'The anchor cannot trade this asset right now.';
      case Sep24TransactionStatus.tooSmall:
        return 'The amount is below the anchor minimum.';
      case Sep24TransactionStatus.tooLarge:
        return 'The amount is above the anchor maximum.';
      case Sep24TransactionStatus.error:
        return 'The anchor could not complete the deposit.';
      case Sep24TransactionStatus.incomplete:
      case Sep24TransactionStatus.created:
      case Sep24TransactionStatus.pendingUserTransferStart:
      case Sep24TransactionStatus.pendingUserTransferComplete:
      case Sep24TransactionStatus.pendingAnchor:
      case Sep24TransactionStatus.pendingTrust:
      case Sep24TransactionStatus.pendingStellar:
      case Sep24TransactionStatus.pendingExternal:
      case Sep24TransactionStatus.unknown:
        return null;
    }
  }
}

/// The kind of SEP-24 transaction being started.
enum Sep24TransactionKind {
  deposit('deposit'),
  withdrawal('withdrawal'),
  unknown('unknown');

  const Sep24TransactionKind(this.rawValue);

  final String rawValue;

  static Sep24TransactionKind fromRaw(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    for (final kind in Sep24TransactionKind.values) {
      if (kind.rawValue == normalized) {
        return kind;
      }
    }
    return Sep24TransactionKind.unknown;
  }
}

/// How an anchor answered a `POST /deposit` request.
enum Sep24DepositResponseKind {
  /// The anchor needs the user to fill in details on a web page.
  interactive,

  /// The anchor created the transaction straight away; no web page needed.
  transaction,

  /// The anchor rejected the request.
  error,
}

/// Everything the SEP-24 deposit flow needs from the user and the wallet.
@immutable
class Sep24DepositRequest {
  const Sep24DepositRequest({
    required this.amount,
    this.asset = defaultAsset,
    this.kind = Sep24TransactionKind.deposit,
    this.account,
    this.email,
    this.phoneNumber,
    this.countryCode,
    this.lang = 'en',
    this.extraFields = const <String, String>{},
  });

  /// Default anchor asset for this app: USDC on Stellar.
  static const String defaultAsset = 'USDC';

  /// Minimum amount the app accepts before hitting the network. Anchors may
  /// enforce a larger minimum; that surfaces as `too_small`.
  static const double minAmount = 1.0;

  /// Human readable amount, e.g. `'50.00'`, as required by SEP-24.
  final String amount;

  /// Asset code the user is buying (USDC by default).
  final String asset;

  final Sep24TransactionKind kind;

  /// Destination Stellar account; the user's own funded account.
  final String? account;

  final String? email;
  final String? phoneNumber;

  /// ISO 3166-1 alpha-3 country code of the fiat leg (e.g. `NGA`).
  final String? countryCode;
  final String lang;

  /// Any additional customer fields the anchor declared as non-certain in
  /// its `/info` response.
  final Map<String, String> extraFields;

  /// Parses and validates [amount]; `null` when it is not a usable number.
  double? get parsedAmount => double.tryParse(amount.trim());

  /// Returns `null` when the request is usable, otherwise a message that can
  /// be shown directly in the UI.
  String? get validationError {
    final amountValue = parsedAmount;
    if (amountValue == null) {
      return 'Enter the amount you want to deposit.';
    }
    if (amountValue.isNaN || amountValue.isInfinite) {
      return 'Enter a valid amount.';
    }
    if (amountValue <= 0) {
      return 'The amount must be greater than zero.';
    }
    if (amountValue < minAmount) {
      return 'The minimum deposit is ${minAmount.toStringAsFixed(2)} $asset.';
    }
    if (asset.trim().isEmpty) {
      return 'Select the asset you want to deposit into.';
    }
    final emailValue = email?.trim() ?? '';
    if (emailValue.isNotEmpty && !emailValue.contains('@')) {
      return 'Enter a valid email address.';
    }
    final accountValue = account?.trim() ?? '';
    if (accountValue.isNotEmpty && accountValue.length < 8) {
      return 'The destination Stellar account looks too short to be valid.';
    }
    return null;
  }

  bool get isValid => validationError == null;

  /// The JSON body sent to the backend, dropping fields the user left blank
  /// so the anchor only sees what was actually provided.
  Map<String, dynamic> toJson() {
    final body = <String, dynamic>{
      'amount': amount.trim(),
      'asset_code': asset.trim(),
      'asset': asset.trim(),
      'kind': kind.rawValue,
      'lang': lang,
    };
    void putIfPresent(String key, String? value) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) {
        body[key] = trimmed;
      }
    }

    putIfPresent('account', account);
    putIfPresent('email', email);
    putIfPresent('phone_number', phoneNumber);
    putIfPresent('country_code', countryCode);
    extraFields.forEach((key, value) {
      if (key.trim().isNotEmpty && value.trim().isNotEmpty) {
        body[key] = value.trim();
      }
    });
    return Map<String, dynamic>.unmodifiable(body);
  }

  Sep24DepositRequest copyWith({
    String? amount,
    String? asset,
    Sep24TransactionKind? kind,
    String? account,
    String? email,
    String? phoneNumber,
    String? countryCode,
    String? lang,
    Map<String, String>? extraFields,
  }) {
    return Sep24DepositRequest(
      amount: amount ?? this.amount,
      asset: asset ?? this.asset,
      kind: kind ?? this.kind,
      account: account ?? this.account,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      countryCode: countryCode ?? this.countryCode,
      lang: lang ?? this.lang,
      extraFields: extraFields ?? this.extraFields,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Sep24DepositRequest &&
            other.amount == amount &&
            other.asset == asset &&
            other.kind == kind &&
            other.account == account &&
            other.email == email &&
            other.phoneNumber == phoneNumber &&
            other.countryCode == countryCode &&
            other.lang == lang &&
            _mapEquals(other.extraFields, extraFields);
  }

  @override
  int get hashCode => Object.hash(
    amount,
    asset,
    kind,
    account,
    email,
    phoneNumber,
    countryCode,
    lang,
    Object.hashAllUnordered(
      extraFields.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => 'Sep24DepositRequest(amount: $amount, asset: $asset)';
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

/// The anchor's answer to a deposit request.
@immutable
class Sep24DepositTicket {
  const Sep24DepositTicket({
    required this.kind,
    this.interactiveUrl,
    this.transactionId,
    this.status = Sep24TransactionStatus.unknown,
    this.error,
    this.raw = const <String, dynamic>{},
  });

  /// Whether the user must open a web page, whether the anchor already
  /// created the transaction, or whether it refused.
  final Sep24DepositResponseKind kind;

  /// The interactive URL to open in the in-app WebView.
  final Uri? interactiveUrl;

  /// Anchor transaction id, used to correlate webhook/redirect callbacks.
  final String? transactionId;

  final Sep24TransactionStatus status;

  /// Anchor-supplied error message for [Sep24DepositResponseKind.error].
  final String? error;

  final Map<String, dynamic> raw;

  bool get needsWebView =>
      kind == Sep24DepositResponseKind.interactive && interactiveUrl != null;

  bool get isRejected => kind == Sep24DepositResponseKind.error;

  factory Sep24DepositTicket.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] ?? json['kind'] ?? '').toString();
    final error = _firstString(json, const <String>[
      'error',
      'error_message',
      'detail',
    ]);
    final transaction = json['transaction'];
    final transactionMap = transaction is Map
        ? Map<String, dynamic>.from(transaction)
        : const <String, dynamic>{};

    final id =
        _firstString(json, const <String>['id', 'transaction_id', 'txn_id']) ??
        _firstString(transactionMap, const <String>['id', 'transaction_id']);

    if (type.toLowerCase() == 'error' || (id == null && error != null)) {
      return Sep24DepositTicket(
        kind: Sep24DepositResponseKind.error,
        error: error ?? 'The anchor rejected the deposit request.',
        raw: json,
      );
    }

    final urlValue =
        _firstString(json, const <String>['url', 'interactive_url']) ??
        _firstString(transactionMap, const <String>['url']);
    final status = Sep24TransactionStatus.fromRaw(
      _firstString(transactionMap, const <String>['status']) ??
          _firstString(json, const <String>['status']),
    );

    if (urlValue != null && urlValue.isNotEmpty) {
      return Sep24DepositTicket(
        kind: Sep24DepositResponseKind.interactive,
        interactiveUrl: Uri.tryParse(urlValue),
        transactionId: id,
        status: status,
        error: error,
        raw: json,
      );
    }

    // `type: transaction` (or anything else with an id): the anchor accepted
    // everything already, so the flow is tracked without a web page.
    if (id != null) {
      return Sep24DepositTicket(
        kind: Sep24DepositResponseKind.transaction,
        transactionId: id,
        status: status,
        error: error,
        raw: json,
      );
    }

    return Sep24DepositTicket(
      kind: Sep24DepositResponseKind.error,
      error: error ?? 'The anchor did not return an interactive URL.',
      raw: json,
    );
  }

  @override
  String toString() =>
      'Sep24DepositTicket(${kind.name}, id: $transactionId, url: $interactiveUrl)';
}

/// A transaction status update, parsed either from a WebView redirect
/// callback or from the backend status endpoint.
@immutable
class Sep24Callback {
  const Sep24Callback({
    required this.uri,
    this.transactionId,
    this.status = Sep24TransactionStatus.unknown,
    this.rawStatus,
    this.kind = Sep24TransactionKind.unknown,
    this.amountIn,
    this.amountOut,
    this.amountFee,
    this.assetCode,
    this.message,
    this.statusEta,
    this.userCancelled = false,
  });

  /// The full callback URL, kept for debugging and for the status banner.
  final Uri uri;

  final String? transactionId;
  final Sep24TransactionStatus status;

  /// The status string exactly as the anchor reported it.
  final String? rawStatus;

  final Sep24TransactionKind kind;
  final String? amountIn;
  final String? amountOut;
  final String? amountFee;
  final String? assetCode;
  final String? message;

  /// Seconds until the anchor expects the next status change, when known.
  final int? statusEta;

  /// True when the anchor page redirected because the user aborted.
  final bool userCancelled;

  bool get hasStatus => rawStatus != null && rawStatus!.isNotEmpty;

  /// How the flow should transition on this callback.
  Sep24FlowOutcome get outcome {
    if (userCancelled) {
      return Sep24FlowOutcome.cancelled;
    }
    if (!hasStatus) {
      return Sep24FlowOutcome.pendingConfirmation;
    }
    if (status.isTerminalSuccess) {
      return Sep24FlowOutcome.success;
    }
    if (status.isTerminalFailure) {
      return Sep24FlowOutcome.failure;
    }
    return Sep24FlowOutcome.inProgress;
  }

  /// Message to surface for this callback, falling back to the anchor text.
  String? get displayMessage {
    if (userCancelled) {
      return message ?? 'Deposit cancelled.';
    }
    if (message != null && message!.isNotEmpty) {
      return message;
    }
    final label = status.label;
    final amount = amountText;
    return amount == null
        ? 'Deposit status: $label.'
        : 'Deposit of $amount: $label.';
  }

  String? get amountText {
    final amount = amountIn ?? amountOut;
    if (amount == null || amount.isEmpty) {
      return null;
    }
    return assetCode == null ? amount : '$amount $assetCode';
  }

  Sep24Callback copyWith({Sep24TransactionStatus? status, String? message}) {
    return Sep24Callback(
      uri: uri,
      transactionId: transactionId,
      status: status ?? this.status,
      rawStatus: status != null ? status.rawValue : rawStatus,
      kind: kind,
      amountIn: amountIn,
      amountOut: amountOut,
      amountFee: amountFee,
      assetCode: assetCode,
      message: message ?? this.message,
      statusEta: statusEta,
      userCancelled: userCancelled,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Sep24Callback &&
            other.uri.toString() == uri.toString() &&
            other.transactionId == transactionId &&
            other.status == status &&
            other.userCancelled == userCancelled;
  }

  @override
  int get hashCode =>
      Object.hash(uri.toString(), transactionId, status, userCancelled);

  @override
  String toString() =>
      'Sep24Callback(status: ${status.name}, id: $transactionId)';
}

String? _firstString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is num) {
      return value.toString();
    }
  }
  return null;
}

/// Recognises the anchor's "the flow moved on" redirects.
///
/// Anchors finish an interactive flow by redirecting the browser to a callback
/// URL that carries the transaction id and (usually) a status. This parser
/// accepts the app's own custom scheme (`zendvo://sep24/callback?...`) and any
/// configured HTTPS host/path pair, and reads parameters from both the query
/// and the fragment so both styles work.
class Sep24CallbackParser {
  const Sep24CallbackParser({
    this.callbackScheme = 'zendvo',
    this.callbackHost = 'sep24',
    this.callbackPaths = const <String>[
      '/callback',
      '/sep24/callback',
      '/sep24',
      '/api/webhooks/sep24',
    ],
    this.additionalHosts = const <String>{},
    this.statusParamNames = const <String>[
      'status',
      'event',
      'transaction_status',
      'status_code',
    ],
  });

  /// Scheme of the in-app callback (e.g. `zendvo` in `zendvo://sep24/...`).
  final String callbackScheme;

  /// Host of the in-app callback.
  final String callbackHost;

  /// Path suffixes that mark a callback on an allow-listed host.
  final List<String> callbackPaths;

  /// Extra hosts (e.g. the backend host) whose [callbackPaths] are treated as
  /// status callbacks.
  final Set<String> additionalHosts;

  /// Query keys that may carry the SEP-24 status.
  final List<String> statusParamNames;

  /// Returns the parsed callback, or `null` when [rawUrl] is just regular page
  /// navigation the WebView should follow normally.
  Sep24Callback? tryParse(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) {
      return null;
    }
    return isCallback(uri) ? parse(uri) : null;
  }

  /// Whether [uri] is a status callback rather than anchor page content.
  bool isCallback(Uri uri) {
    if (uri.scheme == callbackScheme && uri.host == callbackHost) {
      return true;
    }
    final hostMatches =
        additionalHosts.contains(uri.host) ||
        (uri.host.isEmpty && callbackHost.isEmpty);
    if (!hostMatches) {
      return false;
    }
    final path = uri.path;
    return callbackPaths.any(
      (suffix) => suffix.isNotEmpty && path.endsWith(suffix),
    );
  }

  /// Extracts the SEP-24 fields out of a callback [uri].
  Sep24Callback parse(Uri uri) {
    final params = <String, String>{
      ...uri.queryParameters,
      ...uri.fragmentParameters,
    };

    final rawStatus = _first(params, statusParamNames);
    final status = Sep24TransactionStatus.fromRaw(rawStatus);
    final path = uri.path.toLowerCase();
    final cancelled =
        _isTrue(
          _first(params, const <String>['cancelled', 'cancel', 'aborted']),
        ) ||
        (rawStatus != null &&
            const <String>{
              'cancel',
              'cancelled',
              'user_cancelled',
            }.contains(rawStatus.toLowerCase())) ||
        path.endsWith('/cancel') ||
        path.endsWith('/cancelled') ||
        path.endsWith('/abort');

    final eta = int.tryParse(
      _first(params, const <String>['status_eta', 'eta']) ?? '',
    );

    return Sep24Callback(
      uri: uri,
      transactionId: _first(params, const <String>[
        'id',
        'transaction_id',
        'txn_id',
        'ref',
      ]),
      status: status,
      rawStatus: rawStatus,
      kind: Sep24TransactionKind.fromRaw(
        _first(params, const <String>['kind', 'type']),
      ),
      amountIn: _first(params, const <String>['amount_in', 'amount']),
      amountOut: _first(params, const <String>['amount_out']),
      amountFee: _first(params, const <String>['amount_fee']),
      assetCode: _first(params, const <String>['asset_code', 'asset']),
      message: _first(params, const <String>[
        'message',
        'error',
        'error_message',
        'detail',
      ]),
      statusEta: eta,
      userCancelled: cancelled,
    );
  }

  static bool _isTrue(String? value) {
    if (value == null) {
      return false;
    }
    final normalized = value.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  static String? _first(Map<String, String> params, List<String> keys) {
    for (final key in keys) {
      final value = params[key];
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }
}

extension UriCallbackParameters on Uri {
  /// Some anchors report the final status in a fragment
  /// (`#status=completed&id=...`) instead of a query string.
  Map<String, String> get fragmentParameters {
    if (fragment.isEmpty) {
      return const <String, String>{};
    }
    final result = <String, String>{};
    for (final pair in fragment.split(RegExp(r'[&#]'))) {
      if (pair.isEmpty) {
        continue;
      }
      final separator = pair.indexOf('=');
      if (separator == -1) {
        result[_percentDecode(pair)] = '';
      } else {
        result[_percentDecode(pair.substring(0, separator))] = _percentDecode(
          pair.substring(separator + 1),
        );
      }
    }
    return result;
  }
}

String _percentDecode(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } on FormatException {
    return value;
  }
}
