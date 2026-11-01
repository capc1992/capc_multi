import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';

import 'platform_services.dart';

class SqfliteLocalDatabaseDriver implements LocalDatabaseDriver {
  @override
  Future<Database> open(String path, OpenDatabaseOptions options) =>
      sqflite.databaseFactory.openDatabase(path, options: options);
}
