import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'l10n.dart';

// ─── Global Notification Plugin ───────────────────────────────────────────────
final FlutterLocalNotificationsPlugin _notifPlugin =
    FlutterLocalNotificationsPlugin();

const _notifDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'pillbot_alarm',         // alarm channel
    'Pill Alarms',
    channelDescription: 'Alarm sound pill reminders',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true,
    playSound: true,
    enableVibration: true,
    visibility: NotificationVisibility.public,
    // Use system alarm ringtone
    sound: UriAndroidNotificationSound(
        'content://settings/system/alarm_alert'),
  ),
);

// ─── WorkManager Callback (backup — only if zonedSchedule somehow fails) ──────
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      );
      final label = inputData?['label'] ?? 'Dose';
      final emoji = inputData?['emoji'] ?? '\u{1F48A}';
      final motor = (inputData?['motor'] as num?)?.toInt() ?? 99;
      const localDetails = NotificationDetails(
        android: AndroidNotificationDetails(
          'pillbot_alarm',
          'Pill Alarms',
          channelDescription: 'Alarm sound pill reminders',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
          playSound: true,
          enableVibration: true,
          visibility: NotificationVisibility.public,
          sound: UriAndroidNotificationSound(
              'content://settings/system/alarm_alert'),
        ),
      );
      await plugin.show(
        motor,
        '$emoji Time for your $label tablet!',
        '\u{1F48A} Your pill dispenser is dispensing now. Please collect your tablet!',
        localDetails,
      );
    } catch (e) {
      return false;
    }
    return true;
  });
}

// ─── Init notifications + timezone ─────────────────────────────────────────────
Future<void> _initNotifications() async {
  // Initialize timezone data (required for zonedSchedule)
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));

  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _notifPlugin.initialize(
      const InitializationSettings(android: android));

  final androidPlugin = _notifPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
  await androidPlugin?.requestExactAlarmsPermission();
}

// ─── Fires notification + alarm sound IMMEDIATELY ─────────────────────────────
Future<void> _showImmediateNotif(String label, String emoji, int id) async {
  await _notifPlugin.show(
    id,
    '$emoji Time for your $label tablet!',
    '\u{1F48A} Your pill dispenser is dispensing now. Please collect your tablet!',
    _notifDetails,
  );
}

// ─── Schedule exact daily notification using AlarmManager (PRIMARY) ───────────
// This uses Android AlarmManager.setExactAndAllowWhileIdle() under the hood.
// It fires at the EXACT time even when the app is killed, in Doze mode, or offline.
Future<void> _scheduleDailyNotif(int motor, String label, String emoji,
    TimeOfDay t) async {
  // Cancel any existing notification for this motor
  await _notifPlugin.cancel(motor);

  // Calculate the next occurrence of this time
  final now = tz.TZDateTime.now(tz.local);
  var scheduled = tz.TZDateTime(
    tz.local, now.year, now.month, now.day, t.hour, t.minute,
  );
  // If the time has already passed today, schedule for tomorrow
  if (scheduled.isBefore(now)) {
    scheduled = scheduled.add(const Duration(days: 1));
  }

  debugPrint('[ALARM] Scheduling $label (motor $motor) at $scheduled (daily repeat)');

  await _notifPlugin.zonedSchedule(
    motor, // unique notification ID per motor
    '$emoji Time for your $label tablet!',
    '\u{1F48A} Your pill dispenser is dispensing now. Please collect your tablet!',
    scheduled,
    _notifDetails,
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
    matchDateTimeComponents: DateTimeComponents.time, // ← REPEATS DAILY at same time
    payload: 'motor_$motor',
  );
}

// ─── Register WorkManager as BACKUP (secondary, in case AlarmManager is cleared) ─
Future<void> _registerBackupWorkManager(int motor, String label, String emoji,
    TimeOfDay t) async {
  final now = DateTime.now();
  var scheduled = DateTime(now.year, now.month, now.day, t.hour, t.minute);
  if (scheduled.isBefore(now.add(const Duration(seconds: 30)))) {
    scheduled = scheduled.add(const Duration(days: 1));
  }
  await Workmanager().registerOneOffTask(
    'pill_$motor',
    'pillReminder',
    initialDelay: scheduled.difference(now),
    inputData: {'motor': motor, 'label': label, 'emoji': emoji},
    existingWorkPolicy: ExistingWorkPolicy.replace,
    constraints: Constraints(
      networkType: NetworkType.notRequired,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
      requiresStorageNotLow: false,
    ),
  );
}

