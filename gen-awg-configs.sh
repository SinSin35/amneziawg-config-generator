#!/usr/bin/env bash
# Массовая генерация нативных конфигов AmneziaWG для сервера, поставленного через AmneziaVPN.
# Логика повторяет клиент amnezia-client (wireguardConfigurator.cpp / awgConfigurator.cpp):
#  - ключи, PSK, порт и параметры обфускации (Jc, Jmin, Jmax, S1-S4, H1-H4, I1-I5) берутся с сервера;
#  - IP клиента = последний AllowedIPs в конфиге сервера + 1 (с пропуском .254/.255, как в приложении);
#  - пир дописывается в конфиг сервера и применяется через `syncconf`;
#  - клиент записывается в clientsTable, поэтому виден в приложении под своим именем.
# Запускать НА СЕРВЕРЕ (root или доступ к docker), либо удалённо через run-remote.cmd.
#
# Использование: ./gen-awg-configs.sh clients.txt [папка_вывода] [формат]
#   формат:  native   - файлы Имя.conf (нативный конфиг AmneziaWG), по умолчанию
#            amnezia  - файлы Имя.vpn с ключом vpn://... для импорта в приложение AmneziaVPN
#            both     - и то, и другое
#   Для формата amnezia/both на сервере нужен perl (на Debian/Ubuntu есть по умолчанию).
#
# Переменные окружения (необязательно):
#   FORMAT     то же, что третий аргумент
#   CONTAINER  имя контейнера (по умолчанию amnezia-awg2 / amnezia-awg, что найдётся)
#   SERVER_IP  IP/домен для Endpoint (по умолчанию определяется через ifconfig.me)
#   DNS        "1.1.1.1, 1.0.0.1" по умолчанию - как в приложении
#   MTU        если задан - добавляется строка MTU в [Interface] (в нативном конфиге приложения её нет)
set -euo pipefail
say() { echo "$@" >&2; }

LIST="${1:?Укажите файл со списком клиентов: $0 clients.txt [out_dir]}"
OUT="${2:-./awg-configs}"
FORMAT="${3:-${FORMAT:-native}}"
case "$FORMAT" in native|amnezia|both) ;; *) echo "Формат должен быть native, amnezia или both (получено: $FORMAT)" >&2; exit 1;; esac
DNS="${DNS:-1.1.1.1, 1.0.0.1}"
MTU_APP="${MTU:-1376}"   # поле mtu в ключе vpn:// (в приложении по умолчанию 1376; для 3.1 советуют 1280)

