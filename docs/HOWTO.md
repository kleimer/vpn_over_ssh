# HOWTO: тестирование клиента sshtun

Пошаговая инструкция для проверки нового функционала: исключения AS/стран,
include-список, runtime-применение маршрутов, установщик.

Предполагается, что клиент установлен (`install_client.sh install`) и
команда `sshtun` доступна (`/usr/local/bin/sshtun`). Все команды — от
обычного пользователя, sudo запрашивается самим скриптом.

> Для тестов используются адреса из диапазонов TEST-NET (192.0.2.0/24,
> 198.51.100.0/24, 203.0.113.0/24) — они гарантированно ни с чем не
> пересекаются. Реальные IP в тестах не нужны.

---

## 0. Подготовка

```bash
# бэкап данных маршрутной политики (обязательно перед любыми экспериментами)
cp -a ~/sshtun ~/sshtun.bak.$(date +%Y%m%d)

# туннель должен быть поднят
sshtun status
```

Адрес сервера задаётся локально (в коде и репозитории дефолта нет):
в `~/sshtun/server.conf` (строка `SERVER_HOST=...`, файл создаёт
установщик) или через env `SERVER_HOST=... sshtun up`.

Если туннель не поднят: `sshtun up` (проверьте `curl -4 ifconfig.me` —
должен показать IP сервера).

## 1. База: exclude add / del (пользовательские исключения)

```bash
sshtun exclude add 203.0.113.0/24 198.51.100.7     # подсеть + одиночный адрес (станет /32)
ip route show 203.0.113.0/24               # ожидается: via <ваш шлюз> dev <интерфейс>
ip route show 198.51.100.7                 # то же для /32
grep -E '203\.0\.113|198\.51\.100' ~/sshtun/excludes-custom.txt

# с комментарием (появится в файле и в 'sshtun list'):
sshtun exclude add 178.62.9.171 -- мой дроплет в DigitalOcean

sshtun exclude del 203.0.113.0/24 198.51.100.7 178.62.9.171  # откат; маршруты снимутся
ip route show 203.0.113.0/24               # ожидается: пусто (трафик упадёт в туннель)
```

Повторный `exclude add` того же CIDR не дублирует строку; при повторе
с `-- комментарием` комментарий обновляется. `exclude del` ищет по первому
токену строки — удалит и строку с комментарием. Комментарии поддерживают
и include-список, и файлы-токенов `excludes-as.txt` /
`excludes-country.txt` (сохраняются между refresh).

## 2. Include-список: include add / del и приоритеты

Семантика (LPM):
1. Более длинный префикс побеждает **всегда**, независимо от списка.
2. На равных префиксах include побеждает exclude.

```bash
# 2a. include add заворачивает в туннель
sshtun include add 203.0.113.9
ip route show 203.0.113.9        # ожидается: via 10.250.x.y dev tunN

# 2b. равный префикс: exclude add перекрывает include (кто последний — тот и правит
#     live-маршрут; файлы оба помнят свои записи)
sshtun exclude add 203.0.113.9
ip route show 203.0.113.9        # ожидается: via <шлюз> dev <интерфейс> (direct)

# 2c. LPM: более точный exclude побеждает внутри include
sshtun exclude del 203.0.113.9           # снять равный префикс
sshtun include add 203.0.113.0/24  # весь диапазон — в туннель
sshtun exclude add 203.0.113.0/25        # половина диапазона — напрямую (/25 точнее /24)
ip route show 203.0.113.0/24     # via 10.250... (tun)
ip route show 203.0.113.0/25     # via <шлюз>... (direct)
ip route show 203.0.113.128/25   # via 10.250... (tun) — вторая половина

# откат
sshtun exclude del 203.0.113.0/25
sshtun include del 203.0.113.0/24
```

## 3. AS и страны: fetch-as / fetch-country / refresh / --remove

