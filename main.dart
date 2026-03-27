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
const Map<int, String> _stMap = {
  1: '1H', 2: 'HT', 3: '2H', 4: 'ET', 5: 'BT',
  6: 'P',  7: 'FT', 8: 'AET', 9: 'PEN', 10: 'PST', 11: 'CANC',
};

// MT:1 item.ST string → status_short
const Map<String, String> _stStrMap = {
  'MS': '1H', 'HT': 'HT', 'SH': '2H', 'MS2': '2H',
  'FT': 'FT', 'ET': 'ET', 'PEN': 'PEN', 'PST': 'PST', 'CANC': 'CANC',
};

const Map<String, String> _statusLong = {
  '1H': '1. Yarı', 'HT': 'D.A.',   '2H': '2. Yarı',
  'ET': 'Uzatma',  'BT': 'Uzatma D.A.', 'P': 'Penaltılar',
  'FT': 'MS', 'AET': 'MS (UZ)', 'PEN': 'MS (PEN)',
  'PST': 'Ertelendi', 'CANC': 'İptal', 'NS': 'Başlamadı',
};

// ─── Veri yapıları ─────────────────────────────────────────────
class _LiveMatch {
  final int     fixtureId;
  final String  homeTeam, awayTeam;
  int           homeScore, awayScore;
  String        statusShort;
  String        rawData;
  int?          nesineBid;   // eşleşince doldurulur

  _LiveMatch({
    required this.fixtureId,
    required this.homeTeam,
    required this.awayTeam,
    required this.homeScore,
    required this.awayScore,
    required this.statusShort,
    required this.rawData,
    this.nesineBid,
  });
}

// fixture_id → _LiveMatch  (tüm canlı maçlar)
final Map<int, _LiveMatch> _fixtures = {};

// Nesine BID → fixture_id  (dinamik eşleşme cache)
final Map<int, int> _bidToFid = {};

int _goalCount = 0, _writeCount = 0;

// Throttle: son DB yazma zamanı (fixture_id → DateTime)
final Map<int, DateTime> _lastWrite = {};

// ─── Main ──────────────────────────────────────────────────────
Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener v6         ║');
  print('║  👥 TÜM maçlar  ⏱ T\'den elapsed    ║');
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
        'ok': true, 'v': 6,
        'fixtures': _fixtures.length,
        'mapped':   _bidToFid.length,
        'goals':    _goalCount,
        'writes':   _writeCount,
      }))
      ..close());
    print('🌐 Health: :$port');
  });

  await _loadFixtures();
  Timer.periodic(const Duration(minutes: 3), (_) => _loadFixtures());
  Timer.periodic(const Duration(minutes: 5), (_) =>
      print('📊 Maç:${_fixtures.length} Eşleşme:${_bidToFid.length}'
            ' Gol:$_goalCount Yaz:$_writeCount'));

  unawaited(_wsLoop('A'));
  await Future.delayed(const Duration(seconds: 10));
  unawaited(_wsLoop('B'));
  await Completer<void>().future;
}

// ─── WS döngüsü ────────────────────────────────────────────────
Future<void> _wsLoop(String name) async {
  while (true) {
    try { await _connect(name); } catch (e) { print('[$name] ❌ $e'); }
    print('[$name] 🔄 Koptu...');
    await Future.delayed(const Duration(seconds: 2));
  }
}

Future<void> _connect(String name) async {
  print('[$name] 🔌 Bağlanıyor...');
  final ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: {
    'Origin':        'https://www.nesine.com',
    'User-Agent':    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
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
      final bid = _int(m?['BID'] ?? item['bid'] ?? item['BID']);
      if (bid == null) continue;

      if (mt == 1) {
        _onStatusEvent(name, bid, item);
      } else if (m != null) {
        _onScoreEvent(name, bid, m, item);
      }
    }
  } catch (_) {}
}

// ─── Nesine BID → fixture_id eşleştir ─────────────────────────
// İlk kez görülen BID için HomeTeam/AwayTeam ile eşleştirme yap.
// Eşleşince _bidToFid cache'e yaz.
int? _resolve(int bid, Map item) {
  // Cache'de varsa direkt dön
  if (_bidToFid.containsKey(bid)) return _bidToFid[bid];

  // WS item'dan takım isimlerini al
  final nHome = _norm((item['HomeTeam'] ?? item['M']?['HN'] ?? '').toString());
  final nAway = _norm((item['AwayTeam'] ?? item['M']?['AN'] ?? '').toString());
  if (nHome.isEmpty) return null;

  // Tüm fixture'larla karşılaştır
  _LiveMatch? best; double bestScore = 0;
  for (final f in _fixtures.values) {
    final homeSim = _sim(nHome, _norm(f.homeTeam));
    final awaySim = _sim(nAway, _norm(f.awayTeam));
    if (homeSim < 0.45 || awaySim < 0.45) continue;
    final s = (homeSim + awaySim) / 2;
    if (s > bestScore) { bestScore = s; best = f; }
  }

  if (best != null && bestScore >= 0.55) {
    _bidToFid[bid] = best.fixtureId;
    best.nesineBid = bid;
    print('   🔗 bid=$bid → fid=${best.fixtureId}'
          ' (${bestScore.toStringAsFixed(2)}) ${best.homeTeam} vs ${best.awayTeam}');
    return best.fixtureId;
  }
  return null;
}

