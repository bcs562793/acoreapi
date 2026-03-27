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

// Nesine M.ST (int) → status_short
const Map<int, String> _nesineStMap = {
  1: '1H', 2: 'HT', 3: '2H', 4: 'ET', 5: 'BT', 6: 'P',
  7: 'FT', 8: 'AET', 9: 'PEN', 10: 'PST', 11: 'CANC',
};

// MT:1 item.ST (string) → status_short
const Map<String, String> _nesineStStrMap = {
  'MS': '1H', 'HT': 'HT', 'SH': '2H', 'MS2': '2H',
  'FT': 'FT', 'ET': 'ET', 'PEN': 'PEN', 'PST': 'PST', 'CANC': 'CANC',
};

// status_short → Türkçe
const Map<String, String> _statusLong = {
  '1H': '1. Yarı', 'HT': 'D.A.',   '2H': '2. Yarı',
  'ET': 'Uzatma',  'BT': 'Uzatma D.A.', 'P': 'Penaltılar',
  'FT': 'MS', 'AET': 'MS (UZ)', 'PEN': 'MS (PEN)',
  'PST': 'Ertelendi', 'CANC': 'İptal', 'NS': 'Başlamadı',
};

final Map<int, _SbMatch> _matches = {};
int _goalCount = 0, _writeCount = 0;

// ─── Elapsed timer state (per fixtureId) ──────────────────────
// Her maç için hangi fazda ne zaman başladığını tutarız.
// Elapsed = sabit_offset + (şimdi - faz_başlangıcı).inMinutes
class _MatchTimer {
  String status;          // '1H','HT','2H','ET','BT','FT' vb.
  DateTime? phaseStart;   // Bu fazın başlama zamanı (duraklatılınca null)
  int frozenElapsed;      // Duraklama anındaki dakika (HT=45, 2H başı vb.)

  _MatchTimer({required this.status, this.phaseStart, this.frozenElapsed = 0});

  // Anlık elapsed dakikası
  int get elapsed {
    if (phaseStart == null) return frozenElapsed; // Duraklı (HT, BT)
    final running = DateTime.now().difference(phaseStart!).inMinutes;
    return frozenElapsed + running;
  }

  // Gerçek skor eventinden gelen dakika ile timer'ı kalibre et
  void calibrate(int realMinute) {
    if (phaseStart == null) {
      frozenElapsed = realMinute;
      return;
    }
    // phaseStart'ı geriye götür ki elapsed = realMinute olsun
    final offset = frozenElapsed;
    final diff   = realMinute - offset;
    phaseStart   = DateTime.now().subtract(Duration(minutes: diff));
  }
}

final Map<int, _MatchTimer> _timers = {}; // fixtureId → timer

// Timer güncellemesi: her 60 saniyede bir çalışır
late Timer _tickTimer;

// Throttle: son DB yazma zamanı
final Map<int, DateTime> _lastWrite = {};

// ─────────────────────────────────────────────────────────────────
Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener v5         ║');
  print('║  ⏱  Elapsed kendi hesaplanıyor       ║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) { print('❌ SUPABASE env eksik'); exit(1); }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, 'v': 5, 'matches': _matches.length,
          'goals': _goalCount, 'writes': _writeCount,
          'timers': _timers.map((k,v) => MapEntry('$k',
              '${v.status} ${v.elapsed}\'')),
      }))
      ..close());
    print('🌐 Health: :$port');
  });

  await _loadMatches();
  Timer.periodic(const Duration(minutes: 5), (_) => _loadMatches());
  Timer.periodic(const Duration(minutes: 5), (_) =>
      print('📊 Maç:${_matches.length} Gol:$_goalCount Yaz:$_writeCount'));

  // Her 60 saniyede DB'ye elapsed yaz (aktif maçlar için)
  _tickTimer = Timer.periodic(const Duration(seconds: 60), (_) => _writeTick());

  unawaited(_wsLoop('A'));
  await Future.delayed(const Duration(seconds: 10));
  unawaited(_wsLoop('B'));
  await Completer<void>().future;
}

// ─── WS ────────────────────────────────────────────────────────
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

// ─── Event router ──────────────────────────────────────────────
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
        _onStatusEvent(name, bid, item);
      } else if (m != null) {
        _onScoreEvent(name, bid, m);
      }
    }
  } catch (_) {}
}

// ─── Skor + dakika eventi ──────────────────────────────────────
void _onScoreEvent(String name, int bid, Map m) {
  if (!m.containsKey('TS')) return;   // MT:21 odds eventleri TS içermez
  if (m.containsKey('EN')) return;

  final h = _int(m['H']);
  final a = _int(m['A']);
  if (h == null || a == null) return;
  if (h > 30 || a > 30) return;       // Oran değerleri

  final stCode = _int(m['ST']);
  final t      = _int(m['T']);         // Nesine'den gelen dakika (kalibraasyon için)
  final statusShort = stCode != null ? _nesineStMap[stCode] : null;
  final match  = _matches[bid];
  if (match == null) return;
  final fid    = match.fixtureId;

  // Status geçişi varsa timer güncelle
  if (statusShort != null) {
    _applyStatusTransition(fid, statusShort);
  }

  // Nesine dakikası varsa timer'ı kalibre et
  if (t != null) {
    _timers[fid]?.calibrate(t);
  }

  final scoreChanged = h != match.homeScore || a != match.awayScore;
  if (scoreChanged) {
    _goalCount++;
    final elapsed = _timers[fid]?.elapsed ?? t ?? 0;
    print('[$name] ⚽ GOL! bid=$bid ${match.homeTeam} '
        '${match.homeScore}-${match.awayScore} → $h-$a ($elapsed\')');
    match.homeScore = h;
    match.awayScore = a;
    _writeMatch(match, statusShort: statusShort ?? _timers[fid]?.status, forceScore: true);
  }
}

