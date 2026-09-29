import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/api_exceptions.dart';
import 'package:mobile/features/savings/bloc/sep24_bloc.dart';
import 'package:mobile/features/savings/data/sep24_repository.dart';
import 'package:mobile/features/savings/models/sep24_models.dart';
import 'package:mobile/features/savings/presentation/sep24_webview_page.dart';

/// Stand-in for the platform WebView: records every navigation the page
/// forwards and exposes the anchor's own redirects as tappable buttons.
class _FakeAnchor {
  Sep24WebViewRequest? request;

  /// URL -> whether the app consumed (blocked) the navigation.
  final Map<String, bool> decisions = <String, bool>{};
  final List<Sep24NavigationPhase> phases = <Sep24NavigationPhase>[];

  Widget build(BuildContext context, Sep24WebViewRequest request) {
    this.request = request;
    return Builder(
      builder: (context) => Column(
        children: <Widget>[
          Text('ANCHOR:${request.url}'),
          TextButton(
            key: const Key('anchor-awaiting'),
            onPressed: () => navigate(
              'zendvo://sep24/callback?id=anchor-tx-1'
              '&status=pending_user_transfer_start',
            ),
            child: const Text('awaiting'),
          ),
          TextButton(
            key: const Key('anchor-complete'),
            onPressed: () => navigate(
              'zendvo://sep24/callback?id=anchor-tx-1&status=completed'
              '&amount_in=50.00&asset_code=USDC',
            ),
            child: const Text('complete'),
          ),
          TextButton(
            key: const Key('anchor-fail'),
            onPressed: () => navigate(
              'zendvo://sep24/callback?id=anchor-tx-1&status=error'
              '&message=Bank+rejected+the+transfer',
            ),
            child: const Text('fail'),
          ),
          TextButton(
            key: const Key('anchor-page'),
            onPressed: () => navigate('https://anchor.example/sep24/help'),
            child: const Text('page'),
          ),
        ],
      ),
    );
  }

  Future<void> navigate(String url, {Sep24NavigationPhase? phase}) async {
    final consumed = await request!.onNavigation(
      url,
      phase ?? Sep24NavigationPhase.willLoad,
    );
    decisions[url] = consumed;
    phases.add(phase ?? Sep24NavigationPhase.willLoad);
  }
}

class _ScriptedRepository extends Sep24Repository {
  _ScriptedRepository({this.ticket, this.ticketError, this.gate})
    : super(baseUrl: 'http://backend.test');

  Sep24DepositTicket? ticket;
  Object? ticketError;
  Completer<void>? gate;

  int ticketCalls = 0;
  int statusCalls = 0;

  @override
  Future<Sep24DepositTicket> requestDepositTicket(
    Sep24DepositRequest request,
  ) async {
    ticketCalls++;
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
    throw const Sep24StatusUnavailableException();
  }
}

final _interactiveTicket = Sep24DepositTicket(
  kind: Sep24DepositResponseKind.interactive,
  interactiveUrl: Uri.parse('https://anchor.example/sep24/deposit/start'),
  transactionId: 'anchor-tx-1',
);

