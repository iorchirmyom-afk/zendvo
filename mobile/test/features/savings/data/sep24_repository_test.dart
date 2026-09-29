import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/api_client.dart';
import 'package:mobile/core/network/api_exceptions.dart';
import 'package:mobile/features/savings/data/sep24_repository.dart';
import 'package:mobile/features/savings/models/sep24_models.dart';

/// Starts a local HTTP server that responds according to [handler], and
/// returns it together with its base URL.
Future<(HttpServer, List<String>, Uri)> startServer(
  Future<void> Function(HttpRequest) handler,
) async {
  final requests = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUri = Uri.parse('http://127.0.0.1:${server.port}');
  server.listen((request) async {
    requests.add('${request.method} ${request.uri}');
    try {
      await handler(request);
    } catch (error, stackTrace) {
      try {
        await request.response.close();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  });
  return (server, requests, baseUri);
}

Future<void> jsonResponse(
  HttpRequest request,
  int statusCode,
  Map<String, dynamic> body,
) async {
  try {
    await request.drain<void>();
  } on StateError {
    // The test handler already consumed the body to assert on it.
  }
  request.response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

Sep24Repository buildRepository(
  Uri baseUri, {
  Map<String, dynamic>? overrides,
}) {
  return Sep24Repository(
    baseUrl: baseUri.toString(),
    apiClient: ApiClient(
      authTokenProvider: () async => 'test-token',
      baseDelay: const Duration(milliseconds: 1),
    ),
  );
}

void main() {
  const request = Sep24DepositRequest(
    amount: '50.00',
    asset: 'USDC',
    email: 'user@example.com',
    account: 'GABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ01',
  );

  group('Sep24Repository.requestDepositTicket', () {
    test(
      'posts the deposit parameters and returns the interactive url',
      () async {
        late Map<String, dynamic> received;
        late String path;
        final (server, requests, baseUri) = await startServer((req) async {
          path = req.uri.path;
          received =
              jsonDecode(await utf8.decoder.bind(req).join())
                  as Map<String, dynamic>;
          return jsonResponse(req, 200, <String, dynamic>{
            'type': 'interactive_customer_info_needed',
            'url': 'https://anchor.example/sep24/deposit/start',
            'id': 'anchor-tx-1',
          });
        });
        addTearDown(() => server.close(force: true));

        final ticket = await buildRepository(
          baseUri,
        ).requestDepositTicket(request);

        expect(path, '/api/savings/sep24/deposit');
        expect(requests, hasLength(1));
        expect(received['amount'], '50.00');
        expect(received['asset_code'], 'USDC');
        expect(received['email'], 'user@example.com');
        expect(received['account'], isNotEmpty);
        expect(ticket.kind, Sep24DepositResponseKind.interactive);
        expect(ticket.transactionId, 'anchor-tx-1');
        expect(
          ticket.interactiveUrl.toString(),
          'https://anchor.example/sep24/deposit/start'
          '?callback=zendvo%3A%2F%2Fsep24%2Fcallback',
        );
      },
    );

    test('can be pointed at a different anchor route', () async {
      late String path;
      final (server, _, baseUri) = await startServer((req) async {
        path = req.uri.path;
        return jsonResponse(req, 200, <String, dynamic>{
          'type': 'interactive_customer_info_needed',
          'url': 'https://anchor.example/start',
        });
      });
      addTearDown(() => server.close(force: true));

      final repository = Sep24Repository(
        baseUrl: baseUri.toString(),
        depositPath: 'api/wallet/sep24/deposit',
        apiClient: ApiClient(baseDelay: const Duration(milliseconds: 1)),
      );
      final ticket = await repository.requestDepositTicket(request);

      expect(path, '/api/wallet/sep24/deposit');
      expect(ticket.needsWebView, isTrue);
    });

    test('leaves an anchor-provided callback parameter untouched', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{
          'type': 'interactive_customer_info_needed',
          'url': 'https://anchor.example/start?callback=https%3A%2F%2Fkeep.me',
        });
      });
      addTearDown(() => server.close(force: true));

      final ticket = await buildRepository(
        baseUri,
      ).requestDepositTicket(request);

      expect(
        ticket.interactiveUrl!.queryParameters['callback'],
        'https://keep.me',
      );
    });

    test('does not append a callback when disabled', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{
          'type': 'interactive_customer_info_needed',
          'url': 'https://anchor.example/start',
        });
      });
      addTearDown(() => server.close(force: true));

      final repository = Sep24Repository(
        baseUrl: baseUri.toString(),
        attachCallbackUrl: false,
        apiClient: ApiClient(baseDelay: const Duration(milliseconds: 1)),
      );
      final ticket = await repository.requestDepositTicket(request);

      expect(ticket.interactiveUrl.toString(), 'https://anchor.example/start');
    });

    test('rejects invalid parameters before hitting the network', () async {
      final (server, requests, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{});
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        buildRepository(
          baseUri,
        ).requestDepositTicket(const Sep24DepositRequest(amount: '-1')),
        throwsA(
          isA<Sep24Exception>().having(
            (e) => e.message,
            'message',
            'The amount must be greater than zero.',
          ),
        ),
      );
      expect(requests, isEmpty);
    });

    test('propagates the anchor validation error from the backend', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 400, <String, dynamic>{
          'message': 'amount exceeds the anchor maximum',
        });
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        buildRepository(baseUri).requestDepositTicket(request),
        throwsA(
          isA<TransactionFailedException>().having(
            (e) => e.message,
            'message',
            'amount exceeds the anchor maximum',
          ),
        ),
      );
    });

    test('surfaces an anchor error body returned with 200 OK', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{
          'type': 'error',
          'error': 'deposit is disabled',
        });
      });
      addTearDown(() => server.close(force: true));

      final ticket = await buildRepository(
        baseUri,
      ).requestDepositTicket(request);

      expect(ticket.isRejected, isTrue);
      expect(ticket.error, 'deposit is disabled');
    });

    test('surfaces a missing interactive url as a rejection', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{'ok': true});
      });
      addTearDown(() => server.close(force: true));

      final ticket = await buildRepository(
        baseUri,
      ).requestDepositTicket(request);

      expect(ticket.isRejected, isTrue);
      expect(ticket.error, contains('did not return an interactive URL'));
    });
  });

  group('Sep24Repository.fetchTransactionStatus', () {
    test('reads the status for the transaction id', () async {
      late String received;
      final (server, requests, baseUri) = await startServer((req) async {
        received = '${req.method} ${req.uri.path}?${req.uri.query}';
        return jsonResponse(req, 200, <String, dynamic>{
          'id': 'anchor-tx-1',
          'status': 'pending_anchor',
          'amount_in': '50.00',
          'asset_code': 'USDC',
        });
      });
      addTearDown(() => server.close(force: true));

      final callback = await buildRepository(
        baseUri,
      ).fetchTransactionStatus('anchor-tx-1');

      expect(received, 'GET /api/savings/sep24/transaction?id=anchor-tx-1');
      expect(requests, hasLength(1));
      expect(callback.status, Sep24TransactionStatus.pendingAnchor);
      expect(callback.amountIn, '50.00');
      expect(callback.assetCode, 'USDC');
    });

    test(
      'unwraps the {data: ...} envelope and keeps the flow in progress',
      () async {
        final (server, _, baseUri) = await startServer((req) async {
          return jsonResponse(req, 200, <String, dynamic>{
            'data': <String, dynamic>{
              'id': 'tx-2',
              'status': 'completed',
              'message': 'Deposit completed',
            },
          });
        });
        addTearDown(() => server.close(force: true));

        final callback = await buildRepository(
          baseUri,
        ).fetchTransactionStatus('tx-2');

        expect(callback.outcome, Sep24FlowOutcome.success);
        expect(callback.transactionId, 'tx-2');
        expect(callback.displayMessage, 'Deposit completed');
      },
    );

    test('treats an unknown route as "status unavailable"', () async {
      final (server, requests, baseUri) = await startServer((req) async {
        return jsonResponse(req, 404, <String, dynamic>{
          'detail': 'route not found',
        });
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        buildRepository(baseUri).fetchTransactionStatus('anchor-tx-1'),
        throwsA(isA<Sep24StatusUnavailableException>()),
      );
      // 4xx is permanent: the client must not retry it.
      expect(requests, hasLength(1));
    });

    test('unwraps a {transaction: ...} envelope and coerces scalars', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{
          'transaction': <String, dynamic>{
            'id': 1234,
            'status': 'pending_stellar',
            'amount_in': 12.5,
            'status_eta': 45,
            'refunded': false,
          },
        });
      });
      addTearDown(() => server.close(force: true));

      final callback = await buildRepository(
        baseUri,
      ).fetchTransactionStatus('tx-3');

      expect(callback.transactionId, '1234');
      expect(callback.status, Sep24TransactionStatus.pendingStellar);
      expect(callback.amountIn, '12.5');
      expect(callback.statusEta, 45);
      expect(callback.outcome, Sep24FlowOutcome.inProgress);
    });

    test('unwraps a {transactions: [ ... ]} list response', () async {
      final (server, _, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{
          'transactions': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'tx-4', 'status': 'expired'},
          ],
        });
      });
      addTearDown(() => server.close(force: true));

      final callback = await buildRepository(
        baseUri,
      ).fetchTransactionStatus('tx-4');

      expect(callback.status, Sep24TransactionStatus.expired);
      expect(callback.outcome, Sep24FlowOutcome.failure);
    });

    test('dispose() never closes an injected shared client', () async {
      final (server, requests, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{
          'id': 'tx-5',
          'status': 'completed',
        });
      });
      addTearDown(() => server.close(force: true));

      final shared = ApiClient(baseDelay: const Duration(milliseconds: 1));
      final repository = Sep24Repository(
        baseUrl: baseUri.toString(),
        apiClient: shared,
      );
      repository.dispose();

      // The client belongs to the caller, so it is still usable afterwards.
      expect(repository.baseUrl, baseUri.toString());
      await repository.fetchTransactionStatus('tx-5');
      expect(requests, hasLength(1));
      shared.close();
    });

    test('an empty id never reaches the network', () async {
      final (server, requests, baseUri) = await startServer((req) async {
        return jsonResponse(req, 200, <String, dynamic>{});
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        buildRepository(baseUri).fetchTransactionStatus('  '),
        throwsA(isA<Sep24StatusUnavailableException>()),
      );
      expect(requests, isEmpty);
    });

    test('transient congestion is retried and then reported', () async {
      final attempts = <int>[];
      final (server, _, baseUri) = await startServer((req) async {
        attempts.add(attempts.length + 1);
        return jsonResponse(req, 503, <String, dynamic>{
          'message': 'node overloaded',
        });
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        buildRepository(baseUri).fetchTransactionStatus('anchor-tx-1'),
        throwsA(isA<NetworkCongestedException>()),
      );
      expect(attempts, hasLength(3));
    });
  });
}
