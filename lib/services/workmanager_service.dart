import 'package:workmanager/workmanager.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'package:eyyubiye_personel_takip/services/UserServiceApi.dart';

@pragma('vm:entry-point')
void workmanagerCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("=== WorkManager => $task / inputData=$inputData ===");

    // 1) Bildirim init
    await NotificationService().initNotifications();

    final sp = await SharedPreferences.getInstance();
    final userId = sp.getInt('user_id');
    if (userId == null) {
      print("[WorkManager] => userId=null, BFS açmıyorum.");
      return Future.value(true);
    }

    bool todayOff = await UserServiceApi.isTodayOff(userId);
    if (todayOff) {
      // Off => BFS başlatma
      print("[WorkManager] => Bugün off => BFS açmıyorum");
      return Future.value(true);
    }

    // 2) Konum al (opsiyonel)
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      print("[WorkManager] BG konum => lat=${position.latitude}, lng=${position.longitude}");
    } catch (e) {
      print("[WorkManager] Konum alma hatası => $e");
    }

    // 3) BFS => çalışmıyorsa başlat
    bool running = await FlutterBackgroundService().isRunning();
    if (!running) {
      await FlutterBackgroundService().startService();
      print("[WorkManager] => BFS startService() çağrıldı");
    } else {
      print("[WorkManager] => BFS zaten çalışıyor");
    }

    return Future.value(true);
  });
}

class WorkmanagerService {
  static Future<void> initializeWorkmanager() async {
    await Workmanager().initialize(
      workmanagerCallbackDispatcher,
      isInDebugMode: true,
    );
    print("[WorkmanagerService] => initializeWorkmanager() OK");
  }

  static Future<void> schedulePeriodicTask() async {   // MAİNDEN BAŞLATMA KODU
    print("[WorkmanagerService] => schedulePeriodicTask (15dk)");
    // 15 dk bir job
    await Workmanager().registerPeriodicTask(
      "locationTask",
      "fetchLocation",
      frequency: const Duration(minutes: 15),
      // constraints vb eklenebilir
      // inputData ile userId vs göndermek istersen -> inputData: {"userId": ...}
    );
  }

  static Future<void> cancelAllTasks() async {
    print("[WorkmanagerService] => cancelAllTasks()");
    await Workmanager().cancelAll();
  }

  // Sabah 06:00'da başlamak için ekstra bir görev planlıyoruz
  static Future<void> scheduleMorningTask() async {
    print("[WorkmanagerService] => scheduleMorningTask (06:00)");

    final currentTime = DateTime.now();
    final targetTime = DateTime(currentTime.year, currentTime.month, currentTime.day, 6, 0, 0);
    final durationUntilTarget = targetTime.isBefore(currentTime)
        ? targetTime.add(Duration(days: 1)).difference(currentTime)
        : targetTime.difference(currentTime);

    await Workmanager().registerPeriodicTask(
      "locationTask",
      "fetchLocation",
      frequency: const Duration(minutes: 15),
      initialDelay: const Duration(minutes: 15), // İlk başlatma için 15 dakika bekleyebiliriz
    );

  }
}