// ─── Combined: Schedule both AlarmManager + WorkManager backup ───────────────
Future<void> _registerDoseTask(int motor, String label, String emoji,
    TimeOfDay t) async {
  // PRIMARY: Exact AlarmManager-based notification (fires even when app killed)
  await _scheduleDailyNotif(motor, label, emoji, t);
  // BACKUP: WorkManager (in case system clears AlarmManager on reboot without receiver)
  await _registerBackupWorkManager(motor, label, emoji, t);
}

bool _notifPermissionOk = true;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await _initNotifications();
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  runApp(const PillDispenserApp());
}


// ─── Model ────────────────────────────────────────────────────────────────────
class Dose {
  final String label, emoji;
  final int motor;
  final Color color, glowColor;
  TimeOfDay? scheduledTime;
  bool lastTaken;
  DateTime? lastTakenAt;

  Dose({
    required this.label,
    required this.emoji,
    required this.motor,
    required this.color,
    required this.glowColor,
    this.scheduledTime,
    this.lastTaken = false,
    this.lastTakenAt,
  });
}

// ─── App ──────────────────────────────────────────────────────────────────────
class PillDispenserApp extends StatelessWidget {
  const PillDispenserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PillBot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF00D4AA),
          surface: Color(0xFF141828),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─── Home ─────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  static const String _base = 'http://10.0.142.112:5000';

  late List<Dose> _doses;
  final Map<int, bool> _loading = {};
  final Map<int, String> _status = {};
  bool _connected = false;
  bool _permissionOk = false;
  bool _isRegisteringFace = false;
  int _timeLimit = 30;
  String _lang = 'en';
  Timer? _pingTimer;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _doses = [
      Dose(label: 'Morning',   emoji: '🌅', motor: 1,
          color: const Color(0xFFFF8C42), glowColor: const Color(0xFFFF8C42)),
      Dose(label: 'Afternoon', emoji: '☀️', motor: 2,
          color: const Color(0xFF6C63FF), glowColor: const Color(0xFF6C63FF)),
      Dose(label: 'Night',     emoji: '🌙', motor: 3,
          color: const Color(0xFF00D4AA), glowColor: const Color(0xFF00D4AA)),
    ];
    // Load saved language
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('lang') ?? 'en';
      final savedLimit = prefs.getInt('timeLimit') ?? 30;
      setState(() { 
        _lang = saved; 
        _timeLimit = savedLimit;
        L.set(saved); 
      });
    });
    _pulseCtrl = AnimationController(vsync: this,
        duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.8, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadLocal();
    _loadFromPi();
    _pingServer();
    _checkPermission();
    _requestBatteryOptimizationExemption();
    _reRegisterAllDoseTasks(); // Re-register on every app startup as safety net
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pingServer());
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Check notification/alarm permission ──
  Future<void> _checkPermission() async {
    final androidPlugin = _notifPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final ok = await androidPlugin?.canScheduleExactNotifications() ?? false;
    setState(() => _permissionOk = ok);
    if (!ok && mounted) {
      // Ask user to allow exact alarms in Settings
      await androidPlugin?.requestExactAlarmsPermission();
      final okAfter = await androidPlugin?.canScheduleExactNotifications() ?? false;
      if (mounted) setState(() => _permissionOk = okAfter);
    }
  }

  // ── Request battery optimization exemption (critical for background notifications) ──
  Future<void> _requestBatteryOptimizationExemption() async {
    try {
      // Use Android Intent to request battery optimization exemption
      const platform = MethodChannel('com.example.pill_dispenser/battery');
      final bool isExempt = await platform.invokeMethod('isIgnoringBatteryOptimizations') ?? false;
      if (!isExempt) {
        await platform.invokeMethod('requestIgnoreBatteryOptimizations');
      }
    } catch (e) {
      // Fallback: Channel not available, permission still requested via manifest
      debugPrint('[BATTERY] Could not request battery exemption: $e');
    }
  }

  // ── Re-register all saved dose tasks on startup (safety net) ──
  Future<void> _reRegisterAllDoseTasks() async {
    final prefs = await SharedPreferences.getInstance();
    for (final d in _doses) {
      final h = prefs.getInt('${d.motor}_h');
      final m = prefs.getInt('${d.motor}_m');
      if (h != null && m != null) {
        final t = TimeOfDay(hour: h, minute: m);
        await _registerDoseTask(d.motor, d.label, d.emoji, t);
        debugPrint('[WORKMANAGER] Re-registered task for ${d.label} at $h:$m');
      }
    }
  }


  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('lang') ?? 'en';
    setState(() {
      _lang = savedLang;
      L.set(savedLang);
      for (final d in _doses) {
        final h = prefs.getInt('${d.motor}_h');
        final m = prefs.getInt('${d.motor}_m');
        if (h != null && m != null) d.scheduledTime = TimeOfDay(hour: h, minute: m);
        final ts = prefs.getString('${d.motor}_last');
        if (ts != null) {
          d.lastTakenAt = DateTime.tryParse(ts);
          d.lastTaken = d.lastTakenAt != null &&
              _sameDay(d.lastTakenAt!, DateTime.now());
        }
      }
    });
  }

  // ── Language picker ──
  Future<void> _pickLanguage() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF141828),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 16),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 16),
        Text(L.selectLanguage,
            style: const TextStyle(color: Colors.white, fontSize: 18,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: L.languages.length,
            itemBuilder: (_, i) {
              final lang = L.languages[i];
              final isSelected = lang['code'] == _lang;
              return ListTile(
                onTap: () => Navigator.pop(ctx, lang['code']),
                leading: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF6C63FF).withAlpha(50)
                        : Colors.white.withAlpha(10),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(lang['native']![0],
                        style: const TextStyle(fontSize: 16)),
                  ),
                ),
                title: Text(lang['native']!,
                    style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF6C63FF)
                            : Colors.white,
                        fontWeight: isSelected
                            ? FontWeight.w700 : FontWeight.w500)),
                subtitle: Text(lang['name']!,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: isSelected
                    ? const Icon(Icons.check_circle_rounded,
                        color: Color(0xFF6C63FF))
                    : null,
              );
            },
          ),
        ),
        const SizedBox(height: 20),
      ]),
    );
    if (selected != null && selected != _lang) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lang', selected);
      setState(() { _lang = selected; L.set(selected); });
    }
  }

  // ── Sync schedules FROM Pi ──
  Future<void> _loadFromPi() async {
    try {
      final res = await http.get(Uri.parse('$_base/get_schedules'))
          .timeout(const Duration(seconds: 5));
      final Map<String, dynamic> data = jsonDecode(res.body);
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        for (final d in _doses) {
          final t = data[d.motor.toString()];
          if (t != null && t is String && t.contains(':')) {
            final parts = t.split(':');
            d.scheduledTime = TimeOfDay(
                hour: int.parse(parts[0]), minute: int.parse(parts[1]));
            prefs.setInt('${d.motor}_h', d.scheduledTime!.hour);
            prefs.setInt('${d.motor}_m', d.scheduledTime!.minute);
          }
        }
      });
    } catch (_) {}
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _pingServer() async {
    try {
      final res = await http.get(Uri.parse('$_base/'))
          .timeout(const Duration(seconds: 4));
      setState(() => _connected = res.statusCode == 200);
    } catch (_) {
      setState(() => _connected = false);
    }
  }

  // ── Manual dispense ──
  Future<void> _runMotor(Dose dose) async {
    setState(() {
      _loading[dose.motor] = true;
      _status[dose.motor] = L.dispensing;
    });
    try {
      final res = await http
          .get(Uri.parse('$_base/run?motor=${dose.motor}'))
          .timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body);
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setString('${dose.motor}_last', now.toIso8601String());
      setState(() {
        _loading[dose.motor] = false;
        _status[dose.motor] = body['message'] ?? '✅ Done!';
        dose.lastTaken = true;
        dose.lastTakenAt = now;
      });
    } catch (e) {
      setState(() {
        _loading[dose.motor] = false;
        _status[dose.motor] = '❌ Failed – check Wi-Fi';
      });
    }
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) setState(() => _status.remove(dose.motor));
  }

  // ── Pick time → save on Pi + schedule local notification ──
  Future<void> _pickTime(Dose dose) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: dose.scheduledTime ?? TimeOfDay.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          timePickerTheme: TimePickerThemeData(
            backgroundColor: const Color(0xFF141828),
            dialHandColor: dose.color,
            dialBackgroundColor: const Color(0xFF0A0E1A),
            hourMinuteColor: WidgetStateColor.resolveWith(
                (_) => dose.color.withAlpha(50)),
            hourMinuteTextColor: WidgetStateColor.resolveWith(
                (_) => Colors.white),
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;

    // 1) Save locally
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${dose.motor}_h', picked.hour);
    await prefs.setInt('${dose.motor}_m', picked.minute);
    setState(() => dose.scheduledTime = picked);

    // 2) Send to Raspberry Pi
    final timeStr =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    try {
      await http.post(
        Uri.parse('$_base/set_schedule'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'motor': dose.motor, 'time': timeStr}),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}

    // 3) Register WorkManager task (fires even when app is killed)
    await _registerDoseTask(dose.motor, dose.label, dose.emoji, picked);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${dose.emoji} ${dose.label} ${L.scheduledAt} ${picked.format(context)}\nPi ✅'),
        backgroundColor: dose.color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    }
  }

  // ── Capture and Send Face ──
  Future<void> _captureAndSendFace() async {
    setState(() => _isRegisteringFace = true);
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
      );

      if (image == null) {
        setState(() => _isRegisteringFace = false);
        return;
      }

      var request = http.MultipartRequest('POST', Uri.parse('$_base/register_face'));
      request.files.add(await http.MultipartFile.fromPath('image', image.path));

      var response = await request.send().timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ ${L.faceRegistered}'),
            backgroundColor: const Color(0xFF00D4AA),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } else {
        throw Exception('Failed');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L.failedCheckWifi),
          backgroundColor: const Color(0xFFFF5252),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _isRegisteringFace = false);
    }
  }

  // ── Set Time Limit ──
  Future<void> _pickTimeLimit() async {
    final limit = await showDialog<int>(
      context: context,
      builder: (ctx) {
        int tempLimit = _timeLimit;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF141828),
              title: Text(L.collectionTimeLimit, style: const TextStyle(color: Colors.white, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$tempLimit mins', style: const TextStyle(color: Color(0xFF00D4AA), fontSize: 24, fontWeight: FontWeight.bold)),
                  Slider(
                    value: tempLimit.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 11,
                    activeColor: const Color(0xFF00D4AA),
                    onChanged: (val) => setState(() => tempLimit = val.toInt()),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, tempLimit),
                  child: const Text('Save', style: TextStyle(color: Color(0xFF00D4AA))),
                ),
              ],
            );
          }
        );
      }
    );

    if (limit != null && limit != _timeLimit) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('timeLimit', limit);
      setState(() => _timeLimit = limit);

      try {
        await http.post(
          Uri.parse('$_base/set_time_limit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'time_limit': limit}),
        ).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader()),
            SliverToBoxAdapter(child: _buildStatusBar()),
            if (!_permissionOk)
              SliverToBoxAdapter(child: _buildPermissionBanner()),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _DoseCard(
                      dose: _doses[i],
                      isLoading: _loading[_doses[i].motor] == true,
                      statusMsg: _status[_doses[i].motor],
                      onDispense: () => _runMotor(_doses[i]),
                      onSchedule: () => _pickTime(_doses[i]),
                      pulseAnim: _pulseAnim,
                    ),
                  ),
                  childCount: _doses.length,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _buildFooter()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final taken = _doses.where((d) => d.lastTaken).length;
    final total = _doses.length;
    // Find native name of selected language
    final langNative = L.languages
        .firstWhere((l) => l['code'] == _lang,
            orElse: () => {'native': 'EN'})['native'] ?? 'EN';
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFF6C63FF), Color(0xFF00D4AA)]),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(
                  color: const Color(0xFF6C63FF).withAlpha(128),
                  blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: const Center(child: Text('💊', style: TextStyle(fontSize: 24))),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('PillBot', style: TextStyle(fontSize: 26,
                fontWeight: FontWeight.w800, color: Colors.white,
                letterSpacing: -0.5)),
            Text(L.subtitle, style: const TextStyle(
                fontSize: 13, color: Color(0xFF8892B0))),
          ])),
          // Language picker button
          GestureDetector(
            onTap: _pickLanguage,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF6C63FF).withAlpha(30),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF6C63FF).withAlpha(100)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.language_rounded,
                    size: 14, color: Color(0xFF6C63FF)),
                const SizedBox(width: 5),
                Text(langNative,
                    style: const TextStyle(
                        color: Color(0xFF6C63FF),
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(L.selectLanguage,
            style: const TextStyle(fontSize: 10, color: Color(0xFF8892B0))),

        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              const Color(0xFF6C63FF).withAlpha(38),
              const Color(0xFF00D4AA).withAlpha(20),
            ]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF6C63FF).withAlpha(50)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
            Text(L.todaysProgress,
                    style: const TextStyle(color: Colors.white70, fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Text('$taken / $total ${L.dose}',
                    style: const TextStyle(color: Color(0xFF00D4AA),
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : taken / total,
                minHeight: 8,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                    taken == total ? const Color(0xFF00D4AA) : const Color(0xFF6C63FF)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Row(children: [
        AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Transform.scale(
            scale: _connected ? _pulseAnim.value : 1.0,
            child: Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _connected
                    ? const Color(0xFF00D4AA) : const Color(0xFFFF5252),
                boxShadow: _connected ? [BoxShadow(
                    color: const Color(0xFF00D4AA).withAlpha(150),
                    blurRadius: 6)] : [],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _connected ? L.connectedToPi : L.disconnected,
          style: TextStyle(fontSize: 12,
              color: _connected
                  ? const Color(0xFF00D4AA) : const Color(0xFFFF5252),
              fontWeight: FontWeight.w500),
        ),
        const Spacer(),
        GestureDetector(
          onTap: () { _pingServer(); _loadFromPi(); },
          child: const Icon(Icons.refresh_rounded,
              size: 18, color: Color(0xFF8892B0)),
        ),
      ]),
    );
  }

  Widget _buildPermissionBanner() {
    return GestureDetector(
      onTap: _checkPermission,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFF5252).withAlpha(25),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFF5252).withAlpha(100)),
        ),
        child: Row(children: [
          const Icon(Icons.notifications_off_rounded,
              color: Color(0xFFFF5252), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              L.notifPermNeeded,
              style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12,
                  fontWeight: FontWeight.w500),
            ),
          ),
          const Icon(Icons.arrow_forward_ios_rounded,
              color: Color(0xFFFF5252), size: 14),
        ]),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(children: [
        // ── Test Notification Button ──
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: () async {
              await _showImmediateNotif('Morning', '🌅', 99);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text(
                      '🔔 Test notification sent!\nClose the app and check your notification bar.'),
                  backgroundColor: Color(0xFF6C63FF),
                  behavior: SnackBarBehavior.floating,
                  duration: Duration(seconds: 4),
                ));
              }
            },
            icon: const Icon(Icons.notifications_active_rounded, size: 18),
            label: Text(L.testNotif,
                style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF6C63FF),
              side: const BorderSide(color: Color(0xFF6C63FF), width: 1.5),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        
        // ── Register Face Button ──
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _isRegisteringFace ? null : _captureAndSendFace,
            icon: _isRegisteringFace 
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.face_retouching_natural_rounded, size: 18),
            label: Text(L.registerFace, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4AA),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── Set Time Limit Button ──
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _pickTimeLimit,
            icon: const Icon(Icons.timer_rounded, size: 18),
            label: Text('${L.collectionTimeLimit}: $_timeLimit mins', style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF00D4AA),
              side: const BorderSide(color: Color(0xFF00D4AA), width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        
        const Divider(color: Colors.white10),
        const SizedBox(height: 10),
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.medication_rounded, size: 14, color: Color(0xFF8892B0)),
          SizedBox(width: 6),
          Text('PillBot v2.0 · Face Verified Auto-Dispenser',
              style: TextStyle(fontSize: 12, color: Color(0xFF8892B0))),
        ]),
        const SizedBox(height: 8),
      ]),
    );
  }
}


