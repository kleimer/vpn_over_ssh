# Мануал: переключение сервера vpn_over_ssh на BBR

Пошаговая инструкция для вашего сервера vpn_over_ssh (Linux). Перед началом
прочти раздел «Что произойдёт» — там два важных момента: sysctl влияет на
**весь** TCP сервера, и установщик перезапустит сервисы туннельного sshd
(активные клиентские туннели кратковременно оборвутся и переподключатся
сами).

---

## 0. Что произойдёт (кратко)

1. В ядро загрузится модуль `tcp_bbr` и пропишется в автозагрузку
   (`/etc/modules-load.d/vpn-over-ssh-tcp_bbr.conf`).
2. Системный алгоритм TCP станет `bbr`:
   `/etc/sysctl.d/90-vpn-over-ssh-congestion.conf` →
   `net.ipv4.tcp_congestion_control=bbr`, применится сразу.
3. Установщик пересоздаст конфигурацию и **перезапустит** сервисы
   `sshtun-pool-network` и `sshtun-pool-sshd` (отдельный sshd на порту
   65523, основной SSH на 22/tcp не трогается).
4. Активные клиентские туннели оборвутся на время рестарта (~1–2 с на
   сервере + 10–15 с автоматического переподключения на клиентах со
   службой systemd). Если клиент без службы — подними вручную `sshtun up`.

**BBR — sender-side алгоритм и системная настройка.** Она действует на все
исходящие TCP-соединения сервера (основной sshd, веб и т.д.), не только на
туннели. Откат возможен в любой момент (раздел 5). Влияет только на новые
TCP-соединения — уже установленные сессии продолжают со старым алгоритмом.

## 1. Подготовка

```bash
ssh root@<ваш-сервер>    # или свой способ попасть на сервер

# 1.1 Проверь, что ядро умеет BBR:
sysctl net.ipv4.tcp_available_congestion_control
# ОЖИДАЕТСЯ в выводе наличие "bbr", например:  reno cubic bbr
# Если bbr НТЕТ — ядро без BBR (очень старый дистрибутив): обнови ядро/ОС,
# дальше можно не продолжать (установщик сам откажет без последствий).

# 1.2 Проверь текущее значение (для «до/после»):
sysctl net.ipv4.tcp_congestion_control      # скорее всего cubic

# 1.3 Убедись, что на сервере есть репозиторий (установщик запускается из него):
ls ~/vpn_over_ssh/install_server.sh 2>/dev/null || ls /opt/vpn_over_ssh/install_server.sh 2>/dev/null
# если репозитория нет:
#   git clone https://github.com/woldemar/vpn_over_ssh.git ~/vpn_over_ssh
# если есть — обнови до актуального main:
#   cd ~/vpn_over_ssh && git fetch --tags && git checkout main && git pull --ff-only
```

## 2. Включение BBR

```bash
cd ~/vpn_over_ssh   # каталог репозитория

sudo TCP_CONGESTION_CONTROL=bbr bash install_server.sh
```

Установщик идемпотентен: он заново применит всю серверную конфигурацию
(пул tun, NAT, sshd_config) — изменений к уже работающей схеме это не
внесёт, кроме рестарта сервисов.

**Ожидаемый вывод (фрагмент):**

```
[...] Модуль tcp_bbr загружен и добавлен в автозагрузку: /etc/modules-load.d/vpn-over-ssh-tcp_bbr.conf
[...] net.ipv4.tcp_congestion_control=bbr (файл: /etc/sysctl.d/90-vpn-over-ssh-congestion.conf)
...
TCP congestion control:
  net.ipv4.tcp_congestion_control=bbr (файл /etc/sysctl.d/90-vpn-over-ssh-congestion.conf)
```

Если вместо этого `[ERROR] Модуль tcp_bbr недоступен` — система не
изменена, см. п. 1.1.

## 3. Проверка на сервере

```bash
sysctl net.ipv4.tcp_congestion_control                 # -> bbr
cat /etc/sysctl.d/90-vpn-over-ssh-congestion.conf      # файл на месте
systemctl status sshtun-pool-sshd --no-pager           # active (running)
systemctl status sshtun-pool-network --no-pager        # active (exited), ок
ss -lntp | grep 65523                                  # слушает
```

## 4. Проверка и замер с клиента

```bash
# на клиенте (ноутбук): переподнять туннель — чтобы SSH-соединение
# установилось уже поверх BBR (алгоритм цепляется на новые TCP):
sshtun restart
sshtun status                      # running

# замер «после» (в идеале — в те же «плохие» часы, когда линк шумный):
ping -c 30 -i 0.3 <IP_СЕРВЕРА>     # базовый линк: mdev линка не изменится
ping -c 30 -i 0.3 8.8.8.8          # туннель: avg стремится к «линк + 1-3 мс»,
                                   # спайки 300-500 мс (RTO) должны исчезнуть
```

Полный протокол замеров и трактовка цифр: `docs/HOWTO.md`, раздел 7.

## 5. Откат к CUBIC

```bash
# на сервере:
cd ~/vpn_over_ssh
sudo TCP_CONGESTION_CONTROL=cubic bash install_server.sh

# проверка:
sysctl net.ipv4.tcp_congestion_control    # -> cubic

# на клиенте:
sshtun restart
```

Либо вручную, без установщика:

```bash
rm /etc/sysctl.d/90-vpn-over-ssh-congestion.conf \
   /etc/modules-load.d/vpn-over-ssh-tcp_bbr.conf
sysctl -w net.ipv4.tcp_congestion_control=cubic
```

(Загруженный модуль `tcp_bbr` в памяти безвреден и выгрузится при ребуте;
при желании: `modprobe -r tcp_bbr`.)

## 6. Если что-то пошло не так

- **`[ERROR] Модуль tcp_bbr недоступен`** — ядро без BBR. Система не
  изменена. Обнови ядро/ОС на сервере и повтори.
- **`[ERROR] Алгоритм 'bbr' недоступен в ядре`** — то же самое после
  попытки modprobe.
- **Туннели не переподключились сами** (клиент без systemd-службы):
  `sshtun up` на клиенте.
- **Основной SSH (22/tcp) не работает** — установщик его не трогает;
  смотри независимые причины (это вне зоны данного мануала).
