import 'package:flutter/foundation.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';

/// App strings in Russian, Turkish and English, matching the website's wording
/// (web/portal/lib/i18n) and the Windows app (Services/ColituLocalization.cs).
/// Widgets read strings through [ColituLoc.I] and rebuild on language changes
/// via [ListenableBuilder] at the app root.
class ColituLoc extends ChangeNotifier {
  ColituLoc._() : _language = defaultLanguage();

  static final ColituLoc I = ColituLoc._();

  static const languages = ['ru', 'tr', 'en'];

  String _language;

  String get language => _language;

  /// Shortcut used by widgets: `loc['home.connect']`.
  String operator [](String key) => get(key);

  Future<void> load() async {
    final saved = await PreferencesKey().readColituLanguage();
    if (saved != null && saved.isNotEmpty) {
      setLanguage(saved, persist: false);
    }
  }

  Future<void> setLanguage(String? language, {bool persist = true}) async {
    final next = normalize(language);
    if (next != _language) {
      _language = next;
      notifyListeners();
    }
    if (persist) {
      await PreferencesKey().saveColituLanguage(next);
    }
  }

  static String normalize(String? language) {
    final value = (language ?? '').trim().toLowerCase();
    return languages.contains(value) ? value : defaultLanguage();
  }

  /// Russian unless the phone itself runs in Turkish or English, like the
  /// website and the Windows app.
  static String defaultLanguage() {
    final system = PlatformDispatcher.instance.locale.languageCode
        .toLowerCase();
    return switch (system) {
      'tr' => 'tr',
      'en' => 'en',
      _ => 'ru',
    };
  }

  String get(String key) {
    final values = _strings[key];
    if (values == null) return key;
    final index = languages.indexOf(_language);
    return values[index < 0 ? 0 : index];
  }

  String format(String key, Map<String, Object?> args) {
    var text = get(key);
    args.forEach((name, value) {
      text = text.replaceAll('{$name}', '$value');
    });
    return text;
  }

  /// Counted noun with the right plural form ("3 устройства", "5 дней").
  String count(String noun, int n) {
    final form = switch (_language) {
      'ru' => _russianForm(n),
      'en' => n == 1 ? 'one' : 'many',
      _ => 'one',
    };
    return format('$noun.$form', {'n': _groupThousands(n)});
  }

