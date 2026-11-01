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

sshtun exclude del 203.0.113.0/24 198.51.100.7     # откат; маршруты снимутся сразу
ip route show 203.0.113.0/24               # ожидается: пусто (трафик упадёт в туннель)
```

Повторный `exclude add` того же CIDR не дублирует строку; `exclude del` несуществующего
выводит «Нет в ...».

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

```bash
TD=$(mktemp -d); cp ~/sshtun/excludes.txt ~/sshtun/excludes-custom.txt "$TD"

# 3a. базовый fetch и объединение источников
EXCLUDES_DIR=$TD sshtun fetch-as AS62597        # небольшая AS, ~16-30 префиксов
EXCLUDES_DIR=$TD sshtun fetch-as AS9009         # большая, ~3000-4500
grep "managed-sources" "$TD/excludes-as.txt"    # ожидается: AS62597 AS9009
head "$TD/excludes-as.txt"                      # шапка: автогенерация, дата, источник

# 3b. страны
EXCLUDES_DIR=$TD sshtun fetch-country ru de
EXCLUDES_DIR=$TD sshtun list                    # сводка по всем файлам

# 3c. refresh перекачивает всё по шапкам; --remove убирает источники
EXCLUDES_DIR=$TD sshtun refresh
EXCLUDES_DIR=$TD sshtun fetch-as --remove AS9009
grep "managed-sources" "$TD/excludes-as.txt"    # остался только AS62597
EXCLUDES_DIR=$TD sshtun fetch-as --remove AS62597
ls "$TD"                                        # excludes-as.txt удалён совсем
EXCLUDES_DIR=$TD sshtun fetch-country --remove ru de   # аналогично
rm -rf "$TD"

# 3d. живое применение на работающем туннеле (маленькая AS, префиксы TEST-NET
#     не используются — будет реальный трафик по этим маршрутам, это нормально)
sshtun fetch-as AS62597
ip route show | grep -c 'via 192.168'   # до
sshtun fetch-as --remove AS62597        # дифф (в основном del) применится сразу
ip route show | grep -c 'via 192.168'   # после: вернулось как было
```

Контроль скорости: применение диффа в тысячи маршрутов занимает доли
секунды (один netlink-батч). Если видите минуты — баг, сообщите.

## 4. Рестарт и состояние

```bash
sshtun restart      # туннель переподнимется, все файлы подхватятся заново
sshtun status
sshtun doctor
sshtun list         # эффективная политика: include-force + 4 exclude-файла
```

После `restart` маршруты из includes-force.txt и исключений должны быть
на месте: `ip route | grep -c via` вырастет на количество префиксов.

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
- [ ] `fetch-as`/`fetch-country`/`refresh` корректно объединяют и убирают источники
- [ ] дифф в тысячи маршрутов применяется < 1 с
- [ ] `restart` подхватывает все файлы, `status`/`doctor` без ошибок
- [ ] `install`/`uninstall`/`reinstall`/`update` работают, данные не теряются
- [ ] `~/sshtun` восстановлен из бэкапа или оставлен в осознанном состоянии
