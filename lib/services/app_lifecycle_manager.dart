import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLifecycleManager extends StatefulWidget {
  final Widget child;
  const AppLifecycleManager({Key? key, required this.child}) : super(key: key);

  @override
  _AppLifecycleManagerState createState() => _AppLifecycleManagerState();
}

class _AppLifecycleManagerState extends State<AppLifecycleManager> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      _setIsInForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _setIsInForeground(false);
    }
  }

  Future<void> _setIsInForeground(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isInForeground', value);
    debugPrint("[AppLifecycleManager] isInForeground=$value");
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