  String _groupThousands(int n) {
    final digits = n.abs().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(_language == 'en' ? ',' : ' ');
      }
      buffer.write(digits[i]);
    }
    return n < 0 ? '-$buffer' : buffer.toString();
  }

  static String _russianForm(int n) {
    final mod10 = n.abs() % 10;
    final mod100 = n.abs() % 100;
    if (mod10 == 1 && mod100 != 11) return 'one';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'few';
    return 'many';
  }

  String countryName(String code) {
    final values = _countries[code.toUpperCase()];
    if (values == null) return code.toUpperCase();
    final index = languages.indexOf(_language);
    return values[index < 0 ? 0 : index];
  }

  /// "24 сентября 2026" / "24 Eylül 2026" / "24 September 2026".
  String date(DateTime value) {
    final local = value.toLocal();
    final months = _months[_language] ?? _months['en']!;
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  String bytes(int bytes) {
    final units = _language == 'ru'
        ? const ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
        : const ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = unit == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '${_language == 'en' ? text : text.replaceFirst('.', ',')} ${units[unit]}';
  }

  /// Rubles from minor units, formatted like the website ("1 290 ₽").
  String money(int minor) {
    final sign = minor < 0 ? '−' : '';
    final absolute = minor.abs();
    final whole = _groupThousands(absolute ~/ 100);
    final fraction = absolute % 100;
    if (fraction == 0) return '$sign$whole ₽';
    final separator = _language == 'en' ? '.' : ',';
    return '$sign$whole$separator${fraction.toString().padLeft(2, '0')} ₽';
  }

  String percent(int bps) {
    final whole = bps ~/ 100;
    final fraction = bps.abs() % 100;
    if (fraction == 0) return '$whole';
    final text = (fraction / 100).toStringAsFixed(2).substring(2);
    return '$whole${_language == 'en' ? '.' : ','}${text.replaceFirst(RegExp(r'0$'), '')}';
  }

  static bool has(String key) => _strings.containsKey(key);

  @visibleForTesting
  static Iterable<String> get keys => _strings.keys;

  @visibleForTesting
  static List<String> valuesOf(String key) => _strings[key]!;

  static const _months = <String, List<String>>{
    'ru': [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ],
    'tr': [
      'Ocak',
      'Şubat',
      'Mart',
      'Nisan',
      'Mayıs',
      'Haziran',
      'Temmuz',
      'Ağustos',
      'Eylül',
      'Ekim',
      'Kasım',
      'Aralık',
    ],
    'en': [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ],
  };

  // key → [ru, tr, en]
  static const _strings = <String, List<String>>{
    // Background drops (why the tunnel stopped while the app was closed)
    'drop.title': [
      'Соединение прерывалось в фоне в {time}',
      'Bağlantı arka planda {time} sularında koptu',
      'The connection dropped in the background at {time}',
    ],
    'drop.killed': [
      'iOS завершила VPN-туннель из-за нехватки памяти ({mb} МБ).',
      'iOS VPN tünelini bellek sınırı yüzünden kapattı ({mb} MB).',
      'iOS ended the VPN tunnel for using too much memory ({mb} MB).',
    ],
    'drop.core': [
      'Из них ядро VPN: {mb} МБ.',
      'Bunun {mb} MB’ı VPN çekirdeğinde.',
      'The VPN core held {mb} MB of it.',
    ],
    'drop.killedLowMem': [
      'iOS завершила VPN-туннель без предупреждения. Последний замер памяти: {mb} МБ, ниже лимита (около 50 МБ).',
      'iOS VPN tünelini haber vermeden kapattı. Son ölçülen bellek {mb} MB idi, sınırın (yaklaşık 50 MB) altında.',
      'iOS ended the VPN tunnel without warning. Its last measured memory was {mb} MB, below the cap (about 50 MB).',
    ],
    'drop.crashed': [
      'VPN-движок аварийно завершился: {detail}',
      'VPN motoru çöktü: {detail}',
      'The VPN engine crashed: {detail}',
    ],
    'drop.crashedNoDetail': [
      'VPN-движок аварийно завершился.',
      'VPN motoru çöktü.',
      'The VPN engine crashed.',
    ],
    'drop.killedNoMem': [
      'iOS завершила VPN-туннель без предупреждения.',
      'iOS VPN tünelini haber vermeden kapattı.',
      'iOS ended the VPN tunnel without warning.',
    ],
    'drop.network': [
      'Пропала сеть или сменилось подключение.',
      'Ağ bağlantısı kayboldu ya da ağ değişti.',
      'The network went away or changed.',
    ],
    'drop.superseded': [
      'Было включено другое VPN-приложение.',
      'Başka bir VPN uygulaması açıldı.',
      'Another VPN app was turned on.',
    ],
    'drop.disabled': [
      'VPN-профиль Colitu был отключён или удалён в Настройках.',
      'Colitu VPN profili Ayarlar\u2019da kapatıldı veya silindi.',
      'The Colitu VPN profile was turned off or removed in Settings.',
    ],
    'drop.sleep': [
      'Устройство перешло в режим сна.',
      'Cihaz uyku moduna geçti.',
      'The device went to sleep.',
    ],
    'drop.failed': [
      'VPN-движок остановился с ошибкой.',
      'VPN motoru bir hatayla durdu.',
      'The VPN engine stopped with an error.',
    ],
    'drop.other': ['Причина: {reason}.', 'Sebep: {reason}.', 'Reason: {reason}.'],
    'drop.restored': [
      'Постоянная защита сразу восстановила соединение.',
      'Sürekli koruma bağlantıyı hemen yeniden kurdu.',
      'Always-on protection restored the connection right away.',
    ],
    'drop.dismiss': ['Понятно', 'Tamam', 'Got it'],

    // Onboarding
    'onb.skip': ['Пропустить', 'Atla', 'Skip'],
    'onb.next': ['Далее', 'İleri', 'Next'],
    'onb.start': ['Начать', 'Başla', 'Get started'],
    'onb.badge': ['VPN без журналов', 'Kayıt tutmayan VPN', 'No-logs VPN'],
    'onb.1.title': [
      'Добро пожаловать в Colitu',
      'Colitu’ya hoş geldiniz',
      'Welcome to Colitu',
    ],
    'onb.1.sub': [
      'Шифрование трафика, скрытый IP и никаких журналов. Всё, что нужно для свободного интернета.',
      'Şifreli trafik, gizli IP ve sıfır kayıt. Özgür internet için gereken her şey.',
      'Encrypted traffic, a hidden IP and no logs. Everything you need for the open internet.',
    ],
    'onb.2.title': [
      'Одно касание — и вы под защитой',
      'Tek dokunuşla koruma',
      'One tap and you’re protected',
    ],
    'onb.2.sub': [
      'Нажмите кнопку на главном экране. Colitu сам выберет самый быстрый протокол и сервер.',
      'Ana ekrandaki düğmeye basın. Colitu en hızlı protokolü ve sunucuyu kendisi seçer.',
      'Press the button on the home screen. Colitu picks the fastest protocol and server for you.',
    ],
    'onb.3.title': ['Выбирайте локацию', 'Konumunuzu seçin', 'Pick your location'],
    'onb.3.sub': [
      'Во вкладке «Локации» выберите страну — подключение переключится автоматически.',
      '“Konumlar” sekmesinden bir ülke seçin; bağlantı otomatik olarak geçer.',
      'Choose a country in the Locations tab and the connection moves over automatically.',
    ],
    'onb.4.title': ['Всегда на связи', 'Her zaman korumada', 'Always protected'],
    'onb.4.sub': [
      'Включите постоянную защиту в разделе «Аккаунт», и iPhone будет восстанавливать туннель сам.',
      '“Hesap” bölümünden sürekli korumayı açın; iPhone tüneli kendi kendine yeniden kurar.',
      'Turn on always-on protection under Account and your iPhone restores the tunnel by itself.',
    ],
    'onb.create': ['Создать аккаунт', 'Hesap oluştur', 'Create account'],
    'onb.signIn': ['У меня есть аккаунт', 'Hesabım var', 'I have an account'],

    // Home (connection screen)
    'home.statusLabel': ['Статус соединения', 'Bağlantı durumu', 'Connection status'],
    'home.state.off': ['Не подключено', 'Bağlı değil', 'Not connected'],
    'home.state.on': ['Подключено', 'Bağlı', 'Connected'],
    'home.state.connecting': ['Подключение', 'Bağlanıyor', 'Connecting'],
    'home.state.disconnecting': ['Отключение', 'Kesiliyor', 'Disconnecting'],
    'home.tap': ['Нажмите, чтобы подключиться', 'Bağlanmak için dokunun', 'Tap to connect'],
    'home.tapOff': ['Нажмите, чтобы отключить', 'Kesmek için dokunun', 'Tap to disconnect'],
    'home.upload': ['Отправка', 'Yükleme', 'Upload'],
    'home.download': ['Загрузка', 'İndirme', 'Download'],
    'home.phase.preparing': [
      'Получаем конфигурацию…',
      'Yapılandırma alınıyor…',
      'Fetching configuration…',
    ],
    'home.phase.probing': [
      'Выбираем самый быстрый протокол…',
      'En hızlı protokol seçiliyor…',
      'Picking the fastest protocol…',
    ],
    'home.phase.starting': ['Запускаем туннель…', 'Tünel başlatılıyor…', 'Starting the tunnel…'],
    'home.phase.verifying': ['Проверяем трафик…', 'Trafik doğrulanıyor…', 'Verifying traffic…'],
    'home.phase.switching': [
      'Пробуем другой протокол…',
      'Başka protokol deneniyor…',
      'Trying another protocol…',
    ],
    'home.switchingTransport': [
      'Протокол не отвечает, пробуем другой…',
      'Protokol yanıt vermiyor, başkası deneniyor…',
      'Protocol isn’t responding, trying another…',
    ],
    'home.promo.title': [
      'Откройте весь интернет',
      'İnternetin tamamını açın',
      'Unlock more of the internet',
    ],
    'home.promo.sub': [
      'Все серверы и безлимитный трафик с Colitu Pro',
      'Colitu Pro ile tüm sunucular ve sınırsız trafik',
      'Every server and unlimited traffic with Colitu Pro',
    ],
    'home.fastest': ['Самый быстрый сервер', 'En hızlı sunucu', 'Fastest server'],
    'home.autoPicked': ['Выбран автоматически', 'Otomatik seçildi', 'Auto-selected'],
    'home.changeServer': ['Сменить сервер', 'Sunucuyu değiştir', 'Change server'],
    'home.protocol': ['Протокол', 'Protokol', 'Protocol'],
    // Colitu names of the transports; the technical names stay out of the UI.
    'transport.hysteria2': ['Быстрый', 'Hızlı', 'Fast'],
    'transport.vless-reality': ['Скрытный', 'Gizli', 'Stealth'],
    'transport.vless-xhttp': ['Устойчивый', 'Dayanıklı', 'Resilient'],
    'transport.trojan': ['Классический', 'Klasik', 'Classic'],
    'transport.shadowsocks': ['Лёгкий', 'Hafif', 'Light'],
    'transport.other': ['Резервный', 'Yedek', 'Backup'],
    'home.getPro': ['Получить Pro', 'Pro’ya geç', 'Get Pro'],

    // Locations
    'locations.all': ['Все', 'Tümü', 'All'],
    'locations.fast': ['Быстрые', 'Hızlı', 'Fast'],
    'locations.ai': ['Нейросети', 'Yapay zeka', 'AI'],
    'locations.streaming': ['Кино и сериалы', 'Dizi & film', 'Movies & TV'],
    'locations.promo': ['Серверы по всему миру', 'Dünya çapında sunucular', 'Get worldwide coverage'],
    'locations.promoSub': ['с Colitu Pro', 'Colitu Pro ile', 'with Colitu Pro'],
    'locations.online': ['Онлайн: {n}', 'Çevrimiçi: {n}', '{n} online'],

    // Plan hero
    'plan.heroTitle': ['Усильте защиту', 'Gizliliğinizi yükseltin', 'Upgrade your privacy'],
    'plan.heroSub': [
      'Все серверы, максимальная скорость и постоянная защита с Colitu Pro.',
      'Colitu Pro ile tüm sunucular, en yüksek hız ve sürekli koruma.',
      'Every server, top speed and always-on protection with Colitu Pro.',
    ],
    'plan.manageTitle': [
      'Подписка управляется на colitu.com',
      'Abonelik colitu.com üzerinden yönetilir',
      'Your subscription is managed on colitu.com',
    ],
    'plan.manageBody': [
      'Тариф, продление и устройства — в личном кабинете. Войдите с той же почтой, что и в приложении.',
      'Paket, süre uzatma ve cihazlar hesabınızdan yönetilir. Uygulamadaki e-posta adresinizle giriş yapın.',
      'Plans, renewals and devices are handled in your account. Sign in with the same e-mail as in the app.',
    ],
    'plan.manageButton': ['Открыть app.colitu.com', 'app.colitu.com’u aç', 'Open app.colitu.com'],
    'plan.refresh': ['Обновить статус', 'Durumu yenile', 'Refresh status'],
    'plan.refreshHint': [
      'После изменений в кабинете вернитесь сюда и обновите статус.',
      'Hesabınızda değişiklik yaptıktan sonra buraya dönüp durumu yenileyin.',
      'After changing something in your account, come back and refresh.',
    ],
    'plan.manage': ['Управлять', 'Yönet', 'Manage'],
    'plan.lifetime': ['Бессрочно', 'Süresiz', 'No expiry'],
    'plan.select': ['Выберите тариф', 'Paketinizi seçin', 'Select your plan'],
    'plan.get': ['Получить Colitu Pro', 'Colitu Pro’yu al', 'Get Colitu Pro'],
    'plan.total': ['Итого {amount}', 'Toplam {amount}', '{amount} total'],
    'plan.perMonth': ['{amount}/мес.', '{amount}/ay', '{amount}/mo'],

    // Account (settings live here too)
    'account.features': ['Функции', 'Özellikler', 'Features'],
    'account.connection': ['Подключение', 'Bağlantı', 'Connection'],
    'account.general': ['Общие', 'Genel', 'General'],
    'account.protocol': ['Протокол', 'Protokol', 'Protocol'],
    'account.protocolAuto': ['Умный (авто)', 'Akıllı (otomatik)', 'Smart (auto)'],
    'account.howItWorks': ['Как это работает', 'Nasıl çalışır', 'How it works'],
    'account.on': ['Вкл.', 'Açık', 'On'],
    'account.off': ['Выкл.', 'Kapalı', 'Off'],

    // Shell
    'nav.home': ['Главная', 'Ana sayfa', 'Home'],
    'nav.locations': ['Локации', 'Konumlar', 'Locations'],
    'nav.plan': ['Тариф', 'Paket', 'Plan'],
    'nav.account': ['Аккаунт', 'Hesap', 'Account'],
    'nav.settings': ['Настройки', 'Ayarlar', 'Settings'],
    'loading.session': [
      'Восстанавливаем сеанс…',
      'Oturumunuz açılıyor…',
      'Restoring your session…',
    ],

    // Connection status
    'status.protected': ['Защищено', 'Korunuyor', 'Protected'],
    'status.unprotected': ['Не защищено', 'Korunmuyor', 'Not protected'],
    'status.connecting': ['Подключение…', 'Bağlanıyor…', 'Connecting…'],
    'status.reconnecting': [
      'Переподключение…',
      'Yeniden bağlanıyor…',
      'Reconnecting…',
    ],
    'status.disconnecting': [
      'Отключение…',
      'Bağlantı kesiliyor…',
      'Disconnecting…',
    ],

    // Home
    'home.kicker': ['COLITU VPN · iOS', 'COLITU VPN · iOS', 'COLITU VPN · iOS'],
    'home.title.off': [
      'Соединение не защищено',
      'Bağlantınız korunmuyor',
      'Your connection isn’t protected',
    ],
    'home.title.on': ['Вы под защитой', 'Korunuyorsunuz', 'You’re protected'],
    'home.title.connecting': [
      'Защищаем соединение',
      'Bağlantınız güvenceye alınıyor',
      'Securing your connection',
    ],
    'home.title.noplan': [
      'Выберите тариф, чтобы начать',
      'Başlamak için bir paket seçin',
      'Choose a plan to get started',
    ],
    'home.sub.off': [
      'Нажмите кнопку — трафик будет зашифрован, а IP-адрес скрыт.',
      'Düğmeye basın; trafiğiniz şifrelenir, IP adresiniz gizlenir.',
      'Press the button to encrypt your traffic and hide your IP address.',
    ],
    'home.sub.on': [
      'Трафик зашифрован и идёт через {server}.',
      'Trafiğiniz şifreli ve {server} üzerinden geçiyor.',
      'Your traffic is encrypted and routed through {server}.',
    ],
    'home.sub.connecting': [
      'Готовим зашифрованный туннель…',
      'Şifreli tünel hazırlanıyor…',
      'Setting up the encrypted tunnel…',
    ],
    'home.sub.noplan': [
      'Все серверы, безлимитный трафик и защита от утечек — в одном тарифе.',
      'Tüm sunucular, sınırsız trafik ve sızıntı koruması tek pakette.',
      'Every server, unlimited traffic and leak protection in one plan.',
    ],
    'home.connect': ['Подключить', 'Bağlan', 'Connect'],
    'home.disconnect': ['Отключить', 'Bağlantıyı kes', 'Disconnect'],
    'home.cancel': ['Отменить', 'İptal', 'Cancel'],
    'home.session': ['Время сеанса', 'Oturum süresi', 'Session time'],
    'home.publicIp': ['Ваш IP', 'IP adresiniz', 'Your IP'],
    'home.location': ['ЛОКАЦИЯ', 'KONUM', 'LOCATION'],
    'home.change': ['Изменить', 'Değiştir', 'Change'],
    'home.plan': ['ТАРИФ', 'PAKET', 'PLAN'],
    'home.quick': ['БЫСТРЫЕ НАСТРОЙКИ', 'HIZLI AYARLAR', 'QUICK SETTINGS'],
    'home.traffic': ['Трафик за период', 'Bu dönemki trafik', 'Traffic this period'],
    'home.trafficOf': ['{used} из {limit}', '{used} / {limit}', '{used} of {limit}'],
    'home.unlimited': ['Безлимитный трафик', 'Sınırsız trafik', 'Unlimited traffic'],
    'home.devices': ['Устройства', 'Cihazlar', 'Devices'],
    'home.offline': [
      'Нет связи с сервером Colitu. Повторяем попытку…',
      'Colitu sunucusuna ulaşılamıyor. Yeniden deneniyor…',
      'Can’t reach Colitu right now. Retrying…',
    ],

    'server.auto': ['Лучший сервер', 'En iyi sunucu', 'Best server'],
    'server.autoHint': [
      'Colitu сам выберет самый свободный и стабильный',
      'Colitu en boş ve kararlı sunucuyu kendisi seçer',
      'Colitu picks the least busy, most stable one',
    ],
    'server.none': [
      'Серверы появятся здесь',
      'Sunucular burada görünecek',
      'Servers will appear here',
    ],
    'server.load.low': ['Низкая нагрузка', 'Düşük yük', 'Low load'],
    'server.load.medium': ['Средняя нагрузка', 'Orta yük', 'Medium load'],
    'server.load.high': ['Высокая нагрузка', 'Yüksek yük', 'High load'],
    'server.offline': ['Недоступен', 'Çevrimdışı', 'Offline'],
    'server.connected': ['Подключено', 'Bağlı', 'Connected'],
    'server.selected': ['Выбрано', 'Seçili', 'Selected'],

    // Locations
    'locations.kicker': ['ЛОКАЦИИ', 'KONUMLAR', 'LOCATIONS'],
    'locations.title': ['Выберите локацию', 'Bir konum seçin', 'Choose a location'],
    'locations.tagline': ['Быстрее и свободнее', 'Daha hızlı, daha özgür bir internet', 'A faster, freer internet'],
    'locations.fastest': ['Самый быстрый', 'En hızlı sunucu', 'Fastest'],
    'locations.recommended': ['Рекомендуемые', 'Tavsiye edilen', 'Recommended'],
    'locations.allServers': ['Все серверы', 'Tüm sunucular', 'All servers'],
    'locations.sortTitle': ['Сортировка', 'Sıralama', 'Sort by'],
    'locations.sort.ping': ['По пингу', 'Ping’e göre', 'By ping'],
    'locations.sort.name': ['По названию', 'Ada göre', 'By name'],
    'locations.sort.load': ['По нагрузке', 'Yüke göre', 'By load'],
    'locations.sortCancel': ['Отмена', 'Vazgeç', 'Cancel'],
    'locations.sub': [
      'Серверов онлайн: {n}. При смене локации подключение переключится автоматически.',
      'Çevrimiçi sunucu: {n}. Konumu değiştirdiğinizde bağlantı otomatik olarak geçer.',
      '{n} servers online. Switching location moves your connection automatically.',
    ],
    'locations.search': [
      'Поиск страны или города',
      'Ülke veya şehir ara',
      'Search country or city',
    ],
    'locations.empty': ['Ничего не найдено', 'Sonuç bulunamadı', 'Nothing found'],
    'locations.switching': [
      'Переключаемся на {server}…',
      '{server} konumuna geçiliyor…',
      'Switching to {server}…',
    ],
    'locations.switched': [
      'Подключено: {server}',
      'Bağlandı: {server}',
      'Connected to {server}',
    ],
    // The tunnel restarted twice and the server still does not answer
    'server.problem': [
      'Сервер не отвечает даже после перезапусков. Попробовать {server}?',
      'Sunucu yeniden başlatmalara rağmen yanıt vermiyor. {server} denensin mi?',
      'The server is not responding even after restarts. Try {server}?',
    ],
    'server.switch': ['Сменить сервер', 'Sunucuyu değiştir', 'Switch server'],
    'server.problemSwitched': [
      'Сервер не отвечал — переключено на {server}',
      'Sunucu yanıt vermiyordu — {server} konumuna geçildi',
      'The server stopped responding — switched to {server}',
    ],

    // Plan status
    'plan.none': ['Нет активного тарифа', 'Aktif paket yok', 'No active plan'],
    'plan.noneHint': [
      'Выберите тариф, чтобы подключиться.',
      'Bağlanmak için bir paket seçin.',
      'Choose a plan to connect.',
    ],
    'plan.status.active': ['АКТИВЕН', 'AKTİF', 'ACTIVE'],
    'plan.status.trialing': ['ПРОБНЫЙ', 'DENEME', 'TRIAL'],
    'plan.status.expired': ['ИСТЁК', 'SÜRESİ DOLDU', 'EXPIRED'],
    'plan.status.inactive': ['НЕ АКТИВЕН', 'PASİF', 'INACTIVE'],
    'plan.until': ['До {date}', '{date} tarihine kadar', 'Until {date}'],
    'plan.left': ['осталось {left}', '{left} kaldı', '{left} left'],
    'plan.choose': ['Выбрать тариф', 'Paket seç', 'Choose a plan'],
    'plan.extend': ['Продлить', 'Süreyi uzat', 'Extend'],
    'plan.trialName': ['Пробный период', 'Deneme süresi', 'Free trial'],
    'day.one': ['{n} день', '{n} gün', '{n} day'],
    'day.few': ['{n} дня', '{n} gün', '{n} days'],
    'day.many': ['{n} дней', '{n} gün', '{n} days'],
    'hour.one': ['{n} час', '{n} saat', '{n} hour'],
    'hour.few': ['{n} часа', '{n} saat', '{n} hours'],
    'hour.many': ['{n} часов', '{n} saat', '{n} hours'],
    'device.one': ['{n} устройство', '{n} cihaz', '{n} device'],
    'device.few': ['{n} устройства', '{n} cihaz', '{n} devices'],
    'device.many': ['{n} устройств', '{n} cihaz', '{n} devices'],

    // Pricing (same wording as colitu.com/pricing)
    'pricing.kicker': ['ТАРИФЫ', 'PAKETLER', 'PLANS'],
    'pricing.title': [
      'Один тариф. Все серверы.',
      'Tek paket. Tüm sunucular.',
      'One plan. Every server.',
    ],
    'pricing.sub': [
      'Выберите срок и число устройств. Итог со скидкой и комиссией способа оплаты виден сразу.',
      'Sürenizi ve cihaz sayınızı seçin. İndirimler ve ödeme yöntemi komisyonu dahil toplam tutarı baştan görün.',
      'Pick a term and the number of devices. The total with discounts and payment fees is shown up front.',
    ],
    'pricing.current': ['Текущий тариф', 'Mevcut paket', 'Current plan'],
    'pricing.months': ['{n} МЕС.', '{n} AY', '{n} MONTHS'],
    'pricing.oneMonth': ['1 МЕС.', '1 AY', '1 MONTH'],
    'pricing.twoYears': ['2 ГОДА', '2 YIL', '2 YEARS'],
    'pricing.off': ['Скидка {n}%', '%{n} İNDİRİM', '{n}% off'],
    'pricing.best': [
      'САМОЕ ВЫГОДНОЕ ПРЕДЛОЖЕНИЕ',
      'EN AVANTAJLI · EN ÇOK TASARRUF',
      'BEST VALUE · BIGGEST SAVINGS',
    ],
    'pricing.perDevice': [
      'в месяц за устройство',
      'aylık, cihaz başına',
      'per device a month',
    ],
    'pricing.saving': [
      'Экономия {amount} на устройство',
      'Cihaz başına {amount} tasarruf',
      'Save {amount} per device',
    ],
    'pricing.devices': ['Количество устройств', 'Cihaz sayısı', 'Number of devices'],
    'pricing.method': ['Способ оплаты', 'Ödeme yöntemi', 'Payment method'],
    'pricing.noFee': ['Без комиссии', 'Komisyonsuz', 'No fee'],
    'pricing.fee': ['Комиссия {n}%', 'Komisyon %{n}', '{n}% fee'],
    'pricing.summary': ['ИТОГ', 'ÖZET', 'SUMMARY'],
    'pricing.regular': ['Обычная цена', 'Normal fiyat', 'Regular price'],
    'pricing.discount': ['Скидка ({n}%)', 'İndirim (%{n})', 'Discount ({n}%)'],
    'pricing.commission': ['Комиссия', 'Komisyon', 'Payment fee'],
    'pricing.total': ['ИТОГО', 'TOPLAM', 'TOTAL'],
    'pricing.pay': [
      'Перейти к безопасной оплате',
      'Güvenli ödemeye geç',
      'Continue to secure payment',
    ],
    'pricing.secure': [
      'Оплата проходит на защищённой странице платёжного сервиса. Доступ откроется сразу после оплаты.',
      'Ödeme, ödeme sağlayıcısının güvenli sayfasında yapılır. Erişiminiz ödemeden hemen sonra açılır.',
      'You pay on the payment provider’s secure page. Access opens as soon as the payment clears.',
    ],
    'pricing.loadFailed': [
      'Не удалось загрузить тарифы.',
      'Paketler yüklenemedi.',
      'Plans could not be loaded.',
    ],
    'pricing.retry': ['Повторить', 'Tekrar dene', 'Try again'],
    'pricing.unavailable': [
      'Оплата в приложении пока недоступна. Оформите тариф на colitu.com — он появится здесь сразу.',
      'Uygulama içi ödeme henüz açık değil. Paketinizi colitu.com’dan alın; burada anında görünür.',
      'In-app payment isn’t available yet. Buy your plan on colitu.com and it shows up here right away.',
    ],
    'pricing.openWeb': ['Открыть colitu.com', 'colitu.com’u aç', 'Open colitu.com'],
    'pay.checking': ['Проверяем оплату…', 'Ödeme kontrol ediliyor…', 'Checking payment…'],
    'pay.checkingHint': [
      'Завершите оплату в браузере. Эта страница обновится автоматически.',
      'Ödemeyi tarayıcıda tamamlayın. Bu sayfa otomatik olarak güncellenir.',
      'Finish paying in your browser. This page updates by itself.',
    ],
    'pay.reopen': ['Открыть страницу оплаты', 'Ödeme sayfasını aç', 'Open payment page'],
    'pay.cancel': ['Отменить', 'Vazgeç', 'Cancel'],
    'pay.success': ['Оплата прошла', 'Ödeme alındı', 'Payment received'],
    'pay.successHint': [
      'Тариф активен. Можно подключаться.',
      'Paketiniz aktif. Hemen bağlanabilirsiniz.',
      'Your plan is active. You can connect now.',
    ],
    'pay.failed': ['Оплата не прошла', 'Ödeme tamamlanmadı', 'Payment didn’t go through'],
    'pay.failedHint': [
      'Деньги не списаны. Попробуйте ещё раз или выберите другой способ.',
      'Ücret alınmadı. Tekrar deneyin veya başka bir yöntem seçin.',
      'You were not charged. Try again or pick another method.',
    ],
    'pay.back': ['Вернуться к тарифам', 'Paketlere dön', 'Back to plans'],
    'pay.connect': ['Подключиться', 'Bağlan', 'Connect now'],

    // Account
    'account.kicker': ['АККАУНТ', 'HESAP', 'ACCOUNT'],
    'account.title': ['Ваш аккаунт', 'Hesabınız', 'Your account'],
    'account.email': ['Электронная почта', 'E-posta', 'Email'],
    'account.plan': ['Тариф', 'Paket', 'Plan'],
    'account.validUntil': ['Действует до', 'Geçerlilik', 'Valid until'],
    'account.devices': ['УСТРОЙСТВА', 'CİHAZLAR', 'DEVICES'],
    'account.devicesTitle': [
      'Подключено {used} из {limit}',
      '{limit} cihazdan {used} tanesi bağlı',
      '{used} of {limit} in use',
    ],
    'account.thisDevice': ['ЭТО УСТРОЙСТВО', 'BU CİHAZ', 'THIS DEVICE'],
    'account.lastSeen': ['Активность: {date}', 'Son etkinlik: {date}', 'Last active {date}'],
    'account.remove': ['Отключить устройство', 'Cihazı kaldır', 'Remove device'],
    'account.removeConfirm': [
      'Отключить «{name}»? На нём потребуется войти снова.',
      '“{name}” kaldırılsın mı? Bu cihazda yeniden giriş yapmak gerekecek.',
      'Remove “{name}”? It will need to sign in again.',
    ],
    'account.removed': ['Устройство отключено', 'Cihaz kaldırıldı', 'Device removed'],
    'account.manage': ['Управлять на colitu.com', 'colitu.com’da yönet', 'Manage on colitu.com'],
    'account.signOut': ['Выйти', 'Çıkış yap', 'Sign out'],
    'account.signOutConfirm': [
      'Выйти из аккаунта на этом iPhone? VPN будет отключён.',
      'Bu iPhone’da hesaptan çıkılsın mı? VPN bağlantısı kesilecek.',
      'Sign out on this iPhone? The VPN will disconnect.',
    ],
    'account.help': ['Нужна помощь?', 'Yardım mı lazım?', 'Need help?'],
    'account.helpHint': [
      'Напишите нам — отвечаем быстро и по-человечески.',
      'Bize yazın; hızlı ve insan gibi yanıt veririz.',
      'Write to us. We answer quickly, and a real person reads it.',
    ],
    'account.support': ['Центр поддержки', 'Destek merkezi', 'Support center'],
    'account.mail': ['Написать на почту', 'E-posta gönder', 'Email support'],
    'account.diagnostics': [
      'Отправить журнал подключения',
      'Bağlantı kaydını gönder',
      'Send connection log',
    ],
    'account.diagnosticsHint': [
      'Причины обрывов VPN для поддержки',
      'VPN kopmalarının sebebi, destek için',
      'Why the VPN dropped, for support',
    ],
    'account.diagnosticsFailed': [
      'Не удалось подготовить журнал.',
      'Kayıt hazırlanamadı.',
      'The log could not be prepared.',
    ],
    'account.mailUnavailable': [
      'Почтовое приложение недоступно. Напишите на support@colitu.com.',
      'Posta uygulaması açılamadı. support@colitu.com adresine yazın.',
      'No mail app is available. Write to support@colitu.com.',
    ],

    // Settings
    'settings.kicker': ['НАСТРОЙКИ', 'AYARLAR', 'SETTINGS'],
    'settings.title': ['Настройки', 'Ayarlar', 'Settings'],
    'settings.language': ['Язык', 'Dil', 'Language'],
    'settings.connection': ['Подключение', 'Bağlantı', 'Connection'],
    'settings.alwaysOn': ['Постоянная защита', 'Sürekli koruma', 'Always-on protection'],
    'settings.alwaysOnHint': [
      'Если VPN отключится — из-за сети или через Пункт управления, — iOS сразу подключит его снова.',
      'VPN ağ değişimi ya da Denetim Merkezi yüzünden koparsa iOS bağlantıyı hemen yeniden kurar.',
      'If the VPN drops because of the network or Control Center, iOS reconnects it right away.',
    ],
    'settings.dns': ['Защита от утечек DNS', 'DNS sızıntı koruması', 'DNS leak protection'],
    'settings.dnsHint': [
      'DNS-запросы идут только через VPN. Всегда включено.',
      'DNS sorguları yalnızca VPN üzerinden gider. Her zaman açık.',
      'DNS lookups only go through the VPN. Always on.',
    ],
    'settings.autoConnect': ['Автоподключение', 'Otomatik bağlan', 'Auto-connect'],
    'settings.autoConnectHint': [
      'Подключаться сразу после запуска приложения.',
      'Uygulama açılır açılmaz bağlan.',
      'Connect as soon as the app starts.',
    ],
    'settings.adBlock': ['Блокировка рекламы', 'Reklam engelleme', 'Ad blocking'],
    'settings.adBlockHint': [
      'Реклама и трекеры блокируются на DNS-серверах Colitu, во всех приложениях. Журнал запросов не ведётся. Если какой-то сайт сломается, выключите.',
      'Reklam ve izleyiciler tüm uygulamalarda Colitu DNS sunucularında engellenir. Sorgu kaydı tutulmaz. Bir site bozulursa kapatın.',
      'Ads and trackers are blocked on Colitu’s DNS servers, in every app. No query log is kept. If a site breaks, turn it off.',
    ],
    'settings.app': ['Приложение', 'Uygulama', 'App'],
    'settings.about': ['О приложении', 'Hakkında', 'About'],
    'settings.version': ['Версия {version}', 'Sürüm {version}', 'Version {version}'],
    'settings.privacy': ['Конфиденциальность', 'Gizlilik', 'Privacy'],
    'settings.terms': ['Условия', 'Koşullar', 'Terms'],
    'settings.openSource': ['Открытый исходный код', 'Açık kaynak', 'Open source'],
    'settings.openSourceHint': [
      'GPL-3.0 · код приложения на GitHub',
      'GPL-3.0 · uygulamanın kodu GitHub\'da',
      'GPL-3.0 · the app\'s code on GitHub',
    ],
    'settings.licenses': ['Лицензии', 'Lisanslar', 'Licences'],
    'settings.website': ['colitu.com', 'colitu.com', 'colitu.com'],
    'settings.saved': ['Сохранено', 'Kaydedildi', 'Saved'],
    'settings.reconnectHint': [
      'Изменения применятся при следующем подключении.',
      'Değişiklik bir sonraki bağlantıda uygulanır.',
      'Changes apply the next time you connect.',
    ],
    'brand.credit': [
      'Colitu — продукт компании {brand}.',
      'Colitu bir {brand} ürünüdür.',
      'Colitu is a {brand} product.',
    ],

    // Auth
    'auth.kicker': [
      'БЕЗОПАСНО · ПРИВАТНО · БЫСТРО',
      'GÜVENLİ · ÖZEL · HIZLI',
      'SECURE · PRIVATE · FAST',
    ],
    'auth.heroTitle': [
      'Свободный интернет в одно касание.',
      'Özgür internet, tek dokunuşla.',
      'The open internet, one tap away.',
    ],
    'auth.heroSub': [
      'Серверы в разных странах, шифрование трафика и никаких журналов.',
      'Farklı ülkelerde sunucular, şifreli trafik ve kayıt tutmama.',
      'Servers in many countries, encrypted traffic and no activity logs.',
    ],
    'auth.login': ['Вход', 'Giriş', 'Sign in'],
    'auth.register': ['Регистрация', 'Kayıt ol', 'Sign up'],
    'auth.loginTitle': ['С возвращением', 'Tekrar hoş geldiniz', 'Welcome back'],
    'auth.loginSub': [
      'Войдите в аккаунт Colitu — тот же, что на colitu.com.',
      'Colitu hesabınızla giriş yapın; colitu.com ile aynı hesap.',
      'Sign in with your Colitu account, the same one you use on colitu.com.',
    ],
    'auth.registerTitle': ['Создать аккаунт', 'Hesap oluştur', 'Create account'],
    'auth.registerSub': [
      'Зарегистрируйтесь по почте и пользуйтесь Colitu бесплатно: 10 ГБ каждый месяц.',
      'E-postanızla kaydolun, Colitu’yu ücretsiz kullanın: her ay 10 GB.',
      'Sign up with your email and use Colitu for free: 10 GB every month.',
    ],
    'auth.email': ['Электронная почта', 'E-posta', 'Email'],
    'auth.emailHint': ['you@example.com', 'ornek@eposta.com', 'you@example.com'],
    'auth.password': ['Пароль', 'Şifre', 'Password'],
    'auth.passwordHint': ['Не менее 10 символов', 'En az 10 karakter', 'At least 10 characters'],
    'auth.passwordRepeat': ['Повторите пароль', 'Şifreyi tekrarla', 'Repeat password'],
    'auth.show': ['Показать пароль', 'Şifreyi göster', 'Show password'],
    'auth.terms': [
      'Я принимаю условия и политику конфиденциальности',
      'Koşulları ve gizlilik politikasını kabul ediyorum',
      'I accept the terms and privacy policy',
    ],
    'auth.submitLogin': ['Войти', 'Giriş yap', 'Sign in'],
    'auth.submitRegister': ['Создать аккаунт', 'Hesap oluştur', 'Create account'],
    'auth.forgot': ['Забыли пароль?', 'Şifremi unuttum', 'Forgot password?'],
    'auth.remember': [
      'Вы останетесь в аккаунте на этом iPhone.',
      'Bu iPhone’da oturumunuz açık kalır.',
      'You’ll stay signed in on this iPhone.',
    ],
    'auth.err.email': [
      'Введите корректный адрес почты.',
      'Geçerli bir e-posta adresi girin.',
      'Enter a valid email address.',
    ],
    'auth.err.password': [
      'Пароль должен быть не короче 10 символов.',
      'Şifre en az 10 karakter olmalı.',
      'The password must be at least 10 characters.',
    ],
    'auth.err.mismatch': ['Пароли не совпадают.', 'Şifreler eşleşmiyor.', 'Passwords don’t match.'],
    'auth.err.terms': [
      'Примите условия, чтобы продолжить.',
      'Devam etmek için koşulları kabul edin.',
      'Accept the terms to continue.',
    ],
    'reset.title': ['Восстановление пароля', 'Şifrenizi sıfırlayın', 'Reset your password'],
    'reset.heroSub': ['Вернём доступ к аккаунту за минуту.', 'Hesabınıza bir dakikada yeniden erişin.', 'Get back into your account in a minute.'],
    'reset.sub': ['Введите почту аккаунта — мы отправим на неё 6-значный код.', 'Hesabınızın e-posta adresini girin; 6 haneli bir kod gönderelim.', 'Enter your account email and we’ll send you a 6-digit code.'],
    'reset.codeSub': ['Введите код из письма и придумайте новый пароль.', 'E-postadaki kodu girin ve yeni bir şifre belirleyin.', 'Enter the code from the email and choose a new password.'],
    'reset.send': ['Отправить код', 'Kod gönder', 'Send code'],
    'reset.sent': ['Код отправлен на {email}. Проверьте и папку «Спам».', '{email} adresine kod gönderdik. Gereksiz (spam) klasörünü de kontrol edin.', 'We sent a code to {email}. Check your spam folder too.'],
    'reset.newPassword': ['Новый пароль', 'Yeni şifre', 'New password'],
    'reset.submit': ['Сменить пароль и войти', 'Şifreyi değiştir ve giriş yap', 'Change password and sign in'],
    'reset.changeEmail': ['Изменить почту', 'E-postayı değiştir', 'Change email'],
    'reset.back': ['Вернуться ко входу', 'Girişe dön', 'Back to sign in'],
    'reset.note': ['После смены пароля остальные устройства выйдут из аккаунта.', 'Şifre değişince diğer cihazlardaki oturumlar kapanır.', 'Changing the password signs you out on your other devices.'],
    'link.row': ['Войти на телевизоре', 'TV’de oturum aç', 'Sign in on a TV'],
    'link.rowHint': ['Отсканируйте QR-код с экрана телевизора', 'TV ekranındaki QR kodu okutun', 'Scan the QR code on the TV screen'],
    'link.scanTitle': ['Наведите камеру на QR-код', 'Kamerayı QR koda tutun', 'Point the camera at the QR code'],
    'link.scanHint': ['QR-код показан на экране входа Colitu на телевизоре.', 'QR kod, TV’deki Colitu giriş ekranında görünür.', 'The QR code is on the Colitu sign-in screen of your TV.'],
    'link.enterCode': ['Ввести код вручную', 'Kodu elle gir', 'Type the code'],
    'link.useCamera': ['Сканировать камерой', 'Kamerayla okut', 'Scan with the camera'],
    'link.codeLabel': ['Код с экрана телевизора', 'TV’de görünen kod', 'Code shown on the TV'],
    'link.continue': ['Продолжить', 'Devam et', 'Continue'],
    'link.cameraDenied': ['Нет доступа к камере. Разрешите его в настройках или введите код вручную.', 'Kamera izni yok. Ayarlardan izin verin ya da kodu elle girin.', 'No camera access. Allow it in settings or type the code.'],
    'link.confirmTitle': ['Войти на этом устройстве?', 'Bu cihazda oturum açılsın mı?', 'Sign in on this device?'],
    'link.confirmBody': ['Устройство войдёт в аккаунт {email}. Подтверждайте, только если это ваше устройство и оно сейчас перед вами. Colitu никогда не просит о таком подтверждении.', 'Cihaz {email} hesabınızla giriş yapacak. Yalnızca şu an önünüzde duran kendi cihazınızsa onaylayın. Colitu sizden asla böyle bir onay istemez.', 'The device will be signed in to {email}. Only approve if it is your own device and it is in front of you now. Colitu will never ask you to do this.'],
    'link.approve': ['Подтвердить вход', 'Girişi onayla', 'Approve sign-in'],
    'link.deny': ['Отклонить', 'Reddet', 'Decline'],
    'link.approved': ['Готово! Телевизор войдёт через несколько секунд.', 'Tamam! TV birkaç saniye içinde giriş yapacak.', 'Done! The TV will sign in within seconds.'],
    'link.invalid': ['Этот QR-код не от Colitu или устарел. Создайте новый на телевизоре.', 'Bu QR kod Colitu’ya ait değil ya da süresi dolmuş. TV’de yenisini oluşturun.', 'This QR code isn’t from Colitu or has expired. Create a new one on the TV.'],
    'link.unknownDevice': ['Неизвестное устройство', 'Bilinmeyen cihaz', 'Unknown device'],
    'plan.freeName': ['Бесплатный тариф', 'Ücretsiz plan', 'Free plan'],
    'plan.status.quota': ['ЛИМИТ ИСЧЕРПАН', 'KOTA DOLDU', 'LIMIT REACHED'],
    'plan.freeHint': ['10 ГБ каждый месяц', 'Her ay 10 GB', '10 GB every month'],
    'plan.upgrade': ['Перейти на безлимит', 'Sınırsız trafiğe geç', 'Go unlimited'],
    'reset.done': ['Пароль изменён. Вы вошли в аккаунт.', 'Şifreniz değiştirildi, giriş yaptınız.', 'Your password was changed and you’re signed in.'],
    'auth.expired': [
      'Сеанс завершён. Войдите снова.',
      'Oturumunuz sona erdi. Lütfen tekrar giriş yapın.',
      'Your session ended. Please sign in again.',
    ],

    // Errors
    'err.credentials': [
      'Неверная почта или пароль.',
      'E-posta veya şifre hatalı.',
      'Email or password is incorrect.',
    ],
    'err.registration': [
      'Эту почту нельзя зарегистрировать: возможно, аккаунт уже существует.',
      'Bu e-posta ile kayıt yapılamıyor; hesap zaten olabilir.',
      'This email can’t be registered. It may already have an account.',
    ],
    'err.rateLimited': [
      'Слишком много попыток. Подождите минуту.',
      'Çok fazla deneme. Lütfen bir dakika bekleyin.',
      'Too many attempts. Please wait a minute.',
    ],
    'err.deviceLimit': [
      'Достигнут лимит устройств вашего тарифа. Отключите старое устройство на colitu.com/devices или добавьте место в тариф.',
      'Paketinizin cihaz sınırına ulaşıldı. colitu.com/devices adresinden eski bir cihazı kaldırın veya paketinize cihaz ekleyin.',
      'Your plan’s device limit is reached. Remove an old device at colitu.com/devices or add a seat to your plan.',
    ],
    'err.noPlan': [
      'Тариф не активен. Выберите тариф, чтобы подключиться.',
      'Paketiniz aktif değil. Bağlanmak için bir paket seçin.',
      'Your plan isn’t active. Choose a plan to connect.',
    ],
    'err.quota': [
      'Лимит трафика на этот период исчерпан.',
      'Bu dönemin trafik kotası doldu.',
      'You’ve used this period’s traffic allowance.',
    ],
    'err.noServers': [
      'Сейчас нет доступных серверов. Попробуйте чуть позже.',
      'Şu anda uygun sunucu yok. Biraz sonra tekrar deneyin.',
      'No server is available right now. Please try again shortly.',
    ],
    'err.network': [
      'Нет связи с сервером Colitu. Проверьте интернет.',
      'Colitu sunucusuna ulaşılamadı. İnternet bağlantınızı kontrol edin.',
      'Can’t reach Colitu. Check your internet connection.',
    ],
    'err.unreachable': [
      'Сервер не отвечает. Попробуйте другую локацию.',
      'Sunucu yanıt vermiyor. Başka bir konum deneyin.',
      'The server isn’t responding. Try another location.',
    ],
    'err.verify': [
      'VPN подключился, но трафик не идёт. Закройте другие VPN-приложения и попробуйте снова.',
      'VPN bağlandı ama trafik akmıyor. Diğer VPN uygulamalarını kapatıp tekrar deneyin.',
      'The VPN connected but traffic isn’t flowing. Close other VPN apps and try again.',
    ],
    'err.tun': [
      'iOS не смог запустить VPN-туннель. Удалите старый профиль Colitu в Настройках и попробуйте снова.',
      'iOS VPN tünelini başlatamadı. Ayarlar’daki eski Colitu VPN profilini kaldırıp tekrar deneyin.',
      'iOS couldn’t start the VPN tunnel. Remove any old Colitu VPN profile in Settings and try again.',
    ],
    'err.permission': [
      'Доступ к VPN не разрешён. Разрешите Colitu в Настройках › VPN.',
      'VPN izni verilmedi. Ayarlar › VPN’den Colitu’ya izin verin.',
      'VPN permission was denied. Allow Colitu in Settings › VPN.',
    ],
    'err.engine': [
      'VPN-движок не запустился с этой конфигурацией. Попробуйте ещё раз.',
      'VPN motoru bu yapılandırmayla başlayamadı. Tekrar deneyin.',
      'The VPN engine couldn’t start with this configuration. Please try again.',
    ],
    'err.blocked': [
      'Подключение сейчас недоступно: {reason}',
      'Bağlantı şu anda kullanılamıyor: {reason}',
      'Connecting isn’t available right now: {reason}',
    ],
    'err.updateRequired': [
      'Обновите Colitu в App Store, чтобы подключиться.',
      'Bağlanmak için Colitu’yu App Store’dan güncelleyin.',
      'Update Colitu from the App Store to connect.',
    ],
    'err.maintenance': [
      'Идут технические работы. Попробуйте чуть позже.',
      'Bakım çalışması sürüyor. Biraz sonra tekrar deneyin.',
      'Maintenance is in progress. Please try again shortly.',
    ],
    'err.generic': [
      'Что-то пошло не так. Попробуйте ещё раз.',
      'Bir şeyler ters gitti. Tekrar deneyin.',
      'Something went wrong. Please try again.',
    ],
    'err.payment': [
      'Не удалось создать платёж. Попробуйте другой способ оплаты.',
      'Ödeme oluşturulamadı. Başka bir ödeme yöntemi deneyin.',
      'The payment couldn’t be created. Try another payment method.',
    ],
    'err.disconnect': [
      'Не удалось отключиться. Попробуйте ещё раз.',
      'Bağlantı kesilemedi. Tekrar deneyin.',
      'Couldn’t disconnect. Please try again.',
    ],
    'err.reconnectFailed': [
      'Соединение потеряно. Нажмите «Подключить», чтобы восстановить.',
      'Bağlantı koptu. Yeniden bağlanmak için “Bağlan”a basın.',
      'The connection dropped. Press Connect to restore it.',
    ],
    'err.region': [
      'Регистрация и вход из вашего региона сейчас недоступны. Если включён другой VPN или прокси, отключите его и попробуйте снова.',
      'Bulunduğunuz bölgeden kayıt ve giriş şu anda kullanılamıyor. Başka bir VPN veya proxy açıksa kapatıp tekrar deneyin.',
      'Sign-up and sign-in aren’t available from your region right now. If another VPN or proxy is on, turn it off and try again.',
    ],
    'err.trialUsed': [
      'На этом iPhone пробный период уже использован. Выберите тариф, чтобы продолжить.',
      'Bu iPhone’da deneme süresi daha önce kullanıldı. Devam etmek için bir paket seçin.',
      'The free trial was already used on this iPhone. Choose a plan to continue.',
    ],
    'err.notVerified': [
      'Сначала подтвердите адрес электронной почты.',
      'Önce e-posta adresinizi doğrulayın.',
      'Please confirm your email address first.',
    ],
    'verify.kicker': [
      'ПОСЛЕДНИЙ ШАГ',
      'SON ADIM',
      'ONE LAST STEP',
    ],
    'verify.title': [
      'Подтвердите почту',
      'E-postanızı doğrulayın',
      'Confirm your email',
    ],
    'verify.sub': [
      'Мы отправили 6-значный код на {email}. Введите его, чтобы активировать аккаунт и бесплатный тариф.',
      '{email} adresine 6 haneli bir kod gönderdik. Hesabınızı ve ücretsiz planınızı açmak için kodu girin.',
      'We sent a 6-digit code to {email}. Enter it to activate your account and free plan.',
    ],
    'verify.code': [
      'Код из письма',
      'E-postadaki kod',
      'Code from the email',
    ],
    'verify.submit': [
      'Подтвердить',
      'Doğrula',
      'Confirm',
    ],
    'verify.resend': [
      'Отправить код ещё раз',
      'Kodu tekrar gönder',
      'Send the code again',
    ],
    'verify.resendIn': [
      'Отправить снова через {n} с',
      '{n} sn sonra tekrar gönderebilirsiniz',
      'Send again in {n}s',
    ],
    'verify.sent': [
      'Новый код отправлен. Проверьте и папку «Спам».',
      'Yeni kod gönderildi. Gereksiz (spam) klasörünü de kontrol edin.',
      'A new code is on its way. Check your spam folder too.',
    ],
    'verify.other': [
      'Войти в другой аккаунт',
      'Başka bir hesapla giriş yap',
      'Use a different account',
    ],
    'verify.hint': [
      'Код действует 15 минут. Письмо не пришло? Проверьте «Спам» или отправьте код ещё раз.',
      'Kod 15 dakika geçerlidir. E-posta gelmediyse spam klasörüne bakın veya kodu yeniden gönderin.',
      'The code is valid for 15 minutes. No email? Check spam or send the code again.',
    ],
    'verify.done': [
      'Почта подтверждена. Добро пожаловать в Colitu!',
      'E-postanız doğrulandı. Colitu’ya hoş geldiniz!',
      'Email confirmed. Welcome to Colitu!',
    ],
    'verify.err.length': [
      'Введите все 6 цифр кода.',
      'Kodun 6 hanesini de girin.',
      'Enter all 6 digits of the code.',
    ],
    'verify.err.invalid': [
      'Неверный код. Проверьте письмо и попробуйте снова.',
      'Kod hatalı. E-postayı kontrol edip tekrar deneyin.',
      'That code isn’t right. Check the email and try again.',
    ],
    'verify.err.expired': [
      'Срок действия кода истёк. Отправьте новый.',
      'Kodun süresi doldu. Yeni bir kod isteyin.',
      'The code has expired. Request a new one.',
    ],
    'verify.err.wait': [
      'Новый код можно запросить через минуту.',
      'Yeni kodu bir dakika sonra isteyebilirsiniz.',
      'You can request a new code in a minute.',
    ],
    'verify.err.mail': [
      'Сейчас не удаётся отправить письмо. Попробуйте чуть позже или напишите в поддержку.',
      'Şu anda e-posta gönderilemiyor. Biraz sonra tekrar deneyin veya destekle iletişime geçin.',
      'We can’t send email right now. Try again shortly or contact support.',
    ],
    'cat.streaming': [
      'Стриминг',
      'Streaming',
      'Streaming',
    ],
    'cat.gaming': [
      'Игры',
      'Oyun',
      'Gaming',
    ],
    'cat.privacy': [
      'Приватность',
      'Gizlilik',
      'Privacy',
    ],
    'cat.speed': [
      'Скорость',
      'Hız',
      'Speed',
    ],
    'cat.torrent': [
      'Торренты',
      'Torrent',
      'Torrent',
    ],
    'cat.ai': [
      'ИИ',
      'Yapay zekâ',
      'AI',
    ],
    'cat.adblock': [
      'Блокировка рекламы',
      'Reklam engelleme',
      'Ad blocking',
    ],
    'cat.empty': [
      'В этой категории пока нет серверов.',
      'Bu kategoride henüz sunucu yok.',
      'No servers in this category yet.',
    ],
    'nav.support': [
      'Поддержка',
      'Destek',
      'Support',
    ],
    'support.title': [
      'Живая поддержка',
      'Canlı destek',
      'Live support',
    ],
    'support.sub': [
      'Напишите нам прямо из приложения. Отвечает живой человек, обычно в течение часа.',
      'Bize doğrudan uygulamadan yazın. Gerçek bir kişi, genellikle bir saat içinde yanıt verir.',
      'Write to us right from the app. A real person answers, usually within an hour.',
    ],
    'support.new': [
      'Новое обращение',
      'Yeni talep',
      'New request',
    ],
    'support.empty': [
      'Обращений пока нет. Опишите проблему — мы поможем.',
      'Henüz talebiniz yok. Sorununuzu anlatın, yardımcı olalım.',
      'No requests yet. Tell us what’s wrong and we’ll help.',
    ],
    'support.subject': [
      'Тема',
      'Konu',
      'Subject',
    ],
    'support.subjectHint': [
      'Например: не подключается',
      'Örn: Bağlanamıyorum',
      'For example: can’t connect',
    ],
    'support.message': [
      'Сообщение',
      'Mesaj',
      'Message',
    ],
    'support.messageHint': [
      'Опишите, что происходит и что вы уже пробовали…',
      'Ne olduğunu ve neler denediğinizi yazın…',
      'Describe what’s happening and what you’ve tried…',
    ],
    'support.reply': [
      'Напишите ответ…',
      'Yanıtınızı yazın…',
      'Write a reply…',
    ],
    'support.attach': [
      'Прикрепить файл',
      'Dosya ekle',
      'Attach a file',
    ],
    'support.attachHint': [
      'Фото, PDF, TXT, ZIP · до 10 МБ',
      'Fotoğraf, PDF, TXT, ZIP · en fazla 10 MB',
      'Photos, PDF, TXT, ZIP · up to 10 MB',
    ],
    'support.diagnostics': [
      'Приложить диагностику',
      'Tanılama bilgisini ekle',
      'Include diagnostics',
    ],
    'support.diagnosticsHint': [
      'Версия приложения и iOS, модель устройства, сеть, состояние подключения и последние ошибки. Без истории посещений.',
      'Uygulama ve iOS sürümü, cihaz modeli, ağ, bağlantı durumu ve son hatalar. Gezinme geçmişi gönderilmez.',
      'App and iOS version, device model, network, connection state and recent errors. No browsing history.',
    ],
    'support.create': [
      'Отправить обращение',
      'Talebi gönder',
      'Send request',
    ],
    'support.cancel': [
      'Отмена',
      'Vazgeç',
      'Cancel',
    ],
    'support.team': [
      'Поддержка Colitu',
      'Colitu Destek',
      'Colitu Support',
    ],
    'support.status.waiting': [
      'ЖДЁТ ОТВЕТА',
      'YANIT BEKLİYOR',
      'AWAITING REPLY',
    ],
    'support.waitingHint': [
      'Мы ответим здесь как можно скорее.',
      'En kısa sürede burada yanıtlayacağız.',
      'We’ll reply here as soon as we can.',
    ],
    'support.status.open': [
      'В РАБОТЕ',
      'İNCELENİYOR',
      'IN PROGRESS',
    ],
    'support.status.resolved': [
      'РЕШЕНО',
      'ÇÖZÜLDÜ',
      'RESOLVED',
    ],
    'support.status.closed': [
      'ЗАКРЫТО',
      'KAPANDI',
      'CLOSED',
    ],
    'support.closed': [
      'Обращение закрыто. Создайте новое, если нужна помощь.',
      'Bu talep kapatıldı. Yardım gerekirse yeni bir talep açın.',
      'This request is closed. Start a new one if you need help.',
    ],
    'support.newReply': [
      'Новый ответ поддержки',
      'Destekten yeni yanıt',
      'New reply from support',
    ],
    'support.sent': [
      'Обращение отправлено. Мы ответим здесь и по почте.',
      'Talebiniz gönderildi. Buradan ve e-postayla yanıt vereceğiz.',
      'Request sent. We’ll answer here and by email.',
    ],
    'support.err.subject': [
      'Укажите тему и сообщение.',
      'Konu ve mesajı yazın.',
      'Add a subject and a message.',
    ],
    'support.err.file': [
      'Файл больше 10 МБ или такой тип не поддерживается.',
      'Dosya 10 MB’tan büyük veya bu tür desteklenmiyor.',
      'The file is over 10 MB or the type isn’t supported.',
    ],
    'support.err.files': [
      'Можно прикрепить не больше 5 файлов.',
      'En fazla 5 dosya ekleyebilirsiniz.',
      'You can attach up to 5 files.',
    ],
    'support.err.unavailable': [
      'Поддержка в приложении временно недоступна. Напишите на support@colitu.com.',
      'Uygulama içi destek geçici olarak kapalı. support@colitu.com adresine yazın.',
      'In-app support is unavailable right now. Write to support@colitu.com.',
    ],
    'support.help': [
      'Справочный центр',
      'Yardım merkezi',
      'Help centre',
    ],
    'support.back': [
      'Все обращения',
      'Tüm talepler',
      'All requests',
    ],
    'support.photo': [
      'Фото',
      'Fotoğraf',
      'Photo',
    ],
    'support.file': [
      'Файл',
      'Dosya',
      'File',
    ],
    'info.reconnected': ['Соединение восстановлено', 'Bağlantı yeniden kuruldu', 'Connection restored'],
    'info.disconnected': ['VPN отключён', 'VPN bağlantısı kesildi', 'VPN disconnected'],
  };

  static const _countries = <String, List<String>>{
    'AE': ['ОАЭ', 'BAE', 'United Arab Emirates'],
    'AM': ['Армения', 'Ermenistan', 'Armenia'],
    'AR': ['Аргентина', 'Arjantin', 'Argentina'],
    'AT': ['Австрия', 'Avusturya', 'Austria'],
    'AU': ['Австралия', 'Avustralya', 'Australia'],
    'AZ': ['Азербайджан', 'Azerbaycan', 'Azerbaijan'],
    'BE': ['Бельгия', 'Belçika', 'Belgium'],
    'BG': ['Болгария', 'Bulgaristan', 'Bulgaria'],
    'BR': ['Бразилия', 'Brezilya', 'Brazil'],
    'BY': ['Беларусь', 'Belarus', 'Belarus'],
    'CA': ['Канада', 'Kanada', 'Canada'],
    'CH': ['Швейцария', 'İsviçre', 'Switzerland'],
    'CN': ['Китай', 'Çin', 'China'],
    'CY': ['Кипр', 'Kıbrıs', 'Cyprus'],
    'CZ': ['Чехия', 'Çekya', 'Czechia'],
    'DE': ['Германия', 'Almanya', 'Germany'],
    'DK': ['Дания', 'Danimarka', 'Denmark'],
    'EE': ['Эстония', 'Estonya', 'Estonia'],
    'ES': ['Испания', 'İspanya', 'Spain'],
    'FI': ['Финляндия', 'Finlandiya', 'Finland'],
    'FR': ['Франция', 'Fransa', 'France'],
    'GB': ['Великобритания', 'Birleşik Krallık', 'United Kingdom'],
    'GE': ['Грузия', 'Gürcistan', 'Georgia'],
    'GR': ['Греция', 'Yunanistan', 'Greece'],
    'HK': ['Гонконг', 'Hong Kong', 'Hong Kong'],
    'HU': ['Венгрия', 'Macaristan', 'Hungary'],
    'IE': ['Ирландия', 'İrlanda', 'Ireland'],
    'IL': ['Израиль', 'İsrail', 'Israel'],
    'IN': ['Индия', 'Hindistan', 'India'],
    'IS': ['Исландия', 'İzlanda', 'Iceland'],
    'IT': ['Италия', 'İtalya', 'Italy'],
    'JP': ['Япония', 'Japonya', 'Japan'],
    'KR': ['Южная Корея', 'Güney Kore', 'South Korea'],
    'KZ': ['Казахстан', 'Kazakistan', 'Kazakhstan'],
    'LT': ['Литва', 'Litvanya', 'Lithuania'],
    'LU': ['Люксембург', 'Lüksemburg', 'Luxembourg'],
    'LV': ['Латвия', 'Letonya', 'Latvia'],
    'MD': ['Молдова', 'Moldova', 'Moldova'],
    'NL': ['Нидерланды', 'Hollanda', 'Netherlands'],
    'NO': ['Норвегия', 'Norveç', 'Norway'],
    'PL': ['Польша', 'Polonya', 'Poland'],
    'PT': ['Португалия', 'Portekiz', 'Portugal'],
    'RO': ['Румыния', 'Romanya', 'Romania'],
    'RS': ['Сербия', 'Sırbistan', 'Serbia'],
    'RU': ['Россия', 'Rusya', 'Russia'],
    'SE': ['Швеция', 'İsveç', 'Sweden'],
    'SG': ['Сингапур', 'Singapur', 'Singapore'],
    'SK': ['Словакия', 'Slovakya', 'Slovakia'],
    'TR': ['Турция', 'Türkiye', 'Türkiye'],
    'UA': ['Украина', 'Ukrayna', 'Ukraine'],
    'US': ['США', 'ABD', 'United States'],
    'UZ': ['Узбекистан', 'Özbekistan', 'Uzbekistan'],
  };
}
