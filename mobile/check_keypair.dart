import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';
void main() {
  final kp = KeyPair.random();
  print(kp.secretSeed);
}
