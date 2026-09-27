import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'platform_services.dart';

class FfiLocalDatabaseDriver implements LocalDatabaseDriver {
  bool _initialized = false;

  @override
  Future<Database> open(String path, OpenDatabaseOptions options) async {
    if (!_initialized) {
      sqfliteFfiInit();
      _initialized = true;
    }
    return databaseFactoryFfi.openDatabase(path, options: options);
  }
}
