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

// ── Nesine M.ST (int) → status_short ────────────────────────────
const Map<int, String> _nesineStMap = {
  1: '1H', 2: 'HT', 3: '2H', 4: 'ET', 5: 'BT', 6: 'P',
  7: 'FT', 8: 'AET', 9: 'PEN', 10: 'PST', 11: 'CANC',
};

// ── MT:1 item.ST (string) → status_short ────────────────────────
// scoreboard.store'da görülen string değerler
const Map<String, String> _nesineStStrMap = {
  'MS':  '1H',   // Match Start
  'HT':  'HT',   // Half Time
  'SH':  '2H',   // Second Half
  'MS2': '2H',
  'FT':  'FT',   // Full Time
  'ET':  'ET',   // Extra Time
  'PEN': 'PEN',
  'PST': 'PST',
  'CANC':'CANC',
};

// ── status_short → Türkçe ────────────────────────────────────────
const Map<String, String> _statusLong = {
  '1H': '1. Yarı', 'HT': 'D.A.',   '2H': '2. Yarı',
  'ET': 'Uzatma',  'BT': 'Uzatma D.A.', 'P': 'Penaltılar',
  'FT': 'MS', 'AET': 'MS (UZ)', 'PEN': 'MS (PEN)',
  'PST': 'Ertelendi', 'CANC': 'İptal', 'NS': 'Başlamadı',
};

final Map<int, _SbMatch> _matches = {};
int _goalCount = 0, _writeCount = 0;

final Map<int, DateTime> _lastTickWrite = {};
final Map<int, int>      _lastElapsed   = {};
final Map<int, String>   _lastStatus    = {};

Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener v4         ║');
  print('║  MT:11=skor  MT:1=durum  MT:21=oran  ║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) { print('❌ SUPABASE env eksik'); exit(1); }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, 'v': 4, 'matches': _matches.length,
          'goals': _goalCount, 'writes': _writeCount}))
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

Future<void> _wsLoop(String name) async {
  while (true) {
    try { await _connect(name); } catch (e) { print('[$name] ❌ $e'); }
    print('[$name] 🔄 Koptu → poll...');
    await _pollScores(name);
  }
}

Future<void> _connect(String name) async {
  print('[$name] 🔌 Bağlanıyor...');
  final ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: {
    'Origin': 'https://www.nesine.com',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
    'Cache-Control': 'no-cache',
  });
  Timer? ping;
  void send(String s) { try { ws.sink.add(s); } catch (_) {} }
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
  } catch (e) { print('[$name] [ERR] $e'); }
  ping?.cancel();
  print('[$name] [WS] Kapandı code=${ws.closeCode}');
}

// ─── Ana event router ──────────────────────────────────────────
// Nesine WS'de 3 önemli MT tipi:
//   MT:21 → ODD güncelleme  (H/A = oran değerleri, > 30 olabilir)
//   MT:11 → Skor/dakika     (H/A = gerçek skor 0-30, T = dakika, M.ST = durum)
//   MT:1  → Maç durum       (item.S veya item.ST = durum string/kodu)
void _onEvent(String name, String payload) {
  try {
    final list = jsonDecode(payload) as List;
    if (list[0] != 'LiveBets' || list[1] is! List) return;

    for (final item in list[1] as List) {
      if (item is! Map) continue;
      if ((item['sportype'] ?? '').toString().toLowerCase() != 'football') continue;

      final mt  = _int(item['MT']);
      final m   = item['M'] as Map?;
      final bid = _int(m?['BID'] ?? item['bid']);
      if (bid == null) continue;

      if (mt == 1) {
        // Maç durum değişikliği (başlama, devre, bitiş)
        _onStatusEvent(name, bid, item);
      } else if (m != null) {
        // Skor event'i: M içinde TS varsa VE H/A <= 30 ise gerçek skor
        // MT:21 odds eventleri TS içermez → filtreden geçmez
        _onScoreEvent(name, bid, m);
      }
    }
  } catch (_) {}
}

