import 'package:colitu_vpn/core/db/database/database.dart';
import 'package:colitu_vpn/service/localizations/service.dart';
import 'package:colitu_vpn/service/geo_data/system_state.dart';
import 'package:tuple/tuple.dart';

class GeoDataValidator {
  static Future<Tuple2<bool, String>> validate(String name, String url) async {
    if (name.isEmpty) {
      return Tuple2(false, appLocalizationsNoContext().validationNameRequired);
    }
    if (url.isEmpty) {
      return Tuple2(false, appLocalizationsNoContext().validationUrlRequired);
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return Tuple2(false, appLocalizationsNoContext().validationUrlInvalid);
    }
    // The name becomes a file name in the tunnel's data folder: plain names
    // only, so "./geoip" or "../x" can never replace or escape it.
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(name)) {
      return Tuple2(false, appLocalizationsNoContext().validationNameRequired);
    }
    final lower = name.toLowerCase();
    if (lower == SystemGeoDatName.geoSite.name.toLowerCase() ||
        lower == SystemGeoDatName.geoIp.name.toLowerCase()) {
      return Tuple2(false, appLocalizationsNoContext().validationNameDuplicate);
    }
    final db = AppDatabase();
    final nameExists = await db.geoDataDao.nameExists(name);
    if (nameExists) {
      return Tuple2(false, appLocalizationsNoContext().validationNameDuplicate);
    }
    return Tuple2(true, "");
  }
}
