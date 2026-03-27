import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
final _sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

const _wsUrl = 'wss://rt.nesine.com/socket.io/'
    '?platformid=1'
    '&userAgent=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20'
    'AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20'
    'Chrome%2F122.0.0.0%20Safari%2F537.36'
    '&EIO=4&transport=websocket';

// Nesine ST değerleri → status_short
const Map<int, String> _nesineStatusMap = {
  1:  '1H',
  2:  'HT',
  3:  '2H',
  4:  'ET',
  5:  'BT',
  6:  'P',
  7:  'FT',
  8:  'AET',
  9:  'PEN',
  10: 'PST',
  11: 'CANC',
};

// status_short → Türkçe uzun ad (raw_data.fixture.status.long için)
const Map<String, String> _statusLong = {
  '1H':   '1. Yarı',
  'HT':   'D.A.',
  '2H':   '2. Yarı',
  'ET':   'Uzatma',
  'BT':   'Uzatma D.A.',
  'P':    'Penaltılar',
  'FT':   'MS',
  'AET':  'MS (UZ)',
  'PEN':  'MS (PEN)',
  'PST':  'Ertelendi',
  'CANC': 'İptal',
  'NS':   'Başlamadı',
};

// nesine_bid → _SbMatch
final Map<int, _SbMatch> _matches = {};

int _goalCount = 0, _writeCount = 0;

// DB yazma throttle: fixture_id → son yazma zamanı
// Aynı maç için 30 saniyede bir yazma yap (dakika değişmese bile yazmayalım)
final Map<int, DateTime> _lastTickWrite = {};
final Map<int, int> _lastWrittenElapsed = {};
final Map<int, String> _lastWrittenStatus = {};

Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener v3         ║');
  print('║  ✅ Dakika + Status güncelleme eklendi║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) {
    print('❌ SUPABASE env eksik'); exit(1);
  }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'ok':      true,
        'version': 'v3',
        'matches': _matches.length,
        'goals':   _goalCount,
        'writes':  _writeCount,
      }))
      ..close());
    print('🌐 Health: :$port');
  });

  await _loadMatches();
  Timer.periodic(const Duration(minutes: 5), (_) => _loadMatches());
  Timer.periodic(const Duration(minutes: 5), (_) =>
      print('📊 Maç:${_matches.length} Gol:$_goalCount Yaz:$_writeCount'));

  unawaited(_wsLoop('A'));
  await Future.delayed(const Duration(seconds: 10));
  unawaited(_wsLoop('B'));

  await Completer<void>().future;
}

// ─── WS döngüsü ────────────────────────────────────────────────────────────
Future<void> _wsLoop(String name) async {
  while (true) {
    try {
      await _connect(name);
    } catch (e) {
      print('[$name] ❌ WS: $e');
    }
    print('[$name] 🔄 Koptu, HTTP poll başlıyor...');
    await _pollScores(name);
  }
}

// ─── WS bağlantısı ─────────────────────────────────────────────────────────
Future<void> _connect(String name) async {
  print('[$name] 🔌 Bağlanıyor...');
  WebSocketChannel? ws;
  Timer? ping;

  ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: {
    'Origin':        'https://www.nesine.com',
    'User-Agent':    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
    'Cache-Control': 'no-cache',
  });

  void send(String s) { try { ws?.sink.add(s); } catch (_) {} }

  try {
    await for (final raw in ws.stream) {
      final s = raw.toString();
      if (s == '2')           { send('3'); continue; }
      if (s == '3')           { continue; }
      if (s.startsWith('0'))  { send('40'); continue; }
      if (s.startsWith('40')) {
        print('[$name] ✅ Bağlandı');
        send('42["joinroom","LiveBets_V3"]');
        ping?.cancel();
        ping = Timer.periodic(const Duration(seconds: 20), (_) => send('2'));
        continue;
      }
      if (s.startsWith('42')) _onEvent(name, s.substring(2));
    }
  } catch (e) {
    print('[$name] [ERR] $e');
  }

  ping?.cancel();
  print('[$name] [WS] Kapandı code=${ws.closeCode}');
}

