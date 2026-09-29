import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../models/sep24_models.dart';

/// Raised when the anchor or the backend refuses to start a SEP-24 deposit.
class Sep24Exception implements Exception {
  const Sep24Exception(this.message, {this.cause, this.recoverable = true});

  /// User-facing description of the failure.
  final String message;

  /// Underlying error, when there is one.
  final Object? cause;

  /// Whether retrying the same request could plausibly succeed.
  final bool recoverable;

  @override
  String toString() => '$runtimeType: $message';
}

/// Raised when the backend has no SEP-24 status endpoint (or the transaction
/// id is unknown to it). The flow keeps working from WebView callbacks, so
/// callers use this to stop polling instead of showing an error.
class Sep24StatusUnavailableException extends Sep24Exception {
  const Sep24StatusUnavailableException([
    super.message = 'Transaction status is not available from the backend.',
  ]) : super(recoverable: false);
}

/// Talks to the backend for the SEP-24 anchor deposit flow.
///
/// Two calls back this feature:
/// 1. [requestDepositTicket] asks the backend (which proxies the anchor's
///    `POST /deposit`) for the interactive URL to open in the WebView;
/// 2. [fetchTransactionStatus] reads the current status of a transaction so
///    the UI can keep tracking progress even if the WebView is closed, while
///    the backend itself is fed by the anchor webhook
///    (`POST /api/webhooks/sep24`).
///
/// Both paths are configurable because the anchor endpoints are proxied by
/// the backend: override them (or `--dart-define=SEP24_DEPOSIT_PATH=...`)
/// without touching this file.
class Sep24Repository {
  Sep24Repository({
    ApiClient? apiClient,
    String? baseUrl,
    String? depositPath,
    String? statusPath,
    this.callbackUrl = defaultCallbackUrl,
    this.attachCallbackUrl = true,
  }) : _apiClient = apiClient ?? ApiClient(),
       _ownsApiClient = apiClient == null,
       _baseUrl = baseUrl ?? defaultBaseUrl,
       _depositPath = _normalizePath(
         depositPath ??
             const String.fromEnvironment(
               'SEP24_DEPOSIT_PATH',
               defaultValue: defaultDepositPath,
             ),
       ),
       _statusPath = _normalizePath(
         statusPath ??
             const String.fromEnvironment(
               'SEP24_STATUS_PATH',
               defaultValue: defaultStatusPath,
             ),
       );

