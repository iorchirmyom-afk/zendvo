import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/savings/models/sep24_models.dart';

void main() {
  group('Sep24TransactionStatus.fromRaw', () {
    test(
      'parses the SEP-24 statuses the anchor and the backend webhook use',
      () {
        expect(
          Sep24TransactionStatus.fromRaw('pending_user_transfer_start'),
          Sep24TransactionStatus.pendingUserTransferStart,
        );
        expect(
          Sep24TransactionStatus.fromRaw('pending_anchor'),
          Sep24TransactionStatus.pendingAnchor,
        );
        expect(
          Sep24TransactionStatus.fromRaw('completed'),
          Sep24TransactionStatus.completed,
        );
        expect(
          Sep24TransactionStatus.fromRaw('too_small'),
          Sep24TransactionStatus.tooSmall,
        );
      },
    );

    test('tolerates casing, dashes and blank input', () {
      expect(
        Sep24TransactionStatus.fromRaw(' PENDING-USER_TRANSFER_COMPLETE '),
        Sep24TransactionStatus.pendingUserTransferComplete,
      );
      expect(
        Sep24TransactionStatus.fromRaw(''),
        Sep24TransactionStatus.unknown,
      );
      expect(
        Sep24TransactionStatus.fromRaw(null),
        Sep24TransactionStatus.unknown,
      );
    });

    test('maps the simplified /transactions statuses', () {
      expect(
        Sep24TransactionStatus.fromRaw('ready'),
        Sep24TransactionStatus.pendingUserTransferComplete,
      );
      expect(
        Sep24TransactionStatus.fromRaw('pending'),
        Sep24TransactionStatus.pendingAnchor,
      );
      expect(
        Sep24TransactionStatus.fromRaw('success'),
        Sep24TransactionStatus.completed,
      );
      expect(
        Sep24TransactionStatus.fromRaw('failed'),
        Sep24TransactionStatus.error,
      );
    });

    test('classifies terminal vs in-progress statuses', () {
      expect(Sep24TransactionStatus.completed.isTerminalSuccess, isTrue);
      expect(Sep24TransactionStatus.completed.isTerminal, isTrue);
      expect(Sep24TransactionStatus.completed.isInProgress, isFalse);
      expect(Sep24TransactionStatus.expired.isTerminalFailure, isTrue);
      expect(Sep24TransactionStatus.refunded.isTerminalFailure, isTrue);
      expect(Sep24TransactionStatus.pendingTrust.isTerminal, isFalse);
      expect(Sep24TransactionStatus.unknown.isTerminal, isFalse);
      expect(Sep24TransactionStatus.tooSmall.terminalMessage, isNotNull);
      expect(Sep24TransactionStatus.pendingStellar.terminalMessage, isNull);
    });
  });

  group('Sep24DepositRequest', () {
    test('rejects amounts that are not numbers, zero or below the minimum', () {
      expect(
        const Sep24DepositRequest(amount: '').validationError,
        'Enter the amount you want to deposit.',
      );
      expect(
        const Sep24DepositRequest(amount: 'abc').validationError,
        'Enter the amount you want to deposit.',
      );
      expect(
        const Sep24DepositRequest(amount: '0').validationError,
        'The amount must be greater than zero.',
      );
      expect(
        const Sep24DepositRequest(amount: '0.50').validationError,
        contains('minimum deposit'),
      );
      expect(const Sep24DepositRequest(amount: '50.00').isValid, isTrue);
    });

    test('validates optional email and destination account when provided', () {
      expect(
        const Sep24DepositRequest(
          amount: '10',
          email: 'not-an-email',
        ).validationError,
        'Enter a valid email address.',
      );
      expect(
        const Sep24DepositRequest(amount: '10', account: 'GAB').validationError,
        contains('Stellar account'),
      );
      expect(
        const Sep24DepositRequest(amount: '10', email: '', account: '').isValid,
        isTrue,
      );
    });

    test('serialises the anchor body, dropping blank optional fields', () {
      const request = Sep24DepositRequest(
        amount: ' 25.00 ',
        asset: 'USDC',
        email: ' user@example.com ',
        phoneNumber: '',
        countryCode: 'NGA',
        extraFields: <String, String>{'first_name': ' Ada ', 'blank': ''},
      );

      expect(request.toJson(), <String, dynamic>{
        'amount': '25.00',
        'asset_code': 'USDC',
        'asset': 'USDC',
        'kind': 'deposit',
        'lang': 'en',
        'email': 'user@example.com',
        'country_code': 'NGA',
        'first_name': 'Ada',
      });
    });

    test('copyWith replaces only what it is given', () {
      const base = Sep24DepositRequest(
        amount: '10',
        asset: 'USDC',
        email: 'a@b.c',
      );
      final copy = base.copyWith(amount: '20', extraFields: const {'k': 'v'});

      expect(copy.amount, '20');
      expect(copy.asset, 'USDC');
      expect(copy.email, 'a@b.c');
      expect(copy.extraFields, const {'k': 'v'});
      expect(copy.countryCode, isNull);
    });

    test('equality is structural, including extra fields', () {
      const a = Sep24DepositRequest(amount: '10', extraFields: {'k': 'v'});
      const b = Sep24DepositRequest(amount: '10', extraFields: {'k': 'v'});
      const c = Sep24DepositRequest(amount: '11', extraFields: {'k': 'v'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('Sep24DepositTicket.fromJson', () {
    test('reads an interactive_customer_info_needed response', () {
      final ticket = Sep24DepositTicket.fromJson(<String, dynamic>{
        'type': 'interactive_customer_info_needed',
        'url': 'https://anchor.example/sep24/deposit/start?id=42',
        'id': '42',
      });

      expect(ticket.kind, Sep24DepositResponseKind.interactive);
      expect(ticket.needsWebView, isTrue);
      expect(ticket.transactionId, '42');
      expect(
        ticket.interactiveUrl.toString(),
        'https://anchor.example/sep24/deposit/start?id=42',
      );
    });

    test('reads a transaction response with no interactive page needed', () {
      final ticket = Sep24DepositTicket.fromJson(<String, dynamic>{
        'type': 'transaction',
        'transaction': <String, dynamic>{
          'id': 'tx-1',
          'status': 'pending_user_transfer_start',
          'amount_in': '50.00',
        },
      });

      expect(ticket.kind, Sep24DepositResponseKind.transaction);
      expect(ticket.needsWebView, isFalse);
      expect(ticket.transactionId, 'tx-1');
      expect(ticket.status, Sep24TransactionStatus.pendingUserTransferStart);
    });

    test('reads an anchor error response', () {
      final ticket = Sep24DepositTicket.fromJson(<String, dynamic>{
        'type': 'error',
        'error': 'no market for asset USDC',
      });

      expect(ticket.isRejected, isTrue);
      expect(ticket.error, 'no market for asset USDC');
    });

    test(
      'falls back to a rejection when the anchor returns neither url nor id',
      () {
        final ticket = Sep24DepositTicket.fromJson(<String, dynamic>{
          'ok': true,
        });

        expect(ticket.kind, Sep24DepositResponseKind.error);
        expect(ticket.error, contains('interactive URL'));
      },
    );
  });

  group('Sep24CallbackParser', () {
    const parser = Sep24CallbackParser();

    test('recognises the app callback and ignores normal anchor pages', () {
      expect(
        parser.tryParse('https://anchor.example/sep24/deposit/start?id=42'),
        isNull,
      );
      expect(parser.tryParse(''), isNull);
      expect(parser.tryParse(null), isNull);

      final callback = parser.tryParse(
        'zendvo://sep24/callback?id=42&status=pending_anchor&amount_in=50',
      );
      expect(callback, isNotNull);
      expect(callback!.transactionId, '42');
      expect(callback.status, Sep24TransactionStatus.pendingAnchor);
      expect(callback.amountIn, '50');
      expect(callback.outcome, Sep24FlowOutcome.inProgress);
    });

    test('resolves a completed callback to success', () {
      final callback = parser.tryParse(
        'zendvo://sep24/callback?id=42&status=completed&amount_in=50'
        '&asset_code=USDC',
      )!;

      expect(callback.outcome, Sep24FlowOutcome.success);
      expect(callback.assetCode, 'USDC');
      expect(callback.displayMessage, 'Deposit of 50 USDC: Completed.');
    });

    test('resolves a failure status, keeping the anchor message', () {
      final callback = parser.tryParse(
        'zendvo://sep24/callback?id=42&status=error&message=Bank+rejected',
      )!;

      expect(callback.outcome, Sep24FlowOutcome.failure);
      expect(callback.message, 'Bank rejected');
    });

    test('detects a user cancellation', () {
      final cancelCallback = parser.tryParse(
        'zendvo://sep24/callback?cancelled=true',
      )!;
      expect(cancelCallback.outcome, Sep24FlowOutcome.cancelled);
      expect(cancelCallback.displayMessage, 'Deposit cancelled.');
      expect(
        parser.tryParse('zendvo://sep24/cancel')!.outcome,
        Sep24FlowOutcome.cancelled,
      );
      expect(
        parser.tryParse('zendvo://sep24/callback?status=cancelled')!.outcome,
        Sep24FlowOutcome.cancelled,
      );
    });

    test('reads status parameters from the fragment as well as the query', () {
      final callback = parser.tryParse(
        'zendvo://sep24/callback#id=7&status=completed&amount_in=12.5',
      )!;

      expect(callback.transactionId, '7');
      expect(callback.status, Sep24TransactionStatus.completed);
      expect(callback.amountIn, '12.5');
    });

    test('treats a bare handoff as "needs confirmation"', () {
      final callback = parser.tryParse('zendvo://sep24/callback?id=42')!;

      expect(callback.hasStatus, isFalse);
      expect(callback.outcome, Sep24FlowOutcome.pendingConfirmation);
    });

    test('matches an allow-listed backend host on a callback path', () {
      const withBackend = Sep24CallbackParser(
        additionalHosts: <String>{'api.zendvo.test'},
      );

      expect(
        withBackend
            .tryParse(
              'https://api.zendvo.test/api/webhooks/sep24?id=9&status=completed',
            )!
            .status,
        Sep24TransactionStatus.completed,
      );
      expect(
        withBackend
            .tryParse('https://api.zendvo.test/other/sep24?id=9')!
            .transactionId,
        '9',
      );
      expect(
        withBackend.tryParse('https://anchor.example/api/webhooks/sep24'),
        isNull,
      );
    });
  });

  group('Sep24Callback', () {
    test('exposes status eta and amount text from a parsed uri', () {
      final callback = const Sep24CallbackParser().parse(
        Uri.parse(
          'zendvo://sep24/callback?id=1&status=pending_external'
          '&amount_in=5.00&asset_code=USDC&status_eta=30',
        ),
      );

      expect(callback.statusEta, 30);
      expect(callback.amountText, '5.00 USDC');
      expect(callback.displayMessage, contains('Waiting for the bank'));
      expect(callback.copyWith(message: 'hi').message, 'hi');
    });
  });
}
