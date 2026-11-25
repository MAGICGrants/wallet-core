/// The longest label the app saves, in characters. A label names an address in
/// a list row; anything longer is a note, and every label also travels in the
/// metadata backup, whose files are small.
const maxAddressLabelLength = 64;

/// A name the user gave one of their own receive addresses ("Donations").
class AddressLabel {
  const AddressLabel({required this.coin, required this.address, required this.label});

  /// The coin's symbol, upper case (XMR, BTC).
  final String coin;
  final String address;
  final String label;

  /// One label per address per coin: what the label is stored, merged and
  /// backed up under.
  String get key => addressLabelKey(coin, address);

  Map<String, dynamic> toJson() => {'coin': coin, 'address': address, 'label': label};

  factory AddressLabel.fromJson(Map<String, dynamic> json) => AddressLabel(
    coin: (json['coin'] as String).toUpperCase(),
    address: json['address'] as String,
    label: json['label'] as String,
  );

  @override
  bool operator ==(Object other) =>
      other is AddressLabel &&
      other.coin == coin &&
      other.address == address &&
      other.label == label;

  @override
  int get hashCode => Object.hash(coin, address, label);
}

/// [AddressLabel.key] for [address] on [coin]. Addresses compare exactly:
/// Monero's base58 and Bitcoin's bech32 are both case-significant as written.
String addressLabelKey(String coin, String address) => '${coin.toUpperCase()}:$address';