// ─── Event işle ────────────────────────────────────────────────────────────
void _onEvent(String name, String payload) {
  try {
    final list = jsonDecode(payload) as List;
    if (list[0] != 'LiveBets' || list[1] is! List) return;

    for (final item in list[1] as List) {
      if (item is! Map) continue;
      if ((item['sportype'] ?? '').toString().toLowerCase() != 'football') continue;
      final m = item['M'] as Map?;
      if (m == null) continue;
      final bid = _int(m['BID'] ?? item['bid']);
      if (bid == null) continue;

      final h  = _int(m['H']);
      final a  = _int(m['A']);
      final st = _int(m['ST']);  // Nesine durum kodu
      final t  = _int(m['T']);   // dakika

      if (h == null || a == null) continue;
      if (h > 30 || a > 30) continue;
      if (m.containsKey('EN')) continue;
      if (!m.containsKey('TS')) continue;
      if (st != 1 && st != 2 && st != 3 && st != 4 && st != 5 && st != 6) continue;

      // Gol kontrolü
      _onScore(name, bid, m, h, a, t);

      // Dakika + status güncelle (throttled)
      if (t != null || st != null) {
        _onTick(bid, h, a, t, st);
      }
    }
  } catch (_) {}
}

// ─── Gol ───────────────────────────────────────────────────────────────────
void _onScore(String name, int bid, Map m, int newH, int newA, int? min) {
  final match = _matches[bid];
  if (match == null) return;

  if (newH == match.homeScore && newA == match.awayScore) return;

  _goalCount++;
  print('[$name] ⚽ GOL! bid=$bid ${match.homeTeam} '
      '${match.homeScore}-${match.awayScore} → $newH-$newA'
      '${min != null ? " ($min\')" : ""}');

  match.homeScore = newH;
  match.awayScore = newA;

  final statusShort = _nesineStatusMap[_int(m['ST'])] ?? '1H';

  _sbPatch(match.fixtureId, {
    'home_score':   newH,
    'away_score':   newA,
    'score_source': 'nesine',
    'status_short': statusShort,
    if (min != null) 'elapsed_time': min,
    'updated_at':   DateTime.now().toIso8601String(),
  }, updateRawData: true, statusShort: statusShort, elapsed: min);
}

// ─── Dakika + status tick (throttled) ──────────────────────────────────────
// Her dakika değiştiğinde yaz, ama aynı dakikayı 30 saniyeden önce tekrar yazma.
// Bu sayede frontend dakikayı gerçek zamanlı görür (gol olmasa da).
void _onTick(int bid, int h, int a, int? t, int? stCode) {
  final match = _matches[bid];
  if (match == null) return;

  final statusShort = _nesineStatusMap[stCode] ?? '1H';
  final lastElapsed = _lastWrittenElapsed[match.fixtureId];
  final lastStatus  = _lastWrittenStatus[match.fixtureId];
  final lastWrite   = _lastTickWrite[match.fixtureId];
  final now         = DateTime.now();

  // Dakika veya status değişmediyse ve 30 saniye geçmediyse yazma
  final elapsedChanged = t != null && t != lastElapsed;
  final statusChanged  = statusShort != lastStatus;
  final throttleOk     = lastWrite == null ||
      now.difference(lastWrite).inSeconds >= 30;

  if (!elapsedChanged && !statusChanged) return;
  if (!throttleOk) return;

  _lastTickWrite[match.fixtureId]     = now;
  _lastWrittenElapsed[match.fixtureId] = t ?? lastElapsed ?? 0;
  _lastWrittenStatus[match.fixtureId]  = statusShort;

  _sbPatch(match.fixtureId, {
    'status_short': statusShort,
    if (t != null) 'elapsed_time': t,
    'updated_at':  now.toIso8601String(),
  }, updateRawData: true, statusShort: statusShort, elapsed: t);
}

