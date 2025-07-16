import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';

import 'notification_service.dart';
import 'package:eyyubiye_personel_takip/services/UserService.dart';
import 'package:eyyubiye_personel_takip/services/UserServiceApi.dart'; // isTodayOff => tam gun izin?
import 'package:shared_preferences/shared_preferences.dart';

StreamSubscription<Position>? _positionStreamSubscription;
double? gCurrentLat;
double? gCurrentLng;

Future<void> _checkPermission() async {
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      debugPrint("[BGService] Konum izni reddedildi.");
      return;
    }
  }
  if (permission == LocationPermission.deniedForever) {
    debugPrint("[BGService] Konum izni kalıcı reddedildi.");
    return;
  }
}

Future<void> _startTracking() async {
  await _checkPermission();

  final now = DateTime.now();
  final totalMin = now.hour * 60 + now.minute;

  int distanceFilter = 500;
  int intervalSec = 3600;

  // 06..10 => intervalSec=20, 10..22 => intervalSec=120, 22.. => 3600
  if (totalMin >= (6 * 60) && totalMin < (10 * 60)) {
    distanceFilter = 200;
    intervalSec = 20;
  } else if (totalMin >= (10 * 60) && totalMin < (22 * 60)) {
    distanceFilter = 0;
    intervalSec = 120;
  } else {
    distanceFilter = 500;
    intervalSec = 3600;
  }

  final androidSettings = AndroidSettings(
    accuracy: LocationAccuracy.best,
    distanceFilter: distanceFilter,
    intervalDuration: Duration(seconds: intervalSec),
    foregroundNotificationConfig: const ForegroundNotificationConfig(
      notificationTitle: "Arka Planda Konum Servisi",
      notificationText: "Her şey yolunda",
      notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    ),
  );

  final iosSettings = AppleSettings(
    accuracy: LocationAccuracy.best,
    distanceFilter: distanceFilter,
    allowBackgroundLocationUpdates: true,
    showBackgroundLocationIndicator: false,
  );

  LocationSettings locationSettings;
  if (Platform.isAndroid) {
    locationSettings = androidSettings;
  } else if (Platform.isIOS) {
    locationSettings = iosSettings;
  } else {
    locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 500,
    );
  }

  await _positionStreamSubscription?.cancel();

  _positionStreamSubscription = Geolocator.getPositionStream(
    locationSettings: locationSettings,
  ).listen((pos) {
    gCurrentLat = pos.latitude;
    gCurrentLng = pos.longitude;
    debugPrint("[BGService] Konum => lat=${pos.latitude}, lng=${pos.longitude}");
  });
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartService,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'Background Service',
      initialNotificationContent: 'Konum servisi başlatılıyor...',
      foregroundServiceNotificationId: 999,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStartService,
      onBackground: _iosBackgroundHandler,
    ),
  );
  debugPrint("[BGService] configure tamamlandı");
}

@pragma('vm:entry-point')
Future<bool> _iosBackgroundHandler(ServiceInstance service) async {
  debugPrint("[BGService] iOS background fetch");
  return true;
}

@pragma('vm:entry-point')
void onStartService(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().initNotifications();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: "Arkaplan Konum Servisi",
      content: "Her şey yolunda",
    );
  }

  final sp = await SharedPreferences.getInstance();
  final userId = sp.getInt('user_id');
  if (userId != null) {
    bool isOff = await UserServiceApi.isTodayOff(userId);
    if (isOff) {
      debugPrint("[BGService] => Bugün tam gün izin => stopSelf");
      if (service is AndroidServiceInstance) {
        service.stopSelf();
      }
      return;
    }
  }

  // BFS aktif olduğunda konum takibini başlat
  await _startTracking();

  Timer.periodic(const Duration(minutes: 1), (timer) async {
    bool isRunning = true;
    try {
      isRunning = await FlutterBackgroundService().isRunning();
    } catch (e) {
      debugPrint("[BGService] isRunning() hata => $e");
    }
    if (!isRunning) {
      timer.cancel();
      if (service is AndroidServiceInstance) {
        service.stopSelf();
      }
      return;
    }

    final now = DateTime.now();
    final hour = now.hour;
    final min  = now.minute;
    final day  = now.day;

    // 22 => kapat BFS
    if (hour >= 22) {
      debugPrint("[BGService] => Saat 22 oldu, arka plan kapanıyor.");
      await NotificationService().showNotificationCustom(
        "İyi geceler",
        "Arka plan durdu. Sabah 06:00'da görüşmek üzere!",
      );
      timer.cancel();
      if (service is AndroidServiceInstance) {
        service.stopSelf();
      }
      return;
    }

    // 06:00 => handleMorningCheck
    final lastMorningCheck = sp.getInt('lastMorningCheck') ?? -1;
    if (hour == 6 && min == 0 && day != lastMorningCheck) {
      await UserService.handleMorningCheck(userId ?? 1);
      await sp.setInt('lastMorningCheck', day);
    }

    // her saat başı => is_active=1, location_info
    if (min == 0) {
      await UserService.handleSituationHourly(
        userId: userId ?? 1,
        currentLat: gCurrentLat,
        currentLng: gCurrentLng,
      );
    }

    // sabah/akşam => giriş-çıkış
    await UserService.handleGirisCikisNotifications(
      userId: userId ?? 1,
      currentLat: gCurrentLat,
      currentLng: gCurrentLng,
    );

    // ──────────────────────────────────────────────────────────
    // __YENİ EK__ : 06:00..08:10 tablo oluşturma “kaçırmamak” için
    // userService.handleMorningCheck => tablo 1 kez
    // ──────────────────────────────────────────────────────────
    final totalMin = hour * 60 + min;  // dakikaya çevir
    bool morningCreated = sp.getBool('morningCreated') ?? false;
    if (totalMin >= 360 && totalMin <= 490 && !morningCreated) {
      // => 06:00 (360) .. 08:10 (490) arasındayız + tablo oluşturulmadı
      debugPrint("[BGService] => BFS sabah tablo => handleMorningCheck(...)");
      await UserService.handleMorningCheck(userId ?? 1);
      await sp.setBool('morningCreated', true);
    }
  });

  service.on('stopService').listen((event) async {
    await _positionStreamSubscription?.cancel();
    if (service is AndroidServiceInstance) {
      service.stopSelf();
    }
  });
}