// ─── MT:1: Durum değişikliği ──────────────────────────────────
void _onStatusEvent(String name, int bid, Map item) {
  final match = _matches[bid];
  if (match == null) return;

  final stStr  = (item['ST'] ?? item['STL'] ?? '').toString().toUpperCase().trim();
  final stCode = _int(item['S']);
  String? statusShort = _nesineStStrMap[stStr];
  if (statusShort == null && stCode != null) statusShort = _nesineStMap[stCode];
  if (statusShort == null) return;

  final fid    = match.fixtureId;
  final prev   = _timers[fid]?.status ?? 'NS';
  if (statusShort == prev) return;

  print('[$name] 📌 bid=$bid $prev → $statusShort');
  _applyStatusTransition(fid, statusShort);

  if (_isFinished(statusShort)) {
    print('[$name] 🏁 bid=$bid bitti → siliniyor');
    http.delete(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: _sbHeaders(),
    ).ignore();
    _matches.remove(bid);
    _timers.remove(fid);
    return;
  }

  _writeMatch(match, statusShort: statusShort);
}

// ─── Timer geçiş mantığı ──────────────────────────────────────
//
//  NS  → 1H : timer başlar (offset=0)
//  1H  → HT : timer durur  (offset=45)
//  HT  → 2H : timer başlar (offset=45)
//  2H  → ET : timer durur  (offset=90)
//  ET  → BT : timer durur  (offset=105 veya mevcut)
//  BT  → P  : timer durur
//  *   → FT/AET/PEN : timer durur
//
void _applyStatusTransition(int fid, String newStatus) {
  final timer = _timers[fid];
  final prev  = timer?.status ?? 'NS';
  if (prev == newStatus) return;

  switch (newStatus) {
    case '1H':
      // Maç başladı — sıfırdan say
      _timers[fid] = _MatchTimer(
        status: '1H',
        phaseStart: DateTime.now(),
        frozenElapsed: 0,
      );
    case 'HT':
      // Devre arası — 45'te dondur
      _timers[fid] = _MatchTimer(
        status: 'HT',
        phaseStart: null,         // Duraklı
        frozenElapsed: 45,
      );
    case '2H':
      // İkinci yarı — 45'ten devam
      _timers[fid] = _MatchTimer(
        status: '2H',
        phaseStart: DateTime.now(),
        frozenElapsed: 45,
      );
    case 'ET':
      // Uzatma — 90'dan say
      final current = timer?.elapsed ?? 90;
      _timers[fid] = _MatchTimer(
        status: 'ET',
        phaseStart: DateTime.now(),
        frozenElapsed: current >= 90 ? current : 90,
      );
    case 'BT':
      // Uzatma devresi arası — dondur
      final current = timer?.elapsed ?? 105;
      _timers[fid] = _MatchTimer(
        status: 'BT',
        phaseStart: null,
        frozenElapsed: current,
      );
    case 'P':
      _timers[fid] = _MatchTimer(status: 'P', phaseStart: null, frozenElapsed: 120);
    default:
      // FT, AET, PEN, PST, CANC — dondur
      final current = timer?.elapsed ?? 0;
      _timers[fid] = _MatchTimer(
        status: newStatus,
        phaseStart: null,
        frozenElapsed: current,
      );
  }
}

// ─── Her 60 saniyede aktif maçlara elapsed yaz ────────────────
Future<void> _writeTick() async {
  final now = DateTime.now();
  for (final entry in _matches.entries) {
    final bid   = entry.key;
    final match = entry.value;
    final fid   = match.fixtureId;
    final timer = _timers[fid];
    if (timer == null) continue;

    // Duraklamalı statuslarda (HT, BT) tick yazmaya gerek yok
    if (timer.phaseStart == null) continue;
    if (_isFinished(timer.status)) continue;

    // 50s'den önce yazmadık mı? (60s timer'dan biraz önce)
    final last = _lastWrite[fid];
    if (last != null && now.difference(last).inSeconds < 50) continue;

    _writeMatch(match, statusShort: timer.status);
  }
}

