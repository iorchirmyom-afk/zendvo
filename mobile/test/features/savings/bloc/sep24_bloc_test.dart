import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/api_exceptions.dart';
import 'package:mobile/features/savings/bloc/sep24_bloc.dart';
import 'package:mobile/features/savings/data/sep24_repository.dart';
import 'package:mobile/features/savings/models/sep24_models.dart';

/// Repository double: no sockets, fully scripted anchor answers.
class _FakeSep24Repository extends Sep24Repository {
  _FakeSep24Repository({this.ticket, this.gate})
    : super(baseUrl: 'http://backend.test');

  Sep24DepositTicket? ticket;
  Object? ticketError;
  Sep24Callback? statusCallback;
  Object? statusError;

  /// When set, [requestDepositTicket] waits for this completer, so tests can
  /// observe the intermediate loading state.
  final Completer<void>? gate;

  int ticketCalls = 0;
  int statusCalls = 0;
  Sep24DepositRequest? lastRequest;
  String? lastPolledId;

  @override
  Future<Sep24DepositTicket> requestDepositTicket(
    Sep24DepositRequest request,
  ) async {
    ticketCalls++;
    lastRequest = request;
    await gate?.future;
    final error = ticketError;
    if (error != null) {
      throw error;
    }
    return ticket!;
  }

  @override
  Future<Sep24Callback> fetchTransactionStatus(String transactionId) async {
    statusCalls++;
    lastPolledId = transactionId;
    final callback = statusCallback;
    if (callback != null) {
      return callback;
    }
    final error = statusError;
    if (error != null) {
      throw error;
    }
    // Not scripted: behave like a backend without the status route.
    throw const Sep24StatusUnavailableException();
  }
}

Sep24DepositTicket _interactiveTicket({
  String url = 'https://anchor.example/sep24/deposit/start',
  String id = 'anchor-tx-1',
}) {
  return Sep24DepositTicket(
    kind: Sep24DepositResponseKind.interactive,
    interactiveUrl: Uri.parse(url),
    transactionId: id,
  );
}

Sep24Callback _callback(String status, {String id = 'anchor-tx-1'}) {
  return const Sep24CallbackParser().tryParse(
    'zendvo://sep24/callback?id=$id&status=$status',
  )!;
}

/// Runs [act] on [bloc] and returns every state emitted while it settles.
Future<List<Sep24State>> _collect(
  Sep24Bloc bloc,
  void Function() act, {
  Duration? extraSettle,
}) async {
  final states = <Sep24State>[];
  final subscription = bloc.stream.listen(states.add);
  act();
  await pumpEventQueue();
  if (extraSettle != null) {
    await Future<void>.delayed(extraSettle);
    await pumpEventQueue();
  }
  await subscription.cancel();
  return states;
}

class _RecordingObserver extends BlocObserver {
  _RecordingObserver(this.errors);

  final List<Object> errors;

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    errors.add(error);
    super.onError(bloc, error, stackTrace);
  }
}