// ─── Skor / dakika eventi ──────────────────────────────────────
void _onScoreEvent(String name, int bid, Map m) {
  // Güvenlik filtreleri (eski listener ile aynı mantık)
  if (!m.containsKey('TS')) return;    // MT:21 odds eventlerinde TS yok
  if (m.containsKey('EN')) return;     // Bitti işareti

  final h = _int(m['H']);
  final a = _int(m['A']);
  if (h == null || a == null) return;
  if (h > 30 || a > 30) return;       // Oran değerleri, skor değil

  final stCode      = _int(m['ST']);
  final t           = _int(m['T']);
  final statusShort = stCode != null ? _nesineStMap[stCode] : null;
  final match       = _matches[bid];
  if (match == null) return;

  final scoreChanged = h != match.homeScore || a != match.awayScore;

  if (scoreChanged) {
    _goalCount++;
    print('[$name] ⚽ GOL! bid=$bid ${match.homeTeam} '
        '${match.homeScore}-${match.awayScore} → $h-$a'
        '${t != null ? " ($t\')" : ""}');
    match.homeScore = h;
    match.awayScore = a;
    _patch(match, {
      'home_score': h, 'away_score': a, 'score_source': 'nesine',
      if (statusShort != null) 'status_short': statusShort,
      if (t != null) 'elapsed_time': t,
      'updated_at': DateTime.now().toIso8601String(),
    }, statusShort: statusShort, elapsed: t);
  } else {
    _tickUpdate(match, statusShort, t);
  }
}

// ─── MT:1: Maç durum değişikliği ──────────────────────────────
void _onStatusEvent(String name, int bid, Map item) {
  final match = _matches[bid];
  if (match == null) return;

  // item.ST = string ('MS','HT','FT'...) veya item.S = int kod
  final stStr  = (item['ST'] ?? item['STL'] ?? '').toString().toUpperCase().trim();
  final stCode = _int(item['S']);

  String? statusShort = _nesineStStrMap[stStr];
  if (statusShort == null && stCode != null) statusShort = _nesineStMap[stCode];
  if (statusShort == null) return;   // Tanımadığımız durum, atla

  final prevStatus = _lastStatus[match.fixtureId] ?? 'NS';
  if (statusShort == prevStatus) return;  // Aynı durum, tekrar yazma

  print('[$name] 📌 bid=$bid $prevStatus → $statusShort ($stStr)');

  if (_isFinished(statusShort)) {
    print('[$name] 🏁 bid=$bid bitti → siliniyor');
    http.delete(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.${match.fixtureId}'),
      headers: _sbHeaders(),
    ).ignore();
    _matches.remove(bid);
    return;
  }

  _lastStatus[match.fixtureId] = statusShort;
  _patch(match, {
    'status_short': statusShort,
    'updated_at': DateTime.now().toIso8601String(),
  }, statusShort: statusShort, elapsed: _lastElapsed[match.fixtureId]);
}

// ─── Throttled tick (dakika değişince) ────────────────────────
void _tickUpdate(_SbMatch match, String? statusShort, int? t) {
  final fid = match.fixtureId;
  final now = DateTime.now();

  final elapsedChanged = t != null && t != _lastElapsed[fid];
  final statusChanged  = statusShort != null && statusShort != _lastStatus[fid];

  // Hiçbir şey değişmediyse yazma
  if (!elapsedChanged && !statusChanged) return;
  // Sadece dakika değiştiyse (status yok) → 30s throttle uygula
  if (elapsedChanged && !statusChanged &&
      _lastTickWrite[fid] != null &&
      now.difference(_lastTickWrite[fid]!).inSeconds < 30) return;

  _lastTickWrite[fid] = now;
  if (t != null)           _lastElapsed[fid] = t;
  if (statusShort != null) _lastStatus[fid]  = statusShort;

  // ST gelmese bile mevcut status'u kullan — dakikayı yine de yaz
  final effectiveStatus = statusShort ?? _lastStatus[fid];
  final data = <String, dynamic>{'updated_at': now.toIso8601String()};
  if (effectiveStatus != null) data['status_short'] = effectiveStatus;
  if (t != null)               data['elapsed_time'] = t;
  _patch(match, data, statusShort: effectiveStatus, elapsed: t);
}