  /// Backend base URL; matches `SavingsRepository` so a single dart-define
  /// configures the whole app.
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:5000',
  );

  /// Backend route that proxies the anchor's SEP-24 `POST /deposit`.
  static const String defaultDepositPath = '/api/savings/sep24/deposit';

  /// Backend route that returns the status of a SEP-24 transaction.
  static const String defaultStatusPath = '/api/savings/sep24/transaction';

  /// In-app scheme the anchor redirects to when the interactive flow ends.
  static const String defaultCallbackUrl = 'zendvo://sep24/callback';

  final ApiClient _apiClient;

  /// Whether this repository created the [ApiClient] and therefore has to
  /// release it. An injected client stays owned by the caller.
  final bool _ownsApiClient;

  final String _baseUrl;
  final String _depositPath;
  final String _statusPath;

  /// Callback URL handed to the anchor so it can redirect the WebView back
  /// into the app with the transaction status.
  final String callbackUrl;

  /// Whether [callbackUrl] is appended to the interactive URL as a
  /// `callback` query parameter. Disable for anchors that reject unknown
  /// parameters.
  final bool attachCallbackUrl;

  /// The base URL this repository is pointed at.
  String get baseUrl => _baseUrl;

  /// Requests an interactive SEP-24 deposit for [request].
  ///
  /// Throws [Sep24Exception] when the request is invalid or the anchor answer
  /// cannot be understood, and propagates the mapped [ApiException]s from
  /// [ApiClient.postWithRetry] (e.g. [NetworkCongestedException]) so the bloc
  /// can decide what to show and never hangs in a loading state.
  Future<Sep24DepositTicket> requestDepositTicket(
    Sep24DepositRequest request,
  ) async {
    final validationError = request.validationError;
    if (validationError != null) {
      throw Sep24Exception(validationError, recoverable: true);
    }

    final response = await _apiClient.postWithRetry(
      '$_baseUrl$_depositPath',
      request.toJson(),
    );

    final ticket = Sep24DepositTicket.fromJson(response);
    final interactiveUrl = ticket.interactiveUrl;
    if (ticket.kind == Sep24DepositResponseKind.interactive &&
        interactiveUrl != null) {
      return Sep24DepositTicket(
        kind: ticket.kind,
        interactiveUrl: _withCallbackParam(interactiveUrl),
        transactionId: ticket.transactionId,
        status: ticket.status,
        error: ticket.error,
        raw: ticket.raw,
      );
    }
    return ticket;
  }

  /// Reads the current status of the anchor transaction [transactionId].
  ///
  /// Throws [Sep24StatusUnavailableException] when the backend does not
  /// expose (or does not know) the transaction, so the caller can fall back
  /// to WebView callbacks.
  Future<Sep24Callback> fetchTransactionStatus(String transactionId) async {
    final id = transactionId.trim();
    if (id.isEmpty) {
      throw const Sep24StatusUnavailableException(
        'No anchor transaction id to poll for status updates.',
      );
    }

    final uri = Uri.parse(
      '$_baseUrl$_statusPath',
    ).replace(queryParameters: <String, String>{'id': id});

    Map<String, dynamic> response;
    try {
      response = await _apiClient.getWithRetry(uri.toString());
    } on ApiRequestException catch (error) {
      throw Sep24StatusUnavailableException(error.message);
    }

    final payload = _unwrap(response);
    final status = Sep24TransactionStatus.fromRaw(
      payload['status'] as String? ??
          payload['transaction_status'] as String? ??
          payload['event'] as String?,
    );
    return Sep24Callback(
      uri: uri,
      transactionId: _asString(payload['id']) ?? id,
      status: status,
      rawStatus:
          _asString(payload['status']) ??
          _asString(payload['transaction_status']) ??
          _asString(payload['event']),
      kind: Sep24TransactionKind.fromRaw(_asString(payload['kind'])),
      amountIn: _asString(payload['amount_in'] ?? payload['amount']),
      amountOut: _asString(payload['amount_out']),
      amountFee: _asString(payload['amount_fee']),
      assetCode: _asString(payload['asset_code'] ?? payload['asset']),
      message: _asString(payload['message'] ?? payload['error']),
      statusEta: payload['status_eta'] is num
          ? (payload['status_eta'] as num).toInt()
          : int.tryParse(_asString(payload['status_eta']) ?? ''),
    );
  }

  /// Builds the URL the WebView should open, appending the in-app callback so
  /// the anchor can hand the status back to the app.
  Uri _withCallbackParam(Uri url) {
    if (!attachCallbackUrl || callbackUrl.isEmpty) {
      return url;
    }
    if (url.queryParameters.containsKey('callback')) {
      return url;
    }
    return url.replace(
      queryParameters: <String, String>{
        ...url.queryParameters,
        'callback': callbackUrl,
      },
    );
  }

  /// Accepts both a bare SEP-24 transaction object and the `{data: ...}`
  /// envelope the backend uses for list responses.
  Map<String, dynamic> _unwrap(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    final transaction = response['transaction'];
    if (transaction is Map) {
      return Map<String, dynamic>.from(transaction);
    }
    final transactions = response['transactions'];
    if (transactions is List && transactions.isNotEmpty) {
      final first = transactions.first;
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }
    return response;
  }

  static String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }

  static String? _asString(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value.trim().isEmpty ? null : value.trim();
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    return null;
  }

  /// Releases the underlying HTTP client, but only when this repository
  /// created it (an injected [ApiClient] may be shared with other
  /// repositories).
  void dispose() {
    if (_ownsApiClient) {
      _apiClient.close();
    }
  }
}
