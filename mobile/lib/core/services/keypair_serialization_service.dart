import 'dart:convert';
import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'secure_storage_service.dart';

/// Base exception for all keypair serialization failures.
abstract class KeypairSerializationException implements Exception {
  final String message;
  final dynamic cause;

  const KeypairSerializationException(this.message, [this.cause]);

  @override
  String toString() =>
      '$runtimeType: $message${cause != null ? ' (Cause: $cause)' : ''}';
}

/// Thrown when a persisted payload cannot be Base64-decoded or parsed.
class KeypairSerializationFormatException extends KeypairSerializationException {
  const KeypairSerializationFormatException(super.message, [super.cause]);
}

/// Thrown when a decoded payload is structurally invalid (wrong length, etc.).
class KeypairSerializationCorruptedException
    extends KeypairSerializationException {
  const KeypairSerializationCorruptedException(super.message, [super.cause]);
}

/// Thrown when the underlying secure storage layer fails.
class KeypairSerializationStorageException
    extends KeypairSerializationException {
  const KeypairSerializationStorageException(super.message, [super.cause]);
}

/// Serializes an Ed25519 [KeyPair] to and from secure platform storage.
///
/// Design goals (see issue #428):
///   * Private key material is only ever held as a [Uint8List] so it can be
///     zero-wiped. The `S...` secret seed string is never persisted.
///   * The persisted payload is Base64 of the 32-byte raw seed, so leaked
///     storage dumps do not match Stellar's well-known `S[A-Z2-7]{55}`
///     pattern and do not immediately reveal a usable secret.
///   * All buffers are zeroed in `finally` blocks regardless of success,
///     so no plaintext key material lingers in the Dart heap longer than
///     the operation requires.
class StellarKeypairSerializer {
  /// Default namespaced storage key. Distinct from
  /// [SecureStorageService.defaultSeedKey] so the two can coexist.
  static const String defaultKeypairStorageKey = 'savings_wallet_keypair_v1';

  final SecureStorageService _secureStorage;

  /// Constructs a [StellarKeypairSerializer].
  ///
  /// A [SecureStorageService] can be injected for testing, or one is created
  /// bound to [storageKey] by default.
  StellarKeypairSerializer({
    SecureStorageService? secureStorage,
    String storageKey = defaultKeypairStorageKey,
  }) : _secureStorage = secureStorage ??
            SecureStorageService(seedKey: storageKey);

  /// Persists the private key of [keyPair] to secure storage.
  ///
  /// The `S...` secret seed is never used; only the 32-byte raw seed is
  /// Base64-encoded and written. The intermediate buffer is zeroed in a
  /// `finally` block.
  Future<void> saveKeyPair(KeyPair keyPair) async {
    Uint8List? rawSeed;
    try {
      rawSeed = keyPair.privateKey;
      if (rawSeed == null) {
        throw KeypairSerializationStorageException('KeyPair does not contain a private key.');
      }
      final encoded = base64Encode(rawSeed);
      await _secureStorage.saveSecretSeed(encoded);
    } on SecureStorageException catch (e) {
      throw KeypairSerializationStorageException(
        'Failed to persist keypair to secure storage.',
        e,
      );
    } finally {
      if (rawSeed != null) {
        zeroize(rawSeed);
      }
    }
  }

  /// Loads a [KeyPair] from secure storage.
  ///
  /// Returns `null` if no keypair has been persisted.
  /// Throws [KeypairSerializationFormatException] for non-Base64 payloads,
  /// [KeypairSerializationCorruptedException] for wrong-length seeds, and
  /// [KeypairSerializationStorageException] for storage-layer failures.
  Future<KeyPair?> loadKeyPair() async {
    String? encoded;
    Uint8List? rawSeed;
    try {
      encoded = await _secureStorage.getSecretSeed();
      if (encoded == null) {
        return null;
      }

      try {
        rawSeed = base64Decode(encoded);
      } catch (e) {
        throw KeypairSerializationFormatException(
          'Stored keypair payload is not valid Base64.',
          e,
        );
      }

      if (rawSeed.length != 32) {
        throw KeypairSerializationCorruptedException(
          'Stored keypair seed must be 32 bytes, got ${rawSeed.length}.',
        );
      }

      return KeyPair.fromSecretSeedList(rawSeed);
    } on SecureStorageException catch (e) {
      throw KeypairSerializationStorageException(
        'Failed to read keypair from secure storage.',
        e,
      );
    } finally {
      if (rawSeed != null) {
        zeroize(rawSeed);
      }
      encoded = null;
    }
  }

  /// Deletes the persisted keypair.
  Future<void> deleteKeyPair() async {
    try {
      await _secureStorage.deleteSecretSeed();
    } on SecureStorageException catch (e) {
      throw KeypairSerializationStorageException(
        'Failed to delete keypair from secure storage.',
        e,
      );
    }
  }

  /// Returns `true` if a keypair is currently persisted.
  Future<bool> hasKeyPair() async {
    try {
      return await _secureStorage.hasSecretSeed();
    } on SecureStorageException catch (e) {
      throw KeypairSerializationStorageException(
        'Failed to check keypair existence in secure storage.',
        e,
      );
    }
  }

  /// Encodes [keyPair]'s raw seed as a Base64 string.
  ///
  /// Exposed for testing and for callers that need a string representation
  /// without touching platform storage. The intermediate buffer is zeroed.
  static String encodeSeed(KeyPair keyPair) {
    final rawSeed = keyPair.privateKey!;
    try {
      return base64Encode(rawSeed);
    } finally {
      zeroize(rawSeed);
    }
  }

  /// Decodes a Base64 [encoded] seed into a [KeyPair].
  ///
  /// The intermediate buffer is zeroed before returning.
  static KeyPair decodeSeed(String encoded) {
    Uint8List? rawSeed;
    try {
      try {
        rawSeed = base64Decode(encoded);
      } catch (e) {
        throw KeypairSerializationFormatException(
          'Payload is not valid Base64.',
          e,
        );
      }

      if (rawSeed.length != 32) {
        throw KeypairSerializationCorruptedException(
          'Seed must be 32 bytes, got ${rawSeed.length}.',
        );
      }

      // KeyPair copies the bytes internally, so zeroing afterwards is safe.
      return KeyPair.fromSecretSeedList(rawSeed);
    } finally {
      if (rawSeed != null) {
        zeroize(rawSeed);
      }
    }
  }

  /// Overwrites [buffer] with zeros.
  ///
  /// Dart has no `sodium_memzero` equivalent, so this is the best-effort
  /// mitigation available: bytes are overwritten in place before the
  /// reference is dropped and the GC reclaims the allocation.
  static void zeroize(Uint8List buffer) {
    if (buffer.isEmpty) return;
    buffer.fillRange(0, buffer.length, 0);
  }
}
