// nesine_ws_test.dart
// Sadece bağlan, gelen mesajları logla, 60sn sonra çık
// GitHub Actions'da test için

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/io.dart';

const _wsUrl = 'wss://rt.nesine.com/socket.io/'
    '?platformid=1'
    '&userAgent=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20'
    'AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20'
    'Chrome%2F122.0.0.0%20Safari%2F537.36'
    '&EIO=4'
    '&transport=websocket';

Future<void> main() async {
  print('🔌 Nesine WS Test başlıyor...');
  print('URL: $_wsUrl\n');

  final channel = IOWebSocketChannel.connect(
    Uri.parse(_wsUrl),
    headers: {
      'Origin':        'https://www.nesine.com',
      'User-Agent':    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
      'Cache-Control': 'no-cache',
    },
  );

  // 60sn sonra çık
  Timer(const Duration(seconds: 60), () {
    print('\n⏰ 60sn doldu, çıkılıyor...');
    channel.sink.close();
    exit(0);
  });

  int msgCount = 0;

  await for (final raw in channel.stream) {
    msgCount++;
    final str = raw.toString();

    // Engine.IO ping/pong
    if (str == '2') {
      channel.sink.add('3');
      print('🏓 ping→pong');
      continue;
    }

    // Handshake
    if (str.startsWith('0')) {
      try {
        final d = jsonDecode(str.substring(1)) as Map;
        print('🤝 Handshake: sid=${d['sid']}');
        channel.sink.add('40'); // Socket.IO connect
      } catch (e) {
        print('🤝 Handshake raw: $str');
      }
      continue;
    }

    // Socket.IO connected → joinroom gönder
    if (str.startsWith('40')) {
      print('✅ Socket.IO bağlandı!');
      channel.sink.add('42["joinroom","LiveBets"]');
      print('📤 joinroom "LiveBets" gönderildi\n');
      continue;
    }

    // Socket.IO event — en önemli kısım
    if (str.startsWith('42')) {
      final payload = str.substring(2);
      try {
        final list = jsonDecode(payload) as List;
        final eventName = list[0].toString();
        final data      = list.length > 1 ? list[1] : null;

        print('[$msgCount] EVENT: "$eventName"');

        if (eventName == 'LiveBets' && data is List) {
          print('  → ${data.length} item');
          for (final item in data) {
            if (item is! Map) continue;
            final sportype = item['sportype'] ?? '?';
            final mt       = item['MT'];
            final bid      = item['bid'] ?? item['M']?['BID'];
            final m        = item['M'] as Map?;

            print('  • sportype=$sportype MT=$mt bid=$bid');

            if (m != null) {
              // MT=11: skor
              if (mt == 11) {
                print('    📊 SKOR → H=${m['H']} A=${m['A']} T=${m['T']}');
              }
              // MT=13: saat/durum
              else if (mt == 13) {
                print('    ⏱  DURUM → ${m['Value'] ?? m}');
              }
              // Diğer MT'ler
              else {
                print('    ❓ MT=$mt → ${jsonEncode(m).substring(0, jsonEncode(m).length.clamp(0, 150))}');
              }
            }
          }
        } else {
          // LiveBets dışındaki event'leri de logla
          final dataStr = jsonEncode(data);
          print('  → ${dataStr.substring(0, dataStr.length.clamp(0, 300))}');
        }
        print('');
      } catch (e) {
        print('[$msgCount] RAW 42: $payload');
      }
      continue;
    }

    // Diğer mesajlar
    print('[$msgCount] RAW: ${str.substring(0, str.length.clamp(0, 200))}');
  }

  print('\n✅ Toplam $msgCount mesaj alındı');
}
