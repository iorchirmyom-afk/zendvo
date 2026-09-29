import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/services/keypair_serialization_service.dart';
import 'package:mobile/core/services/secure_storage_service.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// In-memory fake mirroring the production test suite's pattern.
class FakeFlutterSecureStorage extends FlutterSecureStorage {
  final Map<String, String> storage = {};
  Exception? errorToThrow;

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    if (value != null) {
      storage[key] = value;
    } else {
      storage.remove(key);
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    return storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    storage.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    return storage.containsKey(key);
  }
}

void main() {
  group('StellarKeypairSerializer', () {
    late FakeFlutterSecureStorage fakeStorage;
    late SecureStorageService secureStorage;
    late StellarKeypairSerializer serializer;

    setUp(() {
      fakeStorage = FakeFlutterSecureStorage();
      secureStorage = SecureStorageService(
        storage: fakeStorage,
        seedKey: StellarKeypairSerializer.defaultKeypairStorageKey,
      );
      serializer = StellarKeypairSerializer(secureStorage: secureStorage);
    });

    test('uses the dedicated namespaced storage key', () {
      expect(
        StellarKeypairSerializer.defaultKeypairStorageKey,
        equals('savings_wallet_keypair_v1'),
      );
      expect(
        StellarKeypairSerializer.defaultKeypairStorageKey,
        isNot(equals(SecureStorageService.defaultSeedKey)),
      );
    });

    test('saveKeyPair persists a Base64 payload, not the S... seed',
        () async {
      final keyPair = KeyPair.random();
      await serializer.saveKeyPair(keyPair);

      final stored =
          fakeStorage.storage[StellarKeypairSerializer.defaultKeypairStorageKey];
      expect(stored, isNotNull);
      expect(stored, isNot(startsWith('S')));

      // Must be decodable to the same 32-byte raw seed.
      final decoded = base64Decode(stored!);
      expect(decoded.length, equals(32));
      expect(
        decoded,
        equals(keyPair.privateKey),
      );
    });

    test('loadKeyPair round-trips the same account id', () async {
      final original = KeyPair.random();
      await serializer.saveKeyPair(original);

      final restored = await serializer.loadKeyPair();
      expect(restored, isNotNull);
      expect(restored!.accountId, equals(original.accountId));
      expect(restored.publicKey, equals(original.publicKey));
    });

    test('loadKeyPair returns null when nothing is stored', () async {
      expect(await serializer.loadKeyPair(), isNull);
    });

    test('hasKeyPair reflects persistence state', () async {
      expect(await serializer.hasKeyPair(), isFalse);
      await serializer.saveKeyPair(KeyPair.random());
      expect(await serializer.hasKeyPair(), isTrue);
    });

    test('deleteKeyPair removes the persisted payload', () async {
      await serializer.saveKeyPair(KeyPair.random());
      expect(await serializer.hasKeyPair(), isTrue);

      await serializer.deleteKeyPair();
      expect(await serializer.hasKeyPair(), isFalse);
      expect(await serializer.loadKeyPair(), isNull);
    });

    test('loadKeyPair throws FormatException for non-Base64 payload',
        () async {
      fakeStorage.storage[StellarKeypairSerializer.defaultKeypairStorageKey] =
          '!!!not-base64!!!';

      expect(
        () => serializer.loadKeyPair(),
        throwsA(isA<KeypairSerializationFormatException>()),
      );
    });

    test('loadKeyPair throws CorruptedException for wrong-length seed',
        () async {
      fakeStorage.storage[StellarKeypairSerializer.defaultKeypairStorageKey] =
          base64Encode(Uint8List.fromList(List<int>.filled(16, 7)));

      expect(
        () => serializer.loadKeyPair(),
        throwsA(isA<KeypairSerializationCorruptedException>()),
      );
    });

    test('loadKeyPair surfaces storage failures as StorageException',
        () async {
      fakeStorage.errorToThrow = PlatformException(
        code: 'Locked',
        message: 'Device keychain is locked',
      );

      expect(
        () => serializer.loadKeyPair(),
        throwsA(isA<KeypairSerializationStorageException>()),
      );
    });

    test('saveKeyPair surfaces storage failures as StorageException',
        () async {
      fakeStorage.errorToThrow = PlatformException(
        code: 'KeystoreError',
        message: 'Hardware keystore unavailable',
      );

      expect(
        () => serializer.saveKeyPair(KeyPair.random()),
        throwsA(isA<KeypairSerializationStorageException>()),
      );
    });

    test('deleteKeyPair surfaces storage failures as StorageException',
        () async {
      fakeStorage.errorToThrow = PlatformException(
        code: 'SecretStorageException',
        message: 'InvalidKeyException: Failed to unwrap key',
      );

      expect(
        () => serializer.deleteKeyPair(),
        throwsA(isA<KeypairSerializationStorageException>()),
      );
    });

    test('encodeSeed / decodeSeed are pure and round-trip', () {
      final original = KeyPair.random();
      final encoded = StellarKeypairSerializer.encodeSeed(original);

      expect(encoded, isNot(startsWith('S')));
      expect(base64Decode(encoded).length, equals(32));

      final restored = StellarKeypairSerializer.decodeSeed(encoded);
      expect(restored.accountId, equals(original.accountId));
    });

    test('decodeSeed rejects malformed input', () {
      expect(
        () => StellarKeypairSerializer.decodeSeed('@@@'),
        throwsA(isA<KeypairSerializationFormatException>()),
      );
      expect(
        () => StellarKeypairSerializer.decodeSeed(
          base64Encode(Uint8List.fromList(List<int>.filled(31, 1))),
        ),
        throwsA(isA<KeypairSerializationCorruptedException>()),
      );
    });

    test('zeroize overwrites every byte with 0', () {
      final buffer = Uint8List.fromList(List<int>.filled(32, 0xAB));
      StellarKeypairSerializer.zeroize(buffer);

      for (final byte in buffer) {
        expect(byte, equals(0));
      }
    });

    test('zeroize is a no-op on empty buffers', () {
      final buffer = Uint8List(0);
      expect(() => StellarKeypairSerializer.zeroize(buffer), returnsNormally);
    });
  });
}
