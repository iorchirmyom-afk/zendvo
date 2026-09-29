import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/api_client.dart';
import 'package:mobile/core/network/api_exceptions.dart';

/// Local server used to exercise `ApiClient.getWithRetry` without touching the
/// internet. Returns the server, the URL to call and the request log.
Future<(HttpServer, String, List<String>)> startServer(
  Future<void> Function(HttpRequest) handler,
) async {
  final seen = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    seen.add(request.method);
    try {
      await handler(request);
    } catch (error, stackTrace) {
      try {
        await request.response.close();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  });
  final url = 'http://127.0.0.1:${server.port}/status?id=1';
  return (server, url, seen);
}

Future<void> jsonResponse(
  HttpRequest request,
  int statusCode, [
  Map<String, dynamic>? body,
]) async {
  await request.drain<void>();
  request.response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body ?? <String, dynamic>{}));
  await request.response.close();
}

void main() {
  group('ApiClient.getWithRetry', () {
    test('returns the decoded body and sends the bearer token', () async {
      final (server, url, seen) = await startServer((request) async {
        expect(request.method, 'GET');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-token',
        );
        return jsonResponse(request, 200, {'status': 'completed'});
      });
      addTearDown(() => server.close(force: true));

      final client = ApiClient(
        authTokenProvider: () async => 'test-token',
        baseDelay: const Duration(milliseconds: 1),
      );
      addTearDown(client.close);

      final result = await client.getWithRetry(url);

      expect(result, {'status': 'completed'});
      expect(seen, ['GET']);
    });

    test('retries transient 503 responses and then succeeds', () async {
      var attempts = 0;
      final (server, url, _) = await startServer((request) async {
        attempts++;
        if (attempts < 3) {
          return jsonResponse(request, 503, {'message': 'node overloaded'});
        }
        return jsonResponse(request, 200, {'status': 'pending_anchor'});
      });
      addTearDown(() => server.close(force: true));

      final client = ApiClient(baseDelay: const Duration(milliseconds: 1));
      addTearDown(client.close);

      final result = await client.getWithRetry(url);

      expect(result['status'], 'pending_anchor');
      expect(attempts, 3);
    });

    test('does not retry permanent 4xx responses', () async {
      var attempts = 0;
      final (server, url, _) = await startServer((request) async {
        attempts++;
        return jsonResponse(request, 404, {'detail': 'unknown transaction'});
      });
      addTearDown(() => server.close(force: true));

      final client = ApiClient(baseDelay: const Duration(milliseconds: 1));
      addTearDown(client.close);

      await expectLater(
        client.getWithRetry(url),
        throwsA(
          isA<ApiRequestException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', 'unknown transaction'),
        ),
      );
      expect(attempts, 1);
    });

    test(
      'gives up with a congestion error once retries are exhausted',
      () async {
        final (server, url, seen) = await startServer((request) async {
          return jsonResponse(request, 500, {'message': 'boom'});
        });
        addTearDown(() => server.close(force: true));

        final client = ApiClient(
          maxRetries: 2,
          baseDelay: const Duration(milliseconds: 1),
        );
        addTearDown(client.close);

        await expectLater(
          client.getWithRetry(url),
          throwsA(isA<NetworkCongestedException>()),
        );
        expect(seen, hasLength(2));
      },
    );

    test('tolerates an empty body', () async {
      final (server, url, _) = await startServer(
        (request) => jsonResponse(request, 204),
      );
      addTearDown(() => server.close(force: true));

      final client = ApiClient(baseDelay: const Duration(milliseconds: 1));
      addTearDown(client.close);

      expect(await client.getWithRetry(url), isEmpty);
    });

    test('postWithRetry keeps mapping statuses the same way', () async {
      final (server, url, _) = await startServer(
        (request) => jsonResponse(request, 409, {'message': 'already there'}),
      );
      addTearDown(() => server.close(force: true));

      final client = ApiClient(baseDelay: const Duration(milliseconds: 1));
      addTearDown(client.close);

      await expectLater(
        client.postWithRetry(url, const <String, dynamic>{}),
        throwsA(
          isA<ConflictException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });
  });
}
