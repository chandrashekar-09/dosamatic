import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────
void main() => runApp(const DosamaticApp());

class DosamaticApp extends StatelessWidget {
  const DosamaticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dosamatic Controller',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ControllerPage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────────────────
class Waypoint {
  final int x, y, z, speed;
  const Waypoint(
      {required this.x, required this.y, required this.z, this.speed = 0});

  Map<String, int> toJson() => {'x': x, 'y': y, 'z': z, 'speed': speed};

  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
        x: (j['x'] ?? 0) as int,
        y: (j['y'] ?? 0) as int,
        z: (j['z'] ?? 0) as int,
        speed: (j['speed'] ?? 0) as int,
      );

  Waypoint copyWith({int? x, int? y, int? z, int? speed}) => Waypoint(
        x: x ?? this.x,
        y: y ?? this.y,
        z: z ?? this.z,
        speed: speed ?? this.speed,
      );
}

class PresetModel {
  final String id, name;
  final List<PresetStep> steps;
  const PresetModel(
      {required this.id, required this.name, required this.steps});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory PresetModel.fromJson(Map<String, dynamic> j) {
    final rawSteps = (j['steps'] as List<dynamic>? ?? []);
    return PresetModel(
      id: (j['id'] ?? DateTime.now().millisecondsSinceEpoch.toString())
          .toString(),
      name: (j['name'] ?? 'Preset').toString(),
      steps: rawSteps.map((s) => PresetStep.fromJson(s)).toList(),
    );
  }
}

class PresetStep {
  final String label;
  final int feed;
  final List<Waypoint> points;
  final String gcode;

  const PresetStep({
    required this.label,
    required this.feed,
    required this.points,
    required this.gcode,
  });

  int get pointCount => points.length;

  Map<String, dynamic> toJson() => {
        'label': label,
        'feed': feed,
        'points': points.map((p) => p.toJson()).toList(),
        'gcode': gcode,
      };

  factory PresetStep.fromJson(dynamic raw) {
    if (raw is List<dynamic>) {
      final points =
          raw.map((p) => Waypoint.fromJson(p as Map<String, dynamic>)).toList();
      return PresetStep(
        label: 'Legacy Step',
        feed: points.isEmpty ? 0 : points.first.speed,
        points: points,
        gcode: '',
      );
    }
    final j = raw as Map<String, dynamic>;
    final points = (j['points'] as List<dynamic>? ?? [])
        .map((p) => Waypoint.fromJson(p as Map<String, dynamic>))
        .toList();
    return PresetStep(
      label: (j['label'] ?? 'Step').toString(),
      feed: (j['feed'] as num?)?.round() ??
          (points.isEmpty ? 0 : points.first.speed),
      points: points,
      gcode: (j['gcode'] ?? '').toString(),
    );
  }
}

class DeviceGcodeFile {
  final String name;
  final int size;

  const DeviceGcodeFile({required this.name, required this.size});

  factory DeviceGcodeFile.fromJson(Map<String, dynamic> j) => DeviceGcodeFile(
        name: (j['name'] ?? '').toString(),
        size: (j['size'] as num?)?.round() ?? 0,
      );
}

enum ShapeType { line, square, triangle, circle, spiral, spinge, custom }