void main() {
  const depositRequest = Sep24DepositRequest(
    amount: '50.00',
    asset: 'USDC',
    email: 'user@example.com',
  );

  late _FakeSep24Repository repository;
  late Sep24Bloc bloc;

  Sep24Bloc buildBloc({
    bool enableStatusPolling = false,
    Duration pollInterval = const Duration(milliseconds: 5),
    void Function(Sep24State)? onTerminal,
  }) {
    return Sep24Bloc(
      repository: repository,
      enableStatusPolling: enableStatusPolling,
      pollInterval: pollInterval,
      onTerminal: onTerminal,
    );
  }

  setUp(() {
    repository = _FakeSep24Repository(ticket: _interactiveTicket());
    bloc = buildBloc();
  });

  tearDown(() async {
    await bloc.close();
  });

  group('state machine', () {
    test('starts in Sep24Initial and never touches the network', () {
      expect(bloc.state, isA<Sep24Initial>());
      expect(bloc.state.isBusy, isFalse);
      expect(repository.ticketCalls, 0);
    });

    test(
      'Initial -> Loading -> WebViewOpen when the anchor needs input',
      () async {
        final states = await _collect(
          bloc,
          () => bloc.startDeposit(amount: '50.00', email: 'user@example.com'),
        );

        expect(states, <Sep24State>[
          const Sep24Loading(
            phase: Sep24LoadingPhase.requestingAnchorUrl,
            request: depositRequest,
            message: 'Contacting the deposit provider…',
          ),
          Sep24WebViewOpen(
            url: Uri.parse('https://anchor.example/sep24/deposit/start'),
            request: depositRequest,
            transactionId: 'anchor-tx-1',
            statusMessage: 'Complete the deposit on the provider page.',
          ),
        ]);
        expect(bloc.state, isA<Sep24WebViewOpen>());
        expect(bloc.currentTransactionId, 'anchor-tx-1');
        expect(repository.lastRequest, depositRequest);
      },
    );

    test('sends the captured parameters to the backend', () async {
      await _collect(
        bloc,
        () => bloc.startDeposit(
          amount: '25.00',
          asset: 'USDC',
          email: 'a@b.c',
          phoneNumber: '+2348012345678',
          countryCode: 'NGA',
        ),
      );

      expect(repository.lastRequest?.toJson(), <String, dynamic>{
        'amount': '25.00',
        'asset_code': 'USDC',
        'asset': 'USDC',
        'kind': 'deposit',
        'lang': 'en',
        'email': 'a@b.c',
        'phone_number': '+2348012345678',
        'country_code': 'NGA',
      });
    });

    test('reports the loading phase while the anchor url is pending', () async {
      final gate = Completer<void>();
      repository = _FakeSep24Repository(
        ticket: _interactiveTicket(),
        gate: gate,
      );
      bloc = buildBloc();

      final states = <Sep24State>[];
      final subscription = bloc.stream.listen(states.add);
      bloc.startDeposit(amount: '50.00', email: 'user@example.com');
      await pumpEventQueue();

      expect(states, hasLength(1));
      expect(states.single, isA<Sep24Loading>());
      expect(bloc.state.isBusy, isTrue);

      gate.complete();
      await pumpEventQueue();
      await subscription.cancel();

      expect(states.last, isA<Sep24WebViewOpen>());
    });
  });

  group('validation and request failures', () {
    test('invalid amount fails fast without calling the backend', () async {
      final states = await _collect(bloc, () => bloc.startDeposit(amount: '0'));

      final error = bloc.state;
      expect(error, isA<Sep24Error>());
      expect((error as Sep24Error).message, contains('greater than zero'));
      expect(error.recoverable, isTrue);
      expect(states, hasLength(1));
      expect(repository.ticketCalls, 0);
    });

    test('anchor rejection surfaces the anchor message', () async {
      repository.ticket = const Sep24DepositTicket(
        kind: Sep24DepositResponseKind.error,
        error: 'no market for USD/USDC',
      );

      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));

      expect((bloc.state as Sep24Error).message, 'no market for USD/USDC');
    });

    test('network congestion is retryable', () async {
      repository.ticketError = const NetworkCongestedException(
        'The network is temporarily congested. Please try again shortly.',
        statusCode: 503,
      );

      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));

      final error = bloc.state as Sep24Error;
      expect(error.recoverable, isTrue);
      expect(error.message, contains('congested'));
    });

    test(
      'a missing anchor endpoint is explained instead of crashing',
      () async {
        repository.ticketError = const ApiRequestException(
          'Not Found',
          statusCode: 404,
        );

        await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));

        final error = bloc.state as Sep24Error;
        expect(error.message, contains('not available yet'));
        expect(error.recoverable, isFalse);
      },
    );

    test(
      'unexpected failures map to a generic message and are reported',
      () async {
        final observed = <Object>[];
        final previousObserver = Bloc.observer;
        Bloc.observer = _RecordingObserver(observed);
        addTearDown(() => Bloc.observer = previousObserver);
        // BlocBase captures Bloc.observer at construction, so the bloc under
        // test has to be built after the recorder is installed.
        bloc = buildBloc();

        repository.ticketError = StateError('boom');
        await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));

        expect((bloc.state as Sep24Error).message, contains('try again'));
        expect(observed, contains(isA<StateError>()));
      },
    );

    test('retry() reuses the last request', () async {
      repository.ticketError = const NetworkCongestedException('congested');
      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      expect(bloc.state, isA<Sep24Error>());

      repository.ticketError = null;
      await _collect(bloc, bloc.retry);

      expect(bloc.state, isA<Sep24WebViewOpen>());
      expect(repository.ticketCalls, 2);
    });
  });

  group('webview status callbacks', () {
    /// Starts the flow so a callback arrives while the page is open, then
    /// reports [url] to the bloc.
    Future<void> navigate(String url, {bool start = true}) async {
      if (start) {
        await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      }
      await _collect(bloc, () => bloc.reportNavigation(url));
    }

    test('completed callback moves to Sep24Success', () async {
      await navigate(
        'zendvo://sep24/callback?id=anchor-tx-1&status=completed'
        '&amount_in=50.00&asset_code=USDC',
      );

      final success = bloc.state as Sep24Success;
      expect(success.transactionId, 'anchor-tx-1');
      expect(success.amountIn, '50.00');
      expect(success.assetCode, 'USDC');
      expect(success.userMessage, 'Deposit of 50.00 USDC completed.');
      expect(bloc.lastOutcome, Sep24FlowOutcome.success);
    });

    test(
      'non-terminal callback keeps the page open and updates the status',
      () async {
        await navigate(
          'zendvo://sep24/callback?id=anchor-tx-1&status=pending_user_transfer_start',
        );

        final open = bloc.state;
        expect(open, isA<Sep24WebViewOpen>());
        expect(
          (open as Sep24WebViewOpen).status,
          Sep24TransactionStatus.pendingUserTransferStart,
        );
        expect(open.status.label, 'Awaiting your transfer');
        expect(open.statusLabel, contains('Awaiting your transfer'));
      },
    );

    test('terminal failure callback moves to Sep24Error', () async {
      await navigate('zendvo://sep24/callback?id=anchor-tx-1&status=too_small');

      final error = bloc.state as Sep24Error;
      expect(error.status, Sep24TransactionStatus.tooSmall);
      expect(error.message, 'The amount is below the anchor minimum.');
      expect(bloc.lastOutcome, Sep24FlowOutcome.failure);
    });

    test('cancel callback returns to Sep24Initial', () async {
      await navigate('zendvo://sep24/callback?cancelled=true');

      expect(bloc.state, isA<Sep24Initial>());
      expect(bloc.lastOutcome, Sep24FlowOutcome.cancelled);
    });

    test('ordinary anchor navigation is ignored', () async {
      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      final before = bloc.state;
      expect(before, isA<Sep24WebViewOpen>());

      await _collect(
        bloc,
        () => bloc.reportNavigation('https://anchor.example/sep24/help'),
      );

      expect(identical(bloc.state, before), isTrue);
    });

    test('a handoff without a status is confirmed with the backend', () async {
      bloc = buildBloc(
        enableStatusPolling: true,
        pollInterval: const Duration(days: 1),
      );
      repository.statusCallback = _callback('completed');

      await navigate('zendvo://sep24/callback?id=anchor-tx-1');

      expect(bloc.state, isA<Sep24Success>());
      expect(repository.statusCalls, greaterThan(0));
      expect(repository.lastPolledId, 'anchor-tx-1');
    });

    test('a handoff with an unreachable status endpoint stays open', () async {
      bloc = buildBloc(
        enableStatusPolling: true,
        pollInterval: const Duration(days: 1),
      );
      repository.statusError = const Sep24StatusUnavailableException();

      await navigate('zendvo://sep24/callback?id=anchor-tx-1');

      final open = bloc.state as Sep24WebViewOpen;
      expect(open.statusMessage, contains('Waiting for the deposit provider'));
      expect(bloc.isPollingStatus, isFalse);
    });
  });

  group('backend status tracking', () {
    test('`type: transaction` resolves through the status endpoint', () async {
      repository.ticket = const Sep24DepositTicket(
        kind: Sep24DepositResponseKind.transaction,
        transactionId: 'tx-9',
        status: Sep24TransactionStatus.pendingUserTransferStart,
      );
      repository.statusCallback = _callback('completed', id: 'tx-9');

      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));

      expect(bloc.state, isA<Sep24Success>());
      expect(repository.lastPolledId, 'tx-9');
    });

    test(
      '`type: transaction` without a status endpoint explains itself',
      () async {
        repository.ticket = const Sep24DepositTicket(
          kind: Sep24DepositResponseKind.transaction,
          transactionId: 'tx-9',
          status: Sep24TransactionStatus.pendingUserTransferStart,
        );
        repository.statusError = const Sep24StatusUnavailableException();

        await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));

        final error = bloc.state as Sep24Error;
        expect(error.message, contains('cannot be checked yet'));
      },
    );

    test('polling promotes the open page to success', () async {
      bloc = buildBloc(enableStatusPolling: true);
      repository.statusCallback = _callback('completed');

      await _collect(
        bloc,
        () => bloc.startDeposit(amount: '50.00'),
        extraSettle: const Duration(milliseconds: 30),
      );

      expect(bloc.state, isA<Sep24Success>());
      expect(bloc.isPollingStatus, isFalse);
      expect(repository.statusCalls, greaterThan(0));
    });

    test('manual refreshStatus picks up a completed deposit', () async {
      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      repository.statusCallback = _callback('completed');

      await _collect(bloc, bloc.refreshStatus);

      expect(bloc.state, isA<Sep24Success>());
    });

    test('transient poll errors keep the flow and the timer alive', () async {
      bloc = buildBloc(enableStatusPolling: true);
      repository.statusError = const NetworkCongestedException('busy');

      await _collect(
        bloc,
        () => bloc.startDeposit(amount: '50.00'),
        extraSettle: const Duration(milliseconds: 20),
      );

      expect(bloc.state, isA<Sep24WebViewOpen>());
      expect(bloc.isPollingStatus, isTrue);
    });
  });

  group('user intent', () {
    test('cancelDeposit aborts an in-flight flow', () async {
      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      await _collect(bloc, bloc.cancelDeposit);

      expect(bloc.state, isA<Sep24Initial>());
      expect(bloc.lastOutcome, Sep24FlowOutcome.cancelled);
      expect(bloc.isPollingStatus, isFalse);
    });

    test('resetFlow clears the captured parameters', () async {
      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      await _collect(bloc, bloc.resetFlow);

      expect(bloc.state, isA<Sep24Initial>());
      expect(bloc.currentRequest, isNull);
      expect(bloc.currentTransactionId, isNull);
    });

    test('onTerminal fires once with the terminal state', () async {
      final terminals = <Sep24State>[];
      bloc = buildBloc(onTerminal: terminals.add);
      repository.statusCallback = _callback('completed');

      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      await _collect(
        bloc,
        () => bloc.reportNavigation(_callback('completed').uri.toString()),
      );

      expect(terminals, hasLength(1));
      expect(terminals.single, isA<Sep24Success>());
    });

    test('close() stops the poller', () async {
      bloc = buildBloc(enableStatusPolling: true);
      await _collect(bloc, () => bloc.startDeposit(amount: '50.00'));
      expect(bloc.isPollingStatus, isTrue);

      await bloc.close();

      expect(bloc.isPollingStatus, isFalse);
      expect(bloc.isClosed, isTrue);
    });
  });
}
