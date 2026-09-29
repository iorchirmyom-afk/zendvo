import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

class WalletCredentials {
  final String accountId;
  final String secretSeed;

  WalletCredentials({
    required this.accountId,
    required this.secretSeed,
  });
}

class WalletGenerationService {
  WalletCredentials generateKeyPair() {
    final keyPair = KeyPair.random();
    return WalletCredentials(
      accountId: keyPair.accountId,
      secretSeed: keyPair.secretSeed,
    );
  }
}
