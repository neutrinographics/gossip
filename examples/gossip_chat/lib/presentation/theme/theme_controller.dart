import 'package:flutter/material.dart';

/// Controller for managing the app's theme mode.
class ThemeController extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  /// The current theme mode.
  ThemeMode get themeMode => _themeMode;

  /// Whether dark mode is currently active based on the theme mode
  /// and system settings.
  bool isDarkMode(BuildContext context) {
    switch (_themeMode) {
      case ThemeMode.dark:
        return true;
      case ThemeMode.light:
        return false;
      case ThemeMode.system:
        return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    }
  }

  /// Sets the theme mode.
  void setThemeMode(ThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      notifyListeners();
    }
  }

  /// Toggles between light and dark mode.
  /// If currently using system mode, switches to the opposite of
  /// the current system brightness.
  void toggleTheme(BuildContext context) {
    if (_themeMode == ThemeMode.dark) {
      _themeMode = ThemeMode.light;
    } else if (_themeMode == ThemeMode.light) {
      _themeMode = ThemeMode.dark;
    } else {
      // System mode - switch to opposite of current system brightness
      final isDark =
          MediaQuery.platformBrightnessOf(context) == Brightness.dark;
      _themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    }
    notifyListeners();
  }
}
