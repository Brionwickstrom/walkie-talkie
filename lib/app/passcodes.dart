import 'dart:math';

/// Passcode rules for private channels (v1.9.4).
///
/// * Setting up a NEW private channel needs a strong passcode: at least
///   [minNew] characters with at least [minDistinct] different ones, or
///   the generated one the app suggests ([generate]: 12 letters and
///   digits without look-alikes, about 59 bits).
/// * Joining someone else's channel, and channels already saved, keep
///   working with any passcode of [minJoin]+ characters (older channels
///   were made with 6), so nothing changes for them.
///
/// Key stretching (PBKDF2, 120k rounds) is unchanged: a stronger setting
/// would give a different key from the same passcode on older phones, so
/// they could not join. The longer passcode is what makes guessing from
/// recorded traffic impractical.
class Passcodes {
  static const int minJoin = 6;
  static const int minNew = 10;
  static const int minDistinct = 5;
  static const int generatedLength = 12;

  /// No 0/o, 1/l/i: easy to read out loud and type.
  static const String alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

  static String generate({int length = generatedLength, Random? random}) {
    final r = random ?? Random.secure();
    return List.generate(
      length,
      (_) => alphabet[r.nextInt(alphabet.length)],
    ).join();
  }

  /// Why [passcode] is not good enough for a new channel, null if it is.
  static String? problemForNew(String passcode) {
    final p = passcode.trim();
    if (p.length < minNew) {
      return 'Use at least $minNew characters, or tap "Make one for me"';
    }
    if (p.toLowerCase().split('').toSet().length < minDistinct) {
      return 'Too easy to guess: mix more different letters and numbers';
    }
    if (_sequence(p.toLowerCase())) {
      return 'Too easy to guess: avoid runs like 1234567890 or abcdefghij';
    }
    return null;
  }

  /// Why [passcode] cannot be used to join a channel, null if it can.
  static String? problemForJoin(String passcode) =>
      passcode.trim().length < minJoin
      ? 'Use at least $minJoin characters'
      : null;

  /// "Strong" / "OK for joining" label for the passcode field.
  static bool isStrong(String passcode) => problemForNew(passcode) == null;

  static bool _sequence(String p) {
    var up = 0, down = 0;
    for (var i = 1; i < p.length; i++) {
      final d = p.codeUnitAt(i) - p.codeUnitAt(i - 1);
      if (d == 1) up++;
      if (d == -1) down++;
    }
    return up >= p.length - 2 || down >= p.length - 2;
  }
}