> Тесты 3a–3c выполняйте в изолированном каталоге (EXCLUDES_DIR), чтобы не
> ставить тысячи реальных маршрутов. Тест 3d — на живом туннеле с маленькой AS.
>
> Схема файлов: `excludes-as.txt` / `excludes-country.txt` — файлы-ИСТОЧНИКИ
> (только токены `AS9009` / `ru`), префиксы разворачиваются в
> `generated/excludes-as.txt` / `generated/excludes-country.txt`.

```bash
TD=$(mktemp -d); cp ~/sshtun/excludes.txt ~/sshtun/excludes-custom.txt "$TD"

# 3a. базовый fetch и объединение источников
EXCLUDES_DIR=$TD sshtun fetch-as AS62597        # небольшая AS, ~16-30 префиксов
EXCLUDES_DIR=$TD sshtun fetch-as AS9009         # большая, ~3000-4500
grep -v '^#' "$TD/excludes-as.txt" | grep .      # ожидается: только токены AS62597 + AS9009
ls "$TD/generated/"                              # ожидается: excludes-as.txt (префиксы)
grep -c '^[0-9]' "$TD/generated/excludes-as.txt" # ожидается: тысячи префиксов

# 3b. страны
EXCLUDES_DIR=$TD sshtun fetch-country ru de
EXCLUDES_DIR=$TD sshtun list                    # сводка: токены + счётчики кэша

# 3c. refresh перекачивает всё по токенам; --remove убирает источники
EXCLUDES_DIR=$TD sshtun refresh
EXCLUDES_DIR=$TD sshtun fetch-as --remove AS9009
grep -v '^#' "$TD/excludes-as.txt" | grep .      # остался только AS62597
EXCLUDES_DIR=$TD sshtun fetch-as --remove AS62597
ls "$TD/excludes-as.txt" 2>&1                   # файла нет — удалён вместе с последним токеном
ls "$TD/generated/"                             # excludes-as.txt тоже удалён
EXCLUDES_DIR=$TD sshtun fetch-country --remove ru de   # аналогично
rm -rf "$TD"

# 3d. живое применение на работающем туннеле (маленькая AS, префиксы TEST-NET
#     не используются — будет реальный трафик по этим маршрутам, это нормально)
sshtun fetch-as AS62597
ip route show table 200 | wc -l   # до
sshtun fetch-as --remove AS62597  # дифф (в основном del) применится сразу
ip route show table 200 | wc -l   # после: вернулось как было
```

Контроль скорости: применение диффа в тысячи маршрутов занимает доли
секунды (один netlink-батч). Если видите минуты — баг, сообщите.

### 3e. Токены прямо в файлах (без команд fetch)

Файлы-токены — это и есть список AS/стран, правится как обычный текст,
по одному токену на строку:

```bash
echo 'AS9009' >> ~/sshtun/excludes-as.txt      # номер AS (с буквами AS)
echo 'ru'    >> ~/sshtun/excludes-country.txt  # код страны, 2 буквы ISO
```

Такой токен развернётся в префиксы:
- при `sshtun refresh`;
- автоматически при следующем `sshtun up` / `restart` (перед стартом).

Убрать токен: `sshtun fetch-as --remove AS9009` / `sshtun fetch-country
--remove ru` — он исчезнет из файла и не появится снова при refresh.
Комментарии (`# ...`) в файлах-токенах сохраняются между refresh.

### 3f. Офлайн-fallback (без сети)

Если при `up` нет сети, а токены есть — туннель не падает, а поднимается
на последнем кэше из `~/sshtun/generated/` (с предупреждением в логе).
Проверка вручную не обязательна: просто имейте в виду, что кэш — это
защита от старта офлайн, данные в нём могут быть устаревшими до ближайшего
успешного `refresh`.

## 4. Рестарт и состояние

```bash
sshtun restart      # туннель переподнимется, все файлы подхватятся заново
sshtun status
sshtun doctor
sshtun list         # эффективная политика: include-force + 4 exclude-файла
```