// ─── HTTP Poll ─────────────────────────────────────────────────────────────
Future<void> _pollScores(String name) async {
  if (_matches.isEmpty) return;
  try {
    final ids = _matches.values.map((m) => m.fixtureId).join(',');
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_score,away_score'
          '&fixture_id=in.($ids)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 8));

    if (res.statusCode != 200) return;
    final rows = (jsonDecode(res.body) as List).cast<Map>();

    for (final r in rows) {
      final fid = _int(r['fixture_id']);
      final dbH = _int(r['home_score']) ?? 0;
      final dbA = _int(r['away_score']) ?? 0;
      if (fid == null) continue;

      final entry = _matches.entries
          .where((e) => e.value.fixtureId == fid)
          .firstOrNull;
      if (entry == null) continue;

      final match = entry.value;
      if (dbH != match.homeScore || dbA != match.awayScore) {
        print('[$name] ⚠️ Poll tutarsızlık! fid=$fid '
            'local=${match.homeScore}-${match.awayScore} db=$dbH-$dbA → güncellendi');
        match.homeScore = dbH;
        match.awayScore = dbA;
      }
    }
  } catch (e) {
    print('[$name] ⚠️ poll: $e');
  }
}

// ─── Supabase ──────────────────────────────────────────────────────────────
Future<void> _loadMatches() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,'
          'nesine_bid,raw_data'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'
          '&nesine_bid=not.is.null'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) return;
    final rows = (jsonDecode(res.body) as List).cast<Map>();

    _matches.clear();
    for (final r in rows) {
      final bid = _int(r['nesine_bid']);
      if (bid == null) continue;
      _matches[bid] = _SbMatch(
        fixtureId: r['fixture_id'] as int,
        homeTeam:  (r['home_team'] ?? '').toString(),
        awayTeam:  (r['away_team'] ?? '').toString(),
        homeScore: _int(r['home_score']) ?? 0,
        awayScore: _int(r['away_score']) ?? 0,
        rawData:   r['raw_data'] as String? ?? '{}',
      );
    }
    print('📋 ${_matches.length} maç yüklendi');
    for (final e in _matches.entries) {
      print('   bid=${e.key} → ${e.value.homeTeam} vs ${e.value.awayTeam}');
    }
  } catch (e) {
    print('⚠️ loadMatches: $e');
  }
}

Future<void> _sbPatch(
  int fid,
  Map<String, dynamic> data, {
  bool updateRawData = false,
  String? statusShort,
  int? elapsed,
}) async {
  // raw_data.fixture.status güncelle — frontend dakikayı buradan okuyor
  if (updateRawData && statusShort != null) {
    final match = _matches.values.where((m) => m.fixtureId == fid).firstOrNull;
    if (match != null) {
      try {
        final raw = Map<String, dynamic>.from(
            jsonDecode(match.rawData) as Map);
        (raw['fixture'] as Map)['status'] = {
          'long':    _statusLong[statusShort] ?? statusShort,
          'short':   statusShort,
          'elapsed': elapsed,
          'extra':   null,
        };
        if (statusShort != 'HT' && statusShort != 'FT') {
          // goals da güncelle
          raw['goals'] = {'home': match.homeScore, 'away': match.awayScore};
        }
        data['raw_data'] = jsonEncode(raw);
        // Local cache güncelle
        match.rawData = data['raw_data'] as String;
      } catch (_) {}
    }
  }

  try {
    final res = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode < 300) _writeCount++;
    else print('❌ SB $fid: ${res.statusCode}');
  } catch (e) { print('❌ SB: $e'); }
}

Map<String, String> _sbHeaders() => {
  'apikey': _sbKey, 'Authorization': 'Bearer $_sbKey',
  'Prefer': 'return=minimal',
};

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse(v.toString());
}

class _SbMatch {
  final int fixtureId;
  final String homeTeam, awayTeam;
  int homeScore, awayScore;
  String rawData;

  _SbMatch({
    required this.fixtureId,
    required this.homeTeam,
    required this.awayTeam,
    required this.homeScore,
    required this.awayScore,
    required this.rawData,
  });
}
