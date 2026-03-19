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

// nesine_bid → _SbMatch
final Map<int, _SbMatch> _matches = {};

int _goalCount = 0, _writeCount = 0;

Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener v2         ║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) {
    print('❌ SUPABASE env eksik'); exit(1);
  }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, 'matches': _matches.length,
          'goals': _goalCount, 'writes': _writeCount}))
      ..close());
    print('🌐 Health: :$port');
  });

  await _loadMatches();
  Timer.periodic(const Duration(minutes: 5), (_) => _loadMatches());
  Timer.periodic(const Duration(minutes: 5), (_) =>
    print('📊 Maç:${_matches.length} Gol:$_goalCount Yaz:$_writeCount'));


  // A hemen, B 10 saniye sonra başlar
  // 10s offset: sunucu aynı anda kesse bile reconnect'ler çakışmaz
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
    // Kopunca hemen HTTP poll yap — WS'de kaçırılan golü yakala
    print('[$name] 🔄 Koptu, HTTP poll başlıyor...');
    await _pollScores(name);
    // Hiç bekleme yok — hemen yeniden bağlan
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

      final h = _int(m['H']);
      final a = _int(m['A']);
      if (h == null || a == null) continue;
      if (h > 30 || a > 30) continue;
      if (m.containsKey('EN')) continue;
      if (!m.containsKey('TS')) continue;
      if (m['ST'] != 1) continue;

      _onScore(name, bid, m);
    }
  } catch (_) {}
}

// ─── Skor değişimi ─────────────────────────────────────────────────────────
void _onScore(String name, int bid, Map m) {
  final match = _matches[bid];
  if (match == null) return;

  final newH = _int(m['H'])!;
  final newA = _int(m['A'])!;
  final min  = _int(m['T']);

  if (newH == match.homeScore && newA == match.awayScore) return;

  _goalCount++;
  print('[$name] ⚽ GOL! bid=$bid ${match.homeTeam} '
      '${match.homeScore}-${match.awayScore} → $newH-$newA'
      '${min != null ? " ($min\')" : ""}');

  match.homeScore = newH;
  match.awayScore = newA;

  _sbPatch(match.fixtureId, {
    'home_score':   newH,
    'away_score':   newA,
    'score_source': 'nesine',
    if (min != null) 'elapsed_time': min,
    'updated_at':   DateTime.now().toIso8601String(),
  });
}

// ─── HTTP Poll: kopunca skoru doğrudan Nesine'den çek ──────────────────────
// Nesine'nin REST endpoint'i varsa buraya ekle.
// Yoksa Supabase'deki mevcut skorla karşılaştır — en azından tutarsızlık tespit edilir.
Future<void> _pollScores(String name) async {
  if (_matches.isEmpty) return;
  try {
    // Supabase'den güncel skoru çek ve local state ile karşılaştır
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
      final fid  = _int(r['fixture_id']);
      final dbH  = _int(r['home_score']) ?? 0;
      final dbA  = _int(r['away_score']) ?? 0;
      if (fid == null) continue;

      // Local map'te bul
      final entry = _matches.entries
          .where((e) => e.value.fixtureId == fid)
          .firstOrNull;
      if (entry == null) continue;

      final match = entry.value;
      if (dbH != match.homeScore || dbA != match.awayScore) {
        print('[$name] ⚠️ Poll tutarsızlık! fid=$fid '
            'local=${match.homeScore}-${match.awayScore} '
            'db=$dbH-$dbA → local güncellendi');
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
          '?select=fixture_id,home_team,away_team,home_score,away_score,nesine_bid'
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

Future<void> _sbPatch(int fid, Map<String, dynamic> data) async {
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
  _SbMatch({required this.fixtureId, required this.homeTeam,
      required this.awayTeam, required this.homeScore, required this.awayScore});
}
