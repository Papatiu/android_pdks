import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// Mevcut importlar
import 'services/workmanager_service.dart';
import 'services/background_service.dart';
import 'services/notification_service.dart';
import 'services/app_lifecycle_manager.dart';

import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/attendance_screen.dart';
import 'screens/loading_screen.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:eyyubiye_personel_takip/services/UserServiceApi.dart';
import 'package:eyyubiye_personel_takip/services/UserService.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

// <-- Constants import:
import 'package:eyyubiye_personel_takip/utils/constants.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// openAppInBackground => force-kill değilse bazen açar (opsiyonel)
Future<void> openAppInBackground() async {
  if (!Platform.isAndroid) return;
  const packageName = 'com.example.eyyubiyePersonelTakip';
  final intent = AndroidIntent(
    action: 'android.intent.action.MAIN',
    category: 'android.intent.category.LAUNCHER',
    package: packageName,
    flags: <int>[268435456, 67108864],
  );
  try {
    await intent.launch();
  } catch (e) {
    print("[openAppInBackground] => hata: $e");
  }
}

/// FCM background handler
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService().initNotifications();

  if (message.data.isNotEmpty) {    //Data ve Save Location
    final data = message.data;
    final action = data['action'];

    // data-only => getLocation
    if (action == 'getLocation') {
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        // Eskiden: "http://192.168.1.179:8000/api/save-location"
        final url = Uri.parse("${Constants.baseUrl}/save-location");
        await http.post(
          url,
          headers: {"Content-Type": "application/json"},
          body: json.encode({
            "user_id": data['user_id'] ?? 0,
            "latitude": position.latitude,
            "longitude": position.longitude,
            "timestamp": DateTime.now().toIso8601String(),
          }),
        );
      } catch (e) {
        // local noti yok
      }
      return;
    }
  }

  // Normal notification
  if (message.notification != null) {    //FCM Normal Bildirim
    final title = message.notification!.title ?? 'FCM BG Title';
    final body  = message.notification!.body  ?? 'FCM BG Body';
    await NotificationService().showNotificationCustom(title, body);
  }
}

Future<void> askBatteryIfNeeded() async { // PİL OPTİMİZASYONU KONTROL
  if (!Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  bool asked = prefs.getBool('askedBattery') ?? false;
  if (!asked) {
    final intent = AndroidIntent(
      action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
    );
    await intent.launch();
    await prefs.setBool('askedBattery', true);
  }
}

Future<void> createAndroidNotificationChannel() async {   //NORMAL BİLDİRİM MEKANİZMASI
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground',
    'My Foreground Service',
    description: 'Channel for location tracking',
    importance: Importance.high,
  );
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

Future<void> initNotifications() async {  //BİLDİRİM SERVİSİ ÇALIŞTIRMA
  await NotificationService().initNotifications();
}

Future<void> main() async {  //SERVİSLERİN AKTİF OLMASI
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  //await NotificationService().initNotifications();
  await createAndroidNotificationChannel();
  await initNotifications();
  await askBatteryIfNeeded();

  // BFS init
  await initializeBackgroundService();
  // Workmanager init
  await WorkmanagerService.initializeWorkmanager();

  final sp = await SharedPreferences.getInstance();
  final userId = sp.getInt('user_id');
  bool todayOff = false;
  if (userId != null) {
    todayOff = await UserServiceApi.isTodayOff(userId);
  }

  // Saat kontrol: 06..22 => schedule WM, 22..06 => cancel
  final hour = DateTime.now().hour;
  if (todayOff) {
    print("[MAIN] => Bugün off => WorkManager cancelAllTasks");
    await WorkmanagerService.cancelAllTasks();
  } else {
    if (hour >= 6 && hour < 22) {
      await WorkmanagerService.schedulePeriodicTask();
    } else {
      await WorkmanagerService.cancelAllTasks();
    }
  }

  runApp(
    AppLifecycleManager( //HAYAT DÖNGÜSÜ KONTROL
      child: MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  DateTime? _backgroundTime;
  final Duration _threshold = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupFCMForegroundListener();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setupFCMForegroundListener() {
    FirebaseMessaging.onMessage.listen((message) async {
      if (message.data.isNotEmpty) {
        final action = message.data['action'];
        if (action == 'getLocation') {
          try {
            final position = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            );
            // Eskiden: "http://192.168.1.115:8000/api/save-location"
            final url = Uri.parse("${Constants.baseUrl}/save-location");
            await http.post(
              url,
              headers: {"Content-Type": "application/json"},
              body: json.encode({
                "user_id": message.data['user_id'] ?? 0,
                "latitude": position.latitude,
                "longitude": position.longitude,
                "timestamp": DateTime.now().toIso8601String(),
              }),
            );
          } catch (e) {
            // local noti yok
          }
          return;
        }
      }

      // Normal notification
      if (message.notification != null) {
        final title = message.notification!.title ?? 'FCM Foreground Title';
        final body  = message.notification!.body  ?? 'FCM Foreground Body';
        await NotificationService().showNotificationCustom(title, body);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _backgroundTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (_backgroundTime != null) {
        final diff = DateTime.now().difference(_backgroundTime!);
        if (diff > _threshold) {
          navigatorKey.currentState?.pushNamedAndRemoveUntil('/', (route) => false);
        }
      }
      _backgroundTime = null;

      final sp = await SharedPreferences.getInstance();
      final userId = sp.getInt('user_id');
      bool todayOff = false;
      if (userId != null) {
        todayOff = await UserServiceApi.isTodayOff(userId);
      }

      final hour = DateTime.now().hour;
      final min  = DateTime.now().minute;
      final totalMin = hour * 60 + min;

      if (todayOff) {
        print("[didChangeAppLifecycleState] => Off => cancel WM + stop BFS");
        await WorkmanagerService.cancelAllTasks();

        final service = FlutterBackgroundService();
        bool running = await service.isRunning();
        if (running) {
          await NotificationService().showNotificationCustom(
            "Off - tatil/izin",
            "Arka plan durduruldu. Yarın görüşmek üzere!",
          );
          service.invoke("stopService");
        }
      } else {
        // 06..22 => schedule, 22..06 => cancel
        if (hour >= 6 && hour < 22) {
          await WorkmanagerService.schedulePeriodicTask();
        } else {
          await WorkmanagerService.cancelAllTasks();
        }

        // 22 ve üstü => BFS kapat
        if (hour >= 22) {
          final service = FlutterBackgroundService();
          bool running = await service.isRunning();
          if (running) {
            await NotificationService().showNotificationCustom(
              "İyi geceler",
              "Arka plan kapandı. Sabah 06:00'da görüşmek üzere!",
            );
            service.invoke("stopService");
          }
        }

        // ─────────────────────────────────────────────────────
        // 06:00..08:10 tablo oluşturmayı “kaçırma” check
        // ─────────────────────────────────────────────────────
        bool morningCreated = sp.getBool('morningCreated') ?? false;
        if (totalMin >= 360 && totalMin <= 490 && !morningCreated) {
          print("[didChangeAppLifecycleState] => onResume sabah => tablo check");
          await UserService.handleMorningCheck(userId ?? 1);
          await sp.setBool('morningCreated', true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eyyübiye Personel Takip',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      initialRoute: '/',
      routes: {
        '/': (context) => SplashScreen(),
        '/login': (context) => LoginScreen(),
        '/attendance': (context) => AttendanceScreen(),
        '/loading': (context) => LoadingScreen(),
      },
    );
  }
}
