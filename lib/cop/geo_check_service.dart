// lib/services/geo_check_service.dart

import 'package:geolocator/geolocator.dart';
import 'package:eyyubiye_personel_takip/cop/location_save_service.dart';

class GeoCheckService {
  static final GeoCheckService _instance = GeoCheckService._internal();
  factory GeoCheckService() => _instance;
  GeoCheckService._internal();

  /// Gelen [pos] konumunu veritabanına kaydeder.
  /// Sadece "her konumda" kaydetmek istediğimiz için ekstra kontrol yok.
  Future<void> checkLocation(Position pos) async {
    final lat = pos.latitude;
    final lng = pos.longitude;

    print("[GeoCheckService] Konum => lat=$lat, lng=$lng");

    // Kayıt et
    bool success = await LocationSaveService().saveLocation(lat, lng);
    if (success) {
      print("[GeoCheckService] Kayıt başarılı => lat=$lat, lng=$lng");
    } else {
      print("[GeoCheckService] Kayıt hatası => lat=$lat, lng=$lng");
    }
  }
}
