# Strings

The rules for user-facing text in Skylight, Spice and the wallet-core screens they share. The same
rules are in each app's design system (the Voice section).

## Where a string lives

- **wallet-core**, when both apps show it with the same meaning. Strings for an app's own screens go
  in `wallet_ui`'s `WalletUiLocalizations` (`packages/wallet_ui/lib/src/l10n`); strings for a shared
  screen go with that screen's package, as `wallet_fhse` and `wallet_backup_platform` do. The app's
  name and counts are placeholders (`{appName}`, `{count}`), not a reason for two copies.
- **The app**, when what it says depends on what that app covers: which chains (several, or Monero
  only), which recovery phrases (BIP39 or Polyseed), or the app's own voice (the welcome pitch, the
  theme descriptions).
- When unsure, keep it in the app. A string moves to wallet-core once both apps word it the same.

## Capitalization by kind

What the text does decides its case, whichever app or package it is in.

**Title Case**, for text that names something:

- screen, sheet, dialog and step titles, questions included ("Use Only One Key?")
- row titles in settings and lists, action rows included ("Remove a Key", "Turn Off Security Keys")
- buttons, links and tooltips ("Add a Security Key", "Copy Address", "Set Up")
- choice titles, tabs, segmented options and filter options ("Built-in Tor", "Primary Address",
  "Any Address")
- field labels and section labels ("Wallet Password", "Security and Privacy"; section labels show
  upper-cased)

**Sentence case**, for text that says something:

- descriptions, subtitles and intro paragraphs
- choice descriptions and row subtitles ("Bundled with Spice Wallet · recommended")
- empty states ("No contacts yet"), status lines ("Connection works", "Checking PIN…"), toasts,
  errors and warnings
- input hints, checkbox labels, and the reason the system unlock prompt gives

**Title Case style.** Capitalize every word except *a, an, the, and, but, or, nor* and prepositions
of three letters or fewer (*as, at, by, for, in, of, on, per, to, via*), unless the word comes first
or last or belongs to a phrasal verb ("Set Up", "Turn On", "Back Up"). Each part of a hyphenated word
follows the same rule ("Clearnet-Only", "Built-in"). Names keep their own casing everywhere: Tor,
OpenAlias, InviZible, iCloud, BIP39, PIN.

**Punctuation.** Titles, labels and buttons take no final period; questions keep their "?". A
fragment, such as a choice description or a row subtitle, takes no period; full sentences do.

**Portuguese** follows the same kinds. Its Title Case keeps articles, prepositions and conjunctions
lowercase wherever they fall (*a, o, um, de, da, do, em, na, no, para, por, com, e, ou*), and
capitalizes possessives: "Restaurar Carteira Existente", "Escanear a Partir de", "Proteja Sua
Carteira".

## Reading shared strings in an app

Each app's `lib/l10n/shared_strings.dart` adds `shared` to its `AppLocalizations`, so a screen
writes `i18n.shared.cancel` for a wallet-core string and `i18n.welcomeDescription` for its own. A
shared string that names the app takes the app's `appShortName` from the same file.

## Adding a string

Say its kind in the ARB description, as `ui_en.arb` does ("Screen title. Title Case."), so the next
person to touch it knows which rule applies.
