// lib/utils/phone_utils.dart
/// Утилиты для валидации и нормализации российских номеров телефона.
/// Входные варианты, которые принимаются:
///  - 89991714551
///  - 9 999 171-45-51
///  - +7 (999) 171-45-51
///  - 8 (999) 1714551
///  - 79991714551
///  - любые комбинации с пробелами, скобками, дефисами
///
/// Выходы:
///  - normalizeToE164(...) -> "+79991714551" (для отправки на сервер)
///  - formatForDisplay(...) -> "89991714551" (для отображения в профиле)
///
/// Если номер невалидный, validatePhone(...) возвращает false.
class PhoneUtils {
  /// Убирает все нецифровые символы и возвращает только цифры.
  static String _digitsOnly(String input) {
    return input.replaceAll(RegExp(r'\D'), '');
  }

  /// Проверка валидности российского номера.
  /// Принимаем номера с 10 цифрами (без кода страны) или 11 цифрами (с 7 или 8).
  static bool validatePhone(String input) {
    final digits = _digitsOnly(input);
    if (digits.isEmpty) return false;
    // допустимы 10 (например 9991714551) или 11 (89991714551 или 79991714551)
    if (digits.length == 10) return true;
    if (digits.length == 11 && (digits.startsWith('7') || digits.startsWith('8'))) return true;
    return false;
  }

  /// Нормализует к E.164 для России: +7XXXXXXXXXX
  /// Примеры:
  ///  - "89991714551" -> "+79991714551"
  ///  - "9991714551" -> "+79991714551"
  ///  - "+7 (999) 171-45-51" -> "+79991714551"
  /// Если номер невалидный — возвращает null.
  static String? normalizeToE164(String input) {
    final digits = _digitsOnly(input);
    if (digits.length == 10) {
      // 10 цифр — считаем, что это без кода страны, добавляем 7
      return '+7$digits';
    }
    if (digits.length == 11) {
      if (digits.startsWith('8')) {
        return '+7' + digits.substring(1);
      }
      if (digits.startsWith('7')) {
        return '+$digits';
      }
    }
    return null;
  }

  /// Формат для отображения в профиле: 8XXXXXXXXXX
  /// Примеры:
  ///  - "+79991714551" -> "89991714551"
  ///  - "89991714551" -> "89991714551"
  ///  - "9991714551" -> "89991714551"
  /// Если невалидный — возвращает пустую строку.
  static String formatForDisplay(String input) {
    final digits = _digitsOnly(input);
    if (digits.length == 10) {
      return '8$digits';
    }
    if (digits.length == 11) {
      if (digits.startsWith('8')) return digits;
      if (digits.startsWith('7')) return '8' + digits.substring(1);
    }
    return '';
  }
}
