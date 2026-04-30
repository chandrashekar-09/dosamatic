import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DosamaticApp());
}

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

class Waypoint {
  final int x;
  final int y;
  final int z;
  final int speed;

  const Waypoint({
    required this.x,
    required this.y,
    required this.z,
    this.speed = 0,
  });

  Map<String, int> toJson() => {'x': x, 'y': y, 'z': z, 'speed': speed};

  factory Waypoint.fromJson(Map<String, dynamic> json) {
    return Waypoint(
      x: (json['x'] ?? 0) as int,
      y: (json['y'] ?? 0) as int,
      z: (json['z'] ?? 0) as int,
      speed: (json['speed'] ?? 0) as int,
    );
  }
}

class PresetModel {
  final String id;
  final String name;
  final List<List<Waypoint>> steps;

  const PresetModel(
      {required this.id, required this.name, required this.steps});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps
            .map((step) => step.map((point) => point.toJson()).toList())
            .toList(),
      };

  factory PresetModel.fromJson(Map<String, dynamic> json) {
    final rawSteps = (json['steps'] as List<dynamic>? ?? <dynamic>[]);
    final steps = rawSteps
        .map(
          (step) => (step as List<dynamic>)
              .map((point) => Waypoint.fromJson(point as Map<String, dynamic>))
              .toList(),
        )
        .toList();

    return PresetModel(
      id: (json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString())
          .toString(),
      name: (json['name'] ?? 'Preset').toString(),
      steps: steps,
    );
  }
}

enum ShapeType {
  line,
  square,
  triangle,
  circle,
  spiral,
  spinge,
  custom,
}

