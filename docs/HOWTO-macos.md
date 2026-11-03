# HOWTO (macOS, Intel): установка и тестирование клиента sshtun

> **Статус: спецификация порта.** Клиент сейчас Linux-only: бэкенд
> маршрутизации завязан на `iproute2` (`ip route`, policy tables),
> `resolvectl`, `flock`, `getent`, `/run` — этого нет на macOS.
> Платформонезависимая часть (токены AS/стран, `generated/`-кэш, fetch,
> exclude/include списки) портирования почти не требует. Этот документ —
> целевая установка и тест-матрица: после реализации порта шаги ниже
> должны выполняться как написано, без правок документа.
>
> Intel vs Apple Silicon: разницы нет — всё на bash и встроенном OpenSSH.

---

## 1. Служба на macOS: launchd (аналог systemd)

Соответствие концепций:

| systemd (Linux) | launchd (macOS) |
|---|---|
| юнит `/etc/systemd/system/sshtun.service` | LaunchDaemon `/Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist` |
| `Restart=always` + `RestartSec=5` | `KeepAlive=true` + `ThrottleInterval=5` |
| автостарт: `systemctl enable` | `RunAtLoad=true` + `launchctl load -w` |
| `systemctl start/stop` | `launchctl kickstart -k gui/0/... ` (даemons: `system/...`) / `launchctl stop` |
| `systemctl status` + `journalctl -u` | `launchctl list`, `log show --predicate`, лог-файлы из plist |

Целевой plist (ставится установщиком, **не загружен** по умолчанию —
аналог «выключенного юнита»):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>ru.vpn-over-ssh.sshtun</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/sshtun</string>
        <string>up</string>
        <string>--foreground</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <string>EXCLUDES_DIR</string><string>/Users/USER/sshtun</string>
        <string>KEY_FILE</string><string>/Users/USER/.ssh/sshtun_ed25519</string>
    </dict>
    <!-- KeepAlive ≈ Restart=always: перезапуск при любом падении цепочки;
         явный 'launchctl stop' чтится и не перезапускает. -->
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <!-- автостарт при загрузке: включается 'launchctl load -w' -->
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>/var/log/sshtun.log</string>
    <key>StandardErrorPath</key><string>/var/log/sshtun.log</string>
</dict>
</plist>
```

Управление (после реализации порта):

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist   # старт
sudo launchctl bootout system/ru.vpn-over-ssh.sshtun                                 # стоп + выгрузка
sudo launchctl load -w /Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist           # старт + автозагрузка (enable)
sudo launchctl unload -w /Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist         # стоп + убрать автозагрузку (disable)
tail -f /var/log/sshtun.log                                                          # лог
```

## 2. Что портировать в бэкенде (Linux → macOS)

| Подсистема | Сейчас (Linux) | Цель (macOS) |
|---|---|---|
| интерфейс | `ip link/addr`, `tunN` | `ifconfig utunN inet <local> <remote> netmask 255.255.255.255 up` (`ssh -w` на macOS создаёт utun) |
| full-tunnel | `0.0.0.0/1`+`128.0.0.0/1` в table 201 | те же полутора default'а: `route add -net 0.0.0.0/1 -interface utunN` |
| excludes | policy table 200 (`ip route`, LPM бесплатно) | `route add -net CIDR <шлюз>` в основную таблицу (LPM у ядра тот же; «main чистая» недостижима — `netstat -rn` будет большим) |
| bypass до сервера | `route replace <ip>/32 table 200` | `route add -host <ip> <шлюз>` |
| DNS | `resolvectl dns/domain` | `networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8` + снятие при down (запоминать предыдущие) |
| IPv6 blackhole | `ip -6 route replace blackhole ::/0 metric 1` | `route add -inet6 ::/0 -blackhole` (проверить на живой системе) |
| state/lock | `/run/sshtun`, `flock` | `/var/run/sshtun`, `shlock` (есть в macOS) |
| резолв хоста | `getent ahostsv4` | `dscacheutil -q host -a name <host>` |
| модуль tun | `modprobe tun` | не нужно (утun встроен) |

Изменится семантика одного пункта: **policy routing (отдельные таблицы) на macOS
нет** — маршруты исключений живут в основной таблице, как в Linux-версии до v1.2.
Семантика префиксов (LPM, include поверх exclude на равных) сохраняется за счёт
порядка добавления: exclude первыми, include поверх (`route add` перезаписывает
совпадающий префикс).

Супервизор (`--foreground`, grace-период, маркер SUPERVISED) и обёртка
(ensure_autogen, restore_owner, `sshtun down/restart` через службу) —
платформонезависимы, переносятся как есть.

## 3. Установка (целевая)

