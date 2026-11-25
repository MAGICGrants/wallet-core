import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'desktop_layout.dart';

/// Inset text field on a sunken warm ground.
///
/// [caption] renders a small static uppercase label above the field (versus
/// [label], the Material floating label inside it).
class BrandTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hint;
  final String? label;
  final String? caption;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final int? maxLines;

  /// A secret is typed here (a password, a PIN, a recovery phrase): no
  /// autocorrect, no suggestions, no smart punctuation, and nothing for the
  /// keyboard to learn or remember. Set it on every field that can be
  /// obscured too: [obscureText] covers this only until a show button turns
  /// it off.
  final bool sensitive;

  /// Takes focus when it appears. For the one field a desktop screen is for
  /// (an unlock password, a PIN); on a phone it would raise the keyboard
  /// unasked, so pass `isDesktopLayout` there.
  final bool autofocus;
  final FocusNode? focusNode;

  /// Characters the field takes, enforced as they are typed; no counter is
  /// shown.
  final int? maxLength;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;

  /// The field's name to screen readers where neither [label] nor [caption]
  /// gives one; [caption] already names it.
  final String? semanticLabel;

  const BrandTextField({
    super.key,
    this.controller,
    this.hint,
    this.label,
    this.caption,
    this.obscureText = false,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.suffix,
    this.maxLines = 1,
    this.sensitive = false,
    this.autofocus = false,
    this.focusNode,
    this.maxLength,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      // Desktop: Enter submits and the field keeps focus, so a wrong password
      // or PIN is typed again straight away. A phone keeps closing its
      // keyboard on Enter, and a field whose action moves on (next) still
      // moves on.
      onEditingComplete:
          isDesktopLayout && (textInputAction == null || textInputAction == TextInputAction.done)
          ? () {}
          : null,
      autofocus: autofocus,
      focusNode: focusNode,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      inputFormatters: maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
      maxLines: obscureText ? 1 : maxLines,
      autocorrect: !sensitive,
      enableSuggestions: !sensitive,
      enableIMEPersonalizedLearning: !sensitive,
      smartDashesType: sensitive ? SmartDashesType.disabled : null,
      smartQuotesType: sensitive ? SmartQuotesType.disabled : null,
      style: BrandText.body,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: BrandText.bodyMuted,
        suffixIcon: suffix,
        filled: true,
        fillColor: BrandColors.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(horizontal: BrandSpacing.lg, vertical: 15),
        enabledBorder: OutlineInputBorder(
          borderRadius: BrandRadii.rField,
          borderSide: BorderSide(color: BrandColors.border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BrandRadii.rField,
          borderSide: BorderSide(color: BrandColors.primary, width: 1),
        ),
      ),
    );

    // The caption names the field to screen readers, read as written rather
    // than upper-cased, so it is not also read on its own.
    // A name the hint already gives is not added again ("Password, Password").
    final name = caption ?? semanticLabel;
    final named = name == null || name == hint ? field : Semantics(label: name, child: field);
    if (caption == null) return named;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: BrandSpacing.sm),
          child: ExcludeSemantics(
            child: Text(caption!.toUpperCase(), style: BrandText.section.copyWith(height: 1)),
          ),
        ),
        named,
      ],
    );
  }
}