После `restart` маршруты из includes-force.txt и исключений должны быть
на месте: `ip route show table 200 | wc -l` вырастет на количество
префиксов.

## 4a. Policy routing (после обновления на таблицы)

Маршруты живут в отдельных таблицах, main не трогается:

```bash
ip rule show | grep 2510        # ожидается 2 правила: 25100 -> 200, 25110 -> 201
ip route                        # main чистая: default + connected, без префиксов
ip route show table 200 | wc -l # ~11k: исключения direct + include via tun + LAN + bypass
ip route show table 201         # 0.0.0.0/1 + 128.0.0.0/1 via tun
ip route get <LAN_шлюз>        # LAN напрямую (table 200), не через tun
```

Проверка полного цикла (down не оставляет следов):

```bash
sshtun down
ip rule show | grep -c 2510     # 0
ip route show table 200 | wc -l # 0
ip route show table 201 | wc -l # 0
sshtun up
```

> Миграция: после обновления на эту версию выполните `sshtun restart`
> один раз — старая схема (маршруты в main) будет зачищена автоматически.

## 5. Установщик

```bash
sudo bash install_client.sh install       # установить/обновить копию в /opt
sshtun --help                             # работает из /usr/local/bin
sudo bash install_client.sh reinstall     # чистая переустановка
sudo bash install_client.sh uninstall     # убрать /opt + symlink (~/sshtun останется)
sudo bash install_client.sh uninstall --purge   # и ~/sshtun тоже (осторожно)
sudo bash install_client.sh update        # git pull + install
```

Проверка после install: `readlink -f /usr/local/bin/sshtun` →
`/opt/sshtun_client/sshtun_full.sh`; `sshtun list` работает (клиентский
скрипт находится по symlink-разрешению).

## 5a. Служба systemd: досмотр и автостарт

После `install_client.sh install` юнит лежит в
`/etc/systemd/system/sshtun.service`, **выключен**:

```bash
systemctl status sshtun            # inactive (dead) — норма
sudo systemctl start sshtun        # туннель под досмотром
systemctl status sshtun            # active (running): sshtun up --foreground
sshtun status                      # туннель работает как обычно
```

Проверка досмотра (переживает «смерть» ssh):

```bash
sudo kill $(sudo bash -c 'source /run/sshtun/state; echo $SSH_PID')   # имитируем падение
sleep 8                             # RestartSec=5 + время поднятия
systemctl status sshtun             # снова active; N restarts в статистике юнита
sshtun status                       # туннель поднялся, маршруты на месте
```

> Убивайте именно ssh-процесс (SSH_PID из state) — команда выше делает это
> сама. Цепочка процессов службы: `wrapper -> sudo -> клиент -> ssh`.
> Случайный kill по sudo/wrapper тоже безопасен (служба перезапустится),
> но тест «падения» должен бить по ssh.

Остановки БЕЗ рестарта (проверить каждую) — при `Restart=always` это
работает через явный stop по systemd:

```bash
sudo systemctl stop sshtun         # штатно, остаётся inactive
sudo systemctl start sshtun
sshtun down                        # обёртка сама пойдёт через systemctl stop
systemctl is-active sshtun         # inactive (dead) — без рестарта
sshtun restart                     # при службе: systemctl restart sshtun
```

Автостарт при загрузке (опционально, требуется ключ без passphrase):

```bash
sudo systemctl enable sshtun       # включить автостарт
sudo systemctl disable sshtun      # выключить
journalctl -u sshtun -f            # лог службы
```

> Ключ с passphrase в службе работать не будет (SSH BatchMode) — для
> службы используйте ключ без пароля, либо не пользуйтесь службой и
> поднимайте туннель вручную `sshtun up` как раньше.

> Миграция данных: старые `excludes-as.txt`/`excludes-country.txt` с
> инлайн-префиксами (до этой версии) подхватываются автоматически —
> источники берутся из шапки, префиксы переносятся в `generated/`
> (офлайн-миграция, если нет сети). Первый же `refresh` перекачает их.

