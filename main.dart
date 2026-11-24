import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AkustikIsgApp());
}

class AkustikIsgApp extends StatelessWidget {
  const AkustikIsgApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AkustikİSG',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF22C55E),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const NoiseMapScreen(),
    );
  }
}

class NoisePoint {
  final double nx;
  final double ny;
  final double db;
  final DateTime timestamp;

  NoisePoint({
    required this.nx,
    required this.ny,
    required this.db,
    required this.timestamp,
  });
}

class NoiseMapScreen extends StatefulWidget {
  const NoiseMapScreen({super.key});

  @override
  State<NoiseMapScreen> createState() => _NoiseMapScreenState();
}

class _NoiseMapScreenState extends State<NoiseMapScreen> {
  File? _floorPlanFile;
  double _mapAspectRatio = 4 / 3;
  double _mapWidthMeters = 40.0;
  double _stepLengthCm = 70.0;

  Offset? _currentPos;
  double _headingDeg = 90.0;
  final List<NoisePoint> _points = [];

  final NoiseMeter _noiseMeter = NoiseMeter();
  StreamSubscription<NoiseReading>? _noiseSub;
  bool _isListening = false;
  double _lastRawDb = 55.0;
  double _currentDb = 35.0;
  double _calibrationOffset = -20.0;

  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  bool _autoStepEnabled = false;
  DateTime _lastAutoStepTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadCalibration();
  }

  @override
  void dispose() {
    _noiseSub?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _calibrationOffset = prefs.getDouble('calibration_offset') ?? -20.0;
    });
  }

  Future<void> _saveCalibration(double value) async {
    setState(() => _calibrationOffset = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('calibration_offset', value);
  }

  Future<void> _pickFloorPlan() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final file = File(picked.path);
    final bytes = await file.readAsBytes();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, (ui.Image img) => completer.complete(img));
    final decoded = await completer.future;

    setState(() {
      _floorPlanFile = file;
      _mapAspectRatio = decoded.width / decoded.height;
      _currentPos = null;
      _points.clear();
    });
  }

  Future<void> _toggleMicrophone() async {
    if (_isListening) {
      await _noiseSub?.cancel();
      _noiseSub = null;
      setState(() => _isListening = false);
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ölçüm için mikrofon izni gereklidir.')),
      );
      return;
    }

    try {
      _noiseSub = _noiseMeter.noise.listen(
        (NoiseReading reading) {
          final raw = reading.meanDecibel;
          if (!raw.isFinite) return;
          final calibrated = (raw + _calibrationOffset).clamp(20.0, 130.0);
          setState(() {
            _lastRawDb = raw;
            _currentDb = (_currentDb * 0.65) + (calibrated * 0.35);
          });
        },
        onError: (Object err) {
          setState(() => _isListening = false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Mikrofon hatası: $err')),
            );
          }
        },
        cancelOnError: true,
      );
      setState(() => _isListening = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Mikrofon başlatılamadı: $e')),
        );
      }
    }
  }

  void _toggleAutoStep(bool enabled) {
    setState(() => _autoStepEnabled = enabled);
    if (enabled) {
      _accelSub?.cancel();
      _accelSub = userAccelerometerEventStream().listen(
        (UserAccelerometerEvent e) {
          if (!_autoStepEnabled || _currentPos == null || !_isListening) return;
          final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
          final now = DateTime.now();
          if (mag > 2.2 &&
              now.difference(_lastAutoStepTime).inMilliseconds > 550) {
            _lastAutoStepTime = now;
            _stepForwardAndMeasure();
          }
        },
        onError: (_) {
          setState(() => _autoStepEnabled = false);
        },
      );
    } else {
      _accelSub?.cancel();
      _accelSub = null;
    }
  }

  void _quickSilentCalibration() {
    if (!_isListening) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Önce mikrofonu başlatın.')),
      );
      return;
    }
    final targetOffset = (35.0 - _lastRawDb).clamp(-40.0, 40.0);
    _saveCalibration(double.parse(targetOffset.toStringAsFixed(1)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Sessiz oda 35 dB olarak kalibre edildi (Ofset: ${targetOffset.toStringAsFixed(1)} dB)',
        ),
      ),
    );
  }

  void _onMapTap(TapDownDetails details, BoxConstraints constraints) {
    final nx = (details.localPosition.dx / constraints.maxWidth).clamp(0.02, 0.98);
    final ny = (details.localPosition.dy / constraints.maxHeight).clamp(0.02, 0.98);
    setState(() {
      _currentPos = Offset(nx, ny);
      if (_isListening) {
        _points.add(NoisePoint(
          nx: nx,
          ny: ny,
          db: _currentDb,
          timestamp: DateTime.now(),
        ));
      }
    });
  }

  void _stepForwardAndMeasure() {
    if (_currentPos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Önce kroki üzerine dokunup başlangıç noktasını seçin.'),
        ),
      );
      return;
    }

    final rad = _headingDeg * math.pi / 180.0;
    final stepMeters = _stepLengthCm / 100.0;
    final mapHeightMeters = _mapWidthMeters / _mapAspectRatio;

    final nextNx =
        (_currentPos!.dx + (stepMeters / _mapWidthMeters) * math.sin(rad))
            .clamp(0.02, 0.98);
    final nextNy =
        (_currentPos!.dy - (stepMeters / mapHeightMeters) * math.cos(rad))
            .clamp(0.02, 0.98);

    setState(() {
      _currentPos = Offset(nextNx, nextNy);
      _points.add(NoisePoint(
        nx: nextNx,
        ny: nextNy,
        db: _currentDb,
        timestamp: DateTime.now(),
      ));
    });
  }

  double get _leqDb {
    if (_points.isEmpty) return 0.0;
    final sumEnergy = _points.fold<double>(
      0.0,
      (sum, p) => sum + math.pow(10, p.db / 10.0).toDouble(),
    );
    return 10.0 * (math.log(sumEnergy / _points.length) / math.ln10);
  }

  double get _maxDb =>
      _points.isEmpty ? 0.0 : _points.map((p) => p.db).reduce(math.max);

  Color _colorForDb(double db) {
    if (db < 75) return const Color(0xFF22C55E);
    if (db < 80) return const Color(0xFFEAB308);
    if (db < 85) return const Color(0xFFF97316);
    return const Color(0xFFEF4444);
  }

  String _isgStatus(double db) {
    if (db < 75) return 'Güvenli';
    if (db < 80) return 'Dikkat';
    if (db < 85) return 'Eylem Değeri (KKD Hazır)';
    return 'Yüksek Risk (KKD Zorunlu)';
  }

  Future<void> _copyCsvToClipboard() async {
    if (_points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dışa aktarılacak ölçüm noktası yok.')),
      );
      return;
    }
    final buffer = StringBuffer();
    buffer.writeln('Nokta;X_Metre;Y_Metre;Gurultu_dB;ISG_Durum;Saat');
    final mapHeightMeters = _mapWidthMeters / _mapAspectRatio;
    for (int i = 0; i < _points.length; i++) {
      final p = _points[i];
      final xm = (p.nx * _mapWidthMeters).toStringAsFixed(2);
      final ym = (p.ny * mapHeightMeters).toStringAsFixed(2);
      final timeStr =
          '${p.timestamp.hour.toString().padLeft(2, '0')}:${p.timestamp.minute.toString().padLeft(2, '0')}:${p.timestamp.second.toString().padLeft(2, '0')}';
      buffer.writeln(
        '${i + 1};$xm;$ym;${p.db.toStringAsFixed(1)};${_isgStatus(p.db)};$timeStr',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_points.length} nokta CSV olarak panoya kopyalandı. Excel\'e yapıştırabilirsiniz.',
        ),
      ),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Ölçek & Kalibrasyon Ayarları',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Kalibrasyon Ofseti: ${_calibrationOffset.toStringAsFixed(1)} dB',
                  ),
                  Slider(
                    value: _calibrationOffset,
                    min: -40.0,
                    max: 40.0,
                    divisions: 160,
                    onChanged: (v) {
                      setModalState(() => _calibrationOffset = v);
                      _saveCalibration(v);
                    },
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _quickSilentCalibration();
                        setModalState(() {});
                      },
                      icon: const Icon(Icons.tune),
                      label: const Text('Sessiz Odada 35 dB\'e Eşitle'),
                    ),
                  ),
                  const Divider(height: 24),
                  Text(
                    'Kroki Gerçek Genişliği: ${_mapWidthMeters.toStringAsFixed(0)} m',
                  ),
                  Slider(
                    value: _mapWidthMeters,
                    min: 5.0,
                    max: 200.0,
                    divisions: 39,
                    onChanged: (v) {
                      setModalState(() => _mapWidthMeters = v);
                      setState(() {});
                    },
                  ),
                  Text('Adım Uzunluğunuz: ${_stepLengthCm.toStringAsFixed(0)} cm'),
                  Slider(
                    value: _stepLengthCm,
                    min: 40.0,
                    max: 110.0,
                    divisions: 14,
                    onChanged: (v) {
                      setModalState(() => _stepLengthCm = v);
                      setState(() {});
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = _colorForDb(_currentDb);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AkustikİSG Harita'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            tooltip: 'Kroki Yükle',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: _pickFloorPlan,
          ),
          IconButton(
            tooltip: 'CSV Kopyala',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyCsvToClipboard,
          ),
          IconButton(
            tooltip: 'Ayarlar ve Kalibrasyon',
            icon: const Icon(Icons.tune),
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: activeColor.withValues(alpha: 0.16),
                    border: Border.all(color: activeColor, width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _isListening
                            ? '${_currentDb.toStringAsFixed(1)} dB'
                            : '-- dB',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: activeColor,
                        ),
                      ),
                      Text(
                        _isListening ? _isgStatus(_currentDb) : 'Mikrofon Kapalı',
                        style: const TextStyle(fontSize: 10, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nokta: ${_points.length}  |  Leq: ${_leqDb.toStringAsFixed(1)} dB',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Maks: ${_maxDb.toStringAsFixed(1)} dB  |  Ofset: ${_calibrationOffset.toStringAsFixed(1)}',
                        style: const TextStyle(fontSize: 11, color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _toggleMicrophone,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isListening ? Colors.redAccent : const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  icon: Icon(_isListening ? Icons.stop : Icons.mic, size: 18),
                  label: Text(_isListening ? 'Dur' : 'Ölç'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: AspectRatio(
                  aspectRatio: _mapAspectRatio,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        onTapDown: (d) => _onMapTap(d, constraints),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (_floorPlanFile != null)
                                Image.file(_floorPlanFile!, fit: BoxFit.fill)
                              else
                                Container(color: const Color(0xFF0B1220)),
                              CustomPaint(
                                painter: HeatmapPainter(
                                  points: _points,
                                  currentPos: _currentPos,
                                  headingDeg: _headingDeg,
                                  hasFloorPlan: _floorPlanFile != null,
                                ),
                              ),
                              if (_currentPos == null)
                                Align(
                                  alignment: Alignment.topCenter,
                                  child: Container(
                                    margin: const EdgeInsets.only(top: 10),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color.fromARGB(200, 15, 23, 42),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text(
                                      'Başlamak için kroki üzerinde konumunuza dokunun',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
            color: const Color(0xFF1E293B),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _dirButton('K', 0),
                    _dirButton('D', 90),
                    _dirButton('G', 180),
                    _dirButton('B', 270),
                    const Spacer(),
                    const Text('Oto Adım', style: TextStyle(fontSize: 12)),
                    Switch(
                      value: _autoStepEnabled,
                      onChanged: _toggleAutoStep,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: () => setState(
                        () => _headingDeg = (_headingDeg - 45 + 360) % 360,
                      ),
                      icon: const Icon(Icons.rotate_left),
                      tooltip: '45° Sola Dön',
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: ElevatedButton.icon(
                          onPressed: _stepForwardAndMeasure,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.directions_walk),
                          label: Text(
                            '1 ADIM İLERİ & ÖLÇ (${_headingDeg.toInt()}°)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () => setState(
                        () => _headingDeg = (_headingDeg + 45) % 360,
                      ),
                      icon: const Icon(Icons.rotate_right),
                      tooltip: '45° Sağa Dön',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: _points.isEmpty
                          ? null
                          : () => setState(() {
                                _points.removeLast();
                                if (_points.isNotEmpty) {
                                  _currentPos = Offset(
                                    _points.last.nx,
                                    _points.last.ny,
                                  );
                                }
                              }),
                      icon: const Icon(Icons.undo, color: Colors.amber),
                      tooltip: 'Son Adımı Geri Al',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dirButton(String label, double angle) {
    final selected = (_headingDeg - angle).abs() < 1;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => setState(() => _headingDeg = angle),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 34,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: selected ? Colors.black : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class HeatmapPainter extends CustomPainter {
  final List<NoisePoint> points;
  final Offset? currentPos;
  final double headingDeg;
  final bool hasFloorPlan;

  HeatmapPainter({
    required this.points,
    required this.currentPos,
    required this.headingDeg,
    required this.hasFloorPlan,
  });

  Color _dbColor(double db) {
    if (db < 75) return const Color(0xFF22C55E);
    if (db < 80) return const Color(0xFFEAB308);
    if (db < 85) return const Color(0xFFF97316);
    return const Color(0xFFEF4444);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!hasFloorPlan) {
      final gridPaint = Paint()
        ..color = const Color.fromARGB(35, 148, 163, 184)
        ..strokeWidth = 1;
      for (int i = 1; i < 10; i++) {
        final dx = size.width * i / 10;
        final dy = size.height * i / 10;
        canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), gridPaint);
        canvas.drawLine(Offset(0, dy), Offset(size.width, dy), gridPaint);
      }
    }

    final radius = size.width * 0.11;
    for (final p in points) {
      final center = Offset(p.nx * size.width, p.ny * size.height);
      final base = _dbColor(p.db);

      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            base.withValues(alpha: 0.65),
            base.withValues(alpha: 0.30),
            base.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    if (points.length > 1) {
      final pathPaint = Paint()
        ..color = const Color.fromARGB(180, 255, 255, 255)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (int i = 0; i < points.length; i++) {
        final pt = Offset(points[i].nx * size.width, points[i].ny * size.height);
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(path, pathPaint);
    }

    for (final p in points) {
      final pt = Offset(p.nx * size.width, p.ny * size.height);
      canvas.drawCircle(pt, 4.0, Paint()..color = _dbColor(p.db));
      canvas.drawCircle(
        pt,
        4.0,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    if (currentPos != null) {
      final pos = Offset(currentPos!.dx * size.width, currentPos!.dy * size.height);
      final rad = headingDeg * math.pi / 180.0;
      final tip = Offset(
        pos.dx + math.sin(rad) * 20,
        pos.dy - math.cos(rad) * 20,
      );

      canvas.drawLine(
        pos,
        tip,
        Paint()
          ..color = const Color(0xFF38BDF8)
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(pos, 8, Paint()..color = const Color(0xFF38BDF8));
      canvas.drawCircle(
        pos,
        8,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HeatmapPainter oldDelegate) => true;
}
