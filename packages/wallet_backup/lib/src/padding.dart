/// File sizes (plan §8).
///
/// Every file is at least [minFileSize] and at most [maxFileSize]; between the
/// two its size is rounded up with PADMÉ, which adds at most about 12%. The
/// floor makes every common single change (a payment with up to about seven
/// destinations, a contact) the same size, so a storage provider cannot tell
/// them apart.
library;

const minFileSize = 1024;
const maxFileSize = 65536;

/// PADMÉ (Nikitin et al., "Reducing Metadata Leakage from Encrypted Files and
/// Communication with PURBs"), as Evolu's `createPadmePaddedLength` and the
/// plan's `backup_size_estimate.py` compute it.
int padme(int length) {
  if (length <= 0) return 0;
  final e = length.bitLength - 1;
  final s = e.bitLength;
  final z = e - s < 0 ? 0 : e - s;
  final mask = (1 << z) - 1;
  return (length + mask) & ~mask;
}

/// The total size of a file whose unpadded size is [rawLength].
int paddedFileSize(int rawLength) {
  if (rawLength > maxFileSize) throw ArgumentError('file too large: $rawLength');
  final padded = padme(rawLength);
  return padded < minFileSize ? minFileSize : padded;
}