// ─── Skor eventi (MT:11 / TS içeren) ──────────────────────────
void _onScoreEvent(String name, int bid, Map m, Map item) {
  if (!m.containsKey('TS')) return;   // MT:21 odds eventleri
  if (m.containsKey('EN')) return;

  final h = _int(m['H']);
  final a = _int(m['A']);
  if (h == null || a == null) return;
  if (h > 30 || a > 30) return;       // Oran değerleri

  final stCode = _int(m['ST']);
  final t      = _int(m['T']);         // Nesine'den gelen gerçek dakika
  final statusShort = stCode != null ? (_stMap[stCode] ?? '1H') : null;

  final fid = _resolve(bid, item);
  if (fid == null) return;
  final fixture = _fixtures[fid];
  if (fixture == null) return;

  final scoreChanged = h != fixture.homeScore || a != fixture.awayScore;
  if (statusShort != null) fixture.statusShort = statusShort;

  if (scoreChanged) {
    _goalCount++;
    print('[$name] ⚽ GOL! bid=$bid ${fixture.homeTeam}'
          ' ${fixture.homeScore}-${fixture.awayScore} → $h-$a'
          '${t != null ? " ($t\')" : ""}');
    fixture.homeScore = h;
    fixture.awayScore = a;
    _writeFixture(fixture, elapsed: t, forceScore: true);
  } else if (t != null) {
    // Skor aynı ama dakika değişti → throttled tick
    _writeTick(fixture, elapsed: t, statusShort: statusShort);
  }
}

// ─── Durum eventi (MT:1) ───────────────────────────────────────
void _onStatusEvent(String name, int bid, Map item) {
  final fid = _resolve(bid, item);
  if (fid == null) return;
  final fixture = _fixtures[fid];
  if (fixture == null) return;

  final stStr  = (item['ST'] ?? item['STL'] ?? '').toString().toUpperCase().trim();
  final stCode = _int(item['S']);
  String? statusShort = _stStrMap[stStr];
  if (statusShort == null && stCode != null) statusShort = _stMap[stCode];
  if (statusShort == null) return;

  final prev = fixture.statusShort;
  if (statusShort == prev) return;

  print('[$name] 📌 fid=$fid $prev → $statusShort');
  fixture.statusShort = statusShort;

  if (_isFinished(statusShort)) {
    print('[$name] 🏁 fid=$fid bitti → siliniyor');
    http.delete(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: _sbHeaders(),
    ).ignore();
    _fixtures.remove(fid);
    _bidToFid.remove(bid);
    return;
  }

  _writeFixture(fixture, elapsed: null);
}

// ─── Throttled tick (dakika değişti ama skor aynı) ────────────
void _writeTick(_LiveMatch fixture, {required int? elapsed, String? statusShort}) {
  if (elapsed == null) return;
  final fid  = fixture.fixtureId;
  final last = _lastWrite[fid];
  // Aynı dakikayı 30s içinde tekrar yazma
  if (last != null && DateTime.now().difference(last).inSeconds < 30) return;

  _writeFixture(fixture, elapsed: elapsed, statusShort: statusShort);
}

// ─── DB'ye yaz ─────────────────────────────────────────────────
Future<void> _writeFixture(
  _LiveMatch fixture, {
  int?    elapsed,
  String? statusShort,
  bool    forceScore = false,
}) async {
  final fid    = fixture.fixtureId;
  final status = statusShort ?? fixture.statusShort;
  _lastWrite[fid] = DateTime.now();

  final data = <String, dynamic>{
    'status_short': status,
    'updated_at':   DateTime.now().toIso8601String(),
    if (elapsed != null) 'elapsed_time': elapsed,
    if (forceScore) ...{
      'home_score':   fixture.homeScore,
      'away_score':   fixture.awayScore,
      'score_source': 'nesine',
    },
  };

  // raw_data güncelle
  try {
    final raw = Map<String, dynamic>.from(jsonDecode(fixture.rawData) as Map);
    (raw['fixture'] as Map)['status'] = {
      'long':    _statusLong[status] ?? status,
      'short':   status,
      'elapsed': elapsed,
      'extra':   null,
    };
    if (forceScore) {
      raw['goals'] = {'home': fixture.homeScore, 'away': fixture.awayScore};
    }
    data['raw_data'] = jsonEncode(raw);
    fixture.rawData  = data['raw_data'] as String;
  } catch (_) {}

  try {
    final res = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode < 300) {
      _writeCount++;
      if (elapsed != null) {
        print('   ⏱  fid=$fid $status ${elapsed}\'');
      }
    } else {
      print('❌ SB $fid: ${res.statusCode}');
    }
  } catch (e) { print('❌ SB: $e'); }
}

