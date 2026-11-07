import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';

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

  final bool autofocus;

  /// Characters the field takes, enforced as they are typed; no counter is
  /// shown.
  final int? maxLength;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;

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
    this.maxLength,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
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

    if (caption == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: BrandSpacing.sm),
          child: Text(caption!.toUpperCase(), style: BrandText.section.copyWith(height: 1)),
        ),
        field,
      ],
    );
  }
}