// ─── DB güncelle + raw_data.fixture.status ────────────────────
Future<void> _patch(_SbMatch match, Map<String, dynamic> data,
    {String? statusShort, int? elapsed}) async {
  if (statusShort != null) {
    try {
      final raw = Map<String, dynamic>.from(jsonDecode(match.rawData) as Map);
      final eff = elapsed ?? _lastElapsed[match.fixtureId];
      (raw['fixture'] as Map)['status'] = {
        'long': _statusLong[statusShort] ?? statusShort,
        'short': statusShort, 'elapsed': eff, 'extra': null,
      };
      raw['goals'] = {'home': match.homeScore, 'away': match.awayScore};
      data['raw_data'] = jsonEncode(raw);
      match.rawData = data['raw_data'] as String;
    } catch (_) {}
  }
  try {
    final res = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.${match.fixtureId}'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode < 300) _writeCount++;
    else print('❌ SB ${match.fixtureId}: ${res.statusCode}');
  } catch (e) { print('❌ SB: $e'); }
}

Future<void> _pollScores(String name) async {
  if (_matches.isEmpty) return;
  try {
    final ids = _matches.values.map((m) => m.fixtureId).join(',');
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_score,away_score&fixture_id=in.($ids)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return;
    for (final r in (jsonDecode(res.body) as List).cast<Map>()) {
      final fid = _int(r['fixture_id']); if (fid == null) continue;
      final e = _matches.entries.where((x) => x.value.fixtureId == fid).firstOrNull;
      if (e == null) continue;
      final dbH = _int(r['home_score']) ?? 0;
      final dbA = _int(r['away_score']) ?? 0;
      if (dbH != e.value.homeScore || dbA != e.value.awayScore) {
        print('[$name] ⚠️ Poll tutarsız fid=$fid → $dbH-$dbA');
        e.value.homeScore = dbH;
        e.value.awayScore = dbA;
      }
    }
  } catch (e) { print('[$name] ⚠️ poll: $e'); }
}

Future<void> _loadMatches() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,'
          'nesine_bid,raw_data,status_short'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'
          '&nesine_bid=not.is.null'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    _matches.clear();
    for (final r in (jsonDecode(res.body) as List).cast<Map>()) {
      final bid = _int(r['nesine_bid']); if (bid == null) continue;
      final fid = r['fixture_id'] as int;
      _matches[bid] = _SbMatch(
        fixtureId: fid,
        homeTeam:  (r['home_team'] ?? '').toString(),
        awayTeam:  (r['away_team'] ?? '').toString(),
        homeScore: _int(r['home_score']) ?? 0,
        awayScore: _int(r['away_score']) ?? 0,
        rawData:   r['raw_data'] as String? ?? '{}',
      );
      _lastStatus[fid] = (r['status_short'] as String?) ?? 'NS';
    }
    print('📋 ${_matches.length} maç yüklendi');
    for (final e in _matches.entries) {
      print('   bid=${e.key} → ${e.value.homeTeam} vs ${e.value.awayTeam}'
          ' [${_lastStatus[e.value.fixtureId]}]');
    }
  } catch (e) { print('⚠️ loadMatches: $e'); }
}

bool _isFinished(String s) =>
    ['FT','AET','PEN','PST','CANC','ABD','AWD','WO'].contains(s);

Map<String, String> _sbHeaders() =>
    {'apikey': _sbKey, 'Authorization': 'Bearer $_sbKey', 'Prefer': 'return=minimal'};

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
  _SbMatch({required this.fixtureId, required this.homeTeam,
      required this.awayTeam, required this.homeScore,
      required this.awayScore, required this.rawData});
}