# Генерация ключа vpn:// (как ExportController: JSON -> qCompress -> base64url без '=').
# На вход (stdin) - нативный конфиг, остальное - через переменные окружения.
PERL_VPN=$(cat <<'PERL'
use strict; use warnings;
use JSON::PP; use Compress::Zlib; use MIME::Base64;
my $native = do { local $/; <STDIN> };
my %c;
for my $l (split /\n/, $native) {
  $l =~ s/\r//g; $l =~ s/^\s+|\s+$//g; next if $l =~ /^\[/;
  my @p = split / = /, $l, 2; $c{$p[0]} = $p[1] if @p == 2;
}
my @awg = qw(Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 HeaderProtectionKey ContentPaddingAddition
             RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies);
my %a = map { $_ => (defined $c{$_} ? $c{$_} : '') } @awg;
sub toggle { my $v = shift; $v =~ s/^\s+|\s+$//g; return length($v) && lc($v) ne 'off' }
my $ver = '';
if ((grep { length $a{$_} } qw(HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts))
    || toggle($a{RandomTrailers}) || toggle($a{DisableCookies})) { $ver = '3.1' }
elsif (length $a{S3} || length $a{S4} || (grep { $a{$_} =~ /-/ } qw(H1 H2 H3 H4))) { $ver = '2' }
elsif (grep { length $a{$_} } qw(I1 I2 I3 I4 I5)) { $ver = '1.5' }

my $port_s = "$ENV{PORT}"; my $port_n = 0 + ("$ENV{PORT}");
my %client = (
  config => $native, hostName => "$ENV{HOST}", port => $port_n, client_ip => "$ENV{CLIENT_IP}",
  client_priv_key => "$ENV{CLIENT_PRIV}", client_pub_key => "$ENV{CLIENT_PUB}",
  server_pub_key => "$ENV{SERVER_PUB}", psk_key => "$ENV{PSK}", clientId => "$ENV{CLIENT_PUB}",
  allowed_ips => ["0.0.0.0/0", "::/0"], persistent_keep_alive => "$ENV{KEEPALIVE}", mtu => "$ENV{MTU_APP}",
);
$client{$_} = $a{$_} for grep { length $a{$_} } @awg;
$client{config} =~ s/^DNS = .*$/DNS = \$PRIMARY_DNS, \$SECONDARY_DNS/m;   # как в приложении: подстановка при подключении (dns1/dns2 ниже)
my %server = (port => $port_s, transport_proto => 'udp', subnet_address => "$ENV{SUBNET_IP}");   # subnet_cidr приложение не пишет (по умолчанию 24)
$server{protocol_version} = $ver if length $ver;
for my $k (@awg) { $server{$k} = $a{$k} if length $a{$k} || $k =~ /^I[1-5]$/ }
$server{last_config} = JSON::PP->new->utf8(0)->encode(\%client);
my ($d1, $d2) = split /\s*,\s*/, $ENV{DNS}, 2;
my %top = (
  format_version => 1, description => "$ENV{NAME}", hostName => "$ENV{HOST}",
  containers => [ { container => "$ENV{CNAME}", awg => \%server } ],
  defaultContainer => "$ENV{CNAME}", dns1 => $d1, dns2 => (defined $d2 ? $d2 : ''),
);
my $json = JSON::PP->new->utf8->canonical->encode(\%top);
my $blob = pack('N', length $json) . Compress::Zlib::compress($json, 8);   # = qCompress
my $b64 = encode_base64($blob, ''); $b64 =~ tr{+/}{-_}; $b64 =~ s/=+$//;
print "vpn://$b64\n";
PERL
)
if [ "$FORMAT" != native ]; then
  perl -MJSON::PP -MCompress::Zlib -MMIME::Base64 -e1 2>/dev/null || { echo "Для формата amnezia нужен perl с модулями JSON::PP, Compress::Zlib (apt install perl)" >&2; exit 1; }
fi
# PersistentKeepalive на сервере не хранится. Приложение (scriptsRegistry.cpp) ставит "25-35", если в конфиге
# есть параметры AWG 3.x, иначе "25". Скрипт делает так же (определяется ниже); KEEPALIVE=... переопределяет.
KEEPALIVE="${KEEPALIVE:-}"
DIR=/opt/amnezia/awg

# --- контейнер ---
if [ -z "${CONTAINER:-}" ]; then
  CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg' | sort -r | head -n1 || true)
fi
[ -n "$CONTAINER" ] || { say "Контейнер AmneziaWG не найден (docker ps). Задайте CONTAINER=..."; exit 1; }
dx() { docker exec "$CONTAINER" "$@"; }

# AWG 2.0: awg0.conf + awg ; AWG legacy (1.x): wg0.conf + wg
if dx test -f $DIR/awg0.conf; then
  CONF=$DIR/awg0.conf; IFACE=awg0; WGBIN=$(dx sh -c 'command -v awg')
else
  CONF=$DIR/wg0.conf;  IFACE=wg0;  WGBIN=$(dx sh -c 'command -v wg || command -v awg')
fi
[ -n "$WGBIN" ] || { say "В контейнере нет awg/wg"; exit 1; }
say "Контейнер: $CONTAINER, конфиг: $CONF, интерфейс: $IFACE"

# --- параметры сервера ---
SERVER_CONF=$(dx cat "$CONF" | tr -d '\r')
SERVER_PUB=$(dx cat $DIR/wireguard_server_public_key.key | tr -d '\r\n')
PSK=$(dx cat $DIR/wireguard_psk.key | tr -d '\r\n')
PORT=$(printf '%s\n' "$SERVER_CONF" | awk -F= '/^ *ListenPort/{gsub(/ /,"",$2); print $2; exit}')
SERVER_ADDR=$(printf '%s\n' "$SERVER_CONF" | awk -F= '/^ *Address/{gsub(/ /,"",$2); print $2; exit}')
SUBNET_CIDR=${SERVER_ADDR##*/}; SERVER_ADDR=${SERVER_ADDR%%/*}
# имя контейнера в ключе vpn://: как ContainerUtils::containerToString
if [ "$IFACE" = awg0 ]; then CNAME=amnezia-awg2; else CNAME=amnezia-awg; fi

if [ -z "${SERVER_IP:-}" ]; then SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me || true); fi
[ -n "$SERVER_IP" ] || { say "Не удалось определить IP. Задайте SERVER_IP=..."; exit 1; }

# Параметры обфускации из [Interface]. I1-I5 в серверном конфиге закомментированы ("# I1 = ...") -
# именно оттуда приложение берёт их значения; пустые значения пропускаем.
# Копируем ВСЕ AWG-параметры сервера (в т.ч. новые из AWG 3.x: HeaderProtectionKey, ContentPaddingAddition,
# Rekey*, RandomTrailers и т.д.), кроме чисто серверных строк (PrivateKey, Address, ListenPort, PostUp...).
OBF=$(printf '%s\n' "$SERVER_CONF" | awk '
  BEGIN { split("privatekey address listenport dns mtu table preup postup predown postdown saveconfig fwmark", b, " ")
          for (i in b) skip[b[i]]=1 }
  /^\[Peer\]/ {exit}
  /^\[Interface\]/ {next}
  { line=$0; commented=(line ~ /^# */); sub(/^# */,"",line)
    if (line !~ /^[A-Za-z][A-Za-z0-9]* *=/) next
    k=line; sub(/ *=.*/,"",k); v=line; sub(/^[^=]*= */,"",v); sub(/ *$/,"",v)
    if (tolower(k) in skip || v=="") next
    if (commented && k !~ /^I[1-5]$/) next      # из закомментированного берём только I1-I5
    g = (k ~ /^(Jc|Jmin|Jmax|S[1-4]|H[1-4])$/) ? 1 : (k ~ /^I[1-5]$/) ? 2 : 3   # порядок как в приложении
    n++; ord[n]=g; txt[n]=k " = " v }
  END { for (g=1; g<=3; g++) for (i=1; i<=n; i++) if (ord[i]==g) print txt[i] }')
[ -n "$OBF" ] || say "ВНИМАНИЕ: параметры обфускации в $CONF не найдены"
if [ -z "$KEEPALIVE" ]; then
  if printf '%s\n' "$OBF" | grep -qE '^(HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies) '; then
    KEEPALIVE="25-35"; else KEEPALIVE="25"; fi
fi
say "PersistentKeepalive: $KEEPALIVE"
say "Параметры, скопированные в клиентские конфиги:"; printf '%s\n' "$OBF" | sed 's/ = .*//' | tr '\n' ' ' >&2; say

# --- таблица клиентов приложения ---
CT=$DIR/clientsTable   # для обоих контейнеров (awg и awg2) приложение использует /opt/amnezia/awg/clientsTable
CT_JSON=$(dx cat "$CT" 2>/dev/null | tr -d '\r\n' || true)
CT_BODY=$(printf '%s' "$CT_JSON" | sed 's/^[[:space:]]*\[//; s/\][[:space:]]*$//')
CT_NEW=""

# --- IP-адреса: как в приложении (последний AllowedIPs + 1) ---
ip2int() { local IFS=.; set -- $1; echo $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 )); }
int2ip() { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }
LAST=$(printf '%s\n' "$SERVER_CONF" | grep -oE 'AllowedIPs *= *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n1 | grep -oE '[0-9.]+$' || true)
[ -n "$LAST" ] || LAST=$SERVER_ADDR
next_ip() {
  local n; n=$(ip2int "$LAST")
  case $(( n & 255 )) in 254) n=$((n+3));; 255) n=$((n+2));; *) n=$((n+1));; esac
  LAST=$(int2ip "$n")
}