// ─── DB yaz ───────────────────────────────────────────────────
Future<void> _writeMatch(
  _SbMatch match, {
  String? statusShort,
  bool forceScore = false,
}) async {
  final fid     = match.fixtureId;
  final timer   = _timers[fid];
  final elapsed = timer?.elapsed;
  final status  = statusShort ?? timer?.status;
  _lastWrite[fid] = DateTime.now();

  final data = <String, dynamic>{
    'updated_at': DateTime.now().toIso8601String(),
    if (status  != null) 'status_short': status,
    if (elapsed != null) 'elapsed_time': elapsed,
    if (forceScore) ...{
      'home_score': match.homeScore,
      'away_score': match.awayScore,
      'score_source': 'nesine',
    },
  };

  // raw_data.fixture.status güncelle
  if (status != null) {
    try {
      final raw = Map<String, dynamic>.from(jsonDecode(match.rawData) as Map);
      (raw['fixture'] as Map)['status'] = {
        'long':    _statusLong[status] ?? status,
        'short':   status,
        'elapsed': elapsed,
        'extra':   null,
      };
      if (forceScore) {
        raw['goals'] = {'home': match.homeScore, 'away': match.awayScore};
      }
      data['raw_data'] = jsonEncode(raw);
      match.rawData    = data['raw_data'] as String;
    } catch (_) {}
  }

  try {
    final res = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode < 300) {
      _writeCount++;
      if (elapsed != null) print('   ⏱  fid=$fid $status $elapsed\'');
    } else {
      print('❌ SB $fid: ${res.statusCode}');
    }
  } catch (e) { print('❌ SB: $e'); }
}

// ─── HTTP Poll ─────────────────────────────────────────────────
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
      e.value.homeScore = _int(r['home_score']) ?? e.value.homeScore;
      e.value.awayScore = _int(r['away_score']) ?? e.value.awayScore;
    }
  } catch (e) { print('[$name] ⚠️ poll: $e'); }
}

// ─── Supabase: maçları yükle ──────────────────────────────────
Future<void> _loadMatches() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,'
          'nesine_bid,raw_data,status_short,elapsed_time'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'
          '&nesine_bid=not.is.null'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;

    // Yeni maçları ekle, mevcut timer'ları koru
    final newBids = <int>{};
    for (final r in (jsonDecode(res.body) as List).cast<Map>()) {
      final bid = _int(r['nesine_bid']); if (bid == null) continue;
      newBids.add(bid);
      final fid     = r['fixture_id'] as int;
      final status  = (r['status_short'] as String?) ?? 'NS';
      final elapsed = _int(r['elapsed_time']);

      if (!_matches.containsKey(bid)) {
        _matches[bid] = _SbMatch(
          fixtureId: fid,
          homeTeam:  (r['home_team'] ?? '').toString(),
          awayTeam:  (r['away_team'] ?? '').toString(),
          homeScore: _int(r['home_score']) ?? 0,
          awayScore: _int(r['away_score']) ?? 0,
          rawData:   r['raw_data'] as String? ?? '{}',
        );
      } else {
        // Skor güncelle, rawData'yı koru
        _matches[bid]!.homeScore = _int(r['home_score']) ?? _matches[bid]!.homeScore;
        _matches[bid]!.awayScore = _int(r['away_score']) ?? _matches[bid]!.awayScore;
      }

      // Timer yoksa DB'deki duruma göre başlat
      if (!_timers.containsKey(fid)) {
        _initTimerFromDb(fid, status, elapsed);
      }
    }

    // Artık listede olmayan maçları temizle
    _matches.removeWhere((bid, _) => !newBids.contains(bid));

    print('📋 ${_matches.length} maç yüklendi');
    for (final e in _matches.entries) {
      final t = _timers[e.value.fixtureId];
      print('   bid=${e.key} → ${e.value.homeTeam} vs ${e.value.awayTeam}'
          ' [${t?.status ?? "?"} ${t?.elapsed ?? 0}\']');
    }
  } catch (e) { print('⚠️ loadMatches: $e'); }
}

/// DB'deki mevcut duruma göre timer başlat (restart/reload sonrası)
void _initTimerFromDb(int fid, String status, int? elapsed) {
  switch (status) {
    case '1H':
      // Elapsed biliniyorsa oradan devam et
      final off = elapsed ?? 0;
      _timers[fid] = _MatchTimer(
        status: '1H',
        phaseStart: DateTime.now().subtract(Duration(minutes: off)),
        frozenElapsed: 0,
      );
    case 'HT':
      _timers[fid] = _MatchTimer(status: 'HT', phaseStart: null, frozenElapsed: 45);
    case '2H':
      final off = elapsed != null ? elapsed - 45 : 0;
      _timers[fid] = _MatchTimer(
        status: '2H',
        phaseStart: DateTime.now().subtract(Duration(minutes: off)),
        frozenElapsed: 45,
      );
    case 'ET':
      final off = elapsed != null ? elapsed - 90 : 0;
      _timers[fid] = _MatchTimer(
        status: 'ET',
        phaseStart: DateTime.now().subtract(Duration(minutes: off.clamp(0, 30))),
        frozenElapsed: 90,
      );
    case 'BT':
      _timers[fid] = _MatchTimer(status: 'BT', phaseStart: null, frozenElapsed: elapsed ?? 105);
    default:
      _timers[fid] = _MatchTimer(status: status, phaseStart: null, frozenElapsed: elapsed ?? 0);
  }
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