// ─── Dose Card ────────────────────────────────────────────────────────────────
class _DoseCard extends StatefulWidget {
  final Dose dose;
  final bool isLoading;
  final String? statusMsg;
  final VoidCallback onDispense, onSchedule;
  final Animation<double> pulseAnim;

  const _DoseCard({
    required this.dose, required this.isLoading, required this.statusMsg,
    required this.onDispense, required this.onSchedule, required this.pulseAnim,
  });

  @override
  State<_DoseCard> createState() => _DoseCardState();
}

class _DoseCardState extends State<_DoseCard> with SingleTickerProviderStateMixin {
  late AnimationController _press;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 100));
    _scale = Tween<double>(begin: 1.0, end: 0.96).animate(
        CurvedAnimation(parent: _press, curve: Curves.easeOut));
  }

  @override
  void dispose() { _press.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final d = widget.dose;
    return AnimatedBuilder(
      animation: _scale,
      builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
      child: GestureDetector(
        onTapDown: (_) => _press.forward(),
        onTapUp: (_) => _press.reverse(),
        onTapCancel: () => _press.reverse(),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF141828),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: d.lastTaken ? d.color.withAlpha(128) : Colors.white.withAlpha(15)),
            boxShadow: [BoxShadow(
                color: d.lastTaken ? d.glowColor.withAlpha(100) : Colors.black.withAlpha(76),
                blurRadius: 16, offset: const Offset(0, 4))],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _header(d),
            const SizedBox(height: 16),
            _scheduleRow(d),
            const SizedBox(height: 16),
            if (widget.statusMsg != null) ...[_statusBanner(d), const SizedBox(height: 12)],
            _dispenseBtn(d),
          ]),
        ),
      ),
    );
  }

  Widget _header(Dose d) {
    return Row(children: [
      Container(
        width: 52, height: 52,
        decoration: BoxDecoration(
          color: d.color.withAlpha(38),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: d.color.withAlpha(76)),
        ),
        child: Center(child: Text(d.emoji, style: const TextStyle(fontSize: 26))),
      ),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_doseLabel(d.motor)} ${L.dose}',
            style: const TextStyle(color: Colors.white, fontSize: 18,
                fontWeight: FontWeight.w700)),
        Text('${L.motorLabel} ${d.motor}',
            style: TextStyle(color: d.color, fontSize: 12, fontWeight: FontWeight.w500)),
      ])),
      if (d.lastTaken)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: d.color.withAlpha(38),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: d.color.withAlpha(102)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle_rounded, size: 12, color: d.color),
            const SizedBox(width: 4),
            Text(L.taken, style: TextStyle(color: d.color, fontSize: 11,
                fontWeight: FontWeight.w700)),
          ]),
        ),
    ]);
  }

  Widget _scheduleRow(Dose d) {
    final timeStr = d.scheduledTime != null ? _fmt(d.scheduledTime!) : L.tapToSetTime;
    return GestureDetector(
      onTap: widget.onSchedule,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(20)),
        ),
        child: Row(children: [
          Icon(Icons.access_time_rounded, size: 16, color: d.color),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(L.autoDispenseTime,
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
            Text(timeStr,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ])),
          Icon(Icons.edit_rounded, size: 14, color: d.color.withAlpha(153)),
          const SizedBox(width: 4),
          Text(L.edit, style: TextStyle(color: d.color.withAlpha(204),
              fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _statusBanner(Dose d) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: d.color.withAlpha(25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.color.withAlpha(76)),
      ),
      child: Row(children: [
        widget.isLoading
            ? SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: d.color))
            : Icon(Icons.info_outline_rounded, size: 14, color: d.color),
        const SizedBox(width: 8),
        Expanded(child: Text(widget.statusMsg!,
            style: TextStyle(color: d.color, fontSize: 13,
                fontWeight: FontWeight.w500))),
      ]),
    );
  }

  Widget _dispenseBtn(Dose d) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: widget.isLoading ? null : widget.onDispense,
        style: ElevatedButton.styleFrom(
          backgroundColor: d.color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: d.color.withAlpha(102),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: widget.isLoading
            ? const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.medication_liquid_rounded, size: 18),
                const SizedBox(width: 8),
                Text(d.lastTaken ? L.dispenseAgain : '${L.dispense} ${_doseLabel(d.motor)}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ]),
      ),
    );
  }

  String _fmt(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  // Returns translated dose label (Morning/Afternoon/Night) by motor number
  String _doseLabel(int motor) {
    if (motor == 1) return L.morning;
    if (motor == 2) return L.afternoon;
    return L.night;
  }
}