mkdir -p "$OUT"
dx cp "$CONF" "$CONF.bak.$(date +%s)"
[ -n "$CT_JSON" ] && dx cp "$CT" "$CT.bak.$(date +%s)" || true

created=0; skipped=0; PEERS=""
while IFS= read -r name || [ -n "$name" ]; do
  name=$(echo "$name" | tr -d '\r' | xargs)
  [ -z "$name" ] && continue
  case "$name" in \#*) continue;; esac

  if printf '%s\n' "$SERVER_CONF" | grep -qxF "# $name" || printf '%s' "$CT_JSON" | grep -qF -e "\"clientName\": \"$name\"" -e "\"clientName\":\"$name\""; then
    say "= $name: уже есть на сервере, пропуск (приватный ключ не хранится)"; skipped=$((skipped+1)); continue
  fi

  next_ip; IP=$LAST
  PRIV=$(dx $WGBIN genkey | tr -d '\r\n')
  PUB=$(printf '%s' "$PRIV" | docker exec -i "$CONTAINER" $WGBIN pubkey | tr -d '\r\n')

  PEERS+=$(printf '\n# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$name" "$PUB" "$PSK" "$IP")$'\n'
  [ -n "$CT_NEW" ] && CT_NEW+=","
  CT_NEW+=$(printf '{"clientId":"%s","userData":{"clientName":"%s","creationDate":"%s"}}' "$PUB" "$name" "$(LC_ALL=C date '+%a %b %-d %T %Y')")   # как QDateTime::toString(): "Wed Nov 11 12:00:00 2026"

  # нативный конфиг (в ключе vpn:// лежит без строки MTU, как в приложении)
  NATIVE=$(
    echo "[Interface]"
    echo "Address = $IP/32"
    echo "DNS = $DNS"
    echo "PrivateKey = $PRIV"
    printf '%s\n' "$OBF"
    echo
    echo "[Peer]"
    echo "PublicKey = $SERVER_PUB"
    echo "PresharedKey = $PSK"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "Endpoint = $SERVER_IP:$PORT"
    echo "PersistentKeepalive = $KEEPALIVE"
  )
  if [ "$FORMAT" != amnezia ]; then
    if [ -n "${MTU:-}" ]; then printf '%s\n' "$NATIVE" | sed "/^DNS = /a MTU = $MTU" > "$OUT/$name.conf"
    else printf '%s\n' "$NATIVE" > "$OUT/$name.conf"; fi
  fi
  if [ "$FORMAT" != native ]; then
    printf '%s\n' "$NATIVE" | NAME="$name" HOST="$SERVER_IP" PORT="$PORT" CLIENT_IP="$IP" CLIENT_PRIV="$PRIV" CLIENT_PUB="$PUB" \
      SERVER_PUB="$SERVER_PUB" PSK="$PSK" KEEPALIVE="$KEEPALIVE" MTU_APP="$MTU_APP" SUBNET_IP="$SERVER_ADDR" \
      SUBNET_CIDR="$SUBNET_CIDR" CNAME="$CNAME" DNS="$DNS" perl -e "$PERL_VPN" > "$OUT/$name.vpn"
  fi

  say "+ $name -> $IP"; created=$((created+1))
done < "$LIST"

if [ "$created" -gt 0 ]; then
  # 1) пиры в конфиг сервера, 2) применить без разрыва текущих соединений (как делает приложение)
  printf '%s' "$PEERS" | docker exec -i "$CONTAINER" sh -c "cat >> $CONF"
  dx bash -c "$WGBIN syncconf $IFACE <($WGBIN-quick strip $CONF)"
  # 3) записать клиентов в clientsTable, чтобы приложение показывало их по именам
  if [ -n "$CT_BODY" ]; then NEWTABLE="[${CT_BODY},${CT_NEW}]"; else NEWTABLE="[${CT_NEW}]"; fi
  printf '%s' "$NEWTABLE" | docker exec -i "$CONTAINER" sh -c "cat > $CT"
fi

say "Готово: создано $created, пропущено $skipped. Конфиги в: $OUT"
