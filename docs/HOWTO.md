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
ip route get 192.168.8.1        # LAN напрямую (table 200), не через tun
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

## 7. Чек-лист перед тегом релиза

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
- [ ] `~/sshtun` восстановлен из бэкапа или оставлен в осознанном состоянии
