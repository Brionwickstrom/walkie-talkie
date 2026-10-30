import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Windows: is the computer on AC power (plugged in)? null when unknown or
/// not Windows (v2.5.6). One cheap system call, no polling of its own.
bool? acPowerOnline() {
  if (!Platform.isWindows) return null;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final get = k32
        .lookupFunction<
          Int32 Function(Pointer<Uint8>),
          int Function(Pointer<Uint8>)
        >('GetSystemPowerStatus');
    // SYSTEM_POWER_STATUS is 12 bytes; byte 0 = ACLineStatus
    // (0 = battery, 1 = AC, 255 = unknown).
    final p = calloc<Uint8>(16);
    try {
      if (get(p) == 0) return null;
      final ac = p[0];
      return ac == 255 ? null : ac == 1;
    } finally {
      calloc.free(p);
    }
  } catch (_) {
    return null;
  }
}
