import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/api_exceptions.dart';
import 'package:mobile/features/savings/bloc/sep24_bloc.dart';
import 'package:mobile/features/savings/data/sep24_repository.dart';
import 'package:mobile/features/savings/models/sep24_models.dart';
import 'package:mobile/features/savings/presentation/sep24_deposit_page.dart';
import 'package:mobile/features/savings/presentation/sep24_webview_page.dart';

class _StubAnchor extends StatelessWidget {
  const _StubAnchor({required this.request});

  final Sep24WebViewRequest request;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('ANCHOR:${request.url}'),
            TextButton(
              key: const Key('stub-complete'),
              onPressed: () => request.onNavigation(
                'zendvo://sep24/callback?id=anchor-tx-1&status=completed'
                '&amount_in=50.00&asset_code=USDC',
                Sep24NavigationPhase.willLoad,
              ),
              child: const Text('complete'),
            ),
            TextButton(
              key: const Key('stub-close-flow'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('back to form'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FakeSep24Repository extends Sep24Repository {
  _FakeSep24Repository({this.ticket, this.ticketError, this.gate})
    : super(baseUrl: 'http://backend.test');

  Sep24DepositTicket? ticket;
  Object? ticketError;

  /// When set, the deposit request blocks until it completes, so the test can
  /// observe the in-flight state of the form.
  Completer<void>? gate;

  final List<Sep24DepositRequest> requests = <Sep24DepositRequest>[];

  @override
  Future<Sep24DepositTicket> requestDepositTicket(
    Sep24DepositRequest request,
  ) async {
    requests.add(request);
    await gate?.future;
    final error = ticketError;
    if (error != null) {
      throw error;
    }
    return ticket!;
  }

  @override
  Future<Sep24Callback> fetchTransactionStatus(String transactionId) async {
    throw const Sep24StatusUnavailableException();
  }
}

final _interactiveTicket = Sep24DepositTicket(
  kind: Sep24DepositResponseKind.interactive,
  interactiveUrl: Uri.parse('https://anchor.example/sep24/deposit/start'),
  transactionId: 'anchor-tx-1',
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 6));
  await tester.pump();
}

void main() {
  late _FakeSep24Repository repository;
  late Sep24Bloc bloc;

  Future<void> pumpForm(WidgetTester tester) async {
    bloc = Sep24Bloc(repository: repository, enableStatusPolling: false);
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Sep24DepositPage(
          bloc: bloc,
          prefillEmail: 'user@example.com',
          webViewFactory: (context, request) => _StubAnchor(request: request),
        ),
      ),
    );
    await settle(tester);
  }

  setUp(() {
    repository = _FakeSep24Repository(ticket: _interactiveTicket);
  });

  testWidgets('collects the parameters and opens the anchor page', (
    tester,
  ) async {
    await pumpForm(tester);

    expect(find.text('user@example.com'), findsOneWidget);
    expect(find.textContaining('USDC (Stellar)'), findsWidgets);

    await tester.enterText(find.byType(TextFormField).first, '50.00');
    await tester.tap(find.text('Continue with deposit'));
    await settle(tester);

    expect(repository.requests, hasLength(1));
    expect(repository.requests.single.amount, '50.00');
    expect(repository.requests.single.asset, 'USDC');
    expect(repository.requests.single.email, 'user@example.com');
    expect(bloc.state, isA<Sep24WebViewOpen>());
    expect(
      find.textContaining('ANCHOR:https://anchor.example/sep24/deposit/start'),
      findsOneWidget,
    );
  });

  testWidgets('the stubbed anchor completing the flow is reported back', (
    tester,
  ) async {
    await pumpForm(tester);
    await tester.enterText(find.byType(TextFormField).first, '50.00');
    await tester.tap(find.text('Continue with deposit'));
    await settle(tester);

    await tester.tap(find.byKey(const Key('stub-complete')));
    await settle(tester);

    expect(bloc.state, isA<Sep24Success>());
    expect(bloc.lastOutcome, Sep24FlowOutcome.success);

    // The anchor page closes itself on success and returns to the form.
    expect(find.textContaining('ANCHOR:'), findsNothing);
    expect(find.text('Continue with deposit'), findsOneWidget);
  });

  testWidgets('closing the anchor page reports a cancelled deposit', (
    tester,
  ) async {
    await pumpForm(tester);
    await tester.enterText(find.byType(TextFormField).first, '50.00');
    await tester.tap(find.text('Continue with deposit'));
    await settle(tester);
    expect(find.textContaining('ANCHOR:'), findsOneWidget);

    await tester.tap(find.text('back to form'));
    await settle(tester);

    expect(find.textContaining('ANCHOR:'), findsNothing);
    expect(find.text('Deposit cancelled.'), findsOneWidget);
    // Leaving the anchor page abandons the flow instead of leaving the bloc
    // stuck in "webview open".
    expect(bloc.state, isA<Sep24Initial>());
    expect(bloc.lastOutcome, Sep24FlowOutcome.cancelled);
  });

  testWidgets('shows the validation error without calling the backend', (
    tester,
  ) async {
    await pumpForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '0.10');
    await tester.tap(find.text('Continue with deposit'));
    await settle(tester);

    expect(find.text('The minimum deposit is 1.00 USDC.'), findsOneWidget);
    expect(repository.requests, isEmpty);
    expect(bloc.state, isA<Sep24Initial>());
  });

  testWidgets('surfaces a backend failure inline and keeps the form usable', (
    tester,
  ) async {
    repository = _FakeSep24Repository(
      ticketError: const TransactionFailedException(
        'No Stellar address registered for this account',
        statusCode: 400,
      ),
    );
    await pumpForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '75.00');
    await tester.tap(find.text('Continue with deposit'));
    await settle(tester);

    expect(bloc.state, isA<Sep24Error>());
    expect(
      find.text('No Stellar address registered for this account'),
      findsOneWidget,
    );
    expect(find.text('Continue with deposit'), findsOneWidget);
  });

  testWidgets('locks the form while the deposit request is in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    repository = _FakeSep24Repository(ticket: _interactiveTicket, gate: gate);
    await pumpForm(tester);
    await tester.enterText(find.byType(TextFormField).first, '50.00');
    await tester.tap(find.text('Continue with deposit'));
    await tester.pump();

    expect(bloc.state, isA<Sep24Loading>());
    expect(find.text('Continue with deposit'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await settle(tester);

    expect(bloc.state, isA<Sep24WebViewOpen>());
    expect(find.textContaining('ANCHOR:'), findsOneWidget);
  });
}