## 5b. Файлы-токены: что где лежит (после обновления)

```bash
cat ~/sshtun/excludes-as.txt        # только токены: AS62597, AS9009...
cat ~/sshtun/excludes-country.txt   # только токены: ru...
ls ~/sshtun/generated/              # развёрнутые префиксы (не править)
sshtun list                         # сводка: токены + счётчики префиксов кэша
```

Добавление AS/страны — либо командами (`fetch-as`/`fetch-country`), либо
строкой-токеном прямо в файл (развернётся при `refresh`/`up`).

## 6. Производительность батча (изолированный тест ядра)

Не трогает main-таблицу (отдельная таблица 100):

```bash
sudo bash -c '
gen() { seq 1 5000 | awk -v op="$1" "{printf \"route %s 10.%d.%d.0/24 dev lo table 100\n\", op, int((\$1-1)/255), (\$1-1)%255}"; }
trap "gen del | ip -force -batch - 2>/dev/null; true" EXIT
gen replace > /tmp/bt.txt
time ip -force -batch /tmp/bt.txt
echo "в таблице 100: $(ip -4 route show table 100 | grep -c "^10\.")"
gen del > /tmp/bt.txt
time ip -force -batch /tmp/bt.txt
'
```

Ожидается: 5000 маршрутов add и del за ~0.1–0.3 с.

## 7. Контроль конгестии TCP: BBR / CUBIC (опционально)

Проблема: весь туннель — один SSH/TCP-поток. На шумном путиклиент ↔ сервер
(потери, вечерняя конгестия транзита) стандартный CUBIC принимает случайные
потери за перегрузку: обвал окна → RTO-спайки 300–500 мс у ВСЕГО туннелированного
трафика (head-of-line blocking). BBR вместо реакции на потери **замеряет**
ёмкость пути и шлёт с неё — спайки снимаются. Это sender-side алгоритм:
полный эффект только когда включён на **обоих** концах внешнего TCP.

> Опция полностью необязательна: по умолчанию (env не задан) установщики
> системный алгоритм не трогают. Откат — перустановка с `TCP_CONGESTION_CONTROL=cubic`
> или удаление файла `/etc/sysctl.d/90-vpn-over-ssh-congestion.conf`.

### 7a. Проверка исходного состояния

```bash
sysctl net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control
ping -c 30 -i 0.3 <IP_СЕРВЕРА>        # до сервера снаружи — базовый джиттер линка
ping -c 30 -i 0.3 8.8.8.8              # через туннель — сравнить после
```

### 7b. Включение BBR (клиент и сервер)

```bash
# на клиенте (эта машина):
sudo TCP_CONGESTION_CONTROL=bbr bash install_client.sh install
sshtun restart                          # важно: BBR действует на НОВЫЕ TCP-соединения

# на сервере:
sudo TCP_CONGESTION_CONTROL=bbr bash install_server.sh
# sshd перезапустится установщиком; действует на новые подключения
```

Проверка: `sysctl net.ipv4.tcp_congestion_control` → `bbr` (с обеих сторон).

### 7c. Замер эффекта

```bash
ping -c 30 -i 0.3 <IP_СЕРВЕРА>   # линк: mdev должен быть ~как был (BBR линк не чинит)
ping -c 30 -i 0.3 8.8.8.8         # туннель: mdev и max должны заметно упасть
```

Ожидание: среднее через туннель стремится к «линк + 1–3 мс», спайки
RTO-типа (300–500 мс) исчезают. Если путь в момент замера сам ровный —
разницы не будет, сравнивайте в «плохие» часы.

### 7d. Откат к CUBIC

```bash
sudo TCP_CONGESTION_CONTROL=cubic bash install_client.sh install   # клиент
sudo TCP_CONGESTION_CONTROL=cubic bash install_server.sh           # сервер
sshtun restart
# либо полный снос настроек (клиент): sudo bash install_client.sh uninstall
```

