import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/service/localizations/service.dart';

enum ThemeCode {
  system("system"),
  light("light"),
  dark("dark");

  const ThemeCode(this.name);

  final String name;

  @override
  String toString() {
    switch (this) {
      case ThemeCode.system:
        return appLocalizationsNoContext().themePageSystem;
      case ThemeCode.light:
        return appLocalizationsNoContext().themePageLight;
      case ThemeCode.dark:
        return appLocalizationsNoContext().themePageDark;
    }
  }

  static ThemeCode fromString(String? name) {
    if (name == null) {
      return ThemeCode.system;
    }
    final theme = ThemeCode.values.firstWhereOrNull(
      (value) => value.name == name,
    );
    if (theme == null) {
      return ThemeCode.system;
    }
    return theme;
  }

  ThemeMode get themeMode {
    switch (this) {
      case ThemeCode.light:
        return ThemeMode.light;
      case ThemeCode.dark:
        return ThemeMode.dark;
      case ThemeCode.system:
        return ThemeMode.system;
    }
  }
}

enum LanguageCode {
  en("en");

  const LanguageCode(this.name);

  final String name;

  @override
  String toString() {
    switch (this) {
      case LanguageCode.en:
        return appLocalizationsNoContext().languagePageEnglish;
    }
  }

  static LanguageCode fromString(String? name) {
    if (name == null) {
      return LanguageCode.en;
    }
    final value = LanguageCode.values.firstWhereOrNull(
      (value) => value.name == name,
    );
    if (value != null) {
      return value;
    }
    return LanguageCode.en;
  }

  Locale get locale {
    return Locale(name);
  }

  TextDirection get textDirection {
    switch (this) {
      case LanguageCode.en:
        return TextDirection.ltr;
    }
  }
}
