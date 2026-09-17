/// A counterparty in the address book: a name, and one address per blockchain.
///
/// Multi-address from the start, even in an app that shows only one. Skylight is
/// Monero-only today and renders the `XMR` entry; the shape is what it needs
/// once swaps give it other chains, and sharing it means both apps read and
/// write one stored format rather than diverging again.
class Contact {
  const Contact({required this.id, required this.name, required this.addresses});

  final String id;
  final String name;

  /// Keyed by upper-case coin symbol. A contact need not have every chain.
  final Map<String, String> addresses;

  String? addressFor(String coinSymbol) => addresses[coinSymbol.toUpperCase()];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'addresses': addresses};

  /// Reads both the multi-address form and the single-address form earlier
  /// Skylight builds wrote. The legacy entry is Monero by definition: it
  /// predates any other chain being storable.
  factory Contact.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('addresses')) {
      final raw = json['addresses'] as Map<dynamic, dynamic>;
      return Contact(
        id: json['id'] as String,
        name: json['name'] as String,
        addresses: raw.map((k, v) => MapEntry(k.toString().toUpperCase(), v.toString())),
      );
    }

    return Contact(
      id: json['id'] as String,
      name: json['name'] as String,
      addresses: {'XMR': json['address'] as String},
    );
  }

  Contact copyWith({String? id, String? name, Map<String, String>? addresses}) =>
      Contact(id: id ?? this.id, name: name ?? this.name, addresses: addresses ?? this.addresses);

  String addressesForClipboard() => addresses.entries.map((e) => '${e.key}: ${e.value}').join('\n');
}