class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});

  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  static const int _customTemplateMax = 1000;
  static const int _maxImportedRawPoints = 5000;
  static const int _firmwareQueueMaxWaypoints = 180;
  static const String _defaultMdnsHost = 'dosamatic.local';
  static const String _settingsHostKey = 'dosamatic.host';
  static const String _settingsUseMdnsKey = 'dosamatic.use_mdns';
  static const String _settingsPresetsKey = 'dosamatic.saved_presets';

  String _deviceState = 'UNKNOWN';
  int _currentX = 0;
  int _currentY = 0;
  int _currentZ = 0;
  int _dcSpeed = 0;
  int _limitX = 14000;
  int _limitY = 14000;
  int _limitZ = 14000;
  int _maxSpeed1 = 2000;
  int _maxSpeed2 = 2000;
  int _maxSpeed3 = 2000;
  bool _isConnected = false;
  bool _isFetchingStatus = false;

  int _selectedTab = 0;

  bool _useMdns = true;
  String _manualHost = '192.168.4.1';

  late Timer _pollingTimer;

  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _limXCtrl = TextEditingController();
  final TextEditingController _limYCtrl = TextEditingController();
  final TextEditingController _limZCtrl = TextEditingController();
  final TextEditingController _spdXCtrl = TextEditingController();
  final TextEditingController _spdYCtrl = TextEditingController();
  final TextEditingController _spdZCtrl = TextEditingController();
  final TextEditingController _jogStepCtrl = TextEditingController();
  final TextEditingController _manualSpeedCtrl = TextEditingController();
  final TextEditingController _dcSpeedCtrl = TextEditingController();

  final FocusNode _limXFocus = FocusNode();
  final FocusNode _limYFocus = FocusNode();
  final FocusNode _limZFocus = FocusNode();
  final FocusNode _spdXFocus = FocusNode();
  final FocusNode _spdYFocus = FocusNode();
  final FocusNode _spdZFocus = FocusNode();

  int _jogStep = 1000;
  int _manualSpeed = 1200;
  int _dcCommandSpeed = 120;
  bool _isSendingDcCommand = false;

  ShapeType _shapeType = ShapeType.square;
  double _shapeSize = 2000;
  int _shapeZ = 0;
  int _circleSegments = 20;
  int _spiralTurns = 5;
  int _spingeWaves = 4;
  int _shapeOffsetX = 0;
  int _shapeOffsetY = 0;
  int _customDrawDensity = 6;
  bool _isImportingDraw = false;
  final Map<ShapeType, int> _shapeSpeedMap = {
    ShapeType.line: 1200,
    ShapeType.square: 1200,
    ShapeType.triangle: 1200,
    ShapeType.circle: 1200,
    ShapeType.spiral: 1200,
    ShapeType.spinge: 1200,
    ShapeType.custom: 1200,
  };

  final List<Waypoint> _customPoints = [
    const Waypoint(x: 0, y: 0, z: 0),
    const Waypoint(x: _customTemplateMax, y: 0, z: 0),
    const Waypoint(x: _customTemplateMax, y: _customTemplateMax, z: 0),
    const Waypoint(x: 0, y: _customTemplateMax, z: 0),
    const Waypoint(x: 0, y: 0, z: 0),
  ];

  List<List<Waypoint>> _draftPresetSteps = <List<Waypoint>>[];
  List<PresetModel> _presets = <PresetModel>[];
  final TextEditingController _presetNameCtrl = TextEditingController();

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
    _manualSpeedCtrl.text = _manualSpeed.toString();
    _dcSpeedCtrl.text = _dcCommandSpeed.toString();
    _hostCtrl.text = _manualHost;
    _loadLocalSettings();

    _pollingTimer = Timer.periodic(
        const Duration(milliseconds: 1500), (_) => _fetchStatus());
    _fetchStatus();
  }

  @override
  void dispose() {
    _pollingTimer.cancel();
    _hostCtrl.dispose();
    _limXCtrl.dispose();
    _limYCtrl.dispose();
    _limZCtrl.dispose();
    _spdXCtrl.dispose();
    _spdYCtrl.dispose();
    _spdZCtrl.dispose();
    _jogStepCtrl.dispose();
    _manualSpeedCtrl.dispose();
    _dcSpeedCtrl.dispose();
    _presetNameCtrl.dispose();
    _limXFocus.dispose();
    _limYFocus.dispose();
    _limZFocus.dispose();
    _spdXFocus.dispose();
    _spdYFocus.dispose();
    _spdZFocus.dispose();
    super.dispose();
  }

  String get _activeHost => _useMdns ? _defaultMdnsHost : _manualHost.trim();
  String get _apiUrl => 'http://$_activeHost/api';

  bool get _isBusyState =>
      _deviceState == 'HOMING' ||
      _deviceState == 'WAITING' ||
      _deviceState == 'MOVING';

  int get _maxCanvasX => math.max(1, _limitX);
  int get _maxCanvasY => math.max(1, _limitY);

  int _asInt(dynamic value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return fallback;
  }

  void _syncControllerFromDevice(
    TextEditingController controller,
    FocusNode focusNode,
    int value,
  ) {
    if (focusNode.hasFocus) return;
    final text = value.toString();
    if (controller.text != text) {
      controller.text = text;
    }
  }

  Future<void> _loadLocalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_settingsHostKey);
    final useMdns = prefs.getBool(_settingsUseMdnsKey);
    final presetJson = prefs.getString(_settingsPresetsKey);

    if (!mounted) {
      return;
    }

    setState(() {
      if (host != null && host.isNotEmpty) {
        _manualHost = host;
        _hostCtrl.text = host;
      }
      if (useMdns != null) {
        _useMdns = useMdns;
      }
      if (presetJson != null && presetJson.isNotEmpty) {
        try {
          final raw = jsonDecode(presetJson) as List<dynamic>;
          _presets = raw
              .map((item) => PresetModel.fromJson(item as Map<String, dynamic>))
              .toList();
        } catch (_) {
          _presets = <PresetModel>[];
        }
      }
    });
  }

  Future<void> _saveConnectionSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final host = _hostCtrl.text.trim();

    await prefs.setBool(_settingsUseMdnsKey, _useMdns);
    if (host.isNotEmpty) {
      await prefs.setString(_settingsHostKey, host);
      _manualHost = host;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _useMdns
              ? 'Using mDNS host: $_defaultMdnsHost'
              : 'Using manual host: $_manualHost',
        ),
      ),
    );

    _fetchStatus();
  }

  Future<void> _savePresets() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        jsonEncode(_presets.map((preset) => preset.toJson()).toList());
    await prefs.setString(_settingsPresetsKey, encoded);
  }

  Future<void> _fetchStatus() async {
    if (_isFetchingStatus) {
      return;
    }

    _isFetchingStatus = true;
    try {
      final response = await http
          .get(Uri.parse('$_apiUrl/status'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (!mounted) {
          return;
        }
        setState(() {
          _isConnected = true;
          _deviceState = (data['state'] ?? 'UNKNOWN').toString();
          _currentX = _asInt(data['m1_pos'], 0);
          _currentY = _asInt(data['m2_pos'], 0);
          _currentZ = _asInt(data['m3_pos'], 0);
          _dcSpeed = _asInt(data['dc_speed'], 0);

          if (data['m1_limit'] != null) {
            _limitX = _asInt(data['m1_limit'], _limitX);
            _syncControllerFromDevice(_limXCtrl, _limXFocus, _limitX);
          }
          if (data['m2_limit'] != null) {
            _limitY = _asInt(data['m2_limit'], _limitY);
            _syncControllerFromDevice(_limYCtrl, _limYFocus, _limitY);
          }
          if (data['m3_limit'] != null) {
            _limitZ = _asInt(data['m3_limit'], _limitZ);
            _syncControllerFromDevice(_limZCtrl, _limZFocus, _limitZ);
          }
          if (data['m1_max_speed'] != null) {
            _maxSpeed1 = _asInt(data['m1_max_speed'], _maxSpeed1);
            _syncControllerFromDevice(_spdXCtrl, _spdXFocus, _maxSpeed1);
          }
          if (data['m2_max_speed'] != null) {
            _maxSpeed2 = _asInt(data['m2_max_speed'], _maxSpeed2);
            _syncControllerFromDevice(_spdYCtrl, _spdYFocus, _maxSpeed2);
          }
          if (data['m3_max_speed'] != null) {
            _maxSpeed3 = _asInt(data['m3_max_speed'], _maxSpeed3);
            _syncControllerFromDevice(_spdZCtrl, _spdZFocus, _maxSpeed3);
          }
        });
      } else {
        if (!mounted) {
          return;
        }
        setState(() => _isConnected = false);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isConnected = false);
    } finally {
      _isFetchingStatus = false;
    }
  }

  Future<bool> _sendPath(List<Waypoint> path) async {
    if (path.isEmpty) {
      return false;
    }
    if (!_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device is not connected.')),
        );
      }
      return false;
    }
    if (_isBusyState) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Device busy in state $_deviceState. Wait for READY.')),
        );
      }
      return false;
    }

    try {
      final gcodeProgram = _buildGcodeProgram(path);

      final gcodeResponse = await http
          .post(
            Uri.parse('$_apiUrl/gcode'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'program': gcodeProgram}),
          )
          .timeout(const Duration(seconds: 4));

      if (gcodeResponse.statusCode == 200) {
        return true;
      }

      final gcodeBody = _tryParseJsonObject(gcodeResponse.body);
      final gcodeAccepted = _asInt(gcodeBody['accepted'], -1);
      if (gcodeResponse.statusCode == 409 && gcodeAccepted >= 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Queue full after accepting $gcodeAccepted lines. Reduce shape points or send smaller batches.',
            ),
          ),
        );
      }

      final legacyResponse = await http
          .post(
            Uri.parse('$_apiUrl/path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(path.map((point) => point.toJson()).toList()),
          )
          .timeout(const Duration(seconds: 3));

      if (legacyResponse.statusCode == 200) {
        final legacyBody = _tryParseJsonObject(legacyResponse.body);
        final accepted = _asInt(legacyBody['accepted'], path.length);
        if (accepted < path.length) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Only $accepted/${path.length} waypoints accepted. Reduce path density or split the path.',
                ),
              ),
            );
          }
          return false;
        }
        return true;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Program rejected (${gcodeResponse.statusCode}/${legacyResponse.statusCode}): ${gcodeResponse.body}',
            ),
          ),
        );
      }
      return false;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send program: $e')),
        );
      }
      return false;
    }
  }

  Map<String, dynamic> _tryParseJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }

  String _buildGcodeProgram(List<Waypoint> path) {
    final buffer = StringBuffer();
    buffer.writeln('G90');

    int? modalFeed;
    for (final point in path) {
      final speed = point.speed > 0 ? point.speed : _manualSpeed;
      if (modalFeed != speed) {
        buffer.writeln('F$speed');
        modalFeed = speed;
      }
      buffer.writeln('G1 X${point.x} Y${point.y} Z${point.z}');
    }

    return buffer.toString();
  }

  Future<void> _homeCommand() async {
    try {
      await http
          .post(Uri.parse('$_apiUrl/home'))
          .timeout(const Duration(seconds: 2));
      _fetchStatus();
    } catch (_) {}
  }

  Future<void> _stopCommand() async {
    try {
      await http
          .post(Uri.parse('$_apiUrl/stop'))
          .timeout(const Duration(seconds: 2));
      _fetchStatus();
    } catch (_) {}
  }

  Future<void> _setDcSpeed(int speed) async {
    if (_isSendingDcCommand || !_isConnected) {
      return;
    }

    setState(() {
      _isSendingDcCommand = true;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$_apiUrl/dc'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'speed': speed.clamp(-255, 255)}),
          )
          .timeout(const Duration(seconds: 2));

      if (!mounted) {
        return;
      }

      if (response.statusCode == 200) {
        setState(() {
          _dcSpeed = speed.clamp(-255, 255);
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('DC command failed: ${response.body}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('DC command error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingDcCommand = false;
        });
      }
    }
  }

  Future<void> _setLimits() async {
    final int max1 = int.tryParse(_limXCtrl.text) ?? _limitX;
    final int max2 = int.tryParse(_limYCtrl.text) ?? _limitY;
    final int max3 = int.tryParse(_limZCtrl.text) ?? _limitZ;
    final int speed1 = int.tryParse(_spdXCtrl.text) ?? _maxSpeed1;
    final int speed2 = int.tryParse(_spdYCtrl.text) ?? _maxSpeed2;
    final int speed3 = int.tryParse(_spdZCtrl.text) ?? _maxSpeed3;

    try {
      final response = await http
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
            }),
          )
          .timeout(const Duration(seconds: 3));

      if (!mounted) {
        return;
      }

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Limits applied successfully.')),
        );
        _fetchStatus();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Limit update failed: ${response.body}')),
        );
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to set limits: $e')),
      );
    }
  }

  void _jog(String axis, int step) {
    int targetX = _currentX;
    int targetY = _currentY;
    int targetZ = _currentZ;

    if (axis == 'X') {
      targetX = (targetX + step).clamp(0, _limitX);
    }
    if (axis == 'Y') {
      targetY = (targetY + step).clamp(0, _limitY);
    }
    if (axis == 'Z') {
      targetZ = (targetZ + step).clamp(0, _limitZ);
    }

    _sendPath(
      <Waypoint>[
        Waypoint(
          x: targetX,
          y: targetY,
          z: targetZ,
          speed: _manualSpeed,
        )
      ],
    );
  }

  void _onJogStepChanged(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed <= 0) {
      return;
    }
    setState(() {
      _jogStep = parsed.clamp(1, 50000);
    });
  }

  void _onManualSpeedChanged(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed <= 0) {
      return;
    }
    setState(() {
      _manualSpeed = parsed.clamp(100, 10000);
    });
  }

  void _onDcCommandSpeedChanged(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0) {
      return;
    }
    setState(() {
      _dcCommandSpeed = parsed.clamp(0, 255);
    });
  }

  int _effectiveCircleSegments(int size) {
    final int maxSegments = _firmwareQueueMaxWaypoints - 1;
    final double radius = size / 2.0;
    final double circumference = 2 * math.pi * radius;
    final int adaptive = (circumference / 120.0).round();
    return math.max(_circleSegments, adaptive).clamp(12, maxSegments);
  }

  void _addRoundedPointIfChanged(
    List<Waypoint> output,
    double x,
    double y,
    int z,
    int speed,
  ) {
    final next = Waypoint(
      x: x.round().clamp(0, _limitX),
      y: y.round().clamp(0, _limitY),
      z: z,
      speed: speed,
    );

    if (output.isEmpty) {
      output.add(next);
      return;
    }

    final last = output.last;
    if (last.x == next.x && last.y == next.y && last.z == next.z) {
      return;
    }
    output.add(next);
  }

  List<Waypoint> _shapeBasePath() {
    final int size = _shapeSize.round().clamp(100, math.min(_limitX, _limitY));
    final int z = _shapeZ.clamp(0, _limitZ);
    final int speed = _shapeSpeedMap[_shapeType] ?? 1200;

    switch (_shapeType) {
      case ShapeType.line:
        return <Waypoint>[
          Waypoint(x: 0, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: 0, z: z, speed: speed),
        ];
      case ShapeType.square:
        return <Waypoint>[
          Waypoint(x: 0, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: size, z: z, speed: speed),
          Waypoint(x: 0, y: size, z: z, speed: speed),
          Waypoint(x: 0, y: 0, z: z, speed: speed),
        ];
      case ShapeType.triangle:
        return <Waypoint>[
          Waypoint(x: 0, y: 0, z: z, speed: speed),
          Waypoint(x: size, y: 0, z: z, speed: speed),
          Waypoint(x: size ~/ 2, y: size, z: z, speed: speed),
          Waypoint(x: 0, y: 0, z: z, speed: speed),
        ];
      case ShapeType.circle:
        final List<Waypoint> points = <Waypoint>[];
        final radius = size / 2.0;
        final centerX = radius;
        final centerY = radius;
        final segments = _effectiveCircleSegments(size);
        for (int i = 0; i <= segments; i++) {
          final angle = (2 * math.pi * i) / segments;
          _addRoundedPointIfChanged(
            points,
            centerX + radius * math.cos(angle),
            centerY + radius * math.sin(angle),
            z,
            speed,
          );
        }
        if (points.isNotEmpty) {
          final first = points.first;
          final last = points.last;
          if (last.x != first.x || last.y != first.y || last.z != first.z) {
            points.add(first);
          }
        }
        return points;
      case ShapeType.spiral:
        final List<Waypoint> points = <Waypoint>[];
        final int samples = (_circleSegments * _spiralTurns).clamp(20, 300);
        final double maxRadius = size / 2.0;
        final double centerX = maxRadius;
        final double centerY = maxRadius;
        for (int i = 0; i <= samples; i++) {
          final double t = i / samples;
          final double angle = 2 * math.pi * _spiralTurns * t;
          final double radius = maxRadius * t;
          final int x = (centerX + radius * math.cos(angle)).round();
          final int y = (centerY + radius * math.sin(angle)).round();
          points.add(Waypoint(
            x: x.clamp(0, _limitX),
            y: y.clamp(0, _limitY),
            z: z,
            speed: speed,
          ));
        }
        return points;
      case ShapeType.spinge:
        final List<Waypoint> points = <Waypoint>[];
        final int samples = (_circleSegments * _spingeWaves).clamp(20, 300);
        final double width = size.toDouble();
        final double amplitude = size / 4.0;
        final double midY = size / 2.0;
        for (int i = 0; i <= samples; i++) {
          final double t = i / samples;
          final int x = (width * t).round();
          final int y =
              (midY + amplitude * math.sin(2 * math.pi * _spingeWaves * t))
                  .round();
          points.add(Waypoint(
            x: x.clamp(0, _limitX),
            y: y.clamp(0, _limitY),
            z: z,
            speed: speed,
          ));
        }
        return points;
      case ShapeType.custom:
        final int stride = _customDrawDensity.clamp(1, 20);
        final List<Waypoint> sampled = <Waypoint>[];
        for (int i = 0; i < _customPoints.length; i += stride) {
          sampled.add(_customPoints[i]);
        }
        if (sampled.isEmpty || sampled.last != _customPoints.last) {
          sampled.add(_customPoints.last);
        }

        final mapped = sampled
            .map(
              (point) => Waypoint(
                x: ((point.x / _customTemplateMax) * size)
                    .round()
                    .clamp(0, _limitX),
                y: ((point.y / _customTemplateMax) * size)
                    .round()
                    .clamp(0, _limitY),
                z: z,
                speed: speed,
              ),
            )
            .toList();
        final List<Waypoint> deduped = <Waypoint>[];
        for (final point in mapped) {
          if (deduped.isEmpty) {
            deduped.add(point);
            continue;
          }
          final last = deduped.last;
          if (last.x == point.x && last.y == point.y && last.z == point.z) {
            continue;
          }
          deduped.add(point);
        }
        return deduped;
    }
  }

  List<Waypoint> _shapePath() {
    final base = _shapeBasePath();
    if (base.isEmpty) {
      return base;
    }

    return base
        .map(
          (point) => Waypoint(
            x: (point.x + _shapeOffsetX).clamp(0, _limitX),
            y: (point.y + _shapeOffsetY).clamp(0, _limitY),
            z: point.z,
            speed: point.speed,
          ),
        )
        .toList();
  }

  int _speedForShape(ShapeType shape) {
    return _shapeSpeedMap[shape] ?? 1200;
  }

  void _setSpeedForShape(ShapeType shape, int speed) {
    final clamped = speed.clamp(100, 10000);
    setState(() {
      _shapeSpeedMap[shape] = clamped;
    });
  }

  Future<void> _openFullScreenDraw() async {
    if (_isImportingDraw) {
      return;
    }

    final points = await Navigator.of(context).push<List<Offset>>(
      MaterialPageRoute(
        builder: (_) => const FullScreenDrawPage(initialPoints: <Offset>[]),
      ),
    );

    if (!mounted || points == null || points.length < 2) {
      return;
    }

    setState(() {
      _isImportingDraw = true;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (!mounted) {
        return;
      }

      final sourcePoints = points.length > _maxImportedRawPoints
          ? _downsamplePoints(points, _maxImportedRawPoints)
          : points;
      final simplified = _simplifyRawPoints(sourcePoints);
      final mapped = _mapDrawnPointsToTemplate(simplified);
      if (mapped.length < 2) {
        return;
      }

      setState(() {
        _customPoints
          ..clear()
          ..addAll(mapped);
        _shapeType = ShapeType.custom;
        _shapeSize =
            (_shapeSize).clamp(300, math.min(_limitX, _limitY).toDouble());
        _shapeOffsetX = 0;
        _shapeOffsetY = 0;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isImportingDraw = false;
        });
      }
    }
  }

  List<Offset> _simplifyRawPoints(List<Offset> points) {
    if (points.isEmpty) {
      return <Offset>[];
    }

    final double minDistance = points.length > 3000 ? 3.0 : 2.0;
    const int maxPoints = 2500;

    final simplified = <Offset>[points.first];
    var last = points.first;

    for (int i = 1; i < points.length; i++) {
      final current = points[i];
      if ((current - last).distance >= minDistance) {
        simplified.add(current);
        last = current;
      }
    }

    if (simplified.last != points.last) {
      simplified.add(points.last);
    }

    if (simplified.length <= maxPoints) {
      return simplified;
    }

    final stride = (simplified.length / maxPoints).ceil().clamp(1, 1000);
    final capped = <Offset>[];
    for (int i = 0; i < simplified.length; i += stride) {
      capped.add(simplified[i]);
    }
    if (capped.last != simplified.last) {
      capped.add(simplified.last);
    }
    return capped;
  }

  List<Offset> _downsamplePoints(List<Offset> points, int maxPoints) {
    if (points.length <= maxPoints) {
      return points;
    }
    final stride = (points.length / maxPoints).ceil().clamp(1, 1000);
    final sampled = <Offset>[];
    for (int i = 0; i < points.length; i += stride) {
      sampled.add(points[i]);
    }
    if (sampled.last != points.last) {
      sampled.add(points.last);
    }
    return sampled;
  }

  List<Waypoint> _mapDrawnPointsToTemplate(List<Offset> rawPoints) {
    if (rawPoints.length < 2) {
      return <Waypoint>[];
    }

    final sampled = rawPoints;

    double minX = sampled.first.dx;
    double minY = sampled.first.dy;
    double maxX = sampled.first.dx;
    double maxY = sampled.first.dy;

    for (final point in sampled) {
      minX = math.min(minX, point.dx);
      minY = math.min(minY, point.dy);
      maxX = math.max(maxX, point.dx);
      maxY = math.max(maxY, point.dy);
    }

    final spanX = math.max(1.0, maxX - minX);
    final spanY = math.max(1.0, maxY - minY);

    return sampled
        .map(
          (p) => Waypoint(
            x: (((p.dx - minX) / spanX) * _customTemplateMax)
                .round()
                .clamp(0, _customTemplateMax),
            y: (((p.dy - minY) / spanY) * _customTemplateMax)
                .round()
                .clamp(0, _customTemplateMax),
            z: 0,
            speed: 0,
          ),
        )
        .toList();
  }

  void _moveShapeByCanvasDelta(double dxUnits, double dyUnits) {
    final base = _shapeBasePath();
    if (base.isEmpty) {
      return;
    }

    final minX = base.map((point) => point.x).reduce(math.min);
    final maxX = base.map((point) => point.x).reduce(math.max);
    final minY = base.map((point) => point.y).reduce(math.min);
    final maxY = base.map((point) => point.y).reduce(math.max);

    final proposedX = _shapeOffsetX + dxUnits.round();
    final proposedY = _shapeOffsetY + dyUnits.round();

    final minOffsetX = -minX;
    final maxOffsetX = _limitX - maxX;
    final minOffsetY = -minY;
    final maxOffsetY = _limitY - maxY;

    setState(() {
      _shapeOffsetX = proposedX.clamp(minOffsetX, maxOffsetX);
      _shapeOffsetY = proposedY.clamp(minOffsetY, maxOffsetY);
    });
  }

  Future<void> _executeCurrentShape() async {
    final path = _shapePath();
    if (path.length > _firmwareQueueMaxWaypoints) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Shape has ${path.length} waypoints, exceeds firmware queue ($_firmwareQueueMaxWaypoints). Reduce points/density.',
          ),
        ),
      );
      return;
    }

    final ok = await _sendPath(path);
    if (!mounted) {
      return;
    }
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Path queued.')),
      );
    }
  }

  void _addCurrentShapeToDraft() {
    final path = _shapePath();
    if (path.isEmpty) {
      return;
    }
    setState(() {
      _draftPresetSteps = <List<Waypoint>>[..._draftPresetSteps, path];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text('Added step ${_draftPresetSteps.length} to preset draft.')),
    );
  }

  Future<void> _executePreset(PresetModel preset) async {
    if (_isBusyState) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Device busy in state $_deviceState. Wait for READY.')),
      );
      return;
    }

    final merged = preset.steps.expand((step) => step).toList();
    if (merged.length > _firmwareQueueMaxWaypoints) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Preset has more than $_firmwareQueueMaxWaypoints waypoints. Reduce steps.',
          ),
        ),
      );
      return;
    }

    final ok = await _sendPath(merged);
    if (!mounted) {
      return;
    }
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preset "${preset.name}" queued.')),
      );
    }
  }

  Future<void> _saveDraftAsPreset() async {
    final name = _presetNameCtrl.text.trim();
    if (name.isEmpty || _draftPresetSteps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Provide a name and at least one draft step.')),
      );
      return;
    }

    final totalPoints = _draftPresetSteps.fold<int>(
      0,
      (sum, step) => sum + step.length,
    );

    if (totalPoints > _firmwareQueueMaxWaypoints) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Draft exceeds firmware queue ($_firmwareQueueMaxWaypoints waypoints).',
          ),
        ),
      );
      return;
    }

    final preset = PresetModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      steps: _draftPresetSteps,
    );

    setState(() {
      _presets = <PresetModel>[..._presets, preset];
      _draftPresetSteps = <List<Waypoint>>[];
      _presetNameCtrl.clear();
    });
    await _savePresets();

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Preset saved.')),
    );
  }

  Future<void> _deletePreset(String id) async {
    setState(() {
      _presets = _presets.where((preset) => preset.id != id).toList();
    });
    await _savePresets();
  }

  String _shapeLabel(ShapeType type) {
    switch (type) {
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

  void _updateCustomPoint(int index, {int? x, int? y, int? z}) {
    if (index < 0 || index >= _customPoints.length) {
      return;
    }

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
    setState(() {
      _customPoints.add(
        Waypoint(
            x: (_customTemplateMax ~/ 2), y: (_customTemplateMax ~/ 2), z: 0),
      );
    });
  }

  void _removeCustomPoint(int index) {
    if (_customPoints.length <= 2) {
      return;
    }
    setState(() {
      _customPoints.removeAt(index);
    });
  }

  Widget _buildHomePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'Status: $_deviceState',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildPosIndicator('X', _currentX, _limitX),
                      _buildPosIndicator('Y', _currentY, _limitY),
                      _buildPosIndicator('Z', _currentZ, _limitZ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _stopCommand,
                  icon: const Icon(Icons.warning),
                  label: const Text('E-STOP'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _homeCommand,
                  icon: const Icon(Icons.home),
                  label: const Text('HOME MOTORS'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Manual Controls (±$_jogStep steps)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Step Size:'),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _jogStepCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '1000',
                  ),
                  onChanged: _onJogStepChanged,
                  onSubmitted: _onJogStepChanged,
                ),
              ),
              const SizedBox(width: 16),
              const Text('Speed:'),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _manualSpeedCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '1200',
                  ),
                  onChanged: _onManualSpeedChanged,
                  onSubmitted: _onManualSpeedChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildJogButtons('X'),
              _buildJogButtons('Y'),
              _buildJogButtons('Z'),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'DC Motor Control',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text('Current speed: $_dcSpeed'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Cmd Speed:'),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: _dcSpeedCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            hintText: '0-255',
                          ),
                          onChanged: _onDcCommandSpeedChanged,
                          onSubmitted: _onDcCommandSpeedChanged,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Slider(
                    min: 0,
                    max: 255,
                    divisions: 255,
                    value: _dcCommandSpeed.toDouble(),
                    onChanged: (value) {
                      setState(() {
                        _dcCommandSpeed = value.round();
                        _dcSpeedCtrl.text = _dcCommandSpeed.toString();
                      });
                    },
                  ),
                  Row(
                    children: [
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
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShapesPage() {
    final path = _shapePath();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          const SizedBox(height: 12),
          Text(
            'Origin is top-left. Drag shape to move. X→right (max $_limitX), Y→down (max $_limitY).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Offset: X=$_shapeOffsetX, Y=$_shapeOffsetY',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text('Execution Speed: ${_speedForShape(_shapeType)} steps/s'),
          Slider(
            min: 100,
            max: 10000,
            divisions: 99,
            value: _speedForShape(_shapeType).toDouble(),
            onChanged: (value) =>
                _setSpeedForShape(_shapeType, value.round().clamp(100, 10000)),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<ShapeType>(
            value: _shapeType,
            decoration: const InputDecoration(labelText: 'Shape Type'),
            items: ShapeType.values
                .map(
                  (type) => DropdownMenuItem<ShapeType>(
                    value: type,
                    child: Text(_shapeLabel(type)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _shapeType = value;
              });
            },
          ),
          const SizedBox(height: 12),
          if (_shapeType != ShapeType.circle) ...[
            Text('Size: ${_shapeSize.round()}'),
            Slider(
              min: 100,
              max: math.max(500.0, math.min(_limitX, _limitY).toDouble()),
              value: _shapeSize.clamp(
                  100, math.max(500.0, math.min(_limitX, _limitY).toDouble())),
              onChanged: (value) => setState(() => _shapeSize = value),
            ),
          ],
          Text('Z: $_shapeZ'),
          Slider(
            min: 0,
            max: _limitZ.toDouble(),
            value: _shapeZ.toDouble().clamp(0, _limitZ.toDouble()),
            onChanged: (value) => setState(() => _shapeZ = value.round()),
          ),
          if (_shapeType == ShapeType.circle) ...[
            Text('Circle size: ${_shapeSize.round()}'),
            Slider(
              min: 100,
              max: math.max(500.0, math.min(_limitX, _limitY).toDouble()),
              value: _shapeSize.clamp(
                  100, math.max(500.0, math.min(_limitX, _limitY).toDouble())),
              onChanged: (value) => setState(() => _shapeSize = value),
            ),
          ],
          if (_shapeType == ShapeType.circle) ...[
            Text('Circle points: $_circleSegments'),
            Slider(
              min: 8,
              max: 160,
              divisions: 152,
              value: _circleSegments.toDouble(),
              onChanged: (value) =>
                  setState(() => _circleSegments = value.round().clamp(8, 160)),
            ),
          ],
          if (_shapeType == ShapeType.spiral) ...[
            Text('Spiral turns: $_spiralTurns'),
            Slider(
              min: 2,
              max: 12,
              divisions: 10,
              value: _spiralTurns.toDouble(),
              onChanged: (value) =>
                  setState(() => _spiralTurns = value.round().clamp(2, 12)),
            ),
            Text('Spiral points: $_circleSegments'),
            Slider(
              min: 8,
              max: 80,
              divisions: 72,
              value: _circleSegments.toDouble(),
              onChanged: (value) =>
                  setState(() => _circleSegments = value.round().clamp(8, 80)),
            ),
          ],
          if (_shapeType == ShapeType.spinge) ...[
            Text('Spinge waves: $_spingeWaves'),
            Slider(
              min: 1,
              max: 12,
              divisions: 11,
              value: _spingeWaves.toDouble(),
              onChanged: (value) =>
                  setState(() => _spingeWaves = value.round().clamp(1, 12)),
            ),
            Text('Spinge points: $_circleSegments'),
            Slider(
              min: 8,
              max: 80,
              divisions: 72,
              value: _circleSegments.toDouble(),
              onChanged: (value) =>
                  setState(() => _circleSegments = value.round().clamp(8, 80)),
            ),
          ],
          if (_shapeType == ShapeType.custom) ...[
            Text(
                'Custom density: $_customDrawDensity (1 = highest resolution, 20 = fewer dots)'),
            Slider(
              min: 1,
              max: 20,
              divisions: 19,
              value: _customDrawDensity.toDouble(),
              onChanged: (value) => setState(
                  () => _customDrawDensity = value.round().clamp(1, 20)),
            ),
            if (_isImportingDraw)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Importing drawing...'),
                  ],
                ),
              )
            else
              ElevatedButton.icon(
                onPressed: _openFullScreenDraw,
                icon: const Icon(Icons.open_in_full),
                label: const Text('Open Full Screen Draw (Draw + OK)'),
              ),
            const SizedBox(height: 8),
            const Text(
              'Template points (after draw, then resize/move in canvas)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (int index = 0; index < _customPoints.length; index++)
              _CustomPointEditor(
                index: index,
                point: _customPoints[index],
                limitX: _customTemplateMax,
                limitY: _customTemplateMax,
                limitZ: _limitZ,
                onChanged: (x, y, z) =>
                    _updateCustomPoint(index, x: x, y: y, z: z),
                onRemove: () => _removeCustomPoint(index),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _addCustomPoint,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Point'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _executeCurrentShape,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Execute Path'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addCurrentShapeToDraft,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Add To Preset Draft'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPresetsPage() {
    final draftPoints = _draftPresetSteps.fold<int>(
      0,
      (sum, step) => sum + step.length,
    );

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
                  Text(
                    'Preset Draft Sequence',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                      'Steps: ${_draftPresetSteps.length} • Waypoints: $draftPoints / 50'),
                  const SizedBox(height: 8),
                  for (int i = 0; i < _draftPresetSteps.length; i++)
                    ListTile(
                      dense: true,
                      title: Text('Step ${i + 1}'),
                      subtitle:
                          Text('${_draftPresetSteps[i].length} waypoints'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            setState(() => _draftPresetSteps.removeAt(i)),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _presetNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Preset name',
                      hintText: 'Example: Batter logo sequence',
                    ),
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
          Text(
            'Saved Presets',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_presets.isEmpty)
            const Text('No presets saved yet.')
          else
            for (final preset in _presets)
              Card(
                child: ListTile(
                  title: Text(preset.name),
                  subtitle: Text(
                    '${preset.steps.length} steps • ${preset.steps.fold<int>(0, (s, step) => s + step.length)} waypoints • speed ${preset.steps.isNotEmpty && preset.steps.first.isNotEmpty ? preset.steps.first.first.speed : 0}',
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () => _executePreset(preset),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deletePreset(preset.id),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

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
              title: const Text('Use .local mode'),
              subtitle: const Text('Host: dosamatic.local'),
              onChanged: (value) => setState(() => _useMdns = value),
            ),
            TextField(
              controller: _hostCtrl,
              enabled: !_useMdns,
              decoration: const InputDecoration(
                labelText: 'Manual IP / Host',
                hintText: '192.168.1.100',
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _saveConnectionSettings,
              icon: const Icon(Icons.wifi),
              label: const Text('Apply Connection Mode'),
            ),
            const Divider(height: 28),
            TextField(
              controller: _limXCtrl,
              focusNode: _limXFocus,
              decoration: const InputDecoration(labelText: 'Max limit X'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _limYCtrl,
              focusNode: _limYFocus,
              decoration: const InputDecoration(labelText: 'Max limit Y'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _limZCtrl,
              focusNode: _limZFocus,
              decoration: const InputDecoration(labelText: 'Max limit Z'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _spdXCtrl,
              focusNode: _spdXFocus,
              decoration:
                  const InputDecoration(labelText: 'Max speed X (steps/s)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _spdYCtrl,
              focusNode: _spdYFocus,
              decoration:
                  const InputDecoration(labelText: 'Max speed Y (steps/s)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _spdZCtrl,
              focusNode: _spdZFocus,
              decoration:
                  const InputDecoration(labelText: 'Max speed Z (steps/s)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _setLimits,
              icon: const Icon(Icons.settings),
              label: const Text('Push Max Limits to ESP32'),
            ),
            const SizedBox(height: 24),
            Text('Current API base: $_apiUrl'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _isConnected ? Colors.green : Colors.red;

    final pages = <Widget>[
      _buildHomePage(),
      _buildShapesPage(),
      _buildPresetsPage(),
    ];

    return Scaffold(
      drawer: _buildSettingsDrawer(),
      appBar: AppBar(
        title: const Text('Dosamatic Wireless Control'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Icon(Icons.wifi, color: statusColor),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Refresh status',
            onPressed: _fetchStatus,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTab,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() => _selectedTab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.polyline), label: 'Shapes'),
          NavigationDestination(
              icon: Icon(Icons.playlist_play), label: 'Presets'),
        ],
      ),
    );
  }

  Widget _buildPosIndicator(String label, int pos, int max) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        Text('$pos', style: const TextStyle(fontSize: 18, color: Colors.blue)),
        Text('Max: $max',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _buildJogButtons(String axis) {
    return Column(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_drop_up, size: 36),
          onPressed: () => _jog(axis, _jogStep),
        ),
        Text(axis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        IconButton(
          icon: const Icon(Icons.arrow_drop_down, size: 36),
          onPressed: () => _jog(axis, -_jogStep),
        ),
      ],
    );
  }
}

class _CustomPointEditor extends StatelessWidget {
  final int index;
  final Waypoint point;
  final int limitX;
  final int limitY;
  final int limitZ;
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
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                Text('P${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline)),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('x-$index-${point.x}'),
                    initialValue: point.x.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'X'),
                    onFieldSubmitted: (value) => onChanged(
                      (int.tryParse(value) ?? point.x).clamp(0, limitX),
                      point.y,
                      point.z,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('y-$index-${point.y}'),
                    initialValue: point.y.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Y'),
                    onFieldSubmitted: (value) => onChanged(
                      point.x,
                      (int.tryParse(value) ?? point.y).clamp(0, limitY),
                      point.z,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('z-$index-${point.z}'),
                    initialValue: point.z.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Z'),
                    onFieldSubmitted: (value) => onChanged(
                      point.x,
                      point.y,
                      (int.tryParse(value) ?? point.z).clamp(0, limitZ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ShapePreview extends StatelessWidget {
  final List<Waypoint> points;
  final int maxX;
  final int maxY;
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        final height = constraints.maxHeight <= 0 ? 1.0 : constraints.maxHeight;
        final plotRect = _computePlotRect(Size(width, height), maxX, maxY);

        return GestureDetector(
          onPanUpdate: (details) {
            final dxUnits = (details.delta.dx / math.max(1.0, plotRect.width)) *
                math.max(1, maxX);
            final dyUnits =
                (details.delta.dy / math.max(1.0, plotRect.height)) *
                    math.max(1, maxY);
            onPanInCanvasUnits(dxUnits, dyUnits);
          },
          child: CustomPaint(
            painter: _ShapePainter(points: points, maxX: maxX, maxY: maxY),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

class _ShapePainter extends CustomPainter {
  final List<Waypoint> points;
  final int maxX;
  final int maxY;

  _ShapePainter({required this.points, required this.maxX, required this.maxY});

  @override
  void paint(Canvas canvas, Size size) {
    final drawRect = _computePlotRect(size, maxX, maxY);

    final fullBgPaint = Paint()..color = const Color(0xFFF8FAFB);
    canvas.drawRect(Offset.zero & size, fullBgPaint);

    final bgPaint = Paint()..color = const Color(0xFFF0F3F4);
    canvas.drawRect(drawRect, bgPaint);

    final axisPaint = Paint()
      ..color = Colors.grey
      ..strokeWidth = 1;

    for (int i = 0; i <= 10; i++) {
      final dx = drawRect.left + drawRect.width * i / 10;
      final dy = drawRect.top + drawRect.height * i / 10;
      canvas.drawLine(
          Offset(dx, drawRect.top), Offset(dx, drawRect.bottom), axisPaint);
      canvas.drawLine(
          Offset(drawRect.left, dy), Offset(drawRect.right, dy), axisPaint);
    }

    final borderPaint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawRect(drawRect, borderPaint);

    if (points.length < 2) {
      return;
    }

    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final px =
          drawRect.left + (points[i].x / math.max(1, maxX)) * drawRect.width;
      final py =
          drawRect.top + (points[i].y / math.max(1, maxY)) * drawRect.height;
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }

    final pathPaint = Paint()
      ..color = Colors.teal
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, pathPaint);

    final pointPaint = Paint()..color = Colors.deepOrange;
    for (final point in points) {
      final px = drawRect.left + (point.x / math.max(1, maxX)) * drawRect.width;
      final py = drawRect.top + (point.y / math.max(1, maxY)) * drawRect.height;
      canvas.drawCircle(Offset(px, py), 3.5, pointPaint);
    }

    final xLimitStyle = const TextStyle(fontSize: 10, color: Colors.black87);
    final yLimitStyle = const TextStyle(fontSize: 10, color: Colors.black87);

    final originText = TextPainter(
      text: const TextSpan(
          text: 'Origin (0,0)',
          style: TextStyle(fontSize: 10, color: Colors.black87)),
      textDirection: TextDirection.ltr,
    )..layout();
    originText.paint(canvas, Offset(drawRect.left + 2, 2));

    final xText = TextPainter(
      text: TextSpan(text: 'X max: $maxX', style: xLimitStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    xText.paint(canvas, Offset(drawRect.right - xText.width, 2));

    final yText = TextPainter(
      text: TextSpan(text: 'Y max: $maxY', style: yLimitStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    yText.paint(canvas, Offset(2, drawRect.bottom + 2));
  }

  @override
  bool shouldRepaint(covariant _ShapePainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.maxX != maxX ||
        oldDelegate.maxY != maxY;
  }
}

Rect _computePlotRect(Size size, int maxX, int maxY) {
  const double padding = 24;

  final availableWidth = math.max(1.0, size.width - (padding * 2));
  final availableHeight = math.max(1.0, size.height - (padding * 2));

  final ratio = math.max(1, maxX) / math.max(1, maxY);
  final availableRatio = availableWidth / availableHeight;

  late final double drawWidth;
  late final double drawHeight;

  if (availableRatio > ratio) {
    drawHeight = availableHeight;
    drawWidth = drawHeight * ratio;
  } else {
    drawWidth = availableWidth;
    drawHeight = drawWidth / ratio;
  }

  final left = padding + (availableWidth - drawWidth) / 2;
  final top = padding + (availableHeight - drawHeight) / 2;
  return Rect.fromLTWH(left, top, drawWidth, drawHeight);
}

class FullScreenDrawPage extends StatefulWidget {
  final List<Offset> initialPoints;

  const FullScreenDrawPage({super.key, required this.initialPoints});

  @override
  State<FullScreenDrawPage> createState() => _FullScreenDrawPageState();
}

class _FullScreenDrawPageState extends State<FullScreenDrawPage> {
  static const int _maxPointsToReturn = 5000;

  late List<Offset> _points;
  Offset? _lastAddedPoint;
  bool _isCompleting = false;

  @override
  void initState() {
    super.initState();
    _points = List<Offset>.from(widget.initialPoints);
    if (_points.isNotEmpty) {
      _lastAddedPoint = _points.last;
    }
  }

  void _appendPoint(Offset point) {
    if (_isCompleting) {
      return;
    }
    final previous = _lastAddedPoint;
    if (previous != null && (point - previous).distance < 1.2) {
      return;
    }
    setState(() {
      _points.add(point);
      _lastAddedPoint = point;
    });
  }

  Future<void> _finishAndClose() async {
    if (_isCompleting) {
      return;
    }

    setState(() {
      _isCompleting = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) {
      return;
    }

    final pointsToReturn = _downsampleForReturn(_points, _maxPointsToReturn);
    Navigator.of(context).pop(pointsToReturn);
  }

  List<Offset> _downsampleForReturn(List<Offset> points, int maxPoints) {
    if (points.length <= maxPoints) {
      return points;
    }
    final stride = (points.length / maxPoints).ceil().clamp(1, 1000);
    final sampled = <Offset>[];
    for (int i = 0; i < points.length; i += stride) {
      sampled.add(points[i]);
    }
    if (sampled.last != points.last) {
      sampled.add(points.last);
    }
    return sampled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Full Screen Draw'),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              _points = <Offset>[];
              _lastAddedPoint = null;
            }),
            icon: const Icon(Icons.clear),
            tooltip: 'Clear',
          ),
          IconButton(
            onPressed: _finishAndClose,
            icon: const Icon(Icons.check),
            tooltip: 'OK',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          if (!_isCompleting) {
            _appendPoint(details.localPosition);
          }
        },
        onPanUpdate: (details) {
          if (!_isCompleting) {
            _appendPoint(details.localPosition);
          }
        },
        child: Stack(
          children: [
            CustomPaint(
              painter: _FreeDrawPainter(_points),
              child: const SizedBox.expand(),
            ),
            if (_isCompleting)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FreeDrawPainter extends CustomPainter {
  final List<Offset> points;

  _FreeDrawPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFFFAFAFA);
    canvas.drawRect(Offset.zero & size, bgPaint);

    final borderPaint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, borderPaint);

    if (points.length < 2) {
      return;
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }

    final linePaint = Paint()
      ..color = Colors.teal
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _FreeDrawPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}