## 8. Мультисервер: профили и переключение

Идея: библиотека профилей `~/sshtun/servers/<имя>.conf` + активный
`~/sshtun/server.conf`. `server use <имя>` атомарно копирует профиль в
`server.conf` (с маркером `# sshtun-profile:`) и, если туннель работает,
переподнимает его (под systemd — через `systemctl restart`, разрыв ~5–10 с).
Если туннель не работает — профиль просто применится при следующем `up`.
Маршрутная политика (exclude/include) от сервера не зависит и не сбрасывается.

### 8a. Подготовка

```bash
cp -a ~/sshtun ~/sshtun.bak.$(date +%Y%m%d-%H%M)   # бэкап (server.conf будет перезаписан)
```

### 8b. Добавление профилей

```bash
# второй сервер (реальный адрес вместо плейсхолдера):
sshtun server add backup 203.0.113.20 --port 65523 --user sshvpn \
  --key ~/.ssh/sshtun_ed25519 -- "запасной"
# миграция текущего server.conf в профиль (адрес возьмите из ~/sshtun/server.conf):
sshtun server add main 203.0.113.10 -- "основной"
sshtun server list
```

Ожидается: список с колонками имя/адрес/порт/комментарий; активный помечен
`(server.conf без профиля) <адрес>`, пока `use` не вызывался.

### 8c. Переключение

```bash
sshtun server use backup      # туннель переподнимется на другом сервере
sshtun status                 # первая строка: "Профиль: backup (<адрес>)"
sshtun server list            # '*' — у backup
sshtun server use backup      # идемпотентно: "уже активен", рестарта нет
ip ro get 203.0.113.55        # проверка, что маршрутизация жива после переключения
```

Вернуться: `sshtun server use main`. Стоп/снятие профиля: `sshtun down`
(конфиг остаётся, при `up` используется активный профиль).

### 8d. Ошибочные пути (ожидается отказ)

```bash
sshtun server use ghost       # нет такого профиля
sshtun server del main        # отказ: профиль активен
sshtun server add backup ...  # отказ: профиль уже существует
sshtun server add 'bad!' ...  # отказ: недопустимое имя
```

### 8e. Что НЕ делает эта фича

- Не поднимает два туннеля одновременно (раздельная маршрутизация по
  серверам — отдельная задача, пока не реализована).
- Не failover'ит сама: переключение только по команде.
- env `SERVER_HOST` перекрывает любые профили (предупреждение об этом
  печатает `server list` и `server use`).

## 9. Чек-лист перед тегом релиза

- [ ] `sshtun exclude add/del` меняют маршруты без перезапуска туннеля
- [ ] `include add` побеждает exclude на равном префиксе; LPM-семантика (2c) верна
- [ ] policy routing: правила 25100/25110 есть при работе, нет после `down`; main чистая (4a)
- [ ] `restart`/`down`/`up` быстрые (~3 с / <1 с / ~3 с даже со списком страны)
- [ ] `fetch-as`/`fetch-country`/`refresh` корректно объединяют и убирают источники; файлы-токены содержат только токены, префиксы — в `generated/` (3a–3c)
- [ ] при `up` без сети туннель поднимается на кэше из `generated/` (3f)
- [ ] дифф в тысячи маршрутов применяется < 1 с
- [ ] `restart` подхватывает все файлы, `status`/`doctor` без ошибок
- [ ] служба: падение ssh → рестарт через ~5 с; `systemctl stop` и `sshtun down` → без рестарта (5a)
- [ ] `install`/`uninstall`/`reinstall`/`update` работают, юнит ставится выключенным, данные не теряются
- [ ] мультисервер: `server add/list/use/del` из HOWTO §8 — переключение переподнимает туннель, маркер `# sshtun-profile:` в `server.conf`, env `SERVER_HOST` предупреждает о приоритете
- [ ] `~/sshtun` восстановлен из бэкапа или оставлен в осознанном состоянии