```bash
# 1) зависимости: только встроенный OpenSSH (ssh -w поддерживает utun) и root.
#    Xcode CLT не нужен (скрипты на bash).

# 2) установка (аналог install_client.sh install):
sudo bash install_macos.sh install
#    - /opt/sshtun_client/sshtun_full.sh + sshtun_pool_client.sh (порт)
#    - /usr/local/bin/sshtun -> symlink
#    - ~/sshtun/ из шаблонов examples/ (существующие файлы не трогает)
#    - /Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist (НЕ загружен)

# 3) ключ (тот же, что на Linux-клиентах):
ssh-keygen -t ed25519 -f ~/.ssh/sshtun_ed25519 -N "" -C "macbook-$(hostname -s)"
#    публичный ключ добавить на сервер в /opt/sshtun_pool/authorized_keys

# 4) ручной старт (без службы):
sshtun up
curl -4 ifconfig.me    # ожидается IP сервера

# 5) служба (досмотр + перезапуски):
sudo launchctl bootstrap system /Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist
#    автостарт при загрузке: sudo launchctl load -w <plist>
```

## 4. Тест-матрица (аналог HOWTO Linux, разделы 1–5a)

TEST-NET адреса те же: 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24.

### 4.1 База: exclude add / del (live, без перезапуска)

```bash
sshtun up
sshtun exclude add 203.0.113.0/24 198.51.100.7
route -n get 203.0.113.0        # ожидается: gateway <ваш шлюз>, не utun
route -n get 198.51.100.7       # то же
sshtun exclude add 178.62.9.171 -- мой дроплет
grep myip ~/sshtun/excludes-custom.txt
sshtun exclude del 203.0.113.0/24 198.51.100.7 178.62.9.171
route -n get 203.0.113.0        # ожидается: interface utun (в туннель)
```

### 4.2 Приоритеты (LPM + include)

```bash
sshtun include add 203.0.113.9
route -n get 203.0.113.9        # via utun
sshtun exclude add 203.0.113.9  # равный префикс: exclude поверх (порядок добавления)
route -n get 203.0.113.9        # via шлюз
sshtun include add 203.0.113.0/24
sshtun exclude add 203.0.113.0/25   # /25 точнее: LPM побеждает
route -n get 203.0.113.10       # utun; route -n get 203.0.113.70 -> шлюз
sshtun exclude del 203.0.113.0/25; sshtun include del 203.0.113.0/24; sshtun exclude del 203.0.113.9
```

### 4.3 AS и страны (платформонезависимо, как в Linux-HOWTO §3)

```bash
TD=$(mktemp -d); cp ~/sshtun/excludes.txt ~/sshtun/excludes-custom.txt "$TD"
EXCLUDES_DIR=$TD sshtun fetch-as AS62597
EXCLUDES_DIR=$TD sshtun fetch-country de
EXCLUDES_DIR=$TD sshtun refresh
EXCLUDES_DIR=$TD sshtun list
# ожидается: файлы-токены содержат только токены, префиксы — в $TD/generated/
```

Офлайн-fallback: при `up` без сети — старт на кэше `~/sshtun/generated/`
с предупреждением (как Linux, HOWTO §3f).

### 4.4 Служба launchd

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/ru.vpn-over-ssh.sshtun.plist
sleep 12; sshtun status                          # running

# досмотр: убить ssh (SSH_PID из state, как в Linux-HOWTO §5a)
sudo kill $(sudo bash -c 'source /var/run/sshtun/state; echo $SSH_PID')
sleep 15; sshtun status                          # running снова (~13-15 с простоя)

# kill sudo/main — тоже рестарт (KeepAlive)
# штатные остановки БЕЗ рестарта:
sudo launchctl stop ru.vpn-over-ssh.sshtun       # через bootout для полного стопа
sshtun down                                      # обёртка пойдёт через launchctl (SUPERVISED=1)
```

Ожидаемые тайминги: рестарт ~10–15 с (ThrottleInterval 5 с + grace 5 с + старт).

### 4.5 Сон ноутбука (главный сценарий)

```bash
# служба загружена, туннель работает
pmset sleepnow            # или закрыть крышку
# разбудить через минуту
sshtun status             # сам поднялся обратно (KeepAlive)
```

## 5. Чек-лист готовности порта

- [ ] `sshtun up/down/restart/status/doctor` работают на macOS (Intel)
- [ ] мультисервер: `server add/list/use/del` — работают без изменений (это
      файловые операции над `~/sshtun/`; переключение переподнимает туннель)
- [ ] full-tunnel + excludes: `route -n get` на TEST-NET сходится с ожиданиями (4.1–4.2)
- [ ] DNS: `scutil --dns` показывает 1.1.1.1/8.8.8.8 при работе; после down — восстановлены прежние
- [ ] fetch/refresh/--remove: токены и `generated/` (4.3), офлайн-fallback
- [ ] служба: kill ssh/sudo → рестарт; `sshtun down`/`launchctl stop` → без рестарта (4.4)
- [ ] сон → самовосстановление (4.5)
- [ ] `install_macos.sh install/uninstall` — файлы, plist, данные не теряются
- [ ] лог службы: `tail -f /var/log/sshtun.log`
