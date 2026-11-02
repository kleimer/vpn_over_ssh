#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==========================================================
# vpn_over_ssh server installer
# ==========================================================
# Multi-client model:
#   - server prepares tun100..tun200 by default
#   - client randomly chooses N and connects with ssh -w N:N
#   - same key may be used from multiple devices
#   - do NOT bind key with tunnel="N" if you want random pool mode
#
# Addressing uses /30-like pairs inside 10.250.0.0/16:
#   tun100 -> server 10.250.0.1, client 10.250.0.2
#   tun101 -> server 10.250.0.5, client 10.250.0.6
#   tun200 -> server 10.250.1.145, client 10.250.1.146
#
# Minimal NAT mode:
#   - prepares tun100..tun200
#   - enables IPv4 forwarding
#   - adds only MASQUERADE + minimal FORWARD rules
#   - does NOT install the old large firewall chains/rate limits/private blocks
#
# Опционально: TCP_CONGESTION_CONTROL=bbr|cubic (env).
#   По умолчанию (не задано/none) система НЕ трогается. bbr подходит для
#   шумных/теряющих путей до клиентов (снимает RTO-спайки SSH-туннеля),
#   но это sender-side алгоритм: эффект есть только когда включён на ОБОИХ
#   концах внешнего TCP. Откат: TCP_CONGESTION_CONTROL=cubic + reinstall,
#   либо вручную удалить /etc/sysctl.d/90-vpn-over-ssh-congestion.conf.
# ==========================================================

BASE_DIR="${BASE_DIR:-/opt/sshtun_pool}"
SERVICE_NAME="${SERVICE_NAME:-sshtun-pool-sshd}"
NETWORK_SERVICE_NAME="${NETWORK_SERVICE_NAME:-sshtun-pool-network}"

SYSTEM_USER="${SYSTEM_USER:-sshvpn}"
LISTEN_PORT="${LISTEN_PORT:-65523}"

TUN_NUM_START="${TUN_NUM_START:-100}"
TUN_POOL_SIZE="${TUN_POOL_SIZE:-101}"
TUN_PREFIX="${TUN_PREFIX:-tun}"
TUN_MTU="${TUN_MTU:-1400}"

TUN_NET_A="${TUN_NET_A:-10}"
TUN_NET_B="${TUN_NET_B:-250}"
TUN_POOL_CIDR="${TUN_POOL_CIDR:-10.250.0.0/16}"

SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
NOLOGIN_BIN="${NOLOGIN_BIN:-/usr/sbin/nologin}"

SSHD_CONFIG="$BASE_DIR/sshd_config"
AUTHORIZED_KEYS="$BASE_DIR/authorized_keys"
HOST_KEY="$BASE_DIR/ssh_host_ed25519_key"

UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NETWORK_SCRIPT="$BASE_DIR/apply-network.sh"
NETWORK_UNIT_FILE="/etc/systemd/system/${NETWORK_SERVICE_NAME}.service"

LIMIT_NOFILE="${LIMIT_NOFILE:-1048576}"
TASKS_MAX="${TASKS_MAX:-8192}"

LOGIN_GRACE_TIME="${LOGIN_GRACE_TIME:-20}"
CLIENT_ALIVE_INTERVAL="${CLIENT_ALIVE_INTERVAL:-30}"
CLIENT_ALIVE_COUNT_MAX="${CLIENT_ALIVE_COUNT_MAX:-3}"
MAX_AUTH_TRIES="${MAX_AUTH_TRIES:-3}"
MAX_SESSIONS="${MAX_SESSIONS:-10}"
MAX_STARTUPS="${MAX_STARTUPS:-50:30:200}"

