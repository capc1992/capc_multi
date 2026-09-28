import 'dart:io';

import 'platform_android.dart';
import 'platform_services.dart';
import 'platform_test_host.dart';
import 'platform_windows.dart';

AppPlatformServices? _instance;

AppPlatformServices createPlatformServices() => _instance ??= _create();

AppPlatformServices _create() {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return TestHostPlatformServices();
  }
  return switch (Platform.operatingSystem) {
    'android' => AndroidPlatformServices(),
    'windows' => WindowsPlatformServices(),
    _ => throw UnsupportedError(
      'CAPC solo admite Windows y Android; plataforma actual: '
      '${Platform.operatingSystem}.',
    ),
  };
}
