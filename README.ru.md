# Colitu VPN для iOS

[![Build](https://img.shields.io/github/actions/workflow/status/Colitu-VPN/colitu-ios/ci.yml?branch=main&style=flat-square&label=build&labelColor=101014)](https://github.com/Colitu-VPN/colitu-ios/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/Colitu-VPN/colitu-ios?style=flat-square&label=release&labelColor=101014&color=7c6cff)](https://github.com/Colitu-VPN/colitu-ios/tags)
[![License](https://img.shields.io/badge/license-GPL--3.0-7c6cff?style=flat-square&labelColor=101014)](LICENSE)
[![Colitu Network](https://img.shields.io/endpoint?url=https://status.colitu.com/api/github-badge/network&style=flat-square)](https://status.colitu.com)

[English](README.md) · **Русский**

Клиент [Colitu VPN](https://colitu.com) для iPhone и iPad с открытым исходным
кодом. Интерфейс на Flutter управляет расширением Network Extension на Swift
(packet tunnel), которое запускает [Xray-core](https://github.com/XTLS/Xray-core)
через [libXray](https://github.com/XTLS/libXray). Все данные об аккаунте,
тарифе и серверах приходят из API Colitu.

| | |
|---|---|
| Bundle ID | `com.colitu.vpn` (приложение), `com.colitu.vpn.tun` (туннель) |
| Минимальная iOS | 15.0 |
| Языки | русский, английский, турецкий (переключаются сразу в приложении) |
| Установка | [TestFlight](https://testflight.apple.com/join/fnVUd6GQ) (открытая бета) |
| Сайт | <https://colitu.com/ru> |
| Лицензия | [GPL-3.0](LICENSE) |

> Для подключения нужен аккаунт Colitu. В приложении нет зашитых серверов:
> список серверов и профили подключения API Colitu выдаёт каждому устройству.

## Возможности

- **Автоматический выбор протокола.** Hysteria2, VLESS Reality / XHTTP, Trojan
  и Shadowsocks пробуются по очереди, туннель проверяется настоящим запросом,
  а если вариант не работает, приложение переходит к следующему.
- **Весь аккаунт в приложении.** Знакомство, вход и регистрация, сброс пароля,
  подтверждение входа на телевизоре по QR-коду, статус тарифа, устройства,
  трафик и обращения в поддержку. В приложении ничего не продаётся: тариф
  покупается и продлевается в личном кабинете app.colitu.com.
- **Локации серверов** с задержкой, измеренной на устройстве, и запоминанием
  выбранной локации.
- **Постоянный VPN** через правила on-demand iOS и автоподключение.
- **Блокировка рекламы и трекеров** по желанию — через собственные DNS-серверы
  Colitu (DNS-over-HTTPS внутри туннеля; серверы не ведут журнал запросов).
- **Безопасное хранение.** Токены сессии хранятся в связке ключей iOS
  (Keychain); конфигурация туннеля передаётся расширению только через App Group.
- **Без слежки.** Нет Firebase, аналитики, рекламы и SDK для отчётов о сбоях.
  Диагностика остаётся на устройстве, пока вы сами не отправите отчёт; данные
  входа и адреса e-mail в нём скрыты.

## Сборка

Нужны macOS с Xcode, Flutter (stable), Go и Python 3.

```bash
flutter pub get
scripts/build-libxray.sh          # собирает swift/All/LibXray.xcframework из исходников
scripts/generate-ffi-bindings.sh  # заново генерирует привязки Dart FFI
flutter analyze --no-fatal-infos
flutter test
flutter build ios --simulator --no-codesign
```

Параметры сборки (`--dart-define`): `COLITU_API_BASE_URL` (по умолчанию
`https://api.colitu.com/api/v1`) и `COLITU_ADBLOCK_DOH` (адреса DNS-серверов
блокировки рекламы через запятую; без него переключатель скрыт). Подробнее —
в [docs/build.md](docs/build.md).

## Безопасность

Об уязвимостях сообщайте на **security@colitu.com**, а не в публичных issue.
См. [SECURITY.md](SECURITY.md) и [Security Whitepaper](https://colitu.com/ru/security).

## Лицензия

Colitu VPN для iOS — свободное ПО под [GNU GPL v3.0](LICENSE). Сторонние
компоненты и их лицензии перечислены в [NOTICE](NOTICE). Название и логотип
Colitu не входят в GPL: если публикуете свою сборку, используйте своё
название и логотип.