log(){ echo "[$(date -Is)] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

CC_SYSCTL_FILE="/etc/sysctl.d/90-vpn-over-ssh-congestion.conf"
CC_MODULE_FILE="/etc/modules-load.d/vpn-over-ssh-tcp_bbr.conf"

# Опциональный выбор алгоритма управления конгестией TCP (BBR/CUBIC/...).
# По умолчанию систему не трогаем. bbr: дополнительно грузим модуль tcp_bbr
# и добавляем его в автозагрузку; при выборе другого алгоритма файл
# автозагрузки убираем. Значение применяется сразу (sysctl -p).
setup_congestion_control() {
  local cc="${TCP_CONGESTION_CONTROL:-}"
  [[ -z "$cc" || "$cc" == "none" ]] && { log "TCP_CONGESTION_CONTROL не задан — системный алгоритм не трогаем"; return 0; }
  cc="$(tr 'A-Z' 'a-z' <<<"$cc")"

  if [[ "$cc" == "bbr" ]]; then
    local avail
    avail=" $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) "
    if [[ "$avail" != *" bbr "* ]]; then
      modprobe tcp_bbr 2>/dev/null || die "Модуль tcp_bbr недоступен (ядро без BBR?). Отказ: оставляем системный алгоритм."
      avail=" $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) "
      [[ "$avail" == *" bbr "* ]] || die "Модуль tcp_bbr загрузился, но алгоритм не появился. Отказ: оставляем системный алгоритм."
    fi
    echo "tcp_bbr" > "$CC_MODULE_FILE"
    log "Модуль tcp_bbr загружен и добавлен в автозагрузку: $CC_MODULE_FILE"
  else
    rm -f "$CC_MODULE_FILE"
  fi

  # проверка доступности: подстрока с границами слов, без grep -q в пайпе
  # (ранний выход консьюмера + pipefail = SIGPIPE-ловушка)
  local avail
  avail=" $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) "
  [[ "$avail" == *" $cc "* ]] \
    || die "Алгоритм '$cc' недоступен в ядре (доступны:$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null))"

  printf '# vpn_over_ssh: выбранный алгоритм управления конгестией TCP\n# (установлено install_server.sh; удалите файл для отката к системному дефолту)\nnet.ipv4.tcp_congestion_control=%s\n' "$cc" > "$CC_SYSCTL_FILE"
  sysctl -p "$CC_SYSCTL_FILE" >/dev/null
  log "net.ipv4.tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control) (файл: $CC_SYSCTL_FILE)"
}

install_deps() {
  local missing=0
  for c in ip iptables ssh-keygen openssl systemctl awk sed grep sysctl seq; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  [[ -x "$SSHD_BIN" ]] || missing=1
  [[ "$missing" -eq 0 ]] && { log "Dependencies OK"; return; }

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openssh-server iproute2 iptables procps openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server iproute iptables procps-ng openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server iproute iptables procps-ng openssl
  else
    die "Install manually: openssh-server iproute2 iptables procps openssl"
  fi
}
# ВАЖНО: вывод читаем в переменную ДО парсинга. Пайплайны вида
# 'ip ... | awk/head' с ранним выходом консьюмера убивают producer SIGPIPE,
# а pipefail+set -e превращают это в молчаливую смерть скрипта (на сервере
# всплыло как exit 141 сразу после install_deps).
detect_wan_if(){ local routes; routes="$(ip -4 route ls)"; awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$routes"; }
detect_wan_ip(){ local ifname="$1" addrs; addrs="$(ip -4 -o addr show dev "$ifname" scope global)"; awk '{split($4,a,"/"); print a[1]; exit}' <<<"$addrs"; }

sshd_supports_directive() {
  local directive="$1" tmp
  tmp="$(mktemp)"
  cp "$SSHD_CONFIG" "$tmp"
  echo "$directive" >> "$tmp"
  "$SSHD_BIN" -t -f "$tmp" >/dev/null 2>&1
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

try_add_sshd_directive() {
  local directive="$1"
  if sshd_supports_directive "$directive"; then
    echo "$directive" >> "$SSHD_CONFIG"
    log "Added sshd directive: $directive"
  else
    log "Skipped unsupported sshd directive: $directive"
  fi
}

[[ $EUID -eq 0 ]] || die "Run as root"
(( TUN_POOL_SIZE >= 1 && TUN_POOL_SIZE <= 16384 )) || die "TUN_POOL_SIZE must be 1..16384 for /30 blocks inside /16"

TUN_NUM_END=$((TUN_NUM_START + TUN_POOL_SIZE - 1))

install_deps

WAN_IF="$(detect_wan_if)"
[[ -n "$WAN_IF" ]] || die "Cannot detect WAN_IF"
WAN_IP="$(detect_wan_ip "$WAN_IF")"
[[ -n "$WAN_IP" ]] || die "Cannot detect WAN_IP on $WAN_IF"

[[ -x "$SSHD_BIN" ]] || die "$SSHD_BIN not found"
[[ -x "$NOLOGIN_BIN" ]] || NOLOGIN_BIN="/sbin/nologin"
[[ -x "$NOLOGIN_BIN" ]] || die "nologin not found"

log "WAN_IF=$WAN_IF"
log "WAN_IP=$WAN_IP"
log "Pool=${TUN_PREFIX}${TUN_NUM_START}-${TUN_PREFIX}${TUN_NUM_END} $TUN_POOL_CIDR"

mkdir -p "$BASE_DIR"
chmod 755 "$BASE_DIR"
chown root:root "$BASE_DIR"

if ! id "$SYSTEM_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$BASE_DIR" --shell "$NOLOGIN_BIN" --no-create-home "$SYSTEM_USER"
fi

SYSTEM_GROUP="$(id -gn "$SYSTEM_USER")"

PASS_STATUS="$(passwd -S "$SYSTEM_USER" 2>/dev/null | awk '{print $2}' || true)"
if [[ "$PASS_STATUS" != "P" ]]; then
  RAND_PASS="$(openssl rand -base64 48)"
  echo "${SYSTEM_USER}:${RAND_PASS}" | chpasswd
  unset RAND_PASS
fi

if [[ ! -f "$HOST_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOST_KEY" -C "${SERVICE_NAME}-host-key"
fi

[[ -f "$AUTHORIZED_KEYS" ]] || touch "$AUTHORIZED_KEYS"

chown root:root "$BASE_DIR"
chmod 755 "$BASE_DIR"
chown root:root "$HOST_KEY" "$HOST_KEY.pub"
chmod 600 "$HOST_KEY"
chmod 644 "$HOST_KEY.pub"
chown root:"$SYSTEM_GROUP" "$AUTHORIZED_KEYS"
chmod 640 "$AUTHORIZED_KEYS"

mkdir -p /run/sshd
chmod 755 /run/sshd

cat > "$SSHD_CONFIG" <<EOF2
# vpn_over_ssh server
Port ${LISTEN_PORT}
ListenAddress 0.0.0.0
AddressFamily inet
Protocol 2

HostKey ${HOST_KEY}
PidFile /run/${SERVICE_NAME}.pid

PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile ${AUTHORIZED_KEYS}

PermitRootLogin no
AllowUsers ${SYSTEM_USER}

PermitTunnel point-to-point
AllowTcpForwarding no
GatewayPorts no

PermitTTY no
X11Forwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitUserEnvironment no
ForceCommand /bin/false

LoginGraceTime ${LOGIN_GRACE_TIME}
ClientAliveInterval ${CLIENT_ALIVE_INTERVAL}
ClientAliveCountMax ${CLIENT_ALIVE_COUNT_MAX}
MaxAuthTries ${MAX_AUTH_TRIES}
MaxSessions ${MAX_SESSIONS}
MaxStartups ${MAX_STARTUPS}
TCPKeepAlive yes

SyslogFacility AUTH
LogLevel VERBOSE

PrintMotd no
PrintLastLog no
PermitEmptyPasswords no
IgnoreRhosts yes
HostbasedAuthentication no
EOF2

chown root:root "$SSHD_CONFIG"
chmod 600 "$SSHD_CONFIG"
try_add_sshd_directive "UnusedConnectionTimeout 60s"
try_add_sshd_directive "PermitListen none"
try_add_sshd_directive "PermitOpen none"
"$SSHD_BIN" -t -f "$SSHD_CONFIG"

cat > "$NETWORK_SCRIPT" <<EOF2
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\\n\\t'

TUN_NUM_START="$TUN_NUM_START"
TUN_POOL_SIZE="$TUN_POOL_SIZE"
TUN_NUM_END="$TUN_NUM_END"
TUN_PREFIX="$TUN_PREFIX"
TUN_MTU="$TUN_MTU"
TUN_NET_A="$TUN_NET_A"
TUN_NET_B="$TUN_NET_B"
TUN_POOL_CIDR="$TUN_POOL_CIDR"
WAN_IF_DEFAULT="$WAN_IF"

log(){ echo "[\$(date -Is)] \$*"; }

detect_wan_if(){ local routes; routes="\$(ip -4 route ls)"; awk '/default/ {for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}' <<<"\$routes"; }

iptables_del_all(){
  local table="\$1"; shift
  while iptables -t "\$table" -C "\$@" >/dev/null 2>&1; do
    iptables -t "\$table" -D "\$@" || true
  done
}

WAN_IF="\${WAN_IF:-\$(detect_wan_if)}"
if [[ -z "\$WAN_IF" ]]; then
  WAN_IF="\$WAN_IF_DEFAULT"
fi
[[ -n "\$WAN_IF" ]] || { echo "[ERROR] Cannot detect WAN_IF" >&2; exit 1; }

calc_pair_ips(){
  local offset="\$1"
  local base=\$((offset * 4))
  local oct3=\$((base / 256))
  local oct4=\$((base % 256))
  server_ip="\${TUN_NET_A}.\${TUN_NET_B}.\${oct3}.\$((oct4 + 1))"
  client_ip="\${TUN_NET_A}.\${TUN_NET_B}.\${oct3}.\$((oct4 + 2))"
}

log "Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
cat > /etc/sysctl.d/99-vpn_over_ssh-sshtun-pool.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL

log "Preparing TUN pool"
for n in \$(seq "\$TUN_NUM_START" "\$TUN_NUM_END"); do
  offset=\$((n - TUN_NUM_START))
  dev="\${TUN_PREFIX}\${n}"
  calc_pair_ips "\$offset"

  if ! ip link show "\$dev" >/dev/null 2>&1; then
    ip tuntap add dev "\$dev" mode tun
  fi

  ip addr flush dev "\$dev" || true
  ip addr add "\${server_ip}/32" peer "\$client_ip" dev "\$dev"
  ip link set "\$dev" mtu "\$TUN_MTU" up
 done

log "Applying minimal NAT rules via WAN_IF=\$WAN_IF"
iptables_del_all nat POSTROUTING -s "\$TUN_POOL_CIDR" -o "\$WAN_IF" -j MASQUERADE
iptables_del_all filter FORWARD -s "\$TUN_POOL_CIDR" -o "\$WAN_IF" -j ACCEPT
iptables_del_all filter FORWARD -d "\$TUN_POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -A POSTROUTING -s "\$TUN_POOL_CIDR" -o "\$WAN_IF" -j MASQUERADE
iptables -I FORWARD 1 -d "\$TUN_POOL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I FORWARD 1 -s "\$TUN_POOL_CIDR" -o "\$WAN_IF" -j ACCEPT

log "TUN pool networking and minimal NAT prepared"

echo "Sample interfaces:"
SAMPLE_END=\$((TUN_NUM_START + 4))
if (( SAMPLE_END > TUN_NUM_END )); then
  SAMPLE_END="\$TUN_NUM_END"
fi
for n in \$(seq "\$TUN_NUM_START" "\$SAMPLE_END"); do
  ip addr show "\${TUN_PREFIX}\${n}" 2>/dev/null | sed -n '1,4p' || true
 done
EOF2

chown root:root "$NETWORK_SCRIPT"
chmod 700 "$NETWORK_SCRIPT"

cat > "$NETWORK_UNIT_FILE" <<EOF2
[Unit]
Description=Prepare TUN pool networking and minimal NAT for vpn_over_ssh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NETWORK_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

chown root:root "$NETWORK_UNIT_FILE"
chmod 644 "$NETWORK_UNIT_FILE"

cat > "$UNIT_FILE" <<EOF2
[Unit]
Description=vpn_over_ssh server
Documentation=man:sshd(8)
After=network-online.target ${NETWORK_SERVICE_NAME}.service
Wants=network-online.target ${NETWORK_SERVICE_NAME}.service

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/sshd
ExecStartPre=${SSHD_BIN} -t -f ${SSHD_CONFIG}
ExecStart=${SSHD_BIN} -D -e -f ${SSHD_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
KillMode=process
LimitNOFILE=${LIMIT_NOFILE}
TasksMax=${TASKS_MAX}

[Install]
WantedBy=multi-user.target
EOF2

chown root:root "$UNIT_FILE"
chmod 644 "$UNIT_FILE"

"$SSHD_BIN" -t -f "$SSHD_CONFIG"
setup_congestion_control
systemctl daemon-reload
systemctl enable "$NETWORK_SERVICE_NAME.service" >/dev/null
systemctl restart "$NETWORK_SERVICE_NAME.service"
systemctl enable "$SERVICE_NAME.service" >/dev/null
systemctl restart "$SERVICE_NAME.service"

echo
echo "[OK] vpn_over_ssh server installed"
echo
echo "Service:"
echo "  systemctl status ${SERVICE_NAME}.service --no-pager"
echo "  systemctl status ${NETWORK_SERVICE_NAME}.service --no-pager"
echo
echo "Authorized keys:"
echo "  ${AUTHORIZED_KEYS}"
echo
echo "Important for random multi-device mode:"
echo "  Do NOT use tunnel=\"N\" in authorized_keys."
echo
echo "Recommended key line:"
echo "  no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-user-rc ssh-ed25519 AAAAC3... user-device"
echo
echo "Quick test key line:"
echo "  ssh-ed25519 AAAAC3... user-device"
echo
echo "Pool:"
echo "  ${TUN_PREFIX}${TUN_NUM_START}-${TUN_PREFIX}${TUN_NUM_END}"
echo "  ${TUN_POOL_CIDR}"
echo
echo "NAT:"
echo "  MASQUERADE ${TUN_POOL_CIDR} -> ${WAN_IF}"
echo
if [[ -n "${TCP_CONGESTION_CONTROL:-}" && "${TCP_CONGESTION_CONTROL:-}" != "none" ]]; then
  echo "TCP congestion control:"
  echo "  net.ipv4.tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) (файл ${CC_SYSCTL_FILE})"
  echo
fi
echo "Client:"
echo "  sudo bash sshtun_pool_client.sh start --host SERVER_IP" --key your_privat_key
echo