// ─────────────────────────────────────────────────────────────────────────────
// CONTROLLER PAGE
// ─────────────────────────────────────────────────────────────────────────────
class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});
  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  // ── Constants ──────────────────────────────────────────────────────────────
  static const int _customTemplateMax = 1000;
  static const int _maxImportedRawPoints = 5000;
  static const int _firmwareQueueMax = 180;
  static const int _minFeedStepsPerSec = 100;
  static const int _maxFeedStepsPerSec = 12000;
  static const double _curveChordErrorSteps = 0.25;
  // How many free slots we target before sending the next chunk
  static const int _streamChunkSize = 60;
  static const int _streamRefillThreshold = 40; // send when free >= this
  static const String _defaultMdnsHost = 'dosamatic.local';
  static const String _keyHost = 'dosamatic.host';
  static const String _keyUseMdns = 'dosamatic.use_mdns';
  static const String _keyPresets = 'dosamatic.saved_presets';
  static const MethodChannel _saveFileChannel =
      MethodChannel('dosamatic/save_file');

  // ── Device state ───────────────────────────────────────────────────────────
  String _deviceState = 'UNKNOWN';
  int _currentX = 0, _currentY = 0, _currentZ = 0;
  int _queueDepth = 0, _queueFree = _firmwareQueueMax;
  int _dcSpeed = 0;
  int _limitX = 14000, _limitY = 14000, _limitZ = 14000;
  int _maxSpeed1 = 12000, _maxSpeed2 = 12000, _maxSpeed3 = 12000;
  double _pathAccel = 18000.0;
  double _junctionDev = 1.20;
  bool _isConnected = false, _isFetchingStatus = false;
  int _selectedTab = 0;

  // ── Connection ─────────────────────────────────────────────────────────────
  bool _useMdns = false;
  String _manualHost = '';

  late Timer _pollingTimer;

  // ── Text controllers ───────────────────────────────────────────────────────
  final _hostCtrl = TextEditingController();
  final _limXCtrl = TextEditingController();
  final _limYCtrl = TextEditingController();
  final _limZCtrl = TextEditingController();
  final _spdXCtrl = TextEditingController();
  final _spdYCtrl = TextEditingController();
  final _spdZCtrl = TextEditingController();
  final _jogStepCtrl = TextEditingController();
  final _manualSpdCtrl = TextEditingController();
  final _dcSpeedCtrl = TextEditingController();
  final _presetNameCtrl = TextEditingController();
  final _pathAccelCtrl = TextEditingController();
  final _junctionDevCtrl = TextEditingController();

  final _limXFocus = FocusNode();
  final _limYFocus = FocusNode();
  final _limZFocus = FocusNode();
  final _spdXFocus = FocusNode();
  final _spdYFocus = FocusNode();
  final _spdZFocus = FocusNode();
  final _pathAccelFocus = FocusNode();
  final _junctionDevFocus = FocusNode();

  // ── Jog / manual ───────────────────────────────────────────────────────────
  int _jogStep = 1000;
  int _manualSpeed = 1200;
  int _dcCommandSpeed = 120;
  bool _isSendingDcCommand = false;

  // ── Shape parameters ───────────────────────────────────────────────────────
  ShapeType _shapeType = ShapeType.square;
  double _shapeSize = 2000;
  int _shapeZ = 0;
  int _circleSegments = 72; // FIX: raised from 20 — adaptive override below
  int _spiralTurns = 5;
  int _spingeWaves = 4;
  int _shapeOffsetX = 0;
  int _shapeOffsetY = 0;
  int _customDrawDensity = 6;
  bool _circleClockwise = true;
  bool _isImportingDraw = false;
  bool _isStreaming = false;
  bool _isUploading = false;

  /// Single source of truth for generated shape/preset feed rate.
  int _masterFeedRate = 7000;

  // ── Custom / preset ─────────────────────────────────────────────────────────
  final List<Waypoint> _customPoints = [
    const Waypoint(x: 0, y: 0, z: 0),
    const Waypoint(x: _customTemplateMax, y: 0, z: 0),
    const Waypoint(x: _customTemplateMax, y: _customTemplateMax, z: 0),
    const Waypoint(x: 0, y: _customTemplateMax, z: 0),
    const Waypoint(x: 0, y: 0, z: 0),
  ];
  List<PresetStep> _draftPresetSteps = [];
  List<PresetModel> _presets = [];
  List<DeviceGcodeFile> _deviceFiles = [];
  bool _isLoadingFiles = false;
  bool _isFormattingStorage = false;
  bool _storageMounted = false;
  int _storageUsed = 0;
  int _storageTotal = 0;
  String _storageError = '';

  // ─────────────────────────────────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _limXCtrl.text = _limitX.toString();
    _limYCtrl.text = _limitY.toString();
    _limZCtrl.text = _limitZ.toString();
    _spdXCtrl.text = _maxSpeed1.toString();
    _spdYCtrl.text = _maxSpeed2.toString();
    _spdZCtrl.text = _maxSpeed3.toString();
    _jogStepCtrl.text = _jogStep.toString();
    _manualSpdCtrl.text = _manualSpeed.toString();
    _dcSpeedCtrl.text = _dcCommandSpeed.toString();
    _pathAccelCtrl.text = _pathAccel.toStringAsFixed(0);
    _junctionDevCtrl.text = _junctionDev.toStringAsFixed(3);
    _hostCtrl.text = _manualHost;
    _loadLocalSettings();

    _pollingTimer = Timer.periodic(
        const Duration(milliseconds: 1500), (_) => _fetchStatus());
    _fetchStatus();
  }

  @override
  void dispose() {
    _pollingTimer.cancel();
    for (final c in [
      _hostCtrl,
      _limXCtrl,
      _limYCtrl,
      _limZCtrl,
      _spdXCtrl,
      _spdYCtrl,
      _spdZCtrl,
      _jogStepCtrl,
      _manualSpdCtrl,
      _dcSpeedCtrl,
      _presetNameCtrl,
      _pathAccelCtrl,
      _junctionDevCtrl,
    ]) {
      c.dispose();
    }
    for (final f in [
      _limXFocus,
      _limYFocus,
      _limZFocus,
      _spdXFocus,
      _spdYFocus,
      _spdZFocus,
      _pathAccelFocus,
      _junctionDevFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  String get _activeHost => _useMdns ? _defaultMdnsHost : _manualHost.trim();
  String get _apiUrl => _activeHost.isEmpty ? '' : 'http://$_activeHost/api';

  bool get _isBusyState =>
      _deviceState == 'HOMING' || _deviceState == 'WAITING';

  bool get _isMoving => _deviceState == 'MOVING';

  int get _maxCanvasX => math.max(1, _limitX);
  int get _maxCanvasY => math.max(1, _limitY);

  int _asInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.round();
    return fallback;
  }

  int _clampFeed(int speed) =>
      speed.clamp(_minFeedStepsPerSec, _maxFeedStepsPerSec).toInt();

  String _normalizeHost(String input) {
    var host = input.trim();
    if (host.isEmpty) return host;
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    final slash = host.indexOf('/');
    if (slash >= 0) host = host.substring(0, slash);
    return host.trim();
  }

  void _syncCtrl(TextEditingController c, FocusNode f, int v) {
    if (f.hasFocus) return;
    final s = v.toString();
    if (c.text != s) c.text = s;
  }

  void _syncDoubleCtrl(TextEditingController c, FocusNode f, double v,
      {int fraction = 2}) {
    if (f.hasFocus) return;
    final s = v.toStringAsFixed(fraction);
    if (c.text != s) c.text = s;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SETTINGS PERSISTENCE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadLocalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      final host = prefs.getString(_keyHost);
      if (host != null && host.isNotEmpty) {
        final normalized = _normalizeHost(host);
        _manualHost = normalized;
        _hostCtrl.text = normalized;
      }
      final useMdns = prefs.getBool(_keyUseMdns);
      if (useMdns != null) _useMdns = useMdns;

      final pJson = prefs.getString(_keyPresets);
      if (pJson != null && pJson.isNotEmpty) {
        try {
          _presets = (jsonDecode(pJson) as List<dynamic>)
              .map((e) => PresetModel.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {}
      }
    });
  }

  Future<void> _savePresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keyPresets, jsonEncode(_presets.map((p) => p.toJson()).toList()));
  }

  Future<void> _saveConnectionSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final host = _normalizeHost(_hostCtrl.text);
    if (!_useMdns && host.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter a manual IP/host or enable mDNS.'),
      ));
      return;
    }
    await prefs.setBool(_keyUseMdns, _useMdns);
    if (host.isNotEmpty) {
      await prefs.setString(_keyHost, host);
      _manualHost = host;
      _hostCtrl.text = host;
      if (!host.endsWith('.local') && host != _defaultMdnsHost) {
        _useMdns = false;
        await prefs.setBool(_keyUseMdns, false);
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_useMdns
          ? 'Using mDNS: $_defaultMdnsHost'
          : 'Using manual host: $_manualHost'),
    ));
    _fetchStatus();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STATUS POLLING
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _fetchStatus() async {
    if (_isFetchingStatus) return;
    _isFetchingStatus = true;
    final host = _activeHost;
    if (host.isEmpty) {
      if (mounted) setState(() => _isConnected = false);
      _isFetchingStatus = false;
      return;
    }
    try {
      final res = await http
          .get(Uri.parse('http://$host/api/status'))
          .timeout(const Duration(seconds: 2));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _isConnected = true;
          _deviceState = (d['state'] ?? 'UNKNOWN').toString();
          _currentX = _asInt(d['m1_pos'], 0);
          _currentY = _asInt(d['m2_pos'], 0);
          _currentZ = _asInt(d['m3_pos'], 0);
          _queueDepth = _asInt(d['queue_depth'], 0);
          _queueFree = _asInt(d['queue_free'], _firmwareQueueMax);
          _dcSpeed = _asInt(d['dc_pwm'], 0);
          _storageMounted = d['storage_mounted'] == true;
          _storageTotal = _asInt(d['storage_total'], _storageTotal);
          _storageUsed = _asInt(d['storage_used'], _storageUsed);

          if (d['max1'] != null) {
            _limitX = _asInt(d['max1'], _limitX);
            _syncCtrl(_limXCtrl, _limXFocus, _limitX);
          }
          if (d['max2'] != null) {
            _limitY = _asInt(d['max2'], _limitY);
            _syncCtrl(_limYCtrl, _limYFocus, _limitY);
          }
          if (d['max3'] != null) {
            _limitZ = _asInt(d['max3'], _limitZ);
            _syncCtrl(_limZCtrl, _limZFocus, _limitZ);
          }
          if (d['m1_max_speed'] != null) {
            _maxSpeed1 = _asInt(d['m1_max_speed'], _maxSpeed1);
            _syncCtrl(_spdXCtrl, _spdXFocus, _maxSpeed1);
          }
          if (d['m2_max_speed'] != null) {
            _maxSpeed2 = _asInt(d['m2_max_speed'], _maxSpeed2);
            _syncCtrl(_spdYCtrl, _spdYFocus, _maxSpeed2);
          }
          if (d['m3_max_speed'] != null) {
            _maxSpeed3 = _asInt(d['m3_max_speed'], _maxSpeed3);
            _syncCtrl(_spdZCtrl, _spdZFocus, _maxSpeed3);
          }
          if (d['path_accel'] != null) {
            _pathAccel = (d['path_accel'] as num).toDouble();
            _syncDoubleCtrl(_pathAccelCtrl, _pathAccelFocus, _pathAccel,
                fraction: 0);
          }
          if (d['junction_dev'] != null) {
            _junctionDev = (d['junction_dev'] as num).toDouble();
            _syncDoubleCtrl(_junctionDevCtrl, _junctionDevFocus, _junctionDev,
                fraction: 3);
          }
        });
      } else {
        setState(() => _isConnected = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    } finally {
      _isFetchingStatus = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STREAMING PATH SENDER
  // ─────────────────────────────────────────────────────────────────────────
  /*
   * For paths longer than the firmware queue (180 waypoints) we stream chunks:
   *   1. Send first chunk immediately.
   *   2. Poll /api/status every 400 ms.
   *   3. When queue_free >= _streamRefillThreshold, send next chunk.
   *   4. Repeat until all waypoints are sent.
   *   5. Wait for device to return to READY before resolving.
   *
   * This means shapes with any number of points can be executed.
   * The firmware's look-ahead still works because there are always several
   * waypoints buffered ahead of the current segment.
   */
  Future<bool> _streamPath(List<Waypoint> path) async {
    if (path.isEmpty) return false;
    if (!_isConnected) {
      _snack('Device not connected.');
      return false;
    }
    if (_isBusyState) {
      _snack('Device busy ($_deviceState). Wait for READY.');
      return false;
    }

    setState(() => _isStreaming = true);
    try {
      int cursor = 0;
      bool firstChunk = true;

      while (cursor < path.length) {
        // ── Build next chunk ─────────────────────────────────────────────
        final int chunkEnd = math.min(cursor + _streamChunkSize, path.length);
        final chunk = path.sublist(cursor, chunkEnd);

        // ── Send as G-code ───────────────────────────────────────────────
        final gcodeBody = _buildGcodeProgram(chunk, resetModal: firstChunk);
        firstChunk = false;

        bool sent = false;
        int retries = 0;
        while (!sent && retries < 5) {
          try {
            final res = await http
                .post(
                  Uri.parse('$_apiUrl/gcode'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'program': gcodeBody}),
                )
                .timeout(const Duration(seconds: 5));

            if (res.statusCode == 200) {
              sent = true;
            } else if (res.statusCode == 409) {
              // Queue full — wait and retry
              await Future<void>.delayed(const Duration(milliseconds: 300));
              retries++;
              await _fetchStatus();
            } else {
              _snack(
                  'Firmware rejected chunk (${res.statusCode}): ${res.body}');
              return false;
            }
          } on TimeoutException {
            retries++;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            _snack('Send error: $e');
            return false;
          }
        }
        if (!sent) {
          _snack('Could not send chunk after $retries retries.');
          return false;
        }

        cursor = chunkEnd;

        // ── If more data, wait for queue to drain enough ─────────────────
        if (cursor < path.length) {
          while (true) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            if (!mounted) return false;
            await _fetchStatus();
            if (_queueFree >= _streamRefillThreshold) break;
            // Safety: if device stopped unexpectedly
            if (!_isMoving && _deviceState == 'READY') break;
            if (_isBusyState) {
              _snack('Device entered unexpected busy state.');
              return false;
            }
          }
        }
      }

      // ── Wait for execution to complete ──────────────────────────────────
      while (_isMoving || _deviceState == 'MOVING') {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return false;
        await _fetchStatus();
      }

      return true;
    } finally {
      if (mounted) setState(() => _isStreaming = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GCODE BUILDER
  // ─────────────────────────────────────────────────────────────────────────
  /// Converts a list of waypoints into a G-code string.
  /// [resetModal] = true sends G90 + F header (first chunk only).
  String _buildGcodeProgram(List<Waypoint> path, {bool resetModal = true}) {
    final buf = StringBuffer();
    if (resetModal) {
      buf.writeln('G21');
      buf.writeln('G90');
    }

    int? lastFeed;
    for (final pt in path) {
      final speed = _clampFeed(pt.speed > 0 ? pt.speed : _masterFeedRate);
      if (lastFeed != speed) {
        buf.writeln('F$speed');
        lastFeed = speed;
      }
      buf.writeln('G1 X${pt.x} Y${pt.y} Z${pt.z}');
    }
    return buf.toString();
  }

  String _fmtG(double v) => v.toStringAsFixed(3);

  String _buildCircleGcode({bool includeFooter = false}) {
    final int size = _shapeSize.round().clamp(100, math.min(_limitX, _limitY));
    final int z = _shapeZ.clamp(0, _limitZ);
    final int speed = _clampFeed(_masterFeedRate);

    final double radius = size / 2.0;
    final double cx = radius + _shapeOffsetX;
    final double cy = radius + _shapeOffsetY;

    final double startX = cx + radius;
    final double startY = cy;
    final double midX = cx - radius;
    final double midY = cy;

    final double i1 = cx - startX;
    final double j1 = cy - startY;
    final double i2 = cx - midX;
    final double j2 = cy - midY;

    final buf = StringBuffer();
    buf.writeln('G21');
    buf.writeln('G90');
    buf.writeln('F$speed');
    buf.writeln('G1 X${_fmtG(startX)} Y${_fmtG(startY)} Z$z');
    final code = _circleClockwise ? 'G2' : 'G3';
    buf.writeln(
        '$code X${_fmtG(midX)} Y${_fmtG(midY)} Z$z I${_fmtG(i1)} J${_fmtG(j1)}');
    buf.writeln(
        '$code X${_fmtG(startX)} Y${_fmtG(startY)} Z$z I${_fmtG(i2)} J${_fmtG(j2)}');
    if (includeFooter) {
      final int cxHome = (_limitX / 2).round();
      final int cyHome = (_limitY / 2).round();
      buf.writeln('G0 X$cxHome Y$cyHome Z$z');
      buf.writeln('M5');
    }
    return buf.toString();
  }

  String _buildGcodeForCurrentShape({bool includeFooter = false}) {
    if (_shapeType == ShapeType.circle) {
      return _buildCircleGcode(includeFooter: includeFooter);
    }
    final gcode = _buildGcodeProgram(_shapePath(), resetModal: true);
    if (!includeFooter) return gcode;
    final int cxHome = (_limitX / 2).round();
    final int cyHome = (_limitY / 2).round();
    return '$gcode\nG0 X$cxHome Y$cyHome Z$_shapeZ\nM5\n';
  }

  String _safeJobFilename(String prefix) {
    final cleanPrefix = prefix
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final p = cleanPrefix.isEmpty ? 'job' : cleanPrefix;
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return '${p.substring(0, math.min(12, p.length))}_$stamp.gco';
  }

  String _presetProgram(List<PresetStep> steps, {bool includeFooter = true}) {
    final buf = StringBuffer()
      ..writeln('G21')
      ..writeln('G90');

    for (final step in steps) {
      final gcode = step.gcode.trim();
      if (gcode.isNotEmpty) {
        for (final raw in const LineSplitter().convert(gcode)) {
          final line = raw.trim();
          if (line.isEmpty) continue;
          final upper = line.toUpperCase();
          if (upper == 'G21' || upper == 'G90' || upper == 'M5') continue;
          if (upper.startsWith('G0 ') && includeFooter) {
            final homeX = (_limitX / 2).round().toString();
            final homeY = (_limitY / 2).round().toString();
            if (upper.contains('X$homeX') && upper.contains('Y$homeY')) {
              continue;
            }
          }
          buf.writeln(line);
        }
      } else {
        buf.write(_buildGcodeProgram(step.points, resetModal: false));
      }
    }

    if (includeFooter) {
      final int cxHome = (_limitX / 2).round();
      final int cyHome = (_limitY / 2).round();
      buf.writeln('G0 X$cxHome Y$cyHome Z$_shapeZ');
      buf.writeln('M5');
    }
    return buf.toString();
  }

  Future<bool> _uploadAndRunGcode(String gcode, String namePrefix) async {
    if (!_isConnected) {
      _snack('Device not connected.');
      return false;
    }
    if (_isBusyState || _isStreaming || _isUploading) {
      _snack('Device busy. Wait for READY.');
      return false;
    }

    setState(() => _isUploading = true);
    try {
      final filename = _safeJobFilename(namePrefix);
      final uri = Uri.parse('http://$_activeHost/upload');
      final req = http.MultipartRequest('POST', uri);
      req.files.add(http.MultipartFile.fromString(
        'file',
        gcode,
        filename: filename,
      ));
      final resp = await req.send();
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        _snack('Upload failed: ${resp.statusCode} $body');
        return false;
      }
      final runUri = Uri.http(_activeHost, '/run', {'file': filename});
      final runResp =
          await http.get(runUri).timeout(const Duration(seconds: 3));
      if (runResp.statusCode != 200) {
        _snack('Run failed: ${runResp.statusCode}');
        return false;
      }
      return true;
    } catch (e) {
      _snack('Upload error: $e');
      return false;
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DEVICE COMMANDS
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _homeCommand() async {
    if (_activeHost.isEmpty) {
      _snack('Set a valid host first.');
      return;
    }
    try {
      await http
          .get(Uri.parse('http://$_activeHost/homing'))
          .timeout(const Duration(seconds: 2));
      _fetchStatus();
    } catch (_) {}
  }

  Future<void> _stopCommand() async {
    if (_activeHost.isEmpty) {
      _snack('Set a valid host first.');
      return;
    }
    try {
      await http
          .get(Uri.parse('http://$_activeHost/stop'))
          .timeout(const Duration(seconds: 2));
      _fetchStatus();
    } catch (_) {}
  }

  Future<void> _setDcSpeed(int speed) async {
    if (_isSendingDcCommand || !_isConnected) return;
    setState(() => _isSendingDcCommand = true);
    try {
      final res = await http
          .post(
            Uri.parse('$_apiUrl/dc'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'speed': speed.clamp(-255, 255)}),
          )
          .timeout(const Duration(seconds: 2));
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() => _dcSpeed = speed.clamp(-255, 255));
      } else {
        _snack('DC command failed: ${res.body}');
      }
    } catch (e) {
      if (mounted) _snack('DC error: $e');
    } finally {
      if (mounted) setState(() => _isSendingDcCommand = false);
    }
  }

  Future<void> _setLimits() async {
    if (_activeHost.isEmpty) {
      _snack('Set a valid host first.');
      return;
    }
    final int max1 = int.tryParse(_limXCtrl.text) ?? _limitX;
    final int max2 = int.tryParse(_limYCtrl.text) ?? _limitY;
    final int max3 = int.tryParse(_limZCtrl.text) ?? _limitZ;
    final int speed1 = int.tryParse(_spdXCtrl.text) ?? _maxSpeed1;
    final int speed2 = int.tryParse(_spdYCtrl.text) ?? _maxSpeed2;
    final int speed3 = int.tryParse(_spdZCtrl.text) ?? _maxSpeed3;
    final double pathAccel = double.tryParse(_pathAccelCtrl.text) ?? _pathAccel;
    final double junctionDev =
        double.tryParse(_junctionDevCtrl.text) ?? _junctionDev;
    try {
      final res = await http
          .post(
            Uri.parse('$_apiUrl/limits'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'max1': max1,
              'max2': max2,
              'max3': max3,
              'speed1': speed1,
              'speed2': speed2,
              'speed3': speed3,
              'path_accel': pathAccel,
              'junction_dev': junctionDev,
            }),
          )
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Limits applied.');
        _fetchStatus();
      } else {
        _snack('Limit update failed: ${res.body}');
      }
    } catch (e) {
      if (mounted) _snack('Failed to set limits: $e');
    }
  }

  void _jog(String axis, int step) {
    int tx = _currentX, ty = _currentY, tz = _currentZ;
    if (axis == 'X') tx = (tx + step).clamp(0, _limitX);
    if (axis == 'Y') ty = (ty + step).clamp(0, _limitY);
    if (axis == 'Z') tz = (tz + step).clamp(0, _limitZ);
    _streamPath([Waypoint(x: tx, y: ty, z: tz, speed: _manualSpeed)]);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHAPE GENERATION
  // ─────────────────────────────────────────────────────────────────────────

  /// For a circle of radius r, compute the minimum segments so arc-error < 0.5 steps.
  /// arc_error = r × (1 − cos(π/N)) ≤ 0.5
  /// → N ≥ π / arccos(1 − 0.5/r)
  int _adaptiveCircleSegments(double radius) {
    if (radius < 1) return 72;
    final double minN =
        math.pi / math.acos(1.0 - _curveChordErrorSteps / radius);
    // User slider acts as a multiplier (quality), min 72 for smoothness
    final int adaptive = minN.ceil().clamp(72, 1000);
    // User's slider value scales quality: _circleSegments is 72–160 user quality
    final int quality = (_circleSegments / 72.0 * adaptive).round();
    return quality.clamp(adaptive, 1600);
  }

  List<Waypoint> _dedupePath(List<Waypoint> path) {
    if (path.length < 2) return path;
    final out = <Waypoint>[path.first];
    for (int i = 1; i < path.length; i++) {
      final p = path[i];
      final last = out.last;
      if (p.x != last.x || p.y != last.y || p.z != last.z) out.add(p);
    }
    return out;
  }

  List<Waypoint> _resamplePathByMaxStep(List<Waypoint> path, double maxStep) {
    if (path.length < 2 || maxStep <= 0) return path;
    final out = <Waypoint>[path.first];

    for (int i = 1; i < path.length; i++) {
      final a = out.last;
      final b = path[i];
      final dx = (b.x - a.x).toDouble();
      final dy = (b.y - a.y).toDouble();
      final dz = (b.z - a.z).toDouble();
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist <= maxStep) {
        out.add(b);
        continue;
      }
      final steps = (dist / maxStep).ceil();
      for (int s = 1; s <= steps; s++) {
        final t = s / steps;
        out.add(Waypoint(
          x: (a.x + dx * t).round().clamp(0, _limitX),
          y: (a.y + dy * t).round().clamp(0, _limitY),
          z: (a.z + dz * t).round().clamp(0, _limitZ),
          speed: a.speed,
        ));
      }
    }

    return _dedupePath(out);
  }

  void _addPointIfChanged(
      List<Waypoint> out, double x, double y, int z, int speed) {
    final next = Waypoint(
      x: x.round().clamp(0, _limitX),
      y: y.round().clamp(0, _limitY),
      z: z,
      speed: speed,
    );
    if (out.isEmpty ||
        out.last.x != next.x ||
        out.last.y != next.y ||
        out.last.z != next.z) {
      out.add(next);
    }
  }

  List<Waypoint> _shapeBasePath() {
    final int size = _shapeSize.round().clamp(100, math.min(_limitX, _limitY));
    final int z = _shapeZ.clamp(0, _limitZ);
    final int speed = _clampFeed(_masterFeedRate);

    switch (_shapeType) {
      // ── Line ─────────────────────────────────────────────────────────────
      case ShapeType.line:
        return [
          Waypoint(x: 0, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: 0, z: z, speed: speed),
        ];

      // ── Square ───────────────────────────────────────────────────────────
      case ShapeType.square:
        return [
          Waypoint(x: 0, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: size, z: z, speed: speed),
          Waypoint(x: 0, y: size, z: z, speed: speed),
          Waypoint(x: 0, y: 0, z: z, speed: speed),
        ];

      // ── Triangle ─────────────────────────────────────────────────────────
      case ShapeType.triangle:
        return [
          Waypoint(x: 0, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: 0, z: z, speed: speed),
          Waypoint(x: size ~/ 2, y: size, z: z, speed: speed),
          Waypoint(x: 0, y: 0, z: z, speed: speed),
        ];

      // ── Circle (FIX: adaptive high-resolution segments) ──────────────────
      case ShapeType.circle:
        {
          final double radius = size / 2.0;
          final double cx = radius, cy = radius;
          final int segs = _adaptiveCircleSegments(radius);
          final pts = <Waypoint>[];

          for (int i = 0; i <= segs; i++) {
            final angle = (2.0 * math.pi * i) / segs;
            _addPointIfChanged(
              pts,
              cx + radius * math.cos(angle),
              cy + radius * math.sin(angle),
              z,
              speed,
            );
          }
          return pts;
        }

      // ── Spiral ───────────────────────────────────────────────────────────
      case ShapeType.spiral:
        {
          final double maxR = size / 2.0;
          final double cx = maxR, cy = maxR;
          // Adaptive: same arc-error criterion per turn
          final int perTurn = _adaptiveCircleSegments(maxR);
          final int samples = (perTurn * _spiralTurns).clamp(72, 2000);
          final pts = <Waypoint>[];
          for (int i = 0; i <= samples; i++) {
            final double t = i / samples;
            final double a = 2.0 * math.pi * _spiralTurns * t;
            final double r = maxR * t;
            _addPointIfChanged(
                pts, cx + r * math.cos(a), cy + r * math.sin(a), z, speed);
          }
          return pts;
        }

      // ── Spinge (sine wave) ───────────────────────────────────────────────
      case ShapeType.spinge:
        {
          final double width = size.toDouble();
          final double amp = size / 4.0;
          final double midY = size / 2.0;
          // Higher resolution for smooth waves
          final int samples =
              (_adaptiveCircleSegments(size / 2.0) * _spingeWaves)
                  .clamp(72, 2000);
          final pts = <Waypoint>[];
          for (int i = 0; i <= samples; i++) {
            final double t = i / samples;
            _addPointIfChanged(
              pts,
              width * t,
              midY + amp * math.sin(2.0 * math.pi * _spingeWaves * t),
              z,
              speed,
            );
          }
          return pts;
        }

      // ── Custom ───────────────────────────────────────────────────────────
      case ShapeType.custom:
        {
          final int stride = _customDrawDensity.clamp(1, 20);
          final sampled = <Waypoint>[];
          for (int i = 0; i < _customPoints.length; i += stride) {
            sampled.add(_customPoints[i]);
          }
          if (sampled.isEmpty || sampled.last != _customPoints.last) {
            sampled.add(_customPoints.last);
          }
          final mapped = sampled
              .map((p) => Waypoint(
                    x: ((p.x / _customTemplateMax) * size)
                        .round()
                        .clamp(0, _limitX),
                    y: ((p.y / _customTemplateMax) * size)
                        .round()
                        .clamp(0, _limitY),
                    z: z,
                    speed: speed,
                  ))
              .toList();
          final deduped = _dedupePath(mapped);
          final double maxStep =
              (size / (30.0 * (21 - _customDrawDensity))).clamp(2.0, 120.0);
          return _resamplePathByMaxStep(deduped, maxStep);
        }
    }
  }

  List<Waypoint> _shapePath() {
    final base = _shapeBasePath();
    if (base.isEmpty) return base;
    final shifted = base
        .map((p) => Waypoint(
              x: (p.x + _shapeOffsetX).clamp(0, _limitX),
              y: (p.y + _shapeOffsetY).clamp(0, _limitY),
              z: p.z,
              speed: p.speed,
            ))
        .toList();

    final deduped = _dedupePath(shifted);
    if (_shapeType == ShapeType.circle ||
        _shapeType == ShapeType.spiral ||
        _shapeType == ShapeType.spinge) {
      final double maxStep = (_shapeSize / 100.0).clamp(2.0, 80.0);
      return _resamplePathByMaxStep(deduped, maxStep);
    }

    return deduped;
  }

  void _moveShapeByCanvasDelta(double dxUnits, double dyUnits) {
    final base = _shapeBasePath();
    if (base.isEmpty) return;
    final minX = base.map((p) => p.x).reduce(math.min);
    final maxX = base.map((p) => p.x).reduce(math.max);
    final minY = base.map((p) => p.y).reduce(math.min);
    final maxY = base.map((p) => p.y).reduce(math.max);
    setState(() {
      _shapeOffsetX =
          (_shapeOffsetX + dxUnits.round()).clamp(-minX, _limitX - maxX);
      _shapeOffsetY =
          (_shapeOffsetY + dyUnits.round()).clamp(-minY, _limitY - maxY);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // EXECUTE / PRESET
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _executeCurrentShape() async {
    if (_isStreaming) {
      _snack('Already streaming a path.');
      return;
    }
    final gcode = _buildGcodeForCurrentShape(includeFooter: true);
    if (gcode.trim().isEmpty) return;
    final ok = await _uploadAndRunGcode(gcode, _shapeType.name);
    if (mounted && ok) _snack('Uploaded and running.');
  }

  Future<void> _exportCurrentGcode() async {
    final gcode = _buildGcodeForCurrentShape(includeFooter: true);
    if (gcode.trim().isEmpty) {
      _snack('No path to export.');
      return;
    }
    try {
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final name = 'dosamatic_${_shapeType.name}_$ts.gcode';
      if (Platform.isAndroid) {
        final saved = await _saveFileChannel.invokeMethod<String>(
          'saveGcode',
          {'fileName': name, 'content': gcode},
        );
        if (!mounted) return;
        if (saved == null || saved.isEmpty) {
          _snack('Export canceled.');
        } else {
          _snack('G-code saved: $saved');
        }
        return;
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save G-code',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: const ['gcode'],
      );
      if (path == null || path.isEmpty) {
        if (mounted) _snack('Export canceled.');
        return;
      }
      final file = File(path);
      await file.writeAsString(gcode);
      if (mounted) _snack('G-code saved: ${file.path}');
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'CANCELED') {
        _snack('Export canceled.');
      } else {
        _snack('Failed to save G-code: ${e.message ?? e.code}');
      }
    } catch (e) {
      if (mounted) _snack('Failed to save G-code: $e');
    }
  }

  Future<void> _refreshDeviceFiles() async {
    if (_activeHost.isEmpty || _isLoadingFiles) return;
    setState(() {
      _isLoadingFiles = true;
      _storageError = '';
    });
    try {
      final res = await http
          .get(Uri.parse('$_apiUrl/files'))
          .timeout(const Duration(seconds: 4));
      if (!mounted) return;
      final body =
          res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
      if (res.statusCode == 200 && body is Map<String, dynamic>) {
        final files = (body['files'] as List<dynamic>? ?? [])
            .map((f) => DeviceGcodeFile.fromJson(f as Map<String, dynamic>))
            .where((f) => f.name.isNotEmpty)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        setState(() {
          _deviceFiles = files;
          _storageMounted = body['mounted'] == true;
          _storageTotal = _asInt(body['total'], 0);
          _storageUsed = _asInt(body['used'], 0);
        });
      } else {
        setState(() {
          _deviceFiles = [];
          _storageError = res.body.isEmpty ? 'List failed' : res.body;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _deviceFiles = [];
          _storageError = 'Storage list error: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _isLoadingFiles = false);
    }
  }

  Future<void> _runDeviceFile(String name) async {
    if (_isBusyState || _isStreaming || _isUploading) {
      _snack('Device busy. Wait for READY.');
      return;
    }
    try {
      final res = await http
          .get(Uri.http(_activeHost, '/run', {'file': name}))
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Running $name');
        _fetchStatus();
      } else {
        _snack('Run failed: ${res.body}');
      }
    } catch (e) {
      if (mounted) _snack('Run error: $e');
    }
  }

  Future<void> _deleteDeviceFile(String name) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_apiUrl/file/delete'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'name': name}),
          )
          .timeout(const Duration(seconds: 4));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Deleted $name');
        _refreshDeviceFiles();
      } else {
        _snack('Delete failed: ${res.body}');
      }
    } catch (e) {
      if (mounted) _snack('Delete error: $e');
    }
  }

  Future<void> _renameDeviceFile(String from) async {
    final ctrl = TextEditingController(text: from.replaceFirst('/', ''));
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename G-code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'File name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || next.isEmpty) return;

    try {
      final res = await http
          .post(
            Uri.parse('$_apiUrl/file/rename'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'from': from, 'to': next}),
          )
          .timeout(const Duration(seconds: 4));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Renamed.');
        _refreshDeviceFiles();
      } else {
        _snack('Rename failed: ${res.body}');
      }
    } catch (e) {
      if (mounted) _snack('Rename error: $e');
    }
  }

  Future<void> _formatDeviceStorage() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Repair ESP32 storage?'),
        content: const Text(
            'This formats LittleFS and deletes stored G-code files.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Format'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isFormattingStorage = true);
    try {
      final res = await http
          .post(Uri.parse('$_apiUrl/storage/format'))
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Storage formatted.');
        _refreshDeviceFiles();
      } else {
        _snack('Format failed: ${res.body}');
      }
    } catch (e) {
      if (mounted) _snack('Format error: $e');
    } finally {
      if (mounted) setState(() => _isFormattingStorage = false);
    }
  }

  void _addCurrentShapeToDraft() {
    final path = _shapePath();
    if (path.isEmpty) return;
    final step = PresetStep(
      label: _shapeLabel(_shapeType),
      feed: _masterFeedRate,
      points: path,
      gcode: _buildGcodeForCurrentShape(includeFooter: false),
    );
    setState(() => _draftPresetSteps = [..._draftPresetSteps, step]);
    _snack('Added step ${_draftPresetSteps.length} to preset draft.');
  }

  Future<void> _executePreset(PresetModel preset) async {
    if (_isBusyState) {
      _snack('Device busy ($_deviceState). Wait for READY.');
      return;
    }
    if (_isStreaming || _isUploading) {
      _snack('Already running.');
      return;
    }
    if (preset.steps.isEmpty) return;
    final gcode = _presetProgram(preset.steps);
    final ok = await _uploadAndRunGcode(gcode, preset.name);
    if (mounted && ok) _snack('Preset "${preset.name}" running.');
  }

  Future<void> _saveDraftAsPreset() async {
    final name = _presetNameCtrl.text.trim();
    if (name.isEmpty || _draftPresetSteps.isEmpty) {
      _snack('Provide a name and at least one step.');
      return;
    }
    final preset = PresetModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      steps: _draftPresetSteps,
    );
    setState(() {
      _presets = [..._presets, preset];
      _draftPresetSteps = [];
      _presetNameCtrl.clear();
    });
    await _savePresets();
    if (mounted) _snack('Preset saved.');
  }

  Future<void> _deletePreset(String id) async {
    setState(() => _presets = _presets.where((p) => p.id != id).toList());
    await _savePresets();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CUSTOM DRAW
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _openFullScreenDraw() async {
    if (_isImportingDraw) return;
    final points = await Navigator.of(context).push<List<Offset>>(
      MaterialPageRoute(
          builder: (_) => const FullScreenDrawPage(initialPoints: [])),
    );
    if (!mounted || points == null || points.length < 2) return;

    setState(() => _isImportingDraw = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (!mounted) return;
      final simplified = _simplifyRawPoints(
          points.length > _maxImportedRawPoints
              ? _downsampleOffsets(points, _maxImportedRawPoints)
              : points);
      final mapped = _mapDrawnPointsToTemplate(simplified);
      if (mapped.length < 2) return;
      setState(() {
        _customPoints
          ..clear()
          ..addAll(mapped);
        _shapeType = ShapeType.custom;
        _shapeSize =
            _shapeSize.clamp(300, math.min(_limitX, _limitY).toDouble());
        _shapeOffsetX = 0;
        _shapeOffsetY = 0;
      });
    } finally {
      if (mounted) setState(() => _isImportingDraw = false);
    }
  }

  List<Offset> _downsampleOffsets(List<Offset> pts, int max) {
    if (pts.length <= max) return pts;
    final stride = (pts.length / max).ceil().clamp(1, 1000);
    final out = <Offset>[];
    for (int i = 0; i < pts.length; i += stride) {
      out.add(pts[i]);
    }
    if (out.last != pts.last) out.add(pts.last);
    return out;
  }

  List<Offset> _simplifyRawPoints(List<Offset> pts) {
    if (pts.isEmpty) return [];
    final minDist = pts.length > 3000 ? 3.0 : 2.0;
    final out = <Offset>[pts.first];
    var last = pts.first;
    for (int i = 1; i < pts.length; i++) {
      if ((pts[i] - last).distance >= minDist) {
        out.add(pts[i]);
        last = pts[i];
      }
    }
    if (out.last != pts.last) out.add(pts.last);
    if (out.length <= 2500) return out;
    return _downsampleOffsets(out, 2500);
  }

  List<Waypoint> _mapDrawnPointsToTemplate(List<Offset> pts) {
    if (pts.length < 2) return [];
    double minX = pts.first.dx, minY = pts.first.dy;
    double maxX = minX, maxY = minY;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    final spanX = math.max(1.0, maxX - minX);
    final spanY = math.max(1.0, maxY - minY);
    return pts
        .map((p) => Waypoint(
              x: (((p.dx - minX) / spanX) * _customTemplateMax)
                  .round()
                  .clamp(0, _customTemplateMax),
              y: (((p.dy - minY) / spanY) * _customTemplateMax)
                  .round()
                  .clamp(0, _customTemplateMax),
              z: 0,
              speed: 0,
            ))
        .toList();
  }

  void _updateCustomPoint(int index, {int? x, int? y, int? z}) {
    if (index < 0 || index >= _customPoints.length) return;
    final old = _customPoints[index];
    setState(() {
      _customPoints[index] = Waypoint(
        x: (x ?? old.x).clamp(0, _customTemplateMax),
        y: (y ?? old.y).clamp(0, _customTemplateMax),
        z: (z ?? old.z).clamp(0, _limitZ),
      );
    });
  }

  void _addCustomPoint() {
    setState(() => _customPoints.add(Waypoint(
        x: _customTemplateMax ~/ 2, y: _customTemplateMax ~/ 2, z: 0)));
  }

  void _removeCustomPoint(int index) {
    if (_customPoints.length <= 2) return;
    setState(() => _customPoints.removeAt(index));
  }

  String _shapeLabel(ShapeType t) {
    switch (t) {
      case ShapeType.line:
        return 'Line';
      case ShapeType.square:
        return 'Square';
      case ShapeType.triangle:
        return 'Triangle';
      case ShapeType.circle:
        return 'Circle';
      case ShapeType.spiral:
        return 'Spiral';
      case ShapeType.spinge:
        return 'Spinge';
      case ShapeType.custom:
        return 'Custom';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — HOME PAGE
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildHomePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('State: $_deviceState',
                        style: Theme.of(context).textTheme.titleLarge),
                    if (_isStreaming)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _posWidget('X', _currentX, _limitX),
                    _posWidget('Y', _currentY, _limitY),
                    _posWidget('Z', _currentZ, _limitZ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Queue: $_queueDepth used  ·  $_queueFree free',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),

          // E-STOP / HOME
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red, foregroundColor: Colors.white),
                onPressed: _stopCommand,
                icon: const Icon(Icons.warning),
                label: const Text('E-STOP'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _homeCommand,
                icon: const Icon(Icons.home),
                label: const Text('HOME'),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // ── Jog controls ───────────────────────────────────────────────
          Text('Manual Jog', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Step:'),
            const SizedBox(width: 10),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _jogStepCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    isDense: true, border: OutlineInputBorder()),
                onChanged: (v) {
                  final p = int.tryParse(v.trim());
                  if (p != null && p > 0) {
                    setState(() => _jogStep = p.clamp(1, 50000));
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            const Text('Speed:'),
            const SizedBox(width: 10),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _manualSpdCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    isDense: true, border: OutlineInputBorder()),
                onChanged: (v) {
                  final p = int.tryParse(v.trim());
                  if (p != null && p > 0) {
                    setState(() => _manualSpeed = p.clamp(100, 10000));
                  }
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildJogButtons('X'),
              _buildJogButtons('Y'),
              _buildJogButtons('Z')
            ],
          ),
          const SizedBox(height: 16),

          // ── DC motor ──────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('DC Motor',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('Current speed: $_dcSpeed'),
                  Slider(
                    min: 0,
                    max: 255,
                    divisions: 255,
                    value: _dcCommandSpeed.toDouble(),
                    onChanged: (v) => setState(() {
                      _dcCommandSpeed = v.round();
                      _dcSpeedCtrl.text = _dcCommandSpeed.toString();
                    }),
                  ),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSendingDcCommand
                            ? null
                            : () => _setDcSpeed(-_dcCommandSpeed),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Backward'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed:
                            _isSendingDcCommand ? null : () => _setDcSpeed(0),
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSendingDcCommand
                            ? null
                            : () => _setDcSpeed(_dcCommandSpeed),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Forward'),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — SHAPES PAGE
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildShapesPage() {
    final path = _shapePath();
    final ptCount = path.length;
    final int radius = (_shapeSize / 2).round();
    final int adaptSegs = _shapeType == ShapeType.circle
        ? _adaptiveCircleSegments(radius.toDouble())
        : 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Preview canvas
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                height: 260,
                child: ShapePreview(
                  points: path,
                  maxX: _maxCanvasX,
                  maxY: _maxCanvasY,
                  onPanInCanvasUnits: _moveShapeByCanvasDelta,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Offset X=$_shapeOffsetX  Y=$_shapeOffsetY  •  Waypoints: $ptCount'
            '${_shapeType == ShapeType.circle ? "  (adaptive: $adaptSegs segs)" : ""}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.speed, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Master Speed: $_masterFeedRate steps/s',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ]),
                  Slider(
                    min: _minFeedStepsPerSec.toDouble(),
                    max: _maxFeedStepsPerSec.toDouble(),
                    divisions: 119,
                    value: _masterFeedRate
                        .clamp(_minFeedStepsPerSec, _maxFeedStepsPerSec)
                        .toDouble(),
                    label: '$_masterFeedRate steps/s',
                    onChanged: (v) => setState(() {
                      _masterFeedRate = _clampFeed(v.round());
                    }),
                  ),
                  Text(
                    'One feed rate for all generated shapes and preset steps.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Shape type picker
          DropdownButtonFormField<ShapeType>(
            value: _shapeType,
            decoration: const InputDecoration(labelText: 'Shape Type'),
            items: ShapeType.values
                .map((t) =>
                    DropdownMenuItem(value: t, child: Text(_shapeLabel(t))))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _shapeType = v);
            },
          ),
          const SizedBox(height: 12),

          // Size
          Text('Size: ${_shapeSize.round()} steps'),
          Slider(
            min: 100,
            max: math.max(500.0, math.min(_limitX, _limitY).toDouble()),
            value: _shapeSize.clamp(
                100.0, math.max(500.0, math.min(_limitX, _limitY).toDouble())),
            onChanged: (v) => setState(() => _shapeSize = v),
          ),

          // Z
          Text('Z: $_shapeZ'),
          Slider(
            min: 0,
            max: _limitZ.toDouble(),
            value: _shapeZ.toDouble().clamp(0.0, _limitZ.toDouble()),
            onChanged: (v) => setState(() => _shapeZ = v.round()),
          ),

          // ── Shape-specific controls ─────────────────────────────────────
          if (_shapeType == ShapeType.circle) ...[
            Text('Circle quality (min segments: $adaptSegs adaptive):'
                ' ×${(_circleSegments / 72.0).toStringAsFixed(2)}'),
            Slider(
              min: 72,
              max: 160,
              divisions: 88,
              value: _circleSegments.toDouble(),
              onChanged: (v) => setState(() => _circleSegments = v.round()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _circleClockwise,
              title: const Text('Clockwise arc (G2)'),
              subtitle: const Text('Toggle for CCW (G3)'),
              onChanged: (v) => setState(() => _circleClockwise = v),
            ),
          ],

          if (_shapeType == ShapeType.spiral) ...[
            Text('Turns: $_spiralTurns'),
            Slider(
                min: 2,
                max: 12,
                divisions: 10,
                value: _spiralTurns.toDouble(),
                onChanged: (v) => setState(() => _spiralTurns = v.round())),
            Text('Resolution per turn: $_circleSegments'),
            Slider(
                min: 36,
                max: 160,
                divisions: 124,
                value: _circleSegments.toDouble().clamp(36, 160),
                onChanged: (v) => setState(() => _circleSegments = v.round())),
          ],

          if (_shapeType == ShapeType.spinge) ...[
            Text('Waves: $_spingeWaves'),
            Slider(
                min: 1,
                max: 12,
                divisions: 11,
                value: _spingeWaves.toDouble(),
                onChanged: (v) => setState(() => _spingeWaves = v.round())),
            Text('Points per wave: $_circleSegments'),
            Slider(
                min: 36,
                max: 160,
                divisions: 124,
                value: _circleSegments.toDouble().clamp(36, 160),
                onChanged: (v) => setState(() => _circleSegments = v.round())),
          ],

          if (_shapeType == ShapeType.custom) ...[
            Text('Density: $_customDrawDensity (1=highest, 20=lowest)'),
            Slider(
                min: 1,
                max: 20,
                divisions: 19,
                value: _customDrawDensity.toDouble(),
                onChanged: (v) =>
                    setState(() => _customDrawDensity = v.round())),
            if (_isImportingDraw)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Importing drawing...'),
                ]),
              )
            else
              ElevatedButton.icon(
                onPressed: _openFullScreenDraw,
                icon: const Icon(Icons.open_in_full),
                label: const Text('Open Full Screen Draw'),
              ),
            const SizedBox(height: 8),
            const Text('Template points:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (int i = 0; i < _customPoints.length; i++)
              _CustomPointEditor(
                index: i,
                point: _customPoints[i],
                limitX: _customTemplateMax,
                limitY: _customTemplateMax,
                limitZ: _limitZ,
                onChanged: (x, y, z) => _updateCustomPoint(i, x: x, y: y, z: z),
                onRemove: () => _removeCustomPoint(i),
              ),
            OutlinedButton.icon(
              onPressed: _addCustomPoint,
              icon: const Icon(Icons.add),
              label: const Text('Add Point'),
            ),
          ],

          const SizedBox(height: 16),
          // Execute / Add to draft
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: (_isStreaming || _isUploading)
                    ? null
                    : _executeCurrentShape,
                icon: (_isStreaming || _isUploading)
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow),
                label: Text((_isStreaming || _isUploading)
                    ? 'Uploading…'
                    : 'Upload & Run'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _addCurrentShapeToDraft,
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add To Draft'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _exportCurrentGcode,
            icon: const Icon(Icons.download),
            label: const Text('Export G-code'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — PRESETS PAGE
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildPresetsPage() {
    final draftTotal =
        _draftPresetSteps.fold<int>(0, (s, step) => s + step.pointCount);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Preset Draft',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('Steps: ${_draftPresetSteps.length}  •  '
                      'Total waypoints: $draftTotal  '
                      '(streaming — no waypoint limit)'),
                  const SizedBox(height: 8),
                  for (int i = 0; i < _draftPresetSteps.length; i++)
                    ListTile(
                      dense: true,
                      title:
                          Text('Step ${i + 1}: ${_draftPresetSteps[i].label}'),
                      subtitle: Text(
                          '${_draftPresetSteps[i].pointCount} waypoints  •  F${_draftPresetSteps[i].feed}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            setState(() => _draftPresetSteps.removeAt(i)),
                      ),
                    ),
                  TextField(
                    controller: _presetNameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Preset name', hintText: 'My Sequence'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _saveDraftAsPreset,
                    icon: const Icon(Icons.save),
                    label: const Text('Save Draft as Preset'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Saved Presets', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_presets.isEmpty)
            const Text('No presets saved yet.')
          else
            for (final preset in _presets)
              Card(
                child: ListTile(
                  title: Text(preset.name),
                  subtitle: Text(
                    '${preset.steps.length} steps  •  '
                    '${preset.steps.fold<int>(0, (s, step) => s + step.pointCount)} total pts',
                  ),
                  trailing: Wrap(spacing: 4, children: [
                    IconButton(
                      icon: (_isStreaming || _isUploading)
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow),
                      onPressed: (_isStreaming || _isUploading)
                          ? null
                          : () => _executePreset(preset),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deletePreset(preset.id),
                    ),
                  ]),
                ),
              ),
        ],
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Widget _buildFilesPage() {
    final usedText = _storageTotal > 0
        ? '${_fmtBytes(_storageUsed)} / ${_fmtBytes(_storageTotal)}'
        : 'Unknown capacity';

    return RefreshIndicator(
      onRefresh: _refreshDeviceFiles,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(
                      _storageMounted ? Icons.sd_storage : Icons.error_outline,
                      color: _storageMounted ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _storageMounted
                            ? 'ESP32 G-code Storage'
                            : 'Storage unavailable',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _isLoadingFiles ? null : _refreshDeviceFiles,
                      icon: _isLoadingFiles
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(usedText),
                  if (_storageError.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_storageError,
                        style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed:
                        _isFormattingStorage ? null : _formatDeviceStorage,
                    icon: _isFormattingStorage
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.build),
                    label: const Text('Repair / Format Storage'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_deviceFiles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No G-code files on ESP32.'),
            )
          else
            for (final file in _deviceFiles)
              Card(
                child: ListTile(
                  title: Text(file.name),
                  subtitle: Text(_fmtBytes(file.size)),
                  trailing: Wrap(spacing: 2, children: [
                    IconButton(
                      tooltip: 'Run',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: (_isStreaming || _isUploading)
                          ? null
                          : () => _runDeviceFile(file.name),
                    ),
                    IconButton(
                      tooltip: 'Rename',
                      icon: const Icon(Icons.drive_file_rename_outline),
                      onPressed: () => _renameDeviceFile(file.name),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteDeviceFile(file.name),
                    ),
                  ]),
                ),
              ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — SETTINGS DRAWER
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildSettingsDrawer() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Connection & Limits',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useMdns,
              title: const Text('Use mDNS (.local)'),
              subtitle: const Text('Host: dosamatic.local'),
              onChanged: (v) => setState(() => _useMdns = v),
            ),
            TextField(
              controller: _hostCtrl,
              enabled: !_useMdns,
              decoration: const InputDecoration(
                  labelText: 'Manual IP / Host', hintText: '192.168.1.100'),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _saveConnectionSettings,
              icon: const Icon(Icons.wifi),
              label: const Text('Apply Connection'),
            ),
            const Divider(height: 28),
            TextField(
                controller: _limXCtrl,
                focusNode: _limXFocus,
                decoration: const InputDecoration(labelText: 'Max limit X'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: _limYCtrl,
                focusNode: _limYFocus,
                decoration: const InputDecoration(labelText: 'Max limit Y'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: _limZCtrl,
                focusNode: _limZFocus,
                decoration: const InputDecoration(labelText: 'Max limit Z'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 12),
            TextField(
                controller: _spdXCtrl,
                focusNode: _spdXFocus,
                decoration:
                    const InputDecoration(labelText: 'Max speed X (steps/s)'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: _spdYCtrl,
                focusNode: _spdYFocus,
                decoration:
                    const InputDecoration(labelText: 'Max speed Y (steps/s)'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: _spdZCtrl,
                focusNode: _spdZFocus,
                decoration:
                    const InputDecoration(labelText: 'Max speed Z (steps/s)'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 12),
            TextField(
                controller: _pathAccelCtrl,
                focusNode: _pathAccelFocus,
                decoration:
                    const InputDecoration(labelText: 'Path accel (steps/s²)'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: _junctionDevCtrl,
                focusNode: _junctionDevFocus,
                decoration:
                    const InputDecoration(labelText: 'Junction dev (steps)'),
                keyboardType: TextInputType.number),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _setLimits,
              icon: const Icon(Icons.settings),
              label: const Text('Push Limits to ESP32'),
            ),
            const SizedBox(height: 16),
            Text('API endpoint: ${_apiUrl.isEmpty ? "(not set)" : _apiUrl}',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ROOT BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildHomePage(),
      _buildShapesPage(),
      _buildPresetsPage(),
      _buildFilesPage(),
    ];
    final wifiColor = _isConnected ? Colors.green : Colors.red;

    return Scaffold(
      drawer: _buildSettingsDrawer(),
      appBar: AppBar(
        title: const Text('Dosamatic Controller'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_isStreaming || _isUploading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          Icon(Icons.wifi, color: wifiColor),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _fetchStatus,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(index: _selectedTab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (i) {
          setState(() => _selectedTab = i);
          if (i == 3) _refreshDeviceFiles();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.polyline), label: 'Shapes'),
          NavigationDestination(
              icon: Icon(Icons.playlist_play), label: 'Presets'),
          NavigationDestination(icon: Icon(Icons.folder), label: 'Files'),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHARED WIDGETS
  // ─────────────────────────────────────────────────────────────────────────
  Widget _posWidget(String label, int pos, int max) => Column(
        children: [
          Text(label,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text('$pos',
              style: const TextStyle(fontSize: 18, color: Colors.blue)),
          Text('/$max',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      );

  Widget _buildJogButtons(String axis) => Column(
        children: [
          IconButton(
              icon: const Icon(Icons.arrow_drop_up, size: 36),
              onPressed: () => _jog(axis, _jogStep)),
          Text(axis,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          IconButton(
              icon: const Icon(Icons.arrow_drop_down, size: 36),
              onPressed: () => _jog(axis, -_jogStep)),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// CUSTOM POINT EDITOR
// ─────────────────────────────────────────────────────────────────────────────
class _CustomPointEditor extends StatelessWidget {
  final int index;
  final Waypoint point;
  final int limitX, limitY, limitZ;
  final void Function(int x, int y, int z) onChanged;
  final VoidCallback onRemove;

  const _CustomPointEditor({
    required this.index,
    required this.point,
    required this.limitX,
    required this.limitY,
    required this.limitZ,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          Row(children: [
            Text('P${index + 1}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: 20)),
          ]),
          Row(children: [
            Expanded(
                child: TextFormField(
              key: ValueKey('x-$index-${point.x}'),
              initialValue: point.x.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'X', isDense: true),
              onFieldSubmitted: (v) => onChanged(
                  (int.tryParse(v) ?? point.x).clamp(0, limitX),
                  point.y,
                  point.z),
            )),
            const SizedBox(width: 6),
            Expanded(
                child: TextFormField(
              key: ValueKey('y-$index-${point.y}'),
              initialValue: point.y.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Y', isDense: true),
              onFieldSubmitted: (v) => onChanged(point.x,
                  (int.tryParse(v) ?? point.y).clamp(0, limitY), point.z),
            )),
            const SizedBox(width: 6),
            Expanded(
                child: TextFormField(
              key: ValueKey('z-$index-${point.z}'),
              initialValue: point.z.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Z', isDense: true),
              onFieldSubmitted: (v) => onChanged(point.x, point.y,
                  (int.tryParse(v) ?? point.z).clamp(0, limitZ)),
            )),
          ]),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHAPE PREVIEW WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class ShapePreview extends StatelessWidget {
  final List<Waypoint> points;
  final int maxX, maxY;
  final void Function(double dxUnits, double dyUnits) onPanInCanvasUnits;

  const ShapePreview({
    super.key,
    required this.points,
    required this.maxX,
    required this.maxY,
    required this.onPanInCanvasUnits,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final w = math.max(1.0, constraints.maxWidth);
      final h = math.max(1.0, constraints.maxHeight);
      final plotRect = _computePlotRect(Size(w, h), maxX, maxY);
      return GestureDetector(
        onPanUpdate: (d) => onPanInCanvasUnits(
          (d.delta.dx / math.max(1.0, plotRect.width)) * math.max(1, maxX),
          (d.delta.dy / math.max(1.0, plotRect.height)) * math.max(1, maxY),
        ),
        child: CustomPaint(
          painter: _ShapePainter(points: points, maxX: maxX, maxY: maxY),
          child: const SizedBox.expand(),
        ),
      );
    });
  }
}

class _ShapePainter extends CustomPainter {
  final List<Waypoint> points;
  final int maxX, maxY;
  _ShapePainter({required this.points, required this.maxX, required this.maxY});

  @override
  void paint(Canvas canvas, Size size) {
    final drawRect = _computePlotRect(size, maxX, maxY);
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFF8FAFB));
    canvas.drawRect(drawRect, Paint()..color = const Color(0xFFF0F3F4));

    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 0.5;
    for (int i = 0; i <= 10; i++) {
      final dx = drawRect.left + drawRect.width * i / 10;
      final dy = drawRect.top + drawRect.height * i / 10;
      canvas.drawLine(
          Offset(dx, drawRect.top), Offset(dx, drawRect.bottom), gridPaint);
      canvas.drawLine(
          Offset(drawRect.left, dy), Offset(drawRect.right, dy), gridPaint);
    }
    canvas.drawRect(
        drawRect,
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke);

    if (points.length < 2) return;

    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final px =
          drawRect.left + (points[i].x / math.max(1, maxX)) * drawRect.width;
      final py =
          drawRect.top + (points[i].y / math.max(1, maxY)) * drawRect.height;
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.teal
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke);

    // Draw waypoints (only if few enough — skip for large circles)
    if (points.length <= 200) {
      final ptPaint = Paint()..color = Colors.deepOrange;
      for (final p in points) {
        final px = drawRect.left + (p.x / math.max(1, maxX)) * drawRect.width;
        final py = drawRect.top + (p.y / math.max(1, maxY)) * drawRect.height;
        canvas.drawCircle(Offset(px, py), 2.5, ptPaint);
      }
    }

    // Labels
    final tp = TextPainter(
      text: const TextSpan(
          text: 'Origin (0,0)',
          style: TextStyle(fontSize: 10, color: Colors.black87)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(drawRect.left + 2, drawRect.top - 14));

    final xLabel = TextPainter(
      text: TextSpan(
          text: 'X max: $maxX',
          style: const TextStyle(fontSize: 10, color: Colors.black87)),
      textDirection: TextDirection.ltr,
    )..layout();
    xLabel.paint(
        canvas, Offset(drawRect.right - xLabel.width, drawRect.top - 14));
  }

  @override
  bool shouldRepaint(covariant _ShapePainter old) =>
      old.points != points || old.maxX != maxX || old.maxY != maxY;
}

Rect _computePlotRect(Size size, int maxX, int maxY) {
  const double padding = 24;
  final aW = math.max(1.0, size.width - padding * 2);
  final aH = math.max(1.0, size.height - padding * 2);
  final ratio = math.max(1, maxX) / math.max(1, maxY);
  final aRatio = aW / aH;
  late double dW, dH;
  if (aRatio > ratio) {
    dH = aH;
    dW = dH * ratio;
  } else {
    dW = aW;
    dH = dW / ratio;
  }
  return Rect.fromLTWH(
      padding + (aW - dW) / 2, padding + (aH - dH) / 2, dW, dH);
}

// ─────────────────────────────────────────────────────────────────────────────
// FULL-SCREEN DRAW PAGE
// ─────────────────────────────────────────────────────────────────────────────
class FullScreenDrawPage extends StatefulWidget {
  final List<Offset> initialPoints;
  const FullScreenDrawPage({super.key, required this.initialPoints});

  @override
  State<FullScreenDrawPage> createState() => _FullScreenDrawPageState();
}

class _FullScreenDrawPageState extends State<FullScreenDrawPage> {
  static const int _maxReturn = 5000;

  late List<Offset> _points;
  Offset? _lastAdded;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    _points = List.from(widget.initialPoints);
    if (_points.isNotEmpty) _lastAdded = _points.last;
  }

  void _addPoint(Offset p) {
    if (_completing) return;
    if (_lastAdded != null && (p - _lastAdded!).distance < 1.2) return;
    setState(() {
      _points.add(p);
      _lastAdded = p;
    });
  }

  Future<void> _finish() async {
    if (_completing) return;
    setState(() => _completing = true);
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;
    final out = _points.length > _maxReturn
        ? _downsample(_points, _maxReturn)
        : _points;
    Navigator.of(context).pop(out);
  }

  List<Offset> _downsample(List<Offset> pts, int max) {
    if (pts.length <= max) return pts;
    final stride = (pts.length / max).ceil().clamp(1, 1000);
    final out = <Offset>[];
    for (int i = 0; i < pts.length; i += stride) {
      out.add(pts[i]);
    }
    if (out.last != pts.last) out.add(pts.last);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Draw Path'),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              _points = [];
              _lastAdded = null;
            }),
            icon: const Icon(Icons.clear),
            tooltip: 'Clear',
          ),
          IconButton(
              onPressed: _finish,
              icon: const Icon(Icons.check),
              tooltip: 'Done'),
          const SizedBox(width: 8),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          if (!_completing) _addPoint(d.localPosition);
        },
        onPanUpdate: (d) {
          if (!_completing) _addPoint(d.localPosition);
        },
        child: Stack(children: [
          CustomPaint(
            painter: _FreeDrawPainter(_points),
            child: const SizedBox.expand(),
          ),
          if (_completing)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ]),
      ),
    );
  }
}

class _FreeDrawPainter extends CustomPainter {
  final List<Offset> points;
  _FreeDrawPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFFAFAFA));
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.teal
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _FreeDrawPainter old) => old.points != points;
}
