import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:eyyubiye_personel_takip/services/notification_service.dart';
import 'package:eyyubiye_personel_takip/utils/constants.dart';

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with WidgetsBindingObserver {
  bool _openedLocationSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initCheck();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Konum ayarlarına gittiysek geri gelince tekrar kontrol et
    if (state == AppLifecycleState.resumed && _openedLocationSettings) {
      _openedLocationSettings = false;
      _initCheck();
    }
  }

  Future<void> _initCheck() async {
    // 1) Pil optimizasyon izni (Android)
    if (Platform.isAndroid) {
      final ignoreStatus = await Permission.ignoreBatteryOptimizations.status;
      if (ignoreStatus.isDenied || ignoreStatus.isRestricted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    }

    // 2) Konum izni
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      LocationPermission asked = await Geolocator.requestPermission();
      if (asked == LocationPermission.denied || asked == LocationPermission.deniedForever) {
        await NotificationService().showNotificationCustom(
          'Konum Hatası',
          'Konum izni verilmedi, lütfen konumu açın.',
        );
        print("SPLASH => Konum izni verilmedi => login");
        _navigateToLogin();
        return;
      }
    }

    // 3) Konum servisi aktif mi?
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await NotificationService().showNotificationCustom(
        'Konum Kapalı',
        'Lütfen konum servislerini açın.',
      );
      print("SPLASH => Konum servisi kapalı => login");
      _openedLocationSettings = true;
      Geolocator.openLocationSettings();
      return;
    }

    // 4) İnternet var mı?
    var connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      await NotificationService().showNotificationCustom(
        'İnternet Yok',
        'Lütfen internet bağlantınızı açın.',
      );
      print("SPLASH => İnternet yok => login");
      _navigateToLogin();
      return;
    }

    // 5) SharedPrefs => token, device_info
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString('auth_token');
    String? deviceInfo = prefs.getString('device_info');

    if (token == null) {
      print("SPLASH => Token null => login");
      _navigateToLogin();
      return;
    }

    // 6) checkAll => Tek API kontrol
    try {
      final checkUrl = Uri.parse('${Constants.baseUrl}/check-all');
      final response = await http.post(
        checkUrl,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
        body: {
          'device_info': deviceInfo ?? '',
        },
      );

      if (response.statusCode == 200) {
        final js = jsonDecode(response.body);
        final status = js['status'];
        final reason = js['reason'];

        if (status == 'login_needed') {
          print("SPLASH => checkAll => login_needed => reason=$reason => login");
          _navigateToLogin();
          return;
        } else if (status == 'blocked') {
          print("SPLASH => checkAll => blocked => reason=$reason => loading");
          Navigator.pushReplacementNamed(context, '/loading', arguments: reason);
          return;
        }
        // YENİ KOD: Versiyon kontrol
        else if (status == 'version_update') {
          print("SPLASH => checkAll => version_update => loading");
          final versionLink = js['version_link'] ?? '';
          final versionDesc = js['version_desc'] ?? '';

          // LoadingScreen'e version_update ile gidiyoruz
          Navigator.pushReplacementNamed(
            context,
            '/loading',
            arguments: {
              'reason': 'version_update',
              'link': versionLink,
              'desc': versionDesc,
            },
          );
          return;
        }
        else if (status == 'ok') {
          print("SPLASH => checkAll => ok => devam");
          // Devam => /profile
        } else {
          print("SPLASH => checkAll => unknown => login");
          _navigateToLogin();
          return;
        }
      } else {
        print("SPLASH => checkAll => statusCode=${response.statusCode} => login");
        _navigateToLogin();
        return;
      }
    } catch (e) {
      print("SPLASH => checkAll => catch => $e => login");
      await NotificationService().showNotificationCustom(
        'Bağlantı Hatası',
        'Tek API kontrol: $e',
      );
      _navigateToLogin();
      return;
    }

    // 7) /profile kontrolü
    try {
      final profileResponse = await http.get(
        Uri.parse('${Constants.baseUrl}/profile'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      if (profileResponse.statusCode == 200) {
        final data = jsonDecode(profileResponse.body);
        final user = data['user'];

        // device verify => device_info
        final verifyResponse = await http.post(
          Uri.parse('${Constants.baseUrl}/device/verify'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'device_info': deviceInfo ?? ''}),
        );

        if (verifyResponse.statusCode == 200) {
          // Konum vs.
          String newIn  = user['check_in_location']  ?? '';
          String newOut = user['check_out_location'] ?? '';

          String? oldIn  = prefs.getString('oldCheckInLoc');
          String? oldOut = prefs.getString('oldCheckOutLoc');
          bool firstTime = (oldIn == null && oldOut == null);

          if (!firstTime) {
            if (oldIn != null && oldIn != newIn && oldIn.isNotEmpty) {
              await NotificationService().showNotificationCustom(
                'Konum Değişikliği',
                'Giriş konumunuz güncellendi: $newIn',
              );
            }
            if (oldOut != null && oldOut != newOut && oldOut.isNotEmpty) {
              await NotificationService().showNotificationCustom(
                'Konum Değişikliği',
                'Çıkış konumunuz güncellendi: $newOut',
              );
            }
          }
          await prefs.setString('oldCheckInLoc', newIn);
          await prefs.setString('oldCheckOutLoc', newOut);

          print("SPLASH => profile => verify => success => attendance");
          _navigateToAttendance();
        } else {
          // verify 403
          final verifyData = jsonDecode(verifyResponse.body);
          String message = verifyData['message'] ?? 'Cihaz doğrulama hatası';

          if (verifyResponse.statusCode == 403 && verifyData['banned'] == true) {
            print("SPLASH => device/verify => 403 banned => loading");
            Navigator.pushReplacementNamed(context, '/loading', arguments: 'banned');
          } else {
            print("SPLASH => device/verify => 403 => $message => login");
            await NotificationService().showNotificationCustom('Cihaz Hatası', message);
            _navigateToLogin();
          }
        }
      }
      else if (profileResponse.statusCode == 401) {
        // Token expired
        print("SPLASH => /profile => 401 => token expired => login");
        await NotificationService().showNotificationCustom(
          'Token Süresi Doldu',
          'Lütfen tekrar giriş yapın.',
        );
        _navigateToLogin();
      }
      else {
        // ban/hata
        final data = jsonDecode(profileResponse.body);
        String message = data['message'] ?? 'Doğrulama başarısız';

        if (profileResponse.statusCode == 403 && data['banned'] == true) {
          print("SPLASH => /profile => 403 banned => loading");
          await NotificationService().showNotificationCustom(
            'Ban Durumu',
            data['ban_reason'] ?? 'Banlı Kullanıcı',
          );
          Navigator.pushReplacementNamed(context, '/loading', arguments: 'banned');
        } else {
          print("SPLASH => /profile => ${profileResponse.statusCode} => $message => login");
          await NotificationService().showNotificationCustom('Hata', message);
          _navigateToLogin();
        }
      }
    } catch (e) {
      print("SPLASH => /profile => catch => $e => login");
      await NotificationService().showNotificationCustom(
        'Bağlantı Hatası',
        'Lütfen tekrar deneyin. $e',
      );
      _navigateToLogin();
    }
  }

  void _navigateToLogin() {
    Navigator.of(context).pushReplacementNamed('/login');
  }

  void _navigateToAttendance() {
    Navigator.of(context).pushReplacementNamed('/attendance');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        // Arka plan vs.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.blue, Colors.purple],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(height: 150),
              Image.network(
                'https://www.eyyubiye.bel.tr/images/logo.png',
                height: 180,
                width: 180,
              ),
              SizedBox(height: 50),
              Container(
                width: 400,
                height: 158,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.8),
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Stack(
                  children: [
                    // ...
                    Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Text(
                          'Eyyübiye Belediyesi',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
