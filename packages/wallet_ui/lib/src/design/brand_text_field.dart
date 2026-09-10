import 'package:flutter/material.dart';

import 'brand.dart';

/// Inset text field on a sunken warm ground.
class BrandTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hint;
  final String? label;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final int? maxLines;

  const BrandTextField({
    super.key,
    this.controller,
    this.hint,
    this.label,
    this.obscureText = false,
    this.keyboardType,
    this.onChanged,
    this.suffix,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: onChanged,
      maxLines: obscureText ? 1 : maxLines,
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
  }
}