void main() {
  late _ScriptedRepository repository;
  late _FakeAnchor anchor;

  setUp(() {
    repository = _ScriptedRepository(ticket: _interactiveTicket);
    anchor = _FakeAnchor();
  });

  /// Advances time enough for the bloc to settle and for SnackBar timers to
  /// expire. `pumpAndSettle` cannot be used: the page keeps an indeterminate
  /// progress bar animating while the flow is in flight.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  }

  /// Pumps [Sep24WebViewPage] with a bloc whose flow has already reached the
  /// WebView state, using [_FakeAnchor] instead of a platform WebView.
  Future<Sep24Bloc> pumpWebViewPage(WidgetTester tester) async {
    final bloc = Sep24Bloc(repository: repository, enableStatusPolling: false);
    addTearDown(bloc.close);
    bloc.startDeposit(amount: '50.00', asset: 'USDC');
    await settle(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: Sep24WebViewPage(
          bloc: bloc,
          webViewFactory: anchor.build,
          successCloseDelay: Duration.zero,
        ),
      ),
    );
    await settle(tester);
    return bloc;
  }

  testWidgets('opens the anchor url with a live status strip', (tester) async {
    final bloc = await pumpWebViewPage(tester);

    expect(bloc.state, isA<Sep24WebViewOpen>());
    expect(
      find.text('ANCHOR:https://anchor.example/sep24/deposit/start'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Complete the deposit on the provider page'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsWidgets);
  });

  testWidgets('shows a waiting view while the anchor url is being fetched', (
    tester,
  ) async {
    final gate = Completer<void>();
    repository = _ScriptedRepository(ticket: _interactiveTicket, gate: gate);
    final bloc = Sep24Bloc(repository: repository, enableStatusPolling: false);
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Sep24WebViewPage(
          bloc: bloc,
          webViewFactory: anchor.build,
          successCloseDelay: Duration.zero,
        ),
      ),
    );
    bloc.startDeposit(amount: '50.00');
    await tester.pump();

    expect(bloc.state, isA<Sep24Loading>());
    expect(
      find.textContaining('Contacting the deposit provider'),
      findsOneWidget,
    );
    expect(find.textContaining('ANCHOR:'), findsNothing);

    gate.complete();
    await settle(tester);

    expect(bloc.state, isA<Sep24WebViewOpen>());
    expect(find.textContaining('ANCHOR:'), findsOneWidget);
  });

  testWidgets('blocks the completed callback, alerts and pops', (tester) async {
    final bloc = await pumpWebViewPage(tester);

    await tester.tap(find.byKey(const Key('anchor-complete')));
    await tester.pump();

    expect(
      anchor.decisions['zendvo://sep24/callback?id=anchor-tx-1&status=completed'
          '&amount_in=50.00&asset_code=USDC'],
      isTrue,
      reason: 'the handoff must not be loaded as a page',
    );
    expect(bloc.state, isA<Sep24Success>());
    // The user is alerted before the page closes.
    expect(
      find.textContaining('Deposit of 50.00 USDC completed'),
      findsOneWidget,
    );

    await settle(tester);
    expect(find.textContaining('ANCHOR:'), findsNothing);
  });

  testWidgets('keeps the page open for non-terminal statuses', (tester) async {
    final bloc = await pumpWebViewPage(tester);

    await tester.tap(find.byKey(const Key('anchor-awaiting')));
    await settle(tester);

    final state = bloc.state as Sep24WebViewOpen;
    expect(state.status, Sep24TransactionStatus.pendingUserTransferStart);
    expect(find.textContaining('Awaiting your transfer'), findsOneWidget);
    expect(find.textContaining('ANCHOR:'), findsOneWidget);
  });

  testWidgets('surfaces an anchor failure with a retry action', (tester) async {
    final bloc = await pumpWebViewPage(tester);

    await tester.tap(find.byKey(const Key('anchor-fail')));
    await settle(tester);

    expect(bloc.state, isA<Sep24Error>());
    expect(find.textContaining('Bank rejected the transfer'), findsWidgets);
    expect(find.byKey(const Key('anchor-complete')), findsNothing);

    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await settle(tester);

    expect(repository.ticketCalls, 2);
    expect(bloc.state, isA<Sep24WebViewOpen>());
    expect(find.textContaining('ANCHOR:'), findsOneWidget);
  });

  testWidgets('lets ordinary anchor pages load normally', (tester) async {
    await pumpWebViewPage(tester);

    await tester.tap(find.byKey(const Key('anchor-page')));
    await settle(tester);

    expect(
      anchor.decisions['https://anchor.example/sep24/help'],
      isFalse,
      reason: 'regular navigation must not be intercepted',
    );
  });

  testWidgets('closing the page cancels the flow and pops', (tester) async {
    final bloc = await pumpWebViewPage(tester);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);

    expect(bloc.state, isA<Sep24Initial>());
    expect(bloc.lastOutcome, Sep24FlowOutcome.cancelled);
    expect(find.textContaining('ANCHOR:'), findsNothing);
  });

  testWidgets('reports a network failure without leaving the flow stuck', (
    tester,
  ) async {
    repository = _ScriptedRepository(
      ticketError: const NetworkCongestedException(
        'The network is temporarily congested. Please try again shortly.',
      ),
    );
    final bloc = await pumpWebViewPage(tester);

    expect(bloc.state, isA<Sep24Error>());
    expect(find.text('Try again'), findsOneWidget);

    repository.ticketError = null;
    repository.ticket = _interactiveTicket;
    await tester.tap(find.text('Try again'));
    await settle(tester);

    expect(bloc.state, isA<Sep24WebViewOpen>());
    expect(find.textContaining('ANCHOR:'), findsOneWidget);
  });

  testWidgets('pops with the terminal state so callers can react', (
    tester,
  ) async {
    final bloc = Sep24Bloc(repository: repository, enableStatusPolling: false);
    addTearDown(bloc.close);
    bloc.startDeposit(amount: '50.00');
    await settle(tester);

    Sep24State? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<Sep24State>(
                MaterialPageRoute<Sep24State>(
                  builder: (context) => Sep24WebViewPage(
                    bloc: bloc,
                    webViewFactory: anchor.build,
                    successCloseDelay: Duration.zero,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('anchor-complete')));
    await settle(tester);

    expect(popped, isA<Sep24Success>());
    expect(find.textContaining('ANCHOR:'), findsNothing);
  });
}