// ─── Tüm canlı maçları yükle ──────────────────────────────────
Future<void> _loadFixtures() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,'
          'status_short,raw_data,nesine_bid'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) return;
    final rows = (jsonDecode(res.body) as List).cast<Map>();

    // Yeni fixture'ları ekle, mevcutları güncelle
    final liveFids = <int>{};
    for (final r in rows) {
      final fid    = r['fixture_id'] as int;
      final bid    = _int(r['nesine_bid']);
      liveFids.add(fid);

      if (_fixtures.containsKey(fid)) {
        // Mevcut — sadece skoru güncelle (rawData ve statusShort listener'ın yazdığı kalır)
        _fixtures[fid]!.homeScore   = _int(r['home_score'])  ?? _fixtures[fid]!.homeScore;
        _fixtures[fid]!.awayScore   = _int(r['away_score'])  ?? _fixtures[fid]!.awayScore;
      } else {
        _fixtures[fid] = _LiveMatch(
          fixtureId:   fid,
          homeTeam:    (r['home_team']  ?? '').toString(),
          awayTeam:    (r['away_team']  ?? '').toString(),
          homeScore:   _int(r['home_score'])  ?? 0,
          awayScore:   _int(r['away_score'])  ?? 0,
          statusShort: (r['status_short'] ?? 'NS').toString(),
          rawData:     r['raw_data'] as String? ?? '{}',
          nesineBid:   bid,
        );
        // nesine_bid zaten varsa cache'e ekle
        if (bid != null) _bidToFid[bid] = fid;
      }
    }

    // Artık canlı olmayan maçları temizle
    _fixtures.removeWhere((fid, _) => !liveFids.contains(fid));
    _bidToFid.removeWhere((_, fid) => !liveFids.contains(fid));

    print('📋 ${_fixtures.length} canlı maç | ${_bidToFid.length} eşleşme');
  } catch (e) { print('⚠️ loadFixtures: $e'); }
}

// ─── Yardımcı fonksiyonlar ─────────────────────────────────────
bool _isFinished(String s) =>
    ['FT','AET','PEN','PST','CANC','ABD','AWD','WO'].contains(s);

Map<String, String> _sbHeaders() =>
    {'apikey': _sbKey, 'Authorization': 'Bearer $_sbKey', 'Prefer': 'return=minimal'};

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse(v.toString());
}

String _norm(String s) => s.toLowerCase()
    .replaceAll('ı','i').replaceAll('ğ','g').replaceAll('ü','u')
    .replaceAll('ş','s').replaceAll('ö','o').replaceAll('ç','c')
    .replaceAll('é','e').replaceAll('è','e').replaceAll('ê','e')
    .replaceAll('á','a').replaceAll('à','a').replaceAll('â','a').replaceAll('ä','a').replaceAll('ã','a')
    .replaceAll('ó','o').replaceAll('ò','o').replaceAll('ô','o')
    .replaceAll('ú','u').replaceAll('ù','u').replaceAll('û','u')
    .replaceAll('í','i').replaceAll('ì','i').replaceAll('î','i')
    .replaceAll('ñ','n').replaceAll('ø','o').replaceAll('å','a')
    .replaceAll('ć','c').replaceAll('č','c').replaceAll('ž','z').replaceAll('š','s')
    .replaceAll(RegExp(r'[^\w\s]'), '')
    .replaceAll(RegExp(r'\s+'), ' ').trim();

double _sim(String a, String b) {
  if (a == b) return 1.0;
  if (a.contains(b) || b.contains(a)) return 0.9;
  final w1 = a.split(' ').where((t) => t.length > 1).toSet();
  final w2 = b.split(' ').where((t) => t.length > 1).toSet();
  if (w1.isEmpty || w2.isEmpty) return 0.0;
  final j = w1.intersection(w2).length / w1.union(w2).length;
  if (j >= 0.5) return 0.7 + j * 0.2;
  if (a.length >= 3 && b.length >= 3 && a.substring(0,3) == b.substring(0,3)) return 0.6;
  return j * 0.5;
}
