import 'package:flutter/material.dart';

class Constants {
  static const String baseUrl = "http://192.168.1.103:8080/api";
  static const String BASE_URL = "http://192.168.1.103:8080/api";

  static const String tokenKey = "auth_token";

  static const Color primaryColor = Colors.blue;
  static const Color secondaryColor = Colors.green;

  static const TextStyle titleStyle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
  );

  static const TextStyle subtitleStyle = TextStyle(
    fontSize: 18,
    color: Colors.grey,
  );

  static const EdgeInsets globalPadding = EdgeInsets.all(16.0);
}
