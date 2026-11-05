#!/bin/bash
# ==============================================================================
# ALIRAZA SSH Management Panel - one-shot installer (built on ARTRICKS menu.sh)
# Created by ALIRAZA | Support: https://t.me/ar_tricks
# v2: fixed custom Dropbear build, IPv6-safe nginx, install self-check
# v3: STABILITY - multilogin by IP (newest wins, no false lock/kill), dropbear backlog + unauth limits,
#     conntrack limit, uvloop ws-proxy, faster keepalives, atomic conf writes
#     v4: animated login page (ALIRAZA SSH MANAGEMENT hero), larger TCP/SSH/WS windows (RAM-adaptive),
#     TCP thin-stream tuning for lower SSH latency
#     v5: BANNER FIX - banner now lives in /etc/artricks/banner.txt (not /etc/issue.net), panel/bot save restarts Dropbear
#     (Dropbear only reads the banner at start-up) without dropping live sessions; re-running the installer keeps your banner;
#     lighter session scan (no journalctl when nobody is connected), 1 systemctl call for service status
#     v6: new "SERVER BY ALIRAZA" banner (applied once, then your panel edits are kept); redesigned ALIRAZA ACCOUNT MANAGEMENT popup after creating an account
#     v7: VIEW-ONLY panel hides all VPS info (IP/OS/kernel/domain/ports/payload, also blocked server-side) and shows an English
#     "get a key from AliRaza" notice (top bar + popup that reappears) with t.me/alirazax0; wider panel layout/popup;
#     bigger TCP + Dropbear windows (RAM-adaptive) and lower-latency SSH tuning
# V2 (PURPLE): new purple/violet animated UI (aurora, plasma, glow), Dropbear keepalive 15s + 8MB window + legacy-client compat,
#     sshd keepalive 30s x6, BBR with cubic fallback + fq qdisc + txqueuelen, up to 256MB TCP windows (RAM-adaptive),
#     bigger ws-proxy buffers, faster dead-peer detection, watchdog service (restarts hung dropbear / ws-proxy)
# V2 BAN: panel 'Blocked IPs' (Accounts tab): blocked IPs cannot log in and only see the English ban notice; list + unblock in the panel
#     V5 DROPBEAR/INFO: newest Dropbear (2026.94 first, auto-fallback), MAX window raised to 64MB (runtime window 8-32MB RAM-adaptive, auto-clamped to what the
#     built binary supports), watchdog no longer restarts ws-proxy/dropbear on a single slow probe (no false disconnects), account popup always shows FULL info (server-built)
# ==============================================================================
# V5 THEMES TAB: panel menu now has a Themes section (single + double color luxury themes with flames); re-applied on every install
# V4 THEME: ice-blue UI with realistic animated ice flames + embers (replaces purple)
# V4 KEYS: every view-only key (Panel logins) now has a validity in days; expired keys are refused at login and kicked out of live sessions; Add days button to renew
# V4 OPTIMIZED: OpenSSH speed layer (CPU-aware AES-GCM/ChaCha order, no forced re-key, auto-reverting drop-in), sshd systemd limits, leaner Dropbear build, scheduler tweak
# V3 OPTIMIZED: dropbear built without zlib (less CPU, no compression stalls), OpenSSH hardening+latency, nginx workers/cpu-affinity/quiet logs/ssl buffers,
#     extra sysctl (neigh table, dirty pages, SYN retries), conntrack timeouts (stale entries expire in 2h not 5 days), irqbalance, TCP_USER_TIMEOUT in ws-proxy
G='\033[1;92m';R='\033[1;31m';Y='\033[1;93m';N='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${R}Run as root: sudo -i${N}" && exit 1
command -v apt-get >/dev/null || { echo -e "${R}Only Debian/Ubuntu (apt) is supported${N}"; exit 1; }
echo -e "${G}=== ALIRAZA SSH Panel Installer V4 (Ice Blue) ===${N}"
read -rp "Domain (A record must point to this VPS): " DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo -e "${R}Invalid domain${N}"; exit 1; }
read -rp "Panel port [2083]: " PP; PP=${PP:-2083}
read -rp "SSH port [8443]: " SP; SP=${SP:-8443}
[[ "$PP" =~ ^[0-9]+$ && "$SP" =~ ^[0-9]+$ && "$PP" != "$SP" ]] || { echo -e "${R}Invalid ports${N}"; exit 1; }
for _p in $PP $SP; do
  case $_p in 22|80|443|109|447|2082|2299|12026) echo -e "${R}Port $_p is reserved, choose another${N}"; exit 1;; esac
  [[ $_p -ge 1 && $_p -le 65535 ]] || { echo -e "${R}Invalid port $_p${N}"; exit 1; }
done
read -rp "Panel username [admin]: " AU; AU=${AU:-admin}
read -rsp "Panel password (blank = random): " AP; echo
[[ -z "$AP" ]] && AP=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
export DEBIAN_FRONTEND=noninteractive
echo -e "${Y}[1/6] Installing packages...${N}"
(apt-get update -y || apt-get update -y) && apt-get install -y curl wget jq openssl nginx dropbear certbot python3 python3-venv python3-pip python3-dev lsof iptables iproute2 net-tools psmisc build-essential zlib1g-dev bzip2 ca-certificates logrotate || { echo -e "${R}Package install failed - check internet/apt and re-run${N}"; exit 1; }
mkdir -p /etc/artricks/users /etc/artricks/ssl /opt/aliraza-panel
apt-get install -y python3-uvloop >/dev/null 2>&1 || true
apt-get install -y irqbalance >/dev/null 2>&1 && systemctl enable --now irqbalance >/dev/null 2>&1 || true   # spreads NIC interrupts over all cores   # optional: faster WebSocket proxy (falls back to plain asyncio)
# ---- AliRaza banner: kept in its OWN file so OS updates / re-running this installer never reset what you saved in the panel ----
BANNER_FILE=/etc/artricks/banner.txt
BANNER_MARK=/etc/artricks/.banner_v6   # new SERVER BY ALIRAZA banner is applied ONCE; afterwards whatever you save in the panel is kept
write_default_banner() { cat > "$BANNER_FILE" <<'BN'
<font color="#FF0000">𝗦𝗘𝗥𝗩𝗘𝗥 <font color="#FF0000">𝗕𝗬</font> 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#00FFFF">🌐 𝗦𝗦𝗛</font>  •  <font color="#00FF00">𝗩𝗟𝗘𝗦𝗦</font>
<font color="#FF1493">⚡ 𝗩𝗠𝗘𝗦</font> • <font color="#FFFF00">𝗧𝗥𝗢𝗝𝗔𝗡</font><font color="#FF0000">🔥</font>

<font color="#FF8C00">📢 𝗝𝗢𝗜𝗡 𝗖𝗛𝗔𝗡𝗘𝗟</font>
<font color='#00FF00'>↓ <a href="https://t.me/ar_tricks">CLICK HERE</a> ↓</font>
BN
}
if [[ ! -f "$BANNER_MARK" ]] || [[ ! -s "$BANNER_FILE" ]]; then
  write_default_banner
  touch "$BANNER_MARK"
fi
chmod 644 "$BANNER_FILE"
# ---- OpenSSH tuning (stability + speed) ----
sed -i 's|^Banner /etc/issue.net$|Banner /etc/artricks/banner.txt|' /etc/ssh/sshd_config 2>/dev/null   # migrate old installs
if [[ -f /etc/ssh/sshd_config ]]; then
SSHD_TUNE='# ALIRAZA tuning
Banner /etc/artricks/banner.txt
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 6
UseDNS no
GSSAPIAuthentication no
Compression no
LoginGraceTime 30
MaxStartups 100:30:200
MaxSessions 100
IPQoS lowdelay throughput
MaxAuthTries 4
PrintMotd no
PrintLastLog no
X11Forwarding no
PermitUserEnvironment no'
if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then
  printf '%s\n' "$SSHD_TUNE" > /etc/ssh/sshd_config.d/00-aliraza.conf; SSHD_MODE=dropin
else
  cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.aliraza.bak
  grep -q 'ALIRAZA tuning' /etc/ssh/sshd_config || printf '\n%s\n' "$SSHD_TUNE" >> /etc/ssh/sshd_config; SSHD_MODE=inline
fi
if command -v sshd >/dev/null && ! sshd -t 2>/dev/null; then
  echo -e "${R}sshd config test failed - reverting SSH tuning${N}"
  rm -f /etc/ssh/sshd_config.d/00-aliraza.conf
  [[ -f /etc/ssh/sshd_config.aliraza.bak ]] && cp /etc/ssh/sshd_config.aliraza.bak /etc/ssh/sshd_config
fi
fi
# ---- V4: OpenSSH extra speed layer (CPU-aware cipher order, no forced re-key, trimmed forwarding). Own file, auto-reverted if sshd -t fails ----
if command -v sshd >/dev/null && [[ -f /etc/ssh/sshd_config ]]; then
  if grep -qw aes /proc/cpuinfo 2>/dev/null; then _CIPH='aes128-gcm@openssh.com,chacha20-poly1305@openssh.com'; else _CIPH='chacha20-poly1305@openssh.com,aes128-gcm@openssh.com'; fi
  SSHD_V4="# ALIRAZA V4 speed layer
Ciphers ^${_CIPH}
KexAlgorithms ^curve25519-sha256,curve25519-sha256@libssh.org
RekeyLimit 4G 1d
AllowAgentForwarding no
AllowStreamLocalForwarding no"
  if [[ "${SSHD_MODE:-}" == dropin ]]; then
    printf '%s\n' "$SSHD_V4" > /etc/ssh/sshd_config.d/01-aliraza-v4.conf
    sshd -t 2>/dev/null || { echo -e "${Y}sshd V4 layer not supported here - skipped${N}"; rm -f /etc/ssh/sshd_config.d/01-aliraza-v4.conf; }
  else
    cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.v4pre
    grep -q 'ALIRAZA V4 speed layer' /etc/ssh/sshd_config || printf '\n%s\n' "$SSHD_V4" >> /etc/ssh/sshd_config
    sshd -t 2>/dev/null || { echo -e "${Y}sshd V4 layer not supported here - skipped${N}"; cp -f /etc/ssh/sshd_config.v4pre /etc/ssh/sshd_config; }
  fi
  for _u in ssh sshd; do
    if systemctl cat "$_u" >/dev/null 2>&1; then
      mkdir -p "/etc/systemd/system/$_u.service.d"
      printf '[Service]\nLimitNOFILE=1048576\nTasksMax=infinity\nOOMScoreAdjust=-500\nNice=-3\n' > "/etc/systemd/system/$_u.service.d/aliraza.conf"
      break
    fi
  done
  systemctl daemon-reload 2>/dev/null
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

# ---- Build Dropbear with custom identification: SSH-2.0-AliRaza-server ----
echo -e "${Y}[1b/6] Building AliRaza-server SSH (Dropbear)...${N}"
build_dropbear() {
  local IDENT="SSH-2.0-AliRaza-server" W=/tmp/aliraza-dropbear LOG=/var/log/aliraza-dropbear-build.log v ok=0
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || return 1
  for v in 2026.94 2026.93 2026.92 2026.91 2026.90 2025.89 2025.88 2024.86; do
    wget -q -T 25 -O db.tar.bz2 "https://matt.ucc.asn.au/dropbear/releases/dropbear-$v.tar.bz2" \
    || wget -q -T 25 -O db.tar.bz2 "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_$v.tar.gz" || continue
    rm -rf src; mkdir src; tar -xf db.tar.bz2 -C src --strip-components=1 2>/dev/null || tar -xzf db.tar.bz2 -C src --strip-components=1 2>/dev/null || continue
    [[ -f src/configure ]] && ok=1 && break
  done
  [[ $ok -eq 1 ]] || { echo "download failed"; return 1; }
  cd src || return 1
  # Dropbear >= 2025.87 keeps its headers in src/, older releases in the top folder: locate them
  local HD; HD=$(dirname "$(find . -name sysoptions.h 2>/dev/null | head -1)")
  [[ -f "$HD/sysoptions.h" ]] || { echo "sysoptions.h not found"; return 1; }
  printf '#define DROPBEAR_SMALL_CODE 0\n' > localoptions.h
  # force the custom identification directly in sysoptions.h (whitespace tolerant), then verify
  sed -i -E "s|^[[:space:]]*#[[:space:]]*define[[:space:]]+LOCAL_IDENT[[:space:]].*|#define LOCAL_IDENT \"$IDENT\"|" "$HD/sysoptions.h"
  grep -q "LOCAL_IDENT \"$IDENT\"" "$HD/sysoptions.h" || { echo "ident patch failed: $(grep -n LOCAL_IDENT "$HD/sysoptions.h" | head -2)"; return 1; }
  sed -i 's|^#define DROPBEAR_SMALL_CODE .*|#define DROPBEAR_SMALL_CODE 0|; s|^#define MAX_UNAUTH_CLIENTS .*|#define MAX_UNAUTH_CLIENTS 500|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  # every WS user reaches Dropbear from 127.0.0.1, so the per-IP cap is really a GLOBAL cap: keep it high
  sed -i 's|^#define MAX_UNAUTH_PER_IP .*|#define MAX_UNAUTH_PER_IP 500|' "$HD/default_options.h" 2>/dev/null
  # V2: bigger default receive window + legacy-client key exchange (both are no-ops if the option does not exist in this release)
  sed -i 's|^#define DEFAULT_RECV_WINDOW .*|#define DEFAULT_RECV_WINDOW 4194304|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  # V5: raise the hard cap of the -W window option (stock = 10MB) so the runtime window can be much bigger
  sed -i -E 's|^[[:space:]]*#[[:space:]]*define[[:space:]]+MAX_RECV_WINDOW[[:space:]].*|#define MAX_RECV_WINDOW (64*1024*1024)|' "$HD/sysoptions.h" "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  local MAXWIN=0
  grep -qE '^#define MAX_RECV_WINDOW \(64\*1024\*1024\)' "$HD/sysoptions.h" 2>/dev/null && MAXWIN=33554432
  # bigger packet payload = fewer packets per MB (less CPU, same latency); only touched when the macro exists
  sed -i -E 's|^#define RECV_MAX_PAYLOAD_LEN .*|#define RECV_MAX_PAYLOAD_LEN 32768|' "$HD/sysoptions.h" 2>/dev/null
  sed -i 's|^#define DROPBEAR_DH_GROUP1 .*|#define DROPBEAR_DH_GROUP1 1|' "$HD/default_options.h" 2>/dev/null
  # listen() backlog of 20 overflows when many users reconnect together (-> dropped/slow connects): raise it
  find . \( -name netio.c -o -name svr-main.c \) -print0 2>/dev/null | xargs -0 -r sed -i -E 's/listen\(([A-Za-z_]+), *20\)/listen(\1, 1024)/' 2>/dev/null
  # never force a re-key (every 1h / 1GB): some mobile SSH clients freeze or drop during re-key
  sed -i 's|^#define KEX_REKEY_TIMEOUT .*|#define KEX_REKEY_TIMEOUT (3600*24*30)|; s|^#define KEX_REKEY_DATA .*|#define KEX_REKEY_DATA 4294967295U|' "$HD/sysoptions.h" 2>/dev/null
  # V4: drop features tunnel clients never use (agent/X11 forwarding, motd); no-op if the option is absent
  sed -i 's|^#define DROPBEAR_SVR_AGENTFWD .*|#define DROPBEAR_SVR_AGENTFWD 0|; s|^#define DROPBEAR_X11FWD .*|#define DROPBEAR_X11FWD 0|; s|^#define DO_MOTD .*|#define DO_MOTD 0|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  : > "$LOG"
  # no utmp/wtmp/lastlog writes (faster logins, no ever-growing wtmp); -O3 build; bundled crypto
  ./configure --prefix=/usr/local --enable-bundled-libtom --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-loginfunc --disable-zlib CFLAGS="-O3 -pipe -fomit-frame-pointer -fno-plt" LDFLAGS="-Wl,-O1,--as-needed" >>"$LOG" 2>&1 || { echo "configure failed (see $LOG)"; return 1; }
  make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" >>"$LOG" 2>&1 || { echo "compile failed (see $LOG)"; return 1; }
  grep -aq "$IDENT" dropbear || { echo "ident check failed"; return 1; }
  # smoke test: the new binary must start and announce the custom identification before it is installed
  ./dropbearkey -t ed25519 -f "$W/test_key" >/dev/null 2>&1 || { echo "keygen failed"; return 1; }
  ./dropbear -F -E -r "$W/test_key" -p 127.0.0.1:22999 -W "$((MAXWIN>0?MAXWIN:1048576))" >/dev/null 2>&1 &
  local DP=$! BL
  sleep 1
  BL=$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22999; head -n1 <&3' 2>/dev/null | tr -d '\r')
  kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
  [[ "$BL" == "$IDENT" ]] || { echo "smoke test failed (got: ${BL:-nothing})"; return 1; }
  install -m 755 dropbear /usr/local/sbin/dropbear
  mkdir -p /etc/artricks; echo "$MAXWIN" > /etc/artricks/dbmaxwin
  /usr/local/sbin/dropbear -V 2>&1 | head -n1 > /etc/artricks/dbversion 2>/dev/null
  echo "built dropbear $v, max window ${MAXWIN}"
}
if ( build_dropbear ); then
  echo -e "${G}Dropbear built: SSH-2.0-AliRaza-server${N}"
else
  echo -e "${R}Custom Dropbear build failed - falling back to stock Dropbear (name stays 'dropbear'). Log: /var/log/aliraza-dropbear-build.log${N}"
  rm -f /usr/local/sbin/dropbear /etc/artricks/dbmaxwin
fi
cd /root 2>/dev/null || cd /
# nginx: more connections (safe - reverted if nginx -t fails)
if [[ -f /etc/nginx/nginx.conf ]]; then
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.aliraza.bak
  grep -q worker_rlimit_nofile /etc/nginx/nginx.conf || sed -i '1i worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
  sed -i 's/worker_connections [0-9]*;/worker_connections 16384;/' /etc/nginx/nginx.conf
  sed -i -E 's/^[[:space:]]*worker_processes[[:space:]].*/worker_processes auto;/' /etc/nginx/nginx.conf
  grep -q worker_cpu_affinity /etc/nginx/nginx.conf || sed -i '1i worker_cpu_affinity auto;' /etc/nginx/nginx.conf
  sed -i -E 's|^error_log .*|error_log /var/log/nginx/error.log crit;|' /etc/nginx/nginx.conf
  nginx -t >/dev/null 2>&1 || cp /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf
fi
# nginx http-level tuning (reverted automatically if nginx -t fails)
cat > /etc/nginx/conf.d/00-aliraza-tune.conf <<'NT'
tcp_nodelay on;
tcp_nopush on;
reset_timedout_connection on;
keepalive_timeout 120s;
keepalive_requests 10000;
server_tokens off;
ssl_session_cache shared:SSL:20m;
ssl_session_timeout 1d;
ssl_session_tickets on;
ssl_buffer_size 8k;
access_log off;
gzip off;
sendfile on;
server_names_hash_bucket_size 128;
client_header_timeout 15s;
client_body_timeout 30s;
large_client_header_buffers 4 16k;
NT
nginx -t >/dev/null 2>&1 || rm -f /etc/nginx/conf.d/00-aliraza-tune.conf
if [[ -f /etc/nginx/nginx.conf ]] && ! grep -Eq '^\s*multi_accept on' /etc/nginx/nginx.conf; then
  sed -i '0,/worker_connections 16384;/s//worker_connections 16384;\n    multi_accept on;\n    use epoll;/' /etc/nginx/nginx.conf
  nginx -t >/dev/null 2>&1 || cp /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf
fi
# keep logs from filling the disk
cat > /etc/logrotate.d/aliraza <<'LR'
/var/log/ws-proxy.log {
    weekly
    rotate 2
    size 20M
    missingok
    notifempty
    copytruncate
    compress
}
LR
mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\nSystemMaxUse=200M\nRateLimitIntervalSec=0\n' > /etc/systemd/journald.conf.d/aliraza.conf
systemctl restart systemd-journald 2>/dev/null
# ---- swap: avoids OOM-kills (random disconnects) on small VPS ----
if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
  if [[ $MEM_MB -le 2048 && $FREE_MB -gt 4096 ]]; then
    if { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; } \
       && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo -e "${G}1G swap enabled${N}"
    else
      rm -f /swapfile
    fi
  fi
fi
# ---- file-descriptor limits ----
cat > /etc/security/limits.d/99-aliraza.conf <<'LIM'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIM
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/aliraza.conf
# ---- nginx: auto-restart + limits ----
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/aliraza.conf <<'NGD'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=2
LimitNOFILE=1048576
OOMScoreAdjust=-300
NGD
echo -e "${Y}[2/6] Core services (WebSocket, auto-kill, tuning)...${N}"
cat > /etc/sysctl.d/99-artricks-ssh.conf <<'SYSCTL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_orphan_retries = 3
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 6

# 🚀 EXTREME SPEED TUNING (Read/Write Buffers)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 524288 134217728
net.ipv4.tcp_wmem = 4096 524288 134217728
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# Stability / many connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 200000
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.ip_local_reserved_ports = 12026
fs.file-max = 1000000
fs.nr_open = 1048576

# Latency / stability extras
net.ipv4.tcp_notsent_lowat = 262144
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_max_orphans = 65536
net.core.optmem_max = 65536
kernel.pid_max = 4194304
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# V2 extras (unknown keys on older/newer kernels are skipped)
net.ipv4.tcp_limit_output_bytes = 1048576
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_recovery = 1
net.core.netdev_budget = 600

# V3 extras
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_frto = 2
net.core.netdev_budget_usecs = 8000
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5

# V4 extras
kernel.sched_autogroup_enabled = 0
SYSCTL_EOF
# window size is RAM-adaptive: <1.5GB RAM = 64MB ceiling, <3.5GB = 128MB, bigger = 256MB (autotuned, only used under load)
_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [[ ${_MB:-0} -lt 1500 ]]; then sed -i 's/134217728/67108864/g' /etc/sysctl.d/99-artricks-ssh.conf; elif [[ ${_MB:-0} -ge 3500 ]]; then sed -i 's/134217728/268435456/g' /etc/sysctl.d/99-artricks-ssh.conf; fi
modprobe tcp_bbr 2>/dev/null; echo tcp_bbr > /etc/modules-load.d/bbr.conf
# BBR needs kernel support (not on OpenVZ/LXC): fall back to cubic instead of leaving a broken setting
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || sed -i 's/= bbr$/= cubic/' /etc/sysctl.d/99-artricks-ssh.conf
sysctl -e -p /etc/sysctl.d/99-artricks-ssh.conf &>/dev/null
echo -e "${G}TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null) | max window: $(sysctl -n net.core.rmem_max 2>/dev/null) bytes${N}"
# conntrack table full = packets silently dropped = random disconnects under load (only if conntrack is active)
cat > /usr/local/bin/aliraza-conntrack.sh <<'CT'
#!/bin/sh
ifc=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
if [ -n "$ifc" ]; then
  if command -v tc >/dev/null 2>&1 && tc qdisc show dev "$ifc" root 2>/dev/null | grep -qE 'qdisc (fq_codel|pfifo_fast)'; then
    tc qdisc replace dev "$ifc" root fq 2>/dev/null
  fi
  ip link set dev "$ifc" txqueuelen 10000 2>/dev/null
fi
[ -e /proc/sys/net/netfilter/nf_conntrack_max ] || exit 0
mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
want=262144; [ "$mem" -le 1024 ] && want=131072
cur=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
[ "$cur" -lt "$want" ] && sysctl -qw net.netfilter.nf_conntrack_max=$want
[ -w /sys/module/nf_conntrack/parameters/hashsize ] && echo $((want/4)) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
# default established timeout is 5 days: dead tunnels would fill the table. 2h is safe (keepalives are 15-60s)
[ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ] && sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_established=7200 net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 net.netfilter.nf_conntrack_tcp_timeout_close_wait=30 net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30 2>/dev/null
exit 0
CT
chmod +x /usr/local/bin/aliraza-conntrack.sh
cat > /etc/systemd/system/aliraza-tune.service <<'TU'
[Unit]
Description=ALIRAZA runtime tuning (conntrack limit)
After=network.target ufw.service netfilter-persistent.service nftables.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/aliraza-conntrack.sh
[Install]
WantedBy=multi-user.target
TU
/usr/local/bin/aliraza-conntrack.sh
# ---- V2 BAN: blocked IPs get a notice (never a login) ----
BAN_BANNER=/etc/artricks/ban_banner.txt
if [[ ! -s "$BAN_BANNER" ]]; then
cat > "$BAN_BANNER" <<'BANBN'
<font color="#FF0000">🚫 𝗬𝗢𝗨 𝗛𝗔𝗩𝗘 𝗕𝗘𝗘𝗡 𝗕𝗔𝗡𝗡𝗘𝗗 𝗕𝗬 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#FFFF00">First apologize for your mistake,</font>
<font color="#00FF00">and then enjoy.</font>

<font color="#00FFFF">Contact: <a href="https://t.me/alirazax0">t.me/alirazax0</a></font>
BANBN
fi
chmod 644 "$BAN_BANNER"
touch /etc/artricks/banned.txt; chmod 644 /etc/artricks/banned.txt
cat > /usr/local/bin/aliraza-ban.sh <<'BANSH'
#!/bin/bash
# Rebuilds the ALIRAZA_BAN nat chain from /etc/artricks/banned.txt (one line per IP: ip<TAB>time<TAB>note).
# Blocked IPs hitting the SSH ports are redirected to the notice-only SSH server (port 2299).
CF=/etc/artricks/panel.json; BF=/etc/artricks/banned.txt; BP=2299
SP=$(jq -r '.ssh_port // 8443' "$CF" 2>/dev/null); [[ "$SP" =~ ^[0-9]+$ ]] || SP=8443
PORTS="22,109,447,$SP"
for T in iptables ip6tables; do
  command -v $T >/dev/null 2>&1 || continue
  $T -t nat -N ALIRAZA_BAN 2>/dev/null
  $T -t nat -F ALIRAZA_BAN 2>/dev/null
  $T -t nat -C PREROUTING -j ALIRAZA_BAN 2>/dev/null || $T -t nat -I PREROUTING 1 -j ALIRAZA_BAN 2>/dev/null
done
[[ -s "$BF" ]] || exit 0
while IFS=$'\t' read -r ip ts note; do
  [[ -z "$ip" ]] && continue
  if [[ "$ip" == *:* ]]; then T=ip6tables; else T=iptables; fi
  command -v $T >/dev/null 2>&1 || continue
  $T -t nat -A ALIRAZA_BAN -s "$ip" -p tcp -m multiport --dports "$PORTS" -j REDIRECT --to-ports $BP 2>/dev/null
done < "$BF"
exit 0
BANSH
chmod +x /usr/local/bin/aliraza-ban.sh
cat > /usr/local/bin/aliraza-ban-ssh.sh <<'BANSSH'
#!/bin/sh
# Notice-only SSH server: shows the ban banner, password login disabled, one auth try, short idle timeout.
B=/usr/local/sbin/dropbear; [ -x "$B" ] || B=/usr/sbin/dropbear
set --
for k in rsa ecdsa ed25519; do [ -f "/etc/dropbear/dropbear_${k}_host_key" ] && set -- "$@" -r "/etc/dropbear/dropbear_${k}_host_key"; done
exec "$B" -F -s -w -j -k -T 1 -I 20 -K 10 -p 2299 -b /etc/artricks/ban_banner.txt "$@"
BANSSH
chmod +x /usr/local/bin/aliraza-ban-ssh.sh
cat > /etc/systemd/system/aliraza-ban-ssh.service <<'BANSVC'
[Unit]
Description=ALIRAZA ban notice SSH (shows the ban message, never allows login)
After=network.target dropbear.service
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/local/bin/aliraza-ban-ssh.sh
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
BANSVC
cat > /etc/systemd/system/aliraza-ban.service <<'BANRULES'
[Unit]
Description=ALIRAZA blocked-IP firewall rules
After=network.target ufw.service netfilter-persistent.service nftables.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/aliraza-ban.sh
[Install]
WantedBy=multi-user.target
BANRULES
cat > /usr/local/bin/aliraza-watchdog.sh <<'WD'
#!/bin/bash
# ALIRAZA watchdog: if Dropbear / ws-proxy are running but stop answering (hung), restart them.
# Stopped services are left alone (systemd Restart=always handles crashes, and a manual stop stays stopped).
fd=0; fw=0
while true; do
  sleep 30
  # V5: a slow answer under heavy load is NOT a hang. 10s probes, 4 failures in a row (~2 min) before any restart.
  b=$(timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/109; head -n1 <&3' 2>/dev/null | tr -d '\r')
  if [[ "$b" == SSH-* ]]; then fd=0; else fd=$((fd+1)); fi
  if [[ $fd -ge 4 ]]; then systemctl is-active --quiet dropbear && systemctl restart dropbear; fd=0; sleep 5; fi
  if timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2082' 2>/dev/null; then fw=0; else fw=$((fw+1)); fi
  if [[ $fw -ge 4 ]]; then systemctl is-active --quiet ws-proxy && systemctl restart ws-proxy; fw=0; fi
done
WD
chmod +x /usr/local/bin/aliraza-watchdog.sh
cat > /etc/systemd/system/aliraza-watchdog.service <<'WDS'
[Unit]
Description=ALIRAZA watchdog (dropbear / ws-proxy hang detection)
After=network.target dropbear.service ws-proxy.service
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/local/bin/aliraza-watchdog.sh
Restart=always
RestartSec=5
Nice=10
[Install]
WantedBy=multi-user.target
WDS
cat > /usr/local/bin/ws-proxy.py <<'WS_EOF'
import asyncio, socket, time, os
try:
    import uvloop
    asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
except Exception: pass
PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'
MAP_DIR = '/run/aliraza/ws'
BAN_FILE = '/etc/artricks/banned.txt'
BAN_PORT = 2299
_B = [0, 0.0, set()]
def is_banned(ip):
    # blocked IPs are sent to the notice-only SSH server (shows the ban message, no login); list is reloaded when the file changes
    now = time.time()
    if now - _B[1] > 2:
        _B[1] = now
        try:
            m = os.stat(BAN_FILE).st_mtime
            if m != _B[0]:
                s = set()
                for l in open(BAN_FILE, encoding='utf-8'):
                    a = l.split('\t')[0].strip()
                    if a: s.add(a)
                _B[2] = s; _B[0] = m
        except Exception:
            _B[2] = set(); _B[0] = 0
    if ip.startswith('::ffff:'): ip = ip[7:]
    return ip in _B[2]
CHUNK = 262144
LIMIT = 1048576
WORKERS = max(1, min(4, os.cpu_count() or 1))
RESP = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
_LF = [None]
def log_client_ip(ip):
    # one long-lived line-buffered handle per worker (no open/close per connection)
    try:
        if _LF[0] is None: _LF[0] = open(LOG_FILE, 'a', buffering=1)
        _LF[0].write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\n")
    except Exception: _LF[0] = None
def tune(w):
    try:
        s = w.get_extra_info('socket')
        if s is not None:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 20)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 5)
            s.setsockopt(socket.IPPROTO_TCP, 18, 90000)  # TCP_USER_TIMEOUT: drop dead peers after 90s of unacked data
    except Exception: pass
    try: w.transport.set_write_buffer_limits(high=4194304, low=1048576)
    except Exception: pass
async def pump(r, w):
    # one direction only: a slow receiver here can never stall the opposite direction
    try:
        while True:
            data = await r.read(CHUNK)
            if not data: break
            w.write(data)
            await w.drain()
    except Exception: pass
async def handle(reader, writer):
    peer = writer.get_extra_info('peername')
    real_ip = peer[0] if peer else '0.0.0.0'
    t_writer = None
    lport = None
    try:
        tune(writer)
        try: request = await asyncio.wait_for(reader.read(4096), 10)
        except asyncio.TimeoutError: return
        if not request: return
        for line in request.decode('utf-8', errors='ignore').split('\r\n'):
            low = line.lower()
            if low.startswith('x-forwarded-for:') or low.startswith('x-real-ip:'):
                real_ip = line.split(':', 1)[1].strip().split(',')[0].strip()
                break
        log_client_ip(real_ip)
        tport = BAN_PORT if is_banned(real_ip) else TARGET_PORT
        writer.write(RESP)
        await writer.drain()
        t_reader = None
        for _try in range(3):
            try:
                t_reader, t_writer = await asyncio.wait_for(asyncio.open_connection(TARGET_HOST, tport, limit=LIMIT), 6)
                break
            except Exception: await asyncio.sleep(0.3)
        if t_reader is None: return
        tune(t_writer)
        # client sent its SSH banner in the same packet as the HTTP header: do not lose it
        rest = request.partition(b"\r\n\r\n")[2]
        if rest.startswith(b"SSH-"): t_writer.write(rest)
        try:
            lport = t_writer.get_extra_info('sockname')[1]
            with open(f"{MAP_DIR}/{lport}", "w") as mf: mf.write(real_ip)
        except Exception: lport = None
        a = asyncio.ensure_future(pump(reader, t_writer))
        b = asyncio.ensure_future(pump(t_reader, writer))
        await asyncio.wait([a, b], return_when=asyncio.FIRST_COMPLETED)
        a.cancel(); b.cancel()
    except Exception: pass
    finally:
        for w in (writer, t_writer):
            try:
                if w is not None: w.close()
            except Exception: pass
        if lport:
            try: os.remove(f"{MAP_DIR}/{lport}")
            except Exception: pass
def init_map():
    try:
        os.makedirs(MAP_DIR, exist_ok=True)
        for f in os.listdir(MAP_DIR): os.remove(os.path.join(MAP_DIR, f))
    except Exception: pass
async def serve():
    server = await asyncio.start_server(handle, '0.0.0.0', PORT, limit=LIMIT, backlog=4096,
                                        reuse_address=True, reuse_port=(WORKERS > 1))
    async with server:
        await server.serve_forever()
def run():
    try: asyncio.run(serve())
    finally: os._exit(1)
def supervise():
    kids = set()
    while True:
        while len(kids) < WORKERS:
            pid = os.fork()
            if pid == 0: run()
            kids.add(pid)
        try: pid, _ = os.wait()
        except ChildProcessError:
            kids.clear(); continue
        kids.discard(pid); time.sleep(0.5)
init_map()
if WORKERS > 1: supervise()
else: run()
WS_EOF
cat > /usr/local/bin/autokill.py <<'PY_EOF'
import os
import time
import subprocess
import re

USER_DIR = "/etc/artricks/users"
WSMAP = "/run/aliraza/ws"
LOCALS = ("127.0.0.1", "::1", "::ffff:127.0.0.1")
# Multi-login rule (IP_LIMIT = max different client IPs at the same time):
#  - counts distinct IPs, NOT sessions (a reconnect of the same device never counts as a 2nd login)
#  - must persist for GRACE_CYCLES checks (10s each) so reconnect overlaps are ignored
#  - NEWEST login wins: only the older extra IP(s) are disconnected (stale session after wifi<->mobile switch)
#  - LOCK_ON_VIOLATION=True restores the old harsh behaviour (lock account + kill every session)
LOCK_ON_VIOLATION = False
GRACE_CYCLES = 2

RE_A = re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
RE_B = re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'? from (\S+)")

def run(cmd, t=15):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=t).decode("utf-8", errors="ignore")
    except Exception:
        return ""

def get_auth_logs():
    raw = run(["journalctl", "-u", "dropbear", "--no-pager", "-g", "auth succeeded", "-n", "5000"])
    if not raw.strip() or raw.lstrip().startswith("-- No entries"):
        raw = run(["journalctl", "-u", "dropbear", "--no-pager", "-n", "2000"])
    if "auth succeeded" not in raw and os.path.exists("/var/log/auth.log"):   # journal already has it -> skip the 2MB file read
        try:
            with open("/var/log/auth.log", "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 2097152))
                raw += "\n" + f.read().decode("utf-8", errors="ignore")
        except Exception:
            pass
    return raw

def get_sessions():
    """user -> [(pid, real_client_ip, age_seconds)]"""
    procs = [p for p in (l.split() for l in run(["ps", "-eo", "pid=,etimes=,comm="]).splitlines()) if len(p) >= 3 and p[2] == "dropbear"]
    if not procs:
        return {}   # nobody connected: skip the expensive journal scan
    last = {}
    for line in get_auth_logs().splitlines():
        m = RE_A.search(line) or RE_B.search(line)
        if m:
            last[m.group(1)] = (m.group(2), m.group(3))
    out = {}
    for p in procs:
        if p[0] not in last:
            continue
        user, frm = last[p[0]]
        ip, _, port = frm.rpartition(":")
        ip = ip.strip("[]")
        real = ip
        if ip in LOCALS and port.isdigit():
            try:
                with open(f"{WSMAP}/{port}") as f:
                    real = f.read().strip() or ip
            except Exception:
                pass
        age = int(p[1]) if p[1].isdigit() else 0
        out.setdefault(user, []).append((p[0], real, age))
    return out

def get_pid_io_bytes(pid):
    total = 0
    try:
        with open(f"/proc/{pid}/io", "r") as f:
            for line in f:
                if line.startswith("rchar:") or line.startswith("wchar:"):
                    total += int(line.split(":")[1].strip())
    except Exception:
        pass
    return total

def kill_pid(pid):
    try:
        os.kill(int(pid), 9)
    except Exception:
        pass

def lock_user(user):
    subprocess.call(["passwd", "-l", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def parse_conf(lines):
    ip_limit, gb_limit, used_mb = 0, "Unlimited", 0.0
    for line in lines:
        if line.startswith("IP_LIMIT="):
            try: ip_limit = int(line.strip().split("=")[1])
            except Exception: pass
        elif line.startswith("GB_LIMIT="):
            gb_limit = line.strip().split("=")[1]
        elif line.startswith("USED_MB="):
            try: used_mb = float(line.strip().split("=")[1])
            except Exception: pass
    return ip_limit, gb_limit, used_mb

def save_usage(conf_path, used_mb):
    # re-read right before writing so a panel edit made meanwhile is not overwritten; atomic replace
    if not os.path.exists(conf_path):
        return  # account was deleted meanwhile: never resurrect its conf
    with open(conf_path, "r") as f:
        lines = f.readlines()
    out, seen = [], False
    for line in lines:
        if line.startswith("USED_MB="):
            out.append(f"USED_MB={used_mb:.2f}\n"); seen = True
        elif line.startswith("LAST_SEEN="):
            continue
        else:
            out.append(line if line.endswith("\n") else line + "\n")
    if not seen:
        out.append(f"USED_MB={used_mb:.2f}\n")
    out.append(f"LAST_SEEN={int(time.time())}\n")
    tmp = conf_path + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(out)
    os.replace(tmp, conf_path)

def extra_ip_sessions(sessions, ip_limit):
    """sessions: [(pid, ip, age)]. Returns pids to disconnect (older extra IPs), [] if within the limit."""
    by_ip = {}
    for pid, ip, age in sessions:
        by_ip.setdefault(ip, []).append((pid, age))
    if len(by_ip) <= ip_limit:
        return []
    order = sorted(by_ip.items(), key=lambda kv: min(a for _, a in kv[1]))  # newest IP first
    victims = []
    for ip, ss in order[ip_limit:]:
        victims += [pid for pid, _ in ss]
    return victims

def main():
    last_pid_bytes = {}
    strikes = {}
    while True:
        try:
            sess = get_sessions()
            live = set()
            if os.path.isdir(USER_DIR):
                for fname in os.listdir(USER_DIR):
                    if not fname.endswith(".conf"):
                        continue
                    uname = fname[:-5]
                    conf_path = os.path.join(USER_DIR, fname)
                    try:
                        with open(conf_path, "r") as f:
                            ip_limit, gb_limit, used_mb = parse_conf(f.readlines())
                        sl = sess.get(uname, [])
                        pids = [x[0] for x in sl]
                        live.update(pids)
                        if not pids:
                            strikes.pop(uname, None)
                            continue
                        for pid in pids:
                            cur = get_pid_io_bytes(pid)
                            if pid in last_pid_bytes and cur > last_pid_bytes[pid]:
                                used_mb += (cur - last_pid_bytes[pid]) / (1024.0 * 1024.0)
                            last_pid_bytes[pid] = cur
                        save_usage(conf_path, used_mb)

                        if gb_limit != "Unlimited":
                            try:
                                if used_mb >= float(gb_limit) * 1024.0:
                                    lock_user(uname)
                                    for pid in pids: kill_pid(pid)
                                    continue
                            except Exception:
                                pass

                        if ip_limit > 0:
                            victims = extra_ip_sessions(sl, ip_limit)
                            if victims:
                                strikes[uname] = strikes.get(uname, 0) + 1
                                if strikes[uname] >= GRACE_CYCLES:
                                    if LOCK_ON_VIOLATION:
                                        lock_user(uname)
                                        victims = pids
                                    for pid in victims: kill_pid(pid)
                                    strikes[uname] = 0
                            else:
                                strikes.pop(uname, None)
                    except Exception:
                        continue
            for pid in [p for p in last_pid_bytes if p not in live]:
                del last_pid_bytes[pid]
        except Exception:
            pass
        time.sleep(10)

if __name__ == "__main__":
    main()
PY_EOF
cat > /usr/local/bin/tgbot.py <<'TG_EOF'
import os
import re
import json
import asyncio
import subprocess
from datetime import datetime, timedelta

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, filters,
)

PANEL_NAME = "ALIRAZA VPN Panel"
CONFIG_FILE = "/etc/artricks/tgbot/config.json"
ADMINS_FILE = "/etc/artricks/tgbot/admins.json"
USERS_DIR = "/etc/artricks/users"
DOMAIN_FILE = "/etc/artricks/domain.conf"
BANNER_FILE = "/etc/artricks/banner.txt"

NGINX_TEMPLATE = """server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name {dom} _;
    location / {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
    location /artricks {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
}}
server {{
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name {dom} _;
    ssl_certificate /etc/letsencrypt/live/{dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{dom}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
    location /artricks {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
}}
"""

FLOWS = {
    "add_user": [
        ("username", "\U0001F464 Username enter karein:"),
        ("password", "\U0001F511 Password enter karein:"),
        ("days", "\U0001F4C5 Expiry days enter karein (e.g. 30):"),
        ("ip_limit", "\U0001F310 Max IP Limit enter karein (e.g. 1):"),
        ("gb_limit", "\U0001F4BE Data Limit GB enter karein (e.g. 5, ya Unlimited):"),
    ],
    "del_user": [("username", "\U0001F464 Delete karne ke liye Username enter karein:")],
    "renew_user": [
        ("username", "\U0001F464 Username enter karein jise renew karna hai:"),
        ("days", "\U0001F4C5 Kitne additional days add karne hain?"),
    ],
    "ip_limit": [
        ("username", "\U0001F464 Username enter karein:"),
        ("value", "\U0001F310 Naya IP Limit enter karein:"),
    ],
    "gb_limit": [
        ("username", "\U0001F464 Username enter karein:"),
        ("value", "\U0001F4BE Naya GB Limit enter karein:"),
    ],
    "domain": [("value", "\U0001F30D Naya domain enter karein (e.g. sub.example.com):")],
    "banner": [("value", "\U0001F4E2 Naya SSH banner text bhejein:")],
    "add_admin": [("value", "\U0001F451 Naye Admin ka Telegram User ID enter karein:")],
    "remove_admin": [("value", "\U0001F5D1 Remove karne ke liye Admin ka Telegram User ID enter karein:")],
}

def load_config():
    with open(CONFIG_FILE) as f: return json.load(f)
def load_admins():
    if not os.path.exists(ADMINS_FILE): return []
    with open(ADMINS_FILE) as f: return json.load(f)
def save_admins(admins):
    with open(ADMINS_FILE, "w") as f: json.dump(admins, f)
def is_admin(uid): return uid in load_admins()
def is_super(uid): return uid == load_config().get("super_admin")
def sh(cmd_list, input_data=None): return subprocess.run(cmd_list, capture_output=True, text=True, input=input_data)
def run(cmd_str): return subprocess.run(cmd_str, shell=True, capture_output=True, text=True)

def get_domain():
    if os.path.exists(DOMAIN_FILE):
        with open(DOMAIN_FILE) as f:
            d = f.read().strip()
            return d if d else "No Domain Set"
    return "No Domain Set"

PANEL_DIR = "/opt/aliraza-panel"
PANEL_PY = PANEL_DIR + "/venv/bin/python"

def panel_call(code):
    if not os.path.exists(PANEL_PY): return False
    r = sh(["bash", "-c", f"cd {PANEL_DIR} && {PANEL_PY} -c 'import app; {code}'"])
    return r.returncode == 0

def apply_nginx_config():
    dom = get_domain()
    if dom == "No Domain Set": return
    if panel_call("app.apply_nginx()"): return
    os.makedirs("/etc/nginx/conf.d", exist_ok=True)
    conf = NGINX_TEMPLATE.format(dom=dom)
    if not os.path.exists(f"/etc/letsencrypt/live/{dom}/fullchain.pem"):
        conf = conf.replace(f"/etc/letsencrypt/live/{dom}/fullchain.pem", "/etc/artricks/ssl/self.crt").replace(f"/etc/letsencrypt/live/{dom}/privkey.pem", "/etc/artricks/ssl/self.key")
    with open("/etc/nginx/conf.d/vpn.conf", "w") as f:
        f.write(conf)
    sh(["rm", "-f", "/etc/nginx/sites-enabled/default"])
    if sh(["nginx", "-t"]).returncode == 0:
        sh(["systemctl", "restart", "nginx"])

def valid_username(u): return bool(u) and len(u)<=32 and u not in (".","..") and u[0]!="-" and not re.search(r"[\s:/\\\x00-\x1f\x7f]", u)

def add_user(username, password, days, ip_limit, gb_limit):
    if not valid_username(username): return False, "Invalid username."
    try: exp_date = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
    except ValueError: return False, "Invalid days value."
    r = sh(["useradd", "-M", "-s", "/bin/bash", "-e", exp_date, "--", username])
    if r.returncode != 0: r = sh(["useradd", "--badname", "-M", "-s", "/bin/bash", "-e", exp_date, "--", username])
    if r.returncode != 0: return False, (r.stderr.strip() or "User create failed.")
    sh(["chpasswd"], input_data=f"{username}:{password}\n")
    os.makedirs(USERS_DIR, exist_ok=True)
    with open(f"{USERS_DIR}/{username}.conf", "w") as f:
        f.write(f"IP_LIMIT={ip_limit}\nGB_LIMIT={gb_limit}\nUSED_MB=0.0\n")
    return True, exp_date

def delete_user(username):
    sh(["userdel", "-f", username])
    try: os.remove(f"{USERS_DIR}/{username}.conf")
    except FileNotFoundError: pass

def renew_user(username, days):
    if sh(["id", username]).returncode != 0: return False
    try: new_exp = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
    except ValueError: return False
    sh(["usermod", "-e", new_exp, username])
    sh(["passwd", "-u", username])
    return True

def update_conf_field(username, field, value):
    path = f"{USERS_DIR}/{username}.conf"
    if not os.path.exists(path): return False
    lines = open(path).readlines()
    new_lines = []
    found = False
    for line in lines:
        if line.startswith(f"{field}="):
            new_lines.append(f"{field}={value}\n")
            found = True
        else: new_lines.append(line)
    if not found: new_lines.append(f"{field}={value}\n")
    with open(path, "w") as f: f.writelines(new_lines)
    sh(["passwd", "-u", username])
    return True

def list_users_text():
    if not os.path.isdir(USERS_DIR): return "Koi user nahi mila."
    entries = []
    for fname in sorted(os.listdir(USERS_DIR)):
        if not fname.endswith(".conf"): continue
        uname = fname[:-5]
        data = {}
        for l in open(f"{USERS_DIR}/{fname}"):
            if "=" in l:
                k, v = l.strip().split("=", 1)
                data[k] = v
        exists = sh(["id", uname]).returncode == 0
        status = "Deleted"
        if exists:
            p = sh(["passwd", "-S", uname])
            status = "LOCKED" if " L " in f" {p.stdout} " else "Active"
        used_mb = 0.0
        try: used_mb = float(data.get("USED_MB", "0") or 0)
        except ValueError: pass
        used_gb = round(used_mb / 1024, 2)
        entries.append(f"\U0001F464 {uname} | IP:{data.get('IP_LIMIT', '?')} | Used:{used_gb}GB / {data.get('GB_LIMIT', '?')}GB | {status}")
    return "\n".join(entries) if entries else "Koi user nahi mila."

def connected_ips_text():
    r = sh(["ss", "-tnp"])
    ports = {"109", "447", "22"}
    try: ports.add(str(json.load(open("/etc/artricks/panel.json")).get("ssh_port")))
    except Exception: pass
    lines = [l for l in r.stdout.splitlines() if "ESTAB" in l and len(l.split()) > 3 and l.split()[3].rsplit(":", 1)[-1] in ports]
    return f"\U0001F50C Active SSH/WS sessions (approx): {len(lines)}"

def status_text():
    def st(svc):
        r = sh(["systemctl", "is-active", svc])
        return "\U0001F7E2 ACTIVE" if r.stdout.strip() == "active" else "\U0001F534 INACTIVE"
    return f"\U0001F30D Domain: {get_domain()}\n\nNginx: {st('nginx')}\nDropbear: {st('dropbear')}\nWS Proxy: {st('ws-proxy')}\nAuto-Kill: {st('autokill')}"

def set_domain(new_domain):
    os.makedirs("/etc/artricks", exist_ok=True)
    with open(DOMAIN_FILE, "w") as f: f.write(new_domain)
    try:
        pj = "/etc/artricks/panel.json"
        c = json.load(open(pj)) if os.path.exists(pj) else {}
        c["domain"] = new_domain
        with open(pj, "w") as f: json.dump(c, f)
    except Exception: pass
    apply_nginx_config()

def setup_ssl():
    dom = get_domain()
    if dom == "No Domain Set": return False, "Pehle domain set karein."
    sh(["systemctl", "stop", "nginx"])
    sh(["certbot", "certonly", "-n", "--standalone", "--preferred-challenges", "http", "--agree-tos", "--register-unsafely-without-email", "-d", dom])
    if os.path.exists(f"/etc/letsencrypt/live/{dom}/fullchain.pem"):
        apply_nginx_config()
        sh(["systemctl", "start", "nginx"])
        return True, "SSL issued successfully."
    sh(["systemctl", "start", "nginx"])
    return False, "SSL fail ho gaya."

def fix_websocket():
    sh(["systemctl", "restart", "dropbear"])
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "restart", "ws-proxy"])
    sh(["systemctl", "restart", "autokill"])
    apply_nginx_config()
    return "WebSocket & Bandwidth engine restarted."

WS_PROXY_SRC = """import socket, threading, select, time
PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'
def log_client_ip(ip):
    try:
        with open(LOG_FILE, 'a') as f: f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\\n")
    except Exception: pass
def handle_client(client_socket, client_addr):
    real_ip = client_addr[0]
    try:
        client_socket.settimeout(10)
        client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        request = client_socket.recv(4096).decode('utf-8', errors='ignore')
        if not request:
            client_socket.close()
            return
        for line in request.split('\\r\\n'):
            if line.lower().startswith('x-forwarded-for:') or line.lower().startswith('x-real-ip:'):
                real_ip = line.split(':')[1].strip().split(',')[0].strip()
                break
        log_client_ip(real_ip)
        response = "HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n"
        client_socket.sendall(response.encode('utf-8'))
        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        target_socket.connect((TARGET_HOST, TARGET_PORT))
        sockets = [client_socket, target_socket]
        client_socket.settimeout(None)
        while True:
            readable, _, _ = select.select(sockets, [], [])
            for s in readable:
                other = target_socket if s is client_socket else client_socket
                data = s.recv(65536)
                if not data: return
                other.sendall(data)
    except Exception: pass
    finally: client_socket.close()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', PORT))
server.listen(200)
while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
"""

WS_PROXY_SERVICE = """[Unit]
Description=ALIRAZA WebSocket Proxy Service
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
Nice=-5
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
"""

AUTOKILL_SRC = open("/usr/local/bin/autokill.py").read() if os.path.exists("/usr/local/bin/autokill.py") else ""

AUTOKILL_SERVICE = """[Unit]
Description=ARTRICKS Auto-Kill & Bandwidth Tracking Service
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always
[Install]
WantedBy=multi-user.target
"""

DEFAULT_BANNER = """<font color="#FF0000">𝗦𝗘𝗥𝗩𝗘𝗥 <font color="#FF0000">𝗕𝗬</font> 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#00FFFF">🌐 𝗦𝗦𝗛</font>  •  <font color="#00FF00">𝗩𝗟𝗘𝗦𝗦</font>
<font color="#FF1493">⚡ 𝗩𝗠𝗘𝗦</font> • <font color="#FFFF00">𝗧𝗥𝗢𝗝𝗔𝗡</font><font color="#FF0000">🔥</font>

<font color="#FF8C00">📢 𝗝𝗢𝗜𝗡 𝗖𝗛𝗔𝗡𝗘𝗟</font>
<font color='#00FF00'>↓ <a href="https://t.me/ar_tricks">CLICK HERE</a> ↓</font>
"""

def install_components_sync():
    sh(["apt-get", "update", "-y"])
    sh(["apt-get", "install", "-y", "curl", "wget", "unzip", "tar", "net-tools", "socat", "jq", "openssl", "nginx", "dropbear", "certbot", "python3", "python3-pip", "lsof", "iptables"])
    if not os.path.exists(BANNER_FILE) or os.path.getsize(BANNER_FILE) == 0:
        with open(BANNER_FILE, "w", encoding="utf-8") as f: f.write(DEFAULT_BANNER)
    panel_call("app.apply_dropbear()")
    sh(["systemctl", "restart", "ssh"])
    if not os.path.exists("/usr/local/bin/ws-proxy.py"):
        with open("/usr/local/bin/ws-proxy.py", "w") as f: f.write(WS_PROXY_SRC)
    sh(["chmod", "+x", "/usr/local/bin/ws-proxy.py"])
    with open("/etc/systemd/system/ws-proxy.service", "w") as f: f.write(WS_PROXY_SERVICE)
    with open("/usr/local/bin/autokill.py", "w") as f: f.write(AUTOKILL_SRC)
    sh(["chmod", "+x", "/usr/local/bin/autokill.py"])
    with open("/etc/systemd/system/autokill.service", "w") as f: f.write(AUTOKILL_SERVICE)
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "enable", "ws-proxy"])
    sh(["systemctl", "restart", "ws-proxy"])
    sh(["systemctl", "enable", "autokill"])
    sh(["systemctl", "restart", "autokill"])
    apply_nginx_config()

def uninstall_all():
    sh(["systemctl", "stop", "aliraza-panel"]); sh(["systemctl", "disable", "aliraza-panel"])
    sh(["systemctl", "stop", "ws-proxy"]); sh(["systemctl", "stop", "autokill"]); sh(["systemctl", "stop", "dropbear"])
    sh(["systemctl", "disable", "ws-proxy"]); sh(["systemctl", "disable", "autokill"])
    for f in ["/etc/systemd/system/ws-proxy.service", "/etc/systemd/system/autokill.service", "/etc/systemd/system/dropbear.service.d/override.conf", "/usr/local/bin/ws-proxy.py", "/usr/local/bin/autokill.py", "/etc/nginx/conf.d/vpn.conf", "/etc/nginx/conf.d/panel.conf", "/etc/systemd/system/aliraza-panel.service"]:
        try: os.remove(f)
        except FileNotFoundError: pass
    sh(["systemctl", "daemon-reload"]); sh(["systemctl", "restart", "nginx"])
    if os.path.isdir(USERS_DIR):
        for fname in os.listdir(USERS_DIR):
            if fname.endswith(".conf"): sh(["userdel", "-f", fname[:-5]])
    sh(["rm", "-rf", "/etc/artricks"]); sh(["rm", "-rf", "/opt/rr-tgbot-venv"]); sh(["rm", "-rf", "/opt/aliraza-panel"])
    for f in ["/usr/local/bin/menu", "/usr/bin/menu"]:
        try: os.remove(f)
        except FileNotFoundError: pass

def schedule_self_removal():
    subprocess.Popen(["bash", "-c", "sleep 3 && systemctl disable tgbot 2>/dev/null; systemctl stop tgbot 2>/dev/null; rm -f /etc/systemd/system/tgbot.service /usr/local/bin/tgbot.py; systemctl daemon-reload"])

def back_keyboard(): return InlineKeyboardMarkup([[InlineKeyboardButton("\u2B05\uFE0F Back to Menu", callback_data="back_main")]])
def main_menu_keyboard(uid):
    rows = [
        [InlineKeyboardButton("\u2795 Add User", callback_data="add_user"), InlineKeyboardButton("\U0001F5D1 Delete User", callback_data="del_user")],
        [InlineKeyboardButton("\U0001F4CB User List", callback_data="list_users"), InlineKeyboardButton("\u23F3 Renew User", callback_data="renew_user")],
        [InlineKeyboardButton("\U0001F310 IP Limit", callback_data="ip_limit"), InlineKeyboardButton("\U0001F4BE GB Limit", callback_data="gb_limit")],
        [InlineKeyboardButton("\U0001F50C Connected IPs", callback_data="conn_ips"), InlineKeyboardButton("\u2699\uFE0F Status", callback_data="sys_status")],
        [InlineKeyboardButton("\U0001F30D Domain", callback_data="domain"), InlineKeyboardButton("\U0001F512 SSL", callback_data="ssl")],
        [InlineKeyboardButton("\U0001F4E2 Banner", callback_data="banner"), InlineKeyboardButton("\U0001F6E0 Fix WebSocket", callback_data="fix_ws")],
        [InlineKeyboardButton("\U0001F4E6 Install Components", callback_data="install"), InlineKeyboardButton("\U0001F9E8 Uninstall Panel", callback_data="uninstall")],
    ]
    if is_super(uid): rows.append([InlineKeyboardButton("\U0001F451 Admin Management", callback_data="admin_mgmt")])
    return InlineKeyboardMarkup(rows)

def admins_text():
    admins = load_admins()
    lines = ["\U0001F451 *Admin Management*\n"]
    for a in admins:
        tag = " (Super Admin)" if a == load_config().get("super_admin") else ""
        lines.append(f"\u2022 `{a}`{tag}")
    return "\n".join(lines)

def admin_menu_keyboard():
    return InlineKeyboardMarkup([[InlineKeyboardButton("\u2795 Add Admin", callback_data="add_admin"), InlineKeyboardButton("\u2796 Remove Admin", callback_data="remove_admin")], [InlineKeyboardButton("\u2B05\uFE0F Back", callback_data="back_main")]])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if not is_admin(uid):
        await update.message.reply_text("\u26D4 Access Denied. Aap authorized admin nahi hain.")
        return
    context.user_data['flow'] = None
    await update.message.reply_text(f"\U0001F44B Welcome to {PANEL_NAME}\n\nApna option chunein:", reply_markup=main_menu_keyboard(uid))

async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data['flow'] = None
    await update.message.reply_text("Cancelled.")

async def execute_flow(flow, data, update: Update):
    if flow == "add_user":
        ok, info = add_user(data["username"], data["password"], data["days"], data["ip_limit"], data["gb_limit"])
        if ok:
            dom = get_domain()
            payload = f"GET /artricks HTTP/1.1[crlf]Host: {dom}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
            msg = f"\u2705 *Account Created*\n\nDomain: `{dom}`\nUsername: `{data['username']}`\nPassword: `{data['password']}`\nExpiry: `{info}`\nIP Limit: `{data['ip_limit']}`\nGB Limit: `{data['gb_limit']}`\n\nSSH Direct: 22, 109, 447\nSSH WS (HTTP): 80\nSSH WS (SSL): 443\n\nPayload:\n`{payload}`"
        else: msg = f"\u274C User create fail: {info}"
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=back_keyboard())
    elif flow == "renew_user":
        ok = renew_user(data["username"], data["days"])
        await update.message.reply_text("\u2705 Renewed." if ok else "\u274C User not found.", reply_markup=back_keyboard())
    elif flow == "ip_limit":
        ok = update_conf_field(data["username"], "IP_LIMIT", data["value"])
        await update.message.reply_text("\u2705 IP limit updated." if ok else "\u274C User config not found.", reply_markup=back_keyboard())
    elif flow == "gb_limit":
        ok = update_conf_field(data["username"], "GB_LIMIT", data["value"])
        await update.message.reply_text("\u2705 GB limit updated." if ok else "\u274C User config not found.", reply_markup=back_keyboard())
    elif flow == "domain":
        if not re.match(r"^[A-Za-z0-9.-]+$", data["value"]):
            await update.message.reply_text("❌ Invalid domain.", reply_markup=back_keyboard())
            return
        set_domain(data["value"])
        await update.message.reply_text(f"\u2705 Domain set to {data['value']}", reply_markup=back_keyboard())
    elif flow == "banner":
        txt = data["value"]
        if len(txt.encode()) > 2000:
            await update.message.reply_text("\u274C Banner bohat bara hai (max 2000 bytes).", reply_markup=back_keyboard())
            return
        old = open(BANNER_FILE, encoding="utf-8").read() if os.path.exists(BANNER_FILE) else None
        with open(BANNER_FILE, "w", encoding="utf-8") as f: f.write(txt if txt.strip() else "\n")
        sh(["systemctl", "restart", "dropbear"])
        await asyncio.sleep(1)
        if sh(["systemctl", "is-active", "dropbear"]).stdout.strip() != "active":
            if old is not None:
                with open(BANNER_FILE, "w", encoding="utf-8") as f: f.write(old)
            sh(["systemctl", "restart", "dropbear"])
            await update.message.reply_text("\u274C Dropbear start nahi hua, purana banner restore kar diya.", reply_markup=back_keyboard())
            return
        await update.message.reply_text("\u2705 Banner updated.", reply_markup=back_keyboard())
    elif flow == "add_admin":
        try: new_id = int(data["value"])
        except ValueError: 
            await update.message.reply_text("\u274C Invalid ID.")
            return
        admins = load_admins()
        if new_id in admins: await update.message.reply_text("\u26A0\uFE0F Already an admin.")
        else:
            admins.append(new_id)
            save_admins(admins)
            await update.message.reply_text(f"\u2705 Admin {new_id} added.", reply_markup=admin_menu_keyboard())

async def text_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if not is_admin(uid): return
    flow = context.user_data.get('flow')
    if not flow: return
    step = context.user_data.get('step', 0)
    field, _ = FLOWS[flow][step]
    context.user_data.setdefault('data', {})[field] = update.message.text.strip()
    step += 1
    if step < len(FLOWS[flow]):
        context.user_data['step'] = step
        await update.message.reply_text(FLOWS[flow][step][1])
        return
    data = context.user_data['data']
    context.user_data['flow'] = None
    if flow == "del_user":
        username = data["username"]
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Confirm Delete", callback_data=f"do_del:{username}"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await update.message.reply_text(f"\u26A0\uFE0F '{username}' delete karna confirm karein:", reply_markup=kb)
        return
    if flow == "remove_admin":
        try: target = int(data["value"])
        except ValueError: 
            await update.message.reply_text("\u274C Invalid ID.")
            return
        if target == load_config().get("super_admin"):
            await update.message.reply_text("\u274C Super admin remove nahi ho sakta.")
            return
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Confirm Remove", callback_data=f"rm_admin:{target}"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await update.message.reply_text(f"\u26A0\uFE0F Admin {target} remove karna confirm karein:", reply_markup=kb)
        return
    await execute_flow(flow, data, update)

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    uid = q.from_user.id
    if not is_admin(uid):
        await q.answer("Access denied.", show_alert=True)
        return
    data = q.data
    await q.answer()
    if data == "back_main":
        context.user_data['flow'] = None
        await q.edit_message_text("\U0001F4CB Main Menu", reply_markup=main_menu_keyboard(uid))
    elif data in FLOWS:
        context.user_data['flow'] = data
        context.user_data['step'] = 0
        context.user_data['data'] = {}
        await q.edit_message_text(FLOWS[data][0][1])
    elif data == "list_users": await q.edit_message_text(list_users_text(), reply_markup=back_keyboard())
    elif data == "conn_ips": await q.edit_message_text(connected_ips_text(), reply_markup=back_keyboard())
    elif data == "sys_status": await q.edit_message_text(status_text(), reply_markup=back_keyboard())
    elif data == "ssl":
        await q.edit_message_text("\U0001F512 SSL issue ho raha hai, wait karein...")
        ok, msg = await asyncio.to_thread(setup_ssl)
        await q.message.reply_text(("\u2705 " if ok else "\u274C ") + msg, reply_markup=back_keyboard())
    elif data == "fix_ws":
        msg = fix_websocket()
        await q.edit_message_text(f"\u2705 {msg}", reply_markup=back_keyboard())
    elif data == "install":
        await q.edit_message_text("\U0001F4E6 Poora system install ho raha hai, 2-5 min lagega...")
        await asyncio.to_thread(install_components_sync)
        await q.message.reply_text("\u2705 Installation complete!", reply_markup=back_keyboard())
    elif data == "uninstall":
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Haan, Uninstall karein", callback_data="do_uninstall"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await q.edit_message_text("\u26A0\uFE0F Yeh sab kuch permanently remove kar dega. Confirm karein:", reply_markup=kb)
    elif data == "do_uninstall":
        await q.edit_message_text("\U0001F9E8 Uninstalling...")
        await asyncio.to_thread(uninstall_all)
        await q.message.reply_text("\u2705 Uninstall complete.")
        schedule_self_removal()
    elif data == "admin_mgmt":
        if not is_super(uid):
            await q.answer("Sirf Super Admin ke liye.", show_alert=True)
            return
        await q.edit_message_text(admins_text(), parse_mode="Markdown", reply_markup=admin_menu_keyboard())
    elif data.startswith("do_del:"):
        delete_user(data.split(":", 1)[1])
        await q.edit_message_text("\u2705 User deleted.", reply_markup=back_keyboard())
    elif data.startswith("rm_admin:"):
        target = int(data.split(":", 1)[1])
        admins = load_admins()
        if target in admins:
            admins.remove(target)
            save_admins(admins)
        await q.edit_message_text(admins_text(), parse_mode="Markdown", reply_markup=admin_menu_keyboard())

def main():
    app = Application.builder().token(load_config()["token"]).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("cancel", cancel))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text_handler))
    app.run_polling()

if __name__ == "__main__":
    main()
TG_EOF
cat > /etc/systemd/system/ws-proxy.service <<'U1'
[Unit]
Description=ALIRAZA WebSocket Proxy
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
Nice=-5
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
U1
cat > /etc/systemd/system/autokill.service <<'U2'
[Unit]
Description=ALIRAZA Auto-Kill & Bandwidth
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always
RestartSec=3
Nice=15
CPUWeight=20
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
U2
cat > /etc/systemd/system/tgbot.service <<'U3'
[Unit]
Description=ALIRAZA Telegram Bot
After=network.target
[Service]
ExecStart=/opt/rr-tgbot-venv/bin/python3 /usr/local/bin/tgbot.py
Restart=always
[Install]
WantedBy=multi-user.target
U3
cat > /etc/systemd/system/aliraza-panel.service <<'U4'
[Unit]
Description=ALIRAZA SSH Panel
After=network.target
StartLimitIntervalSec=0
[Service]
WorkingDirectory=/opt/aliraza-panel
ExecStart=/opt/aliraza-panel/venv/bin/gunicorn -k gthread -w 1 --threads 64 --timeout 120 -b 127.0.0.1:12026 --chdir /opt/aliraza-panel app:app
Restart=always
RestartSec=3
Nice=5
CPUWeight=50
[Install]
WantedBy=multi-user.target
U4
echo -e "${Y}[3/6] Panel app...${N}"
cat > /opt/aliraza-panel/app.py <<'APP_EOF'
# ALIRAZA SSH Panel backend | Support: @ar_tricks
import os,re,json,time,sqlite3,subprocess,secrets,threading,pty,select,struct,fcntl,termios,codecs,datetime,socket
import psutil
from flask import Flask,request,session,jsonify,send_file
from flask_sock import Sock
from werkzeug.security import generate_password_hash,check_password_hash
D="/etc/artricks";UD=D+"/users";CFG=D+"/panel.json";DB=D+"/panel.db";BANNER=D+"/banner.txt"
DEF={"domain":"","panel_port":2083,"ssh_port":8443}
def cfg():
    try: return {**DEF,**json.load(open(CFG))}
    except Exception: return dict(DEF)
def savecfg(c):
    os.makedirs(D,exist_ok=True);json.dump(c,open(CFG,"w"))
    open(D+"/domain.conf","w").write(c["domain"])
def sh(a,inp=None,t=60):
    try:
        r=subprocess.run(a,input=inp,capture_output=True,text=True,timeout=t);return r.returncode==0,(r.stdout+r.stderr).strip()
    except Exception as e: return False,str(e)
def later(f,s=1.5): threading.Timer(s,f).start()
def ufw(p):
    if sh(["ufw","status"])[1].startswith("Status: active"): sh(["ufw","allow",f"{p}/tcp"])
PROXY="""        proxy_pass http://127.0.0.1:%s;proxy_http_version 1.1;proxy_set_header Upgrade $http_upgrade;proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;proxy_set_header X-Real-IP $remote_addr;proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;proxy_send_timeout 86400s;proxy_buffering off;proxy_request_buffering off;proxy_connect_timeout 10s;proxy_next_upstream off;proxy_socket_keepalive on;"""
def apply_nginx():
    c=cfg();d=c["domain"];le=f"/etc/letsencrypt/live/{d}"
    crt,key=(le+"/fullchain.pem",le+"/privkey.pem") if os.path.exists(le+"/fullchain.pem") else (D+"/ssl/self.crt",D+"/ssl/self.key")
    v6=os.path.exists("/proc/net/if_inet6")
    def L(port,extra=""):
        x=" ".join(t for t in ("listen",str(port),extra) if t)+";"
        return x+(x.replace("listen "+str(port),"listen [::]:"+str(port),1) if v6 else "")
    ws=PROXY%2082
    open("/etc/nginx/conf.d/vpn.conf","w").write(f"""server{{{L(80,"default_server backlog=4096 so_keepalive=20s:10s:5")}server_name {d} _;
 location /{{\n{ws}\n }}\n location /artricks{{\n{ws}\n }}}}
server{{{L(443,"ssl default_server backlog=4096 so_keepalive=20s:10s:5")}server_name {d} _;ssl_certificate {crt};ssl_certificate_key {key};ssl_protocols TLSv1.2 TLSv1.3;
 location /{{\n{ws}\n }}\n location /artricks{{\n{ws}\n }}}}""")
    open("/etc/nginx/conf.d/panel.conf","w").write(f"""server{{{L(c['panel_port'],"ssl http2")}server_name _;ssl_certificate {crt};ssl_certificate_key {key};ssl_protocols TLSv1.2 TLSv1.3;
 location /{{\n{PROXY%12026}\n }}}}""")
    try: os.remove("/etc/nginx/sites-enabled/default")
    except Exception: pass
    ok,o=sh(["nginx","-t"])
    if ok: ok,o=sh(["systemctl","restart","nginx"])
    return ok,o
BANNER_MAX=2000  # Dropbear refuses to START if the banner file is bigger than this
DEF_BANNER="""<font color="#FF0000">𝗦𝗘𝗥𝗩𝗘𝗥 <font color="#FF0000">𝗕𝗬</font> 𝗔𝗟𝗜𝗥𝗔𝗭𝗔</font>

<font color="#00FFFF">🌐 𝗦𝗦𝗛</font>  •  <font color="#00FF00">𝗩𝗟𝗘𝗦𝗦</font>
<font color="#FF1493">⚡ 𝗩𝗠𝗘𝗦</font> • <font color="#FFFF00">𝗧𝗥𝗢𝗝𝗔𝗡</font><font color="#FF0000">🔥</font>

<font color="#FF8C00">📢 𝗝𝗢𝗜𝗡 𝗖𝗛𝗔𝗡𝗘𝗟</font>
<font color='#00FF00'>↓ <a href="https://t.me/ar_tricks">CLICK HERE</a> ↓</font>
"""
def set_banner(t):
    # Dropbear reads the banner file only when it starts, so saving the file is not enough: restart it.
    # KillMode=process (see apply_dropbear) keeps connected users online during the restart.
    t=str(t).replace("\r\n","\n")
    if len(t.encode())>BANNER_MAX: raise ValueError(f"Banner bohat bara hai ({len(t.encode())} bytes). Max {BANNER_MAX} bytes.")
    if not t.strip(): t="\n"
    try: old=open(BANNER,encoding="utf-8").read()
    except Exception: old=None
    def put(x): os.makedirs(D,exist_ok=True);tmp=BANNER+".tmp";open(tmp,"w",encoding="utf-8").write(x);os.chmod(tmp,0o644);os.replace(tmp,BANNER)
    put(t);sh(["systemctl","restart","dropbear"]);time.sleep(1)
    if sh(["systemctl","is-active","dropbear"])[1]!="active":
        if old is not None: put(old)
        sh(["systemctl","restart","dropbear"]);raise ValueError("Dropbear restart fail hua, purana banner wapas laga diya")
def apply_dropbear():
    c=cfg();os.makedirs("/etc/dropbear",exist_ok=True)
    if not os.path.exists(BANNER): open(BANNER,"w",encoding="utf-8").write(DEF_BANNER)
    _m=psutil.virtual_memory().total;W=33554432 if _m>=3800*2**20 else 16777216 if _m>=1900*2**20 else 8388608
    for k in("rsa","ecdsa","ed25519"):
        f=f"/etc/dropbear/dropbear_{k}_host_key"
        if not os.path.exists(f): sh(["dropbearkey","-t",k,"-f",f])
    os.makedirs("/etc/systemd/system/dropbear.service.d",exist_ok=True)
    sp=int(c["ssh_port"]);ports=list(dict.fromkeys([sp,109,447]))
    binp="/usr/local/sbin/dropbear" if os.path.exists("/usr/local/sbin/dropbear") else "/usr/sbin/dropbear"
    # V5: only use a window the installed binary really supports (custom build: up to 32MB, stock dropbear caps at 10MB)
    try: _mx=int(open("/etc/artricks/dbmaxwin").read().strip() or 0)
    except Exception: _mx=0
    if not binp.startswith("/usr/local"): _mx=0
    W=min(W,_mx if _mx>0 else 8388608)
    args="-F "+" ".join(f"-p {p}" for p in ports)+f" -b {BANNER} -W {W} -K 15"
    open("/etc/systemd/system/dropbear.service.d/override.conf","w").write("[Unit]\nStartLimitIntervalSec=0\n[Service]\nType=simple\nPIDFile=\nRemainAfterExit=no\nExecStart=\nExecStop=\nExecReload=\nKillMode=process\nExecStart="+binp+" "+args+"\nLimitNOFILE=1048576\nTasksMax=infinity\nNice=-5\nRestart=always\nRestartSec=3\nOOMScoreAdjust=-300\n")
    open("/etc/default/dropbear","w").write(f'NO_START=0\nDROPBEAR_PORT={sp}\nDROPBEAR_BANNER="{BANNER}"\nDROPBEAR_RECEIVE_WINDOW={W}\nDROPBEAR_EXTRA_ARGS="-p 109 -p 447 -b {BANNER} -W {W} -K 15"\n')
    ufw(sp);sh(["systemctl","daemon-reload"]);sh(["systemctl","enable","dropbear"]);return sh(["systemctl","restart","dropbear"])
app=Flask(__name__);sock=Sock(app)
def key():
    f=D+"/secret.key"
    if not os.path.exists(f): open(f,"w").write(secrets.token_hex(32));os.chmod(f,0o600)
    return open(f).read()
app.secret_key=key();app.config.update(SESSION_COOKIE_SAMESITE="Strict",SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SECURE=True,PERMANENT_SESSION_LIFETIME=86400)
def db():
    c=sqlite3.connect(DB);c.execute("create table if not exists admins(u text primary key,p text,role text default 'admin')")
    try: c.execute("alter table admins add column role text default 'admin'");c.commit()
    except Exception: pass
    try: c.execute("alter table admins add column exp integer");c.commit()
    except Exception: pass
    try: os.chmod(DB,0o600)
    except Exception: pass
    return c
def api(f):
    def w(*a,**k):
        if not session.get("u"): return jsonify(error="login"),401
        if session.get("r")!="admin":
            _e=db().execute("select exp from admins where u=?",(session.get("u"),)).fetchone()
            if not _e or (_e[0] and _e[0]<time.time()): session.clear();return jsonify(error="login"),401
        if request.method!="GET" and request.headers.get("X-Panel")!="1": return jsonify(error="bad request"),403
        if session.get("r")!="admin" and (request.method!="GET" or request.path not in("/api/overview","/api/accounts","/api/sessions")): return jsonify(error="View-only login: sirf admin yeh kar sakta hai"),403
        try: return f(*a,**k)
        except Exception as e: return jsonify(error=str(e)),400
    w.__name__=f.__name__;return w
fails={}
@app.route("/")
def index():
    r=send_file("/opt/aliraza-panel/index.html");r.headers["Cache-Control"]="no-store";return r
@app.post("/api/login")
def login():
    ip=request.headers.get("X-Real-IP",request.remote_addr);n,t=fails.get(ip,(0,0))
    if n>=5 and time.time()-t<300: return jsonify(error="Too many attempts. Wait 5 minutes."),429
    j=request.get_json(silent=True) or {};r=db().execute("select p,role,exp from admins where u=?",(j.get("u",""),)).fetchone()
    want="admin" if j.get("role")=="admin" else "user"
    if r and (r[1] or "admin")==want=="user" and r[2] and r[2]<time.time() and check_password_hash(r[0],j.get("p","")): return jsonify(error="This key has expired. Get a new key from AliRaza: t.me/alirazax0"),403
    if r and (r[1] or "admin")==want and check_password_hash(r[0],j.get("p","")): fails.pop(ip,None);session.clear();session.permanent=True;session["u"]=j["u"];session["r"]=want;return jsonify(ok=1)
    fails[ip]=(n+1,time.time());return jsonify(error="Wrong username or password"),401
@app.post("/api/logout")
def logout(): session.clear();return jsonify(ok=1)
@app.get("/api/me")
def me(): return jsonify(u=session.get("u"),role=session.get("r"))
def pub_ip():
    try: return subprocess.check_output(["curl","-4","-s","--max-time","3","ifconfig.me"],text=True).strip()
    except Exception: return ""
IP=[0,""]
SV=[0,{}]
psutil.cpu_percent(None)
def readconf(u):
    d={"IP_LIMIT":"1","GB_LIMIT":"Unlimited","USED_MB":"0"}
    try:
        for l in open(f"{UD}/{u}.conf"):
            if "=" in l: a,b=l.strip().split("=",1);d[a]=b
    except Exception: pass
    return d
def writeconf(u,d): os.makedirs(UD,exist_ok=True);open(f"{UD}/{u}.conf","w").write("".join(f"{k}={v}\n" for k,v in d.items()))
WSMAP="/run/aliraza/ws"
RE_A=re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
RE_B=re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
_SC=[0,[]]
def kill_pid(pid):
    try: os.kill(int(pid),9);return True
    except Exception: return False
def get_sessions(force=False):
    if not force and time.time()-_SC[0]<4: return _SC[1]
    procs=[p for p in (l.split() for l in sh(["ps","-eo","pid=,etimes=,comm="])[1].splitlines()) if len(p)>=3 and p[2]=="dropbear"]
    if not procs: _SC[0]=time.time();_SC[1]=[];return []   # nobody connected: skip the expensive journal scan
    last={}
    r=sh(["journalctl","-u","dropbear","--no-pager","-g","auth succeeded","-n","5000"])
    if not r[0] and not r[1].strip().startswith("-- No entries"): r=sh(["journalctl","-u","dropbear","--no-pager","-n","2000"])
    for l in r[1].splitlines():
        m=RE_A.search(l) or RE_B.search(l)
        if m: last[m.group(1)]=(m.group(2),m.group(3))
    out=[]
    for p in procs:
        if p[0] not in last: continue
        u,frm=last[p[0]];ip,_,port=frm.rpartition(":");ip=ip.strip("[]");real,via=ip,"ssh"
        if ip in("127.0.0.1","::1","::ffff:127.0.0.1"):
            via="ws"
            if port.isdigit():
                try: real=open(f"{WSMAP}/{port}").read().strip() or ip
                except Exception: pass
        out.append(dict(pid=p[0],u=u,ip=real,via=via,secs=int(p[1]) if p[1].isdigit() else 0))
    out.sort(key=lambda x:(x["u"],x["ip"]))
    _SC[0]=time.time();_SC[1]=out;return out
def online():
    m={}
    for x in get_sessions(): m[x["u"]]=m.get(x["u"],0)+1
    return m
def shadow():
    m={}
    for l in open("/etc/shadow"):
        p=l.split(":")
        if len(p)>7: m[p[0]]=(p[1].startswith("!"),p[7])
    return m
@app.get("/api/overview")
@api
def overview():
    if session.get("r")!="admin": return jsonify(users=len(os.listdir(UD)) if os.path.isdir(UD) else 0,online=sum(online().values()),viewonly=True)
    c=cfg();v=psutil.virtual_memory();dk=psutil.disk_usage("/");n=psutil.net_io_counters()
    if time.time()-IP[0]>600: IP[1]=pub_ip();IP[0]=time.time()
    if time.time()-SV[0]>5: _n=("nginx","dropbear","ws-proxy","autokill","tgbot","aliraza-ban-ssh");_o=sh(["systemctl","is-active",*_n])[1].split();SV[1]={s:(i<len(_o) and _o[i]=="active") for i,s in enumerate(_n)};SV[0]=time.time()
    svc=SV[1]
    try: os_=[l.split("=",1)[1].strip().strip('"') for l in open("/etc/os-release") if l.startswith("PRETTY_NAME")][0]
    except Exception: os_=""
    return jsonify(host=socket.gethostname(),os=os_,kernel=os.uname().release,ip=IP[1],cpu=psutil.cpu_percent(None),cores=psutil.cpu_count(),ram=[v.used,v.total],disk=[dk.used,dk.total],
      up=int(time.time()-psutil.boot_time()),load=os.getloadavg(),rx=n.bytes_recv,tx=n.bytes_sent,svc=svc,cfg=c,users=len(os.listdir(UD)) if os.path.isdir(UD) else 0,online=sum(online().values()))
@app.get("/api/accounts")
@api
def accounts():
    by={}
    for x in get_sessions(): by.setdefault(x["u"],[]).append(x)
    sd=shadow();out=[];today=datetime.date.today()
    for f in sorted(os.listdir(UD) if os.path.isdir(UD) else []):
        if not f.endswith(".conf"): continue
        u=f[:-5];d=readconf(u);lk,ex=sd.get(u,(False,""))
        ed=(datetime.date(1970,1,1)+datetime.timedelta(days=int(ex))) if ex.isdigit() else None
        ss=by.get(u,[])
        try: ls=int(float(d.get("LAST_SEEN","0") or 0))
        except Exception: ls=0
        out.append(dict(u=u,ip=d["IP_LIMIT"],gb=d["GB_LIMIT"],used=round(float(d["USED_MB"] or 0)/1024,2),exp=ed.isoformat() if ed else "never",days=(ed-today).days if ed else None,expired=bool(ed and ed<today),locked=lk,online=len(ss),ips=sorted({x["ip"] for x in ss}),last=ls,exists=u in sd))
    return jsonify(out)
@app.get("/api/sessions")
@api
def sessions_api():
    ss=get_sessions(True)
    return jsonify(sessions=ss,users=len({x["u"] for x in ss}),ips=len({x["ip"] for x in ss}))
@app.post("/api/kick")
@api
def kick():
    j=request.get_json() or {};n=0
    if not (j.get("pid") or j.get("u") or j.get("ip")): raise ValueError("Nothing to kick")
    for x in get_sessions(True):
        if (j.get("pid") and str(j["pid"])==x["pid"]) or (j.get("u") and j["u"]==x["u"]) or (j.get("ip") and j["ip"]==x["ip"]):
            if kill_pid(x["pid"]): n+=1
    _SC[0]=0
    return jsonify(ok=1,killed=n)
@app.post("/api/accounts/cleanup")
@api
def cleanup():
    sd=shadow();today=datetime.date.today();n=0
    for f in (os.listdir(UD) if os.path.isdir(UD) else []):
        if not f.endswith(".conf"): continue
        u=f[:-5];ex=sd.get(u,(False,""))[1]
        if UN.match(u) and ex.isdigit() and datetime.date(1970,1,1)+datetime.timedelta(days=int(ex))<today:
            sh(["pkill","-KILL","-u",u]);sh(["userdel","-f",u])
            try: os.remove(f"{UD}/{u}.conf")
            except Exception: pass
            n+=1
    return jsonify(ok=1,deleted=n)
UN=re.compile(r"^(?!-)(?!\.{1,2}$)[^\s:/\\\x00-\x1f\x7f]{1,32}$")  # same rules as uname(); was missing -> delete/cleanup crashed with NameError
def uname(j):
    u=str(j.get("u","")).strip()
    # sirf wo cheezein roki hain jo Linux/system ko tor sakti hain
    if not u or len(u)>32 or u in(".","..") or u[0]=="-" or re.search(r"[\s:/\\\x00-\x1f\x7f]",u): raise ValueError("Username khali na ho, max 32 chars, space / : \\ allowed nahi")
    return u
def pw(p):
    p=str(p)
    if not p or "\n" in p or "\r" in p or "\x00" in p: raise ValueError("Password khali nahi ho sakta")
    return p
def setexp(u,days): sh(["usermod","-e",(datetime.date.today()+datetime.timedelta(days=int(days))).isoformat(),u])
@app.post("/api/accounts")
@api
def acc_add():
    j=request.get_json();u=uname(j);p=pw(j.get("p",""));days=int(j.get("days") or 30);ipl=int(j.get("ip") or 1)
    ok,o=sh(["useradd","-M","-s","/bin/bash","--",u])
    if not ok: ok,o=sh(["useradd","--badname","-M","-s","/bin/bash","--",u])
    if not ok: raise ValueError(o)
    sh(["chpasswd"],f"{u}:{p}\n");setexp(u,days)
    gbl=j.get("gb") or "Unlimited";writeconf(u,{"IP_LIMIT":ipl,"GB_LIMIT":gbl,"USED_MB":"0.0"})
    # V5: build the complete account card on the server so the popup never depends on a second request
    c=cfg();sp=int(c.get("ssh_port") or 8443)
    if not IP[1]:
        try: IP[1]=pub_ip();IP[0]=time.time()
        except Exception: pass
    try: rh=request.host.rsplit(":",1)[0] if not request.host.startswith("[") else request.host
    except Exception: rh=""
    host=c.get("domain") or IP[1] or rh
    pl=f"GET /artricks HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    info=dict(u=u,p=p,exp=(datetime.date.today()+datetime.timedelta(days=days)).isoformat(),days=days,ip=ipl,gb=gbl,host=host,domain=c.get("domain") or "",server_ip=IP[1] or "",ssh_port=sp,ports=list(dict.fromkeys([sp,109,447])),ws=80,wss=443,payload=pl)
    return jsonify(ok=1,info=info)
@app.put("/api/accounts/<u>")
@api
def acc_edit(u):
    j=request.get_json();d=readconf(u)
    if not os.path.exists(f"{UD}/{u}.conf"): raise ValueError("Account not found")
    if j.get("p"): sh(["chpasswd"],f"{u}:{pw(j['p'])}\n")
    if j.get("days") not in(None,""): setexp(u,j["days"])
    if j.get("ip") not in(None,""): d["IP_LIMIT"]=int(j["ip"])
    if j.get("gb") not in(None,""): d["GB_LIMIT"]=j["gb"]
    if j.get("reset"): d["USED_MB"]="0.0"
    writeconf(u,d)
    if j.get("lock") is True:
        sh(["passwd","-l",u])
        for x in get_sessions(True):
            if x["u"]==u: kill_pid(x["pid"])
    else: sh(["passwd","-u",u])
    return jsonify(ok=1)
@app.delete("/api/accounts/<u>")
@api
def acc_del(u):
    if not UN.match(u): raise ValueError("bad name")
    for x in get_sessions(True):
        if x["u"]==u: kill_pid(x["pid"])
    sh(["pkill","-KILL","-u",u])
    ok,o=sh(["userdel","-f",u])
    if sh(["id",u])[0]: raise ValueError("Delete failed: "+(o or "userdel error"))
    try: os.remove(f"{UD}/{u}.conf")
    except Exception: pass
    _SC[0]=0
    return jsonify(ok=1)
@app.route("/api/banner",methods=["GET","PUT"])
@api
def banner():
    if request.method=="PUT": set_banner((request.get_json() or {}).get("t",""));return jsonify(ok=1)
    return jsonify(t=open(BANNER,encoding="utf-8").read() if os.path.exists(BANNER) else "")
TB=D+"/tgbot"
@app.route("/api/tg",methods=["GET","POST"])
@api
def tg():
    if request.method=="POST":
        j=request.get_json();t=j.get("token","").strip();a=int(j.get("admin"))
        if not re.match(r"^\d+:[\w-]{20,}$",t): raise ValueError("Invalid bot token")
        os.makedirs(TB,exist_ok=True);json.dump({"token":t,"super_admin":a},open(TB+"/config.json","w"));json.dump([a],open(TB+"/admins.json","w"));os.chmod(TB+"/config.json",0o600)
        sh(["systemctl","enable","tgbot"]);ok,o=sh(["systemctl","restart","tgbot"]);return jsonify(ok=ok,msg=o)
    if request.args.get("act") in("start","stop","restart"): sh(["systemctl",request.args["act"],"tgbot"])
    try: c=json.load(open(TB+"/config.json"));tok=c["token"][:6]+"…"+c["token"][-4:];adm=c["super_admin"]
    except Exception: tok=adm=None
    return jsonify(active=sh(["systemctl","is-active","tgbot"])[1]=="active",token=tok,admin=adm)
@app.post("/api/service/<s>/<act>")
@api
def service(s,act):
    if s not in("nginx","dropbear","ws-proxy","autokill","tgbot","aliraza-ban-ssh") or act not in("start","stop","restart"): raise ValueError("bad")
    ok,o=sh(["systemctl",act,s]);return jsonify(ok=ok,msg=o)
@app.post("/api/fix")
@api
def fix(): apply_dropbear();apply_ban();sh(["systemctl","restart","aliraza-ban-ssh"]);sh(["systemctl","restart","ws-proxy"]);sh(["systemctl","restart","autokill"]);return jsonify(ok=1,msg=apply_nginx()[1])
def freeport(p,own):
    if p in(80,443,109,447,2082,2299,12026) or not 1<=p<=65535: raise ValueError("Port reserved/invalid")
    if p!=own and sh(["ss","-ltn",f"sport = :{p}"])[1].count("\n")>=1: raise ValueError(f"Port {p} is already in use")
@app.post("/api/settings")
@api
def settings():
    j=request.get_json();c=cfg();msg=[];nw=dict(c)
    if j.get("panel_port"): p=int(j["panel_port"]);freeport(p,c["panel_port"]);nw["panel_port"]=p
    if j.get("ssh_port"): p=int(j["ssh_port"]);freeport(p,c["ssh_port"]);nw["ssh_port"]=p
    if nw["panel_port"]==nw["ssh_port"]: raise ValueError("Panel and SSH port must differ")
    if j.get("domain"):
        d=j["domain"].strip().lower()
        if not re.match(r"^[a-z0-9.-]+$",d): raise ValueError("Invalid domain")
        nw["domain"]=d
    savecfg(nw)
    if nw["domain"]!=c["domain"] and j.get("ssl"):
        sh(["systemctl","stop","nginx"]);ok,o=sh(["certbot","certonly","-n","--standalone","--agree-tos","--register-unsafely-without-email","-d",nw["domain"]],t=180);msg.append("SSL issued" if ok else "SSL failed (self-signed kept): "+o[-200:])
    ufw(nw["panel_port"])
    if nw["ssh_port"]!=c["ssh_port"]: later(apply_dropbear)
    later(apply_nginx);return jsonify(ok=1,msg=" | ".join(msg),cfg=nw)
@app.post("/api/admin")
@api
def admin():
    j=request.get_json();c=db();a=j.get("act");u=j.get("u","").strip()
    if not u or len(u)>64: raise ValueError("Username khali ya bohat lamba")
    if a=="create":
        rl="admin" if j.get("role")=="admin" else "user"
        try: dd=int(j.get("days") or 0)
        except Exception: dd=0
        if dd<0 or dd>3650: raise ValueError("Days must be 0-3650 (0 = no expiry)")
        ex=int(time.time())+dd*86400 if (dd and rl=="user") else None
        c.execute("insert into admins(u,p,role,exp) values(?,?,?,?)",(u,generate_password_hash(pw(j.get("p",""))),rl,ex))
    elif a=="password": c.execute("update admins set p=? where u=?",(generate_password_hash(pw(j.get("p",""))),u))
    elif a=="rename":
        n=j.get("new","").strip()
        if not n or len(n)>64: raise ValueError("Username khali ya bohat lamba")
        c.execute("update admins set u=? where u=?",(n,u));session["u"]=n if session["u"]==u else session["u"]
    elif a=="extend":
        try: dd=int(j.get("days") or 0)
        except Exception: dd=0
        if dd<1 or dd>3650: raise ValueError("Days must be 1-3650")
        r=c.execute("select role,exp from admins where u=?",(u,)).fetchone()
        if not r or (r[0] or "admin")=="admin": raise ValueError("Only view-only keys can have an expiry")
        c.execute("update admins set exp=? where u=?",(max(int(time.time()),r[1] or 0)+dd*86400,u))
    elif a=="noexpiry": c.execute("update admins set exp=NULL where u=?",(u,))
    elif a=="delete":
        tr=c.execute("select role from admins where u=?",(u,)).fetchone()
        if u==session["u"] or (tr and (tr[0] or "admin")=="admin" and c.execute("select count(*) from admins where role='admin' or role is null").fetchone()[0]<2): raise ValueError("Cannot delete this admin")
        c.execute("delete from admins where u=?",(u,))
    c.commit();return jsonify(ok=1,admins=[r[0] for r in c.execute("select u from admins")])
@app.get("/api/admins")
@api
def admins(): return jsonify([{"u":r[0],"role":r[1] or "admin","left":(r[2]-int(time.time())) if r[2] else None} for r in db().execute("select u,role,exp from admins")])

# ---------- V2 BAN: blocked IPs ----------
BANF=D+"/banned.txt"
def bans():
    out=[]
    try:
        for l in open(BANF,encoding="utf-8"):
            p=l.rstrip("\n").split("\t")
            if p and p[0]: out.append(dict(ip=p[0],ts=int(p[1]) if len(p)>1 and p[1].isdigit() else 0,note=p[2] if len(p)>2 else ""))
    except Exception: pass
    return out
def savebans(L):
    tmp=BANF+".tmp"
    with open(tmp,"w",encoding="utf-8") as f: f.write("".join(f"{b['ip']}\t{b['ts']}\t{b['note']}\n" for b in L))
    os.chmod(tmp,0o644);os.replace(tmp,BANF)
def apply_ban(): return sh(["/usr/local/bin/aliraza-ban.sh"])
def normip(s):
    import ipaddress
    a=ipaddress.ip_address(str(s).strip().strip("[]"))
    return a.ipv4_mapped if getattr(a,"ipv4_mapped",None) else a
def server_ips():
    s=set()
    for L in psutil.net_if_addrs().values():
        for a in L:
            if a.family in(socket.AF_INET,socket.AF_INET6): s.add(a.address.split("%")[0])
    return s
@app.get("/api/bans")
@api
def bans_list():
    ss=get_sessions()
    return jsonify([{**b,"online":sum(1 for x in ss if x["ip"]==b["ip"])} for b in bans()])
@app.post("/api/bans")
@api
def ban_add():
    j=request.get_json() or {};a=normip(j.get("ip",""));ip=a.compressed
    if a.is_loopback or a.is_unspecified or ip in server_ips(): raise ValueError("This IP cannot be blocked")
    note=re.sub(r"[\t\r\n]"," ",str(j.get("note",""))).strip()[:80]
    savebans([b for b in bans() if b["ip"]!=ip]+[dict(ip=ip,ts=int(time.time()),note=note)]);apply_ban();n=0
    for x in get_sessions(True):
        if x["ip"]==ip and kill_pid(x["pid"]): n+=1
    _SC[0]=0
    return jsonify(ok=1,killed=n)
@app.post("/api/unban")
@api
def ban_del():
    ip=normip((request.get_json() or {}).get("ip","")).compressed
    savebans([b for b in bans() if b["ip"]!=ip]);apply_ban();return jsonify(ok=1)

APP_EOF
cat > /opt/aliraza-panel/index.html <<'UI_EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#050c0f"><title>ALIRAZA SSH Panel V2</title>
<style>
:root{--bg:#050c0f;--card:#0b1a21;--card2:#112832;--line:#265064;--tx:#ecf9ff;--mu:#8eaebe;--g:#87d9f9;--g2:#2face7;--f1:#4dbaf1;--f2:#87d9f9;--f3:#d6f2fe;--ok:#4ade80;--bad:#ff4d6d;--r:16px}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--tx);font:14.5px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
body::before{content:"";position:fixed;inset:0;z-index:0;pointer-events:none;background:radial-gradient(800px 460px at 8% -8%,#2face733,transparent 62%),radial-gradient(760px 460px at 100% 0,#28a7c230,transparent 60%);animation:glowpulse 5s ease-in-out infinite alternate}
#app{position:relative;z-index:1;min-height:100vh;padding-bottom:48px}
h1,h2,h3{margin:0}
h2{font-size:17px;font-weight:700;margin-bottom:14px;color:var(--tx);display:flex;align-items:center;gap:8px;flex-wrap:wrap}
h3{font-size:15px;margin-bottom:8px;color:var(--f3)}
/* flames + embers (decorative, behind the panel) */
.fire{position:fixed;left:0;right:0;bottom:0;height:230px;z-index:0;pointer-events:none;overflow:hidden}
.fire::before{content:"";position:absolute;left:-10%;right:-10%;bottom:-40px;height:150px;background:radial-gradient(ellipse at 50% 100%,#0ea5e966 0%,#0a4f8a44 45%,transparent 72%);animation:glowpulse 2.4s ease-in-out infinite alternate}
.fire i{position:absolute;bottom:-55px;left:var(--x);width:var(--w);height:calc(var(--w)*1.9);margin-left:calc(var(--w)/-2);background:radial-gradient(ellipse at 50% 78%,#effbff 0%,#a5e4ff 28%,#38a6e8 55%,#0a4f8aaa 68%,transparent 74%);border-radius:50% 50% 46% 46%/72% 72% 28% 28%;filter:blur(7px);opacity:.85;mix-blend-mode:screen;transform-origin:50% 100%;animation:flame var(--d) ease-in-out infinite alternate;animation-delay:var(--dl)}
.embers{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}
.embers b{position:absolute;bottom:-12px;left:var(--x);width:var(--s);height:var(--s);border-radius:50%;background:#b6e8fc;box-shadow:0 0 8px 2px #46c2f2cc;opacity:0;animation:ember var(--d) linear infinite;animation-delay:var(--dl)}
@keyframes flame{0%{transform:scale(.82,.78) rotate(-4deg) translateX(-4px)}35%{transform:scale(1.02,1.18) rotate(2deg) translateX(3px)}70%{transform:scale(.9,1.0) rotate(-2deg) translateX(-2px)}100%{transform:scale(1.08,1.25) rotate(4deg) translateX(4px)}}
@keyframes ember{0%{transform:translate(0,0) scale(1);opacity:0}8%{opacity:1}60%{opacity:.7}100%{transform:translate(var(--dx),-88vh) scale(.15);opacity:0}}
@keyframes glowpulse{from{opacity:.55}to{opacity:1}}
@keyframes shine{0%{background-position:0% 50%}100%{background-position:200% 50%}}
@keyframes flicker{0%,100%{transform:scale(1) rotate(-3deg);filter:drop-shadow(0 0 6px #28b0e3)}25%{transform:scale(1.12) rotate(3deg);filter:drop-shadow(0 0 12px #b6e8fc)}50%{transform:scale(.95) rotate(-2deg);filter:drop-shadow(0 0 7px #2face7)}75%{transform:scale(1.08) rotate(2deg);filter:drop-shadow(0 0 14px #28a7c2)}}
@keyframes edgeglow{0%,100%{box-shadow:0 6px 24px #0000004a,0 0 0 #28b0e300}50%{box-shadow:0 6px 24px #0000004a,0 0 18px #28b0e340}}
@keyframes sweep{0%{transform:translateX(-120%)}100%{transform:translateX(320%)}}
/* header + nav */
header{display:flex;align-items:center;gap:12px;padding:12px 18px;position:sticky;top:0;z-index:5;background:#050c0ff2;border-bottom:1px solid var(--line)}
header::after{content:"";position:absolute;left:0;right:0;bottom:-1px;height:2px;background:linear-gradient(90deg,transparent,#2face7,#8ed3f7,#2face7,transparent);background-size:200% 100%;animation:shine 3s linear infinite}
header .sp{flex:1}
.brand{font-size:21px;font-weight:800;letter-spacing:.6px;line-height:1.15;background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent}
.brand small{display:block;font-size:11px;font-weight:500;letter-spacing:.3px;-webkit-text-fill-color:var(--mu);color:var(--mu)}
.logo{-webkit-text-fill-color:initial;display:inline-block;transform-origin:50% 90%;animation:flicker 1.3s ease-in-out infinite}
nav{display:flex;flex-direction:column;gap:6px;flex:0 0 220px;width:220px;padding:16px 12px 24px 16px;position:sticky;top:64px;max-height:calc(100vh - 64px);overflow-y:auto;scrollbar-width:none}
.layout{display:flex;align-items:flex-start;max-width:1800px;margin:0 auto}
#mb,.scrim{display:none}
nav::-webkit-scrollbar{display:none}
nav a{display:block;color:var(--mu);padding:11px 16px;border:1px solid var(--line);border-radius:12px;cursor:pointer;white-space:nowrap;font-weight:600;font-size:13.5px;background:#0b1a21cc;transition:color .2s,background .2s,border-color .2s,box-shadow .2s,transform .2s}
nav a:hover{color:var(--tx);border-color:#3c8fb7;box-shadow:0 0 12px #4dbaf133;transform:translateX(3px)}
nav a.on{color:#fff;border-color:transparent;background:linear-gradient(135deg,#2face7,#28a7c2,#2face7);background-size:200% 200%;animation:shine 3s linear infinite;box-shadow:0 0 16px #4dbaf166}
main{flex:1;min-width:0;max-width:1500px;padding:16px}
/* cards */
.card{background:linear-gradient(180deg,#132d39f2,#0b1a21f2);border:1px solid var(--line);border-radius:var(--r);padding:18px;margin-bottom:16px;box-shadow:0 6px 24px #0000004a;transition:transform .22s ease,border-color .22s ease;animation:edgeglow 4s ease-in-out infinite}
@media(hover:hover){.card:hover{transform:translateY(-3px);border-color:#46c2f2}}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
.grid>div{background:#071319;border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.k{color:var(--mu);font-size:12px}
.v{font-size:21px;font-weight:700;color:var(--f3)}
/* the expand animation: plays once when a tab opens, never on background refresh */
@keyframes expand{from{opacity:0;transform:translateY(16px) scale(.95)}to{opacity:1;transform:none}}
@keyframes fade{from{opacity:0}to{opacity:1}}
@keyframes slidein{from{opacity:0;transform:translateX(24px)}to{opacity:1;transform:none}}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}
main.enter>.card{animation:expand .5s cubic-bezier(.2,.8,.2,1) both}
main.enter>.card:nth-child(2){animation-delay:.07s}main.enter>.card:nth-child(3){animation-delay:.14s}main.enter>.card:nth-child(4){animation-delay:.21s}main.enter>.card:nth-child(5){animation-delay:.28s}
main.enter .grid>div{animation:expand .45s cubic-bezier(.2,.8,.2,1) both}
main.enter .grid>div:nth-child(2){animation-delay:.05s}main.enter .grid>div:nth-child(3){animation-delay:.1s}main.enter .grid>div:nth-child(4){animation-delay:.15s}main.enter .grid>div:nth-child(5){animation-delay:.2s}main.enter .grid>div:nth-child(6){animation-delay:.25s}main.enter .grid>div:nth-child(7){animation-delay:.3s}main.enter .grid>div:nth-child(8){animation-delay:.35s}
/* buttons */
button{position:relative;overflow:hidden;background:#2997c9;color:#fff;border:0;border-radius:10px;padding:9px 16px;font:inherit;font-weight:600;font-size:13.5px;cursor:pointer;transition:filter .2s,transform .12s,box-shadow .2s}
button:hover{filter:brightness(1.12);box-shadow:0 0 14px #4dbaf166}button:active{transform:scale(.96)}
button.f{background:linear-gradient(135deg,#2face7,#28a7c2)}
button.f::after{content:"";position:absolute;top:0;bottom:0;left:0;width:35%;background:linear-gradient(90deg,transparent,#ffffff55,transparent);transform:translateX(-120%);animation:sweep 3.2s ease-in-out infinite}
button.s{background:transparent;color:var(--f3);border:1px solid #34799b}button.s:hover{background:#112832;filter:none}
button.d{background:#e11d48;color:#fff}
button:focus-visible,input:focus-visible,nav a:focus-visible,textarea:focus-visible,select:focus-visible{outline:2px solid var(--f2);outline-offset:2px}
/* forms */
input,textarea,select{background:#071319;border:1px solid var(--line);color:var(--tx);padding:10px 12px;border-radius:10px;font:inherit;width:100%;transition:border-color .2s,box-shadow .2s}
input:focus,select:focus,textarea:focus{border-color:var(--f2);box-shadow:0 0 0 3px #87d9f930}
input[type=checkbox]{width:auto;accent-color:var(--f1)}
::placeholder{color:#648290}
label{display:block;margin:10px 0 4px;color:var(--mu);font-size:13px}
.row{display:flex;gap:12px;flex-wrap:wrap;align-items:flex-end}.row>*{flex:1;min-width:140px}
/* tables */
.tw{overflow-x:auto;-webkit-overflow-scrolling:touch}
table{width:100%;border-collapse:collapse}
td,th{padding:10px 8px;border-bottom:1px solid var(--line);text-align:left;font-size:13px;vertical-align:middle}
th{color:var(--mu);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.6px}
tr:last-child td{border-bottom:0}
@media(hover:hover){table tr:hover td{background:#4dbaf114}}
/* badges */
.b{display:inline-flex;align-items:center;padding:3px 11px;border-radius:999px;font-size:12px;font-weight:700}
.on1{background:#0d3a22;color:var(--ok)}.off1{background:#4a1522;color:var(--bad)}.mu1{background:#18323e;color:var(--mu)}
.b.on1::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor;margin-right:7px;animation:blink 1.8s ease-in-out infinite}
/* bars + code */
.bar{height:7px;background:#071319;border-radius:6px;overflow:hidden;margin-top:8px}
.bar i{display:block;height:100%;border-radius:6px;background:linear-gradient(90deg,#2face7,#8ed3f7,#2face7);background-size:200% 100%;animation:shine 2.5s linear infinite;transition:width .6s ease}
pre.c{background:#051016;border:1px solid var(--line);padding:12px;border-radius:10px;overflow-x:auto;white-space:pre-wrap;word-break:break-all;margin:8px 0;color:var(--f3);font:12.5px/1.6 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
/* toast, footer, login */
#toast{position:fixed;top:74px;right:14px;z-index:60;background:var(--card2);border:1px solid var(--f2);padding:11px 16px;border-radius:12px;display:none;max-width:84vw;box-shadow:0 10px 30px #0008,0 0 16px #28b0e340;animation:slidein .3s ease both}
footer{text-align:center;color:var(--mu);font-size:12px;margin-top:22px}footer a{color:var(--f2);text-decoration:none}
.login{max-width:380px;margin:11vh auto;padding:0 16px;text-align:center}
.login .brand{font-size:34px}
.login .card{text-align:left;animation:expand .55s cubic-bezier(.2,.8,.2,1) both,edgeglow 4s ease-in-out .6s infinite}
.rt{display:flex;gap:8px;margin-bottom:14px}
.rt button{flex:1;background:transparent;color:var(--mu);border:1px solid var(--line)}
.rt button.on{background:linear-gradient(135deg,#2face7,#28a7c2);color:#fff;border-color:transparent}
body.ro .wr{display:none!important}
.vbar{text-align:center;padding:9px 14px;font-size:13px;font-weight:600;background:linear-gradient(90deg,#144157,#1c5b78,#144157);border-bottom:1px solid #3c8fb7;color:var(--f3);position:relative;z-index:5}
.vbar a{color:#fff;text-decoration:underline}
.tgb{display:inline-block;margin-top:8px;padding:11px 20px;border-radius:12px;background:linear-gradient(135deg,#2face7,#28a7c2);color:#fff!important;font-weight:800;text-decoration:none;box-shadow:0 0 16px #4dbaf166;transition:transform .2s}
.tgb:hover{transform:translateY(-2px)}
.vn{text-align:center;line-height:1.6}
.vpin{position:fixed;left:50%;bottom:12px;transform:translateX(-50%);z-index:9999;width:calc(100% - 24px);max-width:460px;text-align:center;padding:14px 16px;border-radius:16px;background:linear-gradient(180deg,#132d39f7,#0b1a21f7);border:1px solid #46c2f2;box-shadow:0 0 24px #4dbaf166,0 10px 30px #000a;animation:edgeglow 4s ease-in-out infinite}
.vpin .at{font-weight:900;font-size:16px;letter-spacing:2px;color:var(--f2)}
body.vo main{padding-bottom:190px}
/* account-created popup */
.ov{position:fixed;inset:0;z-index:50;background:#030a0dc4;display:flex;align-items:center;justify-content:center;padding:14px;animation:fade .2s ease both}
.ov .card{width:100%;max-width:640px;max-height:92vh;overflow-y:auto;margin:0;border-color:#3c8fb7;animation:expand .35s cubic-bezier(.2,.8,.2,1) both}
.ov .card:hover{transform:none}
.ov .ir{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);word-break:break-all}.ov .ir b{color:var(--f3);font-weight:600;text-align:right}
.ov .ah{text-align:center;padding:2px 0 12px;border-bottom:1px dashed var(--line);margin-bottom:6px}
.ov .at{font-weight:900;font-size:clamp(17px,4.6vw,23px);letter-spacing:2px;line-height:1.25;background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent;filter:drop-shadow(0 0 10px #4dbaf155)}
.ov .as{margin-top:6px;font-size:12.5px;color:var(--ok)}
.ov .sec{margin:16px 0 2px;font-size:11.5px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:var(--f2)}
.ov .af{text-align:center;color:var(--mu);font-size:11.5px;margin-top:16px}
@media(max-width:600px){header{padding:10px 12px;gap:8px}header button{padding:7px 12px;font-size:12.5px;white-space:nowrap}.brand{font-size:18px}main{padding:4px 12px 12px}.card{padding:14px}.v{font-size:18px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.grid>div{padding:10px 12px}.row>*{min-width:100%}.fire{height:170px}}
@media(max-width:820px){#mb{display:inline-flex}nav{position:fixed;left:0;top:0;bottom:0;max-height:none;width:250px;flex:none;z-index:40;background:#061218;border-right:1px solid var(--line);padding:76px 14px 20px;transform:translateX(-105%);transition:transform .28s ease}nav.open{transform:none;box-shadow:8px 0 40px #000b}.scrim{position:fixed;inset:0;z-index:39;background:#000a}.scrim.show{display:block}.layout{display:block}main{max-width:none;padding:8px 12px 12px}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}

/* ===== v4 animated login ===== */
.login2{max-width:1020px;margin:0 auto;padding:6vh 18px 24px}
.lgw{display:grid;grid-template-columns:1.1fr .9fr;gap:34px;align-items:center;min-height:66vh}
.hero{text-align:center}
.lgc .card{margin:0 auto;max-width:400px;text-align:left;animation:expand .55s cubic-bezier(.2,.8,.2,1) both,edgeglow 4s ease-in-out .6s infinite}
.orb{position:relative;width:230px;height:230px;margin:0 auto 14px}
.ring{position:absolute;border-radius:50%;border:1px dashed #8ed3f766;will-change:transform}
.r1{inset:0;animation:spin 14s linear infinite}
.r2{inset:13%;border-color:#87d9f977;animation:spin 10s linear infinite reverse}
.r3{inset:27%;border-color:#4dbaf188;animation:spin 7s linear infinite}
.dot{position:absolute;top:-14px;left:50%;margin-left:-14px;width:28px;height:28px;border-radius:50%;background:#0b1a21;border:1px solid #46c2f2;display:grid;place-items:center;box-shadow:0 0 14px #28b0e399}
.dot em{font-style:normal;font-size:14px;display:block}
.d1 em{animation:spin 14s linear infinite reverse}.d2 em{animation:spin 10s linear infinite}.d3 em{animation:spin 7s linear infinite reverse}
.core{position:absolute;inset:38%;border-radius:50%;display:grid;place-items:center;background:radial-gradient(circle,#46c2f255,#0b1a21 70%);border:1px solid #46c2f2;font-size:30px;animation:corepulse 2.4s ease-in-out infinite}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes corepulse{0%,100%{box-shadow:0 0 18px #4dbaf155,inset 0 0 12px #4dbaf133;transform:scale(1)}50%{box-shadow:0 0 34px #4dbaf1aa,inset 0 0 18px #4dbaf166;transform:scale(1.07)}}
.ttl{margin:0;font-size:clamp(38px,7vw,62px);font-weight:900;letter-spacing:4px;line-height:1.05;background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent;filter:drop-shadow(0 0 14px #4dbaf155)}
.sub{margin:8px 0 16px;font:700 clamp(15px,2.6vw,20px) ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--f3);letter-spacing:.12em;min-height:1.7em}
.typ{display:inline-block;overflow:hidden;white-space:nowrap;vertical-align:bottom;border-right:3px solid var(--f2);width:0;animation:typing 7s steps(14,end) infinite,caret .8s step-end infinite}
@keyframes typing{0%{width:0}35%,70%{width:calc(14*(1ch + .12em))}100%{width:0}}
@keyframes caret{50%{border-color:transparent}}
.chips{display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-bottom:16px}
.chips span{display:inline-flex;align-items:center;gap:7px;padding:5px 12px;border:1px solid var(--line);border-radius:999px;background:#0b1a21cc;font-size:12px;color:var(--f3);animation:fade .6s ease both}
.chips i{width:7px;height:7px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok);animation:blink 1.8s ease-in-out infinite}
.chips span:nth-child(2) i{animation-delay:.3s}.chips span:nth-child(3) i{animation-delay:.6s}
.term{max-width:360px;margin:0 auto;text-align:left;background:#051016e6;border:1px solid var(--line);border-radius:12px;padding:12px 14px;font:12.5px/1.8 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--mu);position:relative;overflow:hidden}
.term::after{content:"";position:absolute;left:0;right:0;top:0;height:40%;background:linear-gradient(180deg,transparent,#46c2f218,transparent);animation:scan 3.5s linear infinite;pointer-events:none}
@keyframes scan{from{transform:translateY(-100%)}to{transform:translateY(300%)}}
.tl{opacity:0;animation:tline .5s ease forwards;animation-delay:calc(var(--i)*.9s + .6s)}
.tl.ok{color:var(--ok)}
@keyframes tline{from{opacity:0;transform:translateX(-8px)}to{opacity:1;transform:none}}
.cur{display:inline-block;width:8px;height:14px;background:var(--f2);vertical-align:-2px;animation:blink 1s step-end infinite}
@media(max-width:860px){.lgw{grid-template-columns:1fr;gap:18px;min-height:0}.login2{padding-top:3vh}.orb{width:170px;height:170px}.core{font-size:24px}.term{display:none}.lgc .card{max-width:440px}}
@media(prefers-reduced-motion:reduce){.typ{width:auto;border-right:0}.tl{opacity:1}}

/* ===== V2 ice-blue extras ===== */
.aurora{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}
.aurora span{position:absolute;width:46vmax;height:46vmax;border-radius:50%;filter:blur(90px);opacity:.34;mix-blend-mode:screen;will-change:transform;animation:drift 18s ease-in-out infinite alternate}
.aurora span:nth-child(1){background:#2face7;left:-12vmax;top:-14vmax}
.aurora span:nth-child(2){background:#28a7c2;right:-16vmax;top:10vh;animation-duration:24s;animation-delay:-6s}
.aurora span:nth-child(3){background:#2563eb;left:22vw;bottom:-26vmax;opacity:.24;animation-duration:30s;animation-delay:-12s}
@keyframes drift{from{transform:translate(0,0) scale(1)}to{transform:translate(8vw,6vh) scale(1.22)}}
.card{position:relative}
.card::after{content:"";position:absolute;left:16px;right:16px;top:0;height:2px;border-radius:2px;background:linear-gradient(90deg,transparent,#46c2f2,#7ce0f6,#46c2f2,transparent);background-size:200% 100%;animation:shine 3.5s linear infinite;pointer-events:none}
@media(hover:hover){.grid>div{transition:transform .2s,border-color .2s,box-shadow .2s}.grid>div:hover{transform:translateY(-2px);border-color:#46c2f2;box-shadow:0 0 16px #4dbaf133}}
button.f{background:linear-gradient(135deg,#2face7,#28a7c2)}
.v{text-shadow:0 0 14px #46c2f244}
</style></head><body><div class="aurora"><span></span><span></span><span></span></div><div class="fire"><i style="--x:4.0%;--w:80px;--d:1.36s;--dl:-0.55s"></i><i style="--x:12.2%;--w:63px;--d:0.75s;--dl:-0.75s"></i><i style="--x:20.4%;--w:83px;--d:1.11s;--dl:-1.27s"></i><i style="--x:28.6%;--w:73px;--d:0.73s;--dl:-0.61s"></i><i style="--x:36.8%;--w:64px;--d:0.87s;--dl:-0.77s"></i><i style="--x:45.0%;--w:63px;--d:1.28s;--dl:-0.17s"></i><i style="--x:53.2%;--w:74px;--d:1.14s;--dl:-0.82s"></i><i style="--x:61.4%;--w:63px;--d:1.1s;--dl:-0.56s"></i><i style="--x:69.6%;--w:74px;--d:0.73s;--dl:-1.2s"></i><i style="--x:77.8%;--w:78px;--d:0.99s;--dl:-0.76s"></i><i style="--x:86.0%;--w:96px;--d:0.92s;--dl:-1.14s"></i><i style="--x:94.2%;--w:71px;--d:0.77s;--dl:-0.8s"></i></div><div class="embers"><b style="--x:27%;--s:4px;--dx:-48px;--d:7.7s;--dl:-0.6s"></b><b style="--x:10%;--s:3px;--dx:3px;--d:8.4s;--dl:-3.8s"></b><b style="--x:43%;--s:5px;--dx:14px;--d:9.6s;--dl:-3.3s"></b><b style="--x:34%;--s:3px;--dx:29px;--d:8.9s;--dl:-0.7s"></b><b style="--x:41%;--s:5px;--dx:52px;--d:6.7s;--dl:-4.0s"></b><b style="--x:80%;--s:2px;--dx:-45px;--d:7.6s;--dl:-1.5s"></b><b style="--x:46%;--s:3px;--dx:59px;--d:7.4s;--dl:-0.4s"></b><b style="--x:88%;--s:2px;--dx:37px;--d:7.8s;--dl:-7.1s"></b><b style="--x:43%;--s:4px;--dx:28px;--d:6.8s;--dl:-4.5s"></b><b style="--x:61%;--s:2px;--dx:47px;--d:5.5s;--dl:-2.4s"></b><b style="--x:92%;--s:2px;--dx:-53px;--d:8.7s;--dl:-2.8s"></b><b style="--x:76%;--s:5px;--dx:-24px;--d:8.6s;--dl:-8.0s"></b><b style="--x:47%;--s:2px;--dx:60px;--d:7.3s;--dl:-1.5s"></b><b style="--x:17%;--s:5px;--dx:-53px;--d:6.1s;--dl:-2.6s"></b><b style="--x:97%;--s:3px;--dx:-10px;--d:7.0s;--dl:-7.8s"></b><b style="--x:13%;--s:3px;--dx:-3px;--d:7.0s;--dl:-2.5s"></b></div><div id="toast"></div><div id="app"></div>
<script>
const $=s=>document.querySelector(s),A=$("#app");let tab="core",me=null,role="user",lrole="admin",ws=null,timer=null;
const e=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function toast(m,bad){const t=$("#toast");t.textContent=m;t.style.borderColor=bad?"var(--bad)":"var(--g)";t.style.display="block";setTimeout(()=>t.style.display="none",3500)}
async function api(p,m="GET",b){const r=await fetch("/api/"+p,{method:m,headers:{"Content-Type":"application/json","X-Panel":"1"},body:b?JSON.stringify(b):undefined});const j=await r.json().catch(()=>({}));if(r.status==401&&p!="login"){me=null;return boot()}if(!r.ok)throw new Error(j.error||"Error");return j}
const go=f=>async(...a)=>{try{await f(...a)}catch(x){toast(x.message,1)}};
const gb=b=>(b/1073741824).toFixed(1)+" GB",val=id=>$("#"+id).value;
const dur=s=>s>=86400?Math.floor(s/86400)+"d "+Math.floor(s%86400/3600)+"h":s>=3600?Math.floor(s/3600)+"h "+Math.floor(s%3600/60)+"m":Math.max(0,Math.floor(s/60))+"m "+(s%60)+"s";
const seen=t=>t?new Date(t*1000).toLocaleString():"never";
const foot=`<footer>Created by <b style="color:var(--g)">ALIRAZA</b> &nbsp;|&nbsp; Support: <a href="https://t.me/ar_tricks" target="_blank" rel="noopener">@ar_tricks</a></footer>`;
const put=(el,h)=>{if(!el)return false;if(el.__h!==h){el.__h=h;el.innerHTML=h;return true}return false};
const copyTxt=async t=>{try{await navigator.clipboard.writeText(t)}catch(_){const a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();document.execCommand("copy");a.remove()}toast("Copied")};
const TG="https://t.me/alirazax0";
const vbar=`<div class="vbar">🔒 View-only mode &middot; To use the full panel, get a key from <b>AliRaza</b> &rarr; <a href="${TG}" target="_blank" rel="noopener">t.me/alirazax0</a></div>`;
const vnote=()=>`<div class="card vn"><h2>🔒 View-only access</h2><div>You are signed in with a <b>view-only</b> account, so VPS details and server settings are hidden.</div><div style="margin-top:8px">Want to use the full panel? Get a key from <b style="color:var(--g)">AliRaza</b> on Telegram.</div><a class="tgb" href="${TG}" target="_blank" rel="noopener">✈ Message AliRaza on Telegram</a><div class="k" style="margin-top:8px">t.me/alirazax0</div></div>`;
let vpT=null;
function vpop(){if(role=="admin"||!me){document.querySelectorAll(".vpin").forEach(n=>n.remove());document.body.classList.remove("vo");return}if(document.querySelector(".vpin"))return;document.body.classList.add("vo");const d=document.createElement("div");d.className="vpin";d.innerHTML=`<div class="at">🔒 VIEW-ONLY MODE</div><div style="margin-top:6px;line-height:1.6">To use the <b>full panel</b>, get a key from <b style="color:var(--g)">AliRaza</b>.</div><a class="tgb" href="${TG}" target="_blank" rel="noopener">✈ t.me/alirazax0</a>`;document.body.appendChild(d)}
function showInfo(x){const h=x.host||x.domain||x.server_ip||location.hostname,gbl=x.gb||"Unlimited",ports=(x.ports&&x.ports.length?x.ports:[x.ssh_port||8443,109,447]).join(", "),
pl=x.payload||`GET /artricks HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`,
all=`===== ALIRAZA ACCOUNT MANAGEMENT =====\n\nUsername: ${x.u}\nPassword: ${x.p}\nHost: ${h}\n${x.server_ip?"Server IP: "+x.server_ip+"\n":""}Expiry: ${x.exp||"-"}\nIP Limit: ${x.ip}\nData Limit: ${gbl}\n\nSSH Ports: ${ports}\nWS (HTTP): ${x.ws||80}\nWS+SSL: ${x.wss||443}\n\nPayload:\n${pl}\n\nCreated by ALIRAZA | https://t.me/ar_tricks`,
r=(i,k,v)=>`<div class="ir"><span class="k">${i} ${k}</span><b>${e(v)}</b></div>`;
document.querySelectorAll(".ov").forEach(n=>n.remove());
const d=document.createElement("div");d.className="ov";
d.innerHTML=`<div class="card"><div class="ah"><div class="at">ALIRAZA ACCOUNT MANAGEMENT</div><div class="as">&#9989; Account created successfully</div></div>
<div class="sec">&#128100; Login details</div>${r("&#128273;","Username",x.u)}${r("&#128274;","Password",x.p)}${r("&#9203;","Expires",x.exp||"-")}${r("&#128101;","IP limit",x.ip)}${r("&#128230;","Data limit",gbl)}
<div class="sec">&#127760; Server details</div>${r("&#127970;","Host / Domain",h)}${x.server_ip?r("&#128225;","Server IP",x.server_ip):""}${r("&#128268;","SSH ports",ports)}${r("&#9889;","WS (HTTP)",x.ws||80)}${r("&#128737;","WS + SSL",x.wss||443)}
<div class="sec">&#128220; Payload</div><pre class="c">${e(pl)}</pre>
<br><div class="row" style="justify-content:center"><button class="f" id="cb">Copy all</button><button class="s" id="pb">Copy payload</button><button class="s" id="xb">Close</button></div>
<div class="af">Created by <b style="color:var(--g)">ALIRAZA</b> &nbsp;|&nbsp; <a href="https://t.me/ar_tricks" target="_blank" rel="noopener" style="color:var(--f2);text-decoration:none">@ar_tricks</a></div></div>`;
document.body.appendChild(d);
const close=()=>{d.remove();document.removeEventListener("keydown",esc)},esc=ev=>{if(ev.key=="Escape")close()};document.addEventListener("keydown",esc);
d.onclick=ev=>{if(ev.target===d)close()};d.querySelector("#xb").onclick=close;d.querySelector("#cb").onclick=()=>copyTxt(all);d.querySelector("#pb").onclick=()=>copyTxt(pl)}
async function boot(){const j=await fetch("/api/me").then(r=>r.json());me=j.u;role=j.role||"user";document.body.classList.toggle("ro",role!="admin");if(role!="admin"&&!["core","on","acc"].includes(tab))tab="core";me?shell():loginView()}
function loginView(){A.innerHTML=`<div class="login2"><div class="lgw"><section class="hero"><div class="orb"><div class="ring r1"><span class="dot d1"><em>⚡</em></span></div><div class="ring r2"><span class="dot d2"><em>🔒</em></span></div><div class="ring r3"><span class="dot d3"><em>🌐</em></span></div><div class="core"><span class="logo">🔮</span></div></div><h1 class="ttl">ALIRAZA</h1><div class="sub"><span class="typ">SSH MANAGEMENT</span></div><div class="chips"><span><i></i>Dropbear</span><span><i></i>WebSocket</span><span><i></i>SSL/TLS</span></div><div class="term"><div class="tl" style="--i:0">$ aliraza --status</div><div class="tl ok" style="--i:1">✔ secure tunnel ready</div><div class="tl ok" style="--i:2">✔ users synced · auto-kill on</div><div class="tl" style="--i:3">$ <b class="cur"></b></div></div></section><div class="lgc"><div class="card" style="text-align:left"><h2 style="margin-bottom:12px">🔐 Panel Login</h2><div class="rt"><button type="button" id="ra" class="${lrole=="admin"?"on":""}">Admin</button><button type="button" id="ru" class="${lrole=="user"?"on":""}">User (view only)</button></div><label>Username</label><input id="lu" autocomplete="username"><label>Password</label><input id="lp" type="password" autocomplete="current-password"><br><br><button class="f" style="width:100%" id="lb">Sign in</button></div></div></div>${foot}</div>`;
$("#ra").onclick=()=>{lrole="admin";loginView()};$("#ru").onclick=()=>{lrole="user";loginView()};$("#lb").onclick=go(async()=>{await api("login","POST",{u:val("lu"),p:val("lp"),role:lrole});boot()});$("#lp").onkeydown=ev=>{if(ev.key=="Enter")$("#lb").click()}}
const TABS={core:"Core",on:"Online",acc:"Accounts",ban:"Banner",tg:"Telegram Bot",set:"Settings"};
function shell(){A.innerHTML=`<header><button class="s" id="mb" aria-label="Menu">☰</button><div class="brand"><span class="logo">🔮</span> ALIRAZA<small>SSH Management Panel &middot; V2</small></div><div class="sp"></div><span class="b ${role=="admin"?"on1":"mu1"}">${role=="admin"?"ADMIN":"VIEW ONLY"}</span><button class="s" id="lo">Logout (${e(me)})</button></header>${role!="admin"?vbar:""}<div class="layout"><nav>${Object.entries(TABS).filter(([k])=>role=="admin"||["core","on","acc"].includes(k)).map(([k,v])=>`<a tabindex="0" data-t="${k}">${v}</a>`).join("")}</nav><main id="m"></main></div><div class="scrim" id="sc"></div>`;
const nv=document.querySelector("nav"),sc=$("#sc"),cl=()=>{nv.classList.remove("open");sc.classList.remove("show")};$("#mb").onclick=()=>{nv.classList.toggle("open");sc.classList.toggle("show",nv.classList.contains("open"))};sc.onclick=cl;
document.querySelectorAll("nav a").forEach(a=>{a.onclick=()=>{tab=a.dataset.t;cl();view()};a.onkeydown=ev=>{if(ev.key=="Enter")a.click()}});$("#lo").onclick=async()=>{await api("logout","POST");boot()};clearInterval(vpT);document.querySelectorAll(".vpin").forEach(n=>n.remove());document.body.classList.remove("vo");if(role!="admin"){vpop();vpT=setInterval(vpop,1000)}view()}
function view(){clearInterval(timer);if(ws){ws.close();ws=null}document.querySelectorAll("nav a").forEach(a=>a.classList.toggle("on",a.dataset.t==tab));const m=$("#m");m.innerHTML="";m.classList.add("enter");clearTimeout(view.t);view.t=setTimeout(()=>m.classList.remove("enter"),1100);go(V[tab])(m)}
const V={
async core(m){if(role!="admin"){m.innerHTML=`${vnote()}<div class="card" id="c1"><h2>Panel stats</h2><div class="k">Loading...</div></div>${foot}`;const dv=async()=>{const o=await api("overview");if(!$("#c1"))return;put($("#c1"),`<h2>Panel stats</h2><div class="grid"><div><div class="k">Accounts</div><div class="v">${o.users}</div></div><div><div class="k">Online now</div><div class="v">${o.online}</div></div></div>`)};await dv();timer=setInterval(()=>document.hidden||go(dv)(),10000);return}
m.innerHTML=`<div class="card" id="c1"><h2>VPS info</h2><div class="k">Loading...</div></div><div class="card" id="c2"><h2>SSH account info</h2></div><div class="card" id="c3"><h2>Services</h2></div>${foot}`;
const draw=async()=>{const o=await api("overview");if(!$("#c1"))return;const c=o.cfg,h=c.domain||o.ip,pct=a=>Math.round(a[0]/a[1]*100),pl=`GET /artricks HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`;
put($("#c1"),`<h2>VPS info</h2><div class="grid"><div><div class="k">Host / OS</div>${e(o.host)}<br>${e(o.os)}</div><div><div class="k">Public IP</div><div class="v">${e(o.ip||"-")}</div></div><div><div class="k">Uptime</div><div class="v">${Math.floor(o.up/86400)}d ${Math.floor(o.up%86400/3600)}h</div></div><div><div class="k">Load</div><div class="v">${o.load.map(x=>x.toFixed(2)).join(" ")}</div></div>
<div><div class="k">CPU (${o.cores} cores)</div><div class="v">${o.cpu}%</div><div class="bar"><i style="width:${o.cpu}%"></i></div></div><div><div class="k">RAM ${gb(o.ram[0])} / ${gb(o.ram[1])}</div><div class="v">${pct(o.ram)}%</div><div class="bar"><i style="width:${pct(o.ram)}%"></i></div></div><div><div class="k">Disk ${gb(o.disk[0])} / ${gb(o.disk[1])}</div><div class="v">${pct(o.disk)}%</div><div class="bar"><i style="width:${pct(o.disk)}%"></i></div></div><div><div class="k">Traffic in / out</div><div class="v">${gb(o.rx)} / ${gb(o.tx)}</div></div></div>`);
if(put($("#c2"),`<h2>SSH account info</h2><div class="grid"><div><div class="k">Host</div>${e(h)}</div><div><div class="k">SSH port</div><div class="v">${c.ssh_port}</div></div><div><div class="k">WS / WS+SSL</div><div class="v">80 / 443</div></div><div><div class="k">Accounts / online</div><div class="v">${o.users} / ${o.online}</div></div></div><div class="k" style="margin-top:14px">Payload</div><pre class="c">${e(pl)}</pre><button class="s" id="cp">Copy payload</button>`))$("#cp").onclick=()=>copyTxt(pl);
if(put($("#c3"),`<h2>Services</h2><div class="tw"><table>${Object.entries(o.svc).map(([s,a])=>`<tr><td>${s}</td><td><span class="b ${a?"on1":"off1"}">${a?"running":"stopped"}</span></td><td class="wr"><button class="s" data-s="${s}">Restart</button></td></tr>`).join("")}</table></div><br><button class="f wr" id="fx">Fix SSH / WS connection</button>`)){
$("#c3").querySelectorAll("[data-s]").forEach(b=>b.onclick=go(async()=>{await api(`service/${b.dataset.s}/restart`,"POST");toast("Restarted "+b.dataset.s);draw()}));$("#fx").onclick=go(async()=>{await api("fix","POST");toast("Connection fixed");draw()})}};
await draw();timer=setInterval(()=>document.hidden||go(draw)(),10000)},
async acc(m){m.innerHTML=`<div class="card wr"><h2>Add account</h2><div class="row"><div><label>Username (kuch bhi likho)</label><input id="au" autocomplete="off" placeholder="any name / symbols"></div><div><label>Password (kuch bhi likho)</label><input id="ap" autocomplete="off" placeholder="any password"></div><div><label>Days</label><input id="ad" type="number" value="30"></div><div><label>IP limit</label><input id="ai" type="number" value="1"></div><div><label>Data limit GB (blank = unlimited)</label><input id="ag"></div></div><br><button class="f" id="aa">Create account</button></div>
<div class="card"><h2>Accounts <span class="k" id="cnt"></span></h2><div class="row"><div><input id="q" placeholder="Search username or IP"></div><div><select id="f"><option value="all">All</option><option value="on">Online</option><option value="off">Offline</option><option value="lock">Locked</option><option value="exp">Expired</option></select></div><div class="wr" style="flex:0 0 auto;min-width:0"><button class="s" id="cx">Delete expired</button></div></div><div class="tw"><table id="tb"></table></div></div>
<div class="card wr" id="bc"><h2>🚫 Blocked IPs <span class="k" id="bcn"></span></h2><div class="k">A blocked IP cannot log in on SSH, WebSocket or SSL. It only sees the ban message from AliRaza. Unblock here to restore access.</div><div class="row"><div><label>IP address</label><input id="bi" autocomplete="off" placeholder="e.g. 203.0.113.5"></div><div><label>Note (optional)</label><input id="bn" autocomplete="off" placeholder="reason"></div><div style="flex:0 0 auto;min-width:0"><button class="d" id="bb">Block IP</button></div></div><div class="tw"><table id="bt"></table></div></div>
<div class="card wr" id="ed" style="display:none"><h2>Edit <span id="en"></span></h2><div class="row"><div><label>New password</label><input id="ep"></div><div><label>Renew (days from today)</label><input id="ey" type="number"></div><div><label>IP limit</label><input id="ei" type="number"></div><div><label>Data limit GB</label><input id="eg"></div></div><br><div class="row" style="justify-content:flex-start"><button id="es">Save &amp; unlock</button><button class="s" id="el">Lock</button><button class="s" id="er">Reset usage</button></div></div>`;
let L=[],BL=[];
const status=a=>!a.exists?"missing":a.locked?"locked":a.expired?"expired":a.online?"online":"offline";
const cls={online:"on1",offline:"mu1",locked:"off1",expired:"off1",missing:"off1"};
const paint=()=>{const q=val("q").toLowerCase(),f=val("f");
const rows=L.filter(a=>(!q||a.u.toLowerCase().includes(q)||a.ips.some(i=>i.includes(q)))&&(f=="all"||(f=="on"&&a.online)||(f=="off"&&!a.online)||(f=="lock"&&a.locked)||(f=="exp"&&a.expired)));
$("#cnt").textContent=`(${rows.length}/${L.length} shown, ${L.filter(a=>a.online).length} online)`;
put($("#tb"),`<tr><th>User</th><th>Status</th><th>Online IPs</th><th>Expires</th><th>Data</th><th>Last seen</th><th class="wr"></th></tr>`+(rows.map(a=>{const s=status(a);return `<tr data-u="${e(a.u)}"><td>${e(a.u)}</td><td><span class="b ${cls[s]}">${s}</span></td><td>${a.ips.map(e).join("<br>")||"-"}<div class="k">${a.online}/${e(a.ip)} sessions</div></td><td>${e(a.exp)}${a.days!=null?` (${a.days<0?"expired":a.days+"d left"})`:""}</td><td>${a.used}/${e(a.gb)} GB</td><td>${a.online?"now":seen(a.last)}</td><td class="wr" style="white-space:nowrap"><button class="s" data-a="e">Edit</button> ${a.online?`<button class="s" data-a="k">Kick</button> `:""}${a.ips.length?`<button class="s" data-a="b">Ban IP</button> `:""}<button class="s" data-a="l" data-v="${a.locked?0:1}">${a.locked?"Unlock":"Lock"}</button> <button class="d" data-a="d">Delete</button></td></tr>`}).join("")||`<tr><td colspan="7">No accounts match.</td></tr>`))};
const bp=()=>{put($("#bt"),`<tr><th>Blocked IP</th><th>Since</th><th>Note</th><th>Live</th><th></th></tr>`+(BL.map(b=>`<tr data-i="${e(b.ip)}"><td>${e(b.ip)}</td><td>${seen(b.ts)}</td><td>${e(b.note)||"-"}</td><td>${b.online?b.online+" session(s)":"-"}</td><td style="white-space:nowrap"><button class="s" data-a="ub">Unblock</button></td></tr>`).join("")||`<tr><td colspan="5">No blocked IPs.</td></tr>`));$("#bcn").textContent=`(${BL.length})`};
const loadB=async()=>{if(role!="admin")return;BL=await api("bans");bp()};
const load=async()=>{L=await api("accounts");paint();await loadB()};
const edit=u=>{const a=L.find(x=>x.u==u)||{};$("#ed").style.display="block";$("#en").textContent=u;$("#ep").value="";$("#ey").value="";$("#ei").value=a.ip??"";$("#eg").value=a.gb=="Unlimited"?"":(a.gb??"");$("#ed").scrollIntoView();const body=x=>({p:val("ep"),days:val("ey"),ip:val("ei"),gb:val("eg"),...x});
$("#es").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({lock:false}));toast("Saved");load()});$("#el").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({lock:true}));toast("Locked");load()});$("#er").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({reset:true,lock:false}));toast("Usage reset");load()})};
$("#aa").onclick=go(async()=>{const x={u:val("au"),p:val("ap"),days:val("ad"),ip:val("ai"),gb:val("ag")};const r=await api("accounts","POST",x);toast("Account created");["au","ap","ag"].forEach(i=>$("#"+i).value="");showInfo(r.info||{u:x.u,p:x.p,ip:x.ip||1,gb:x.gb,exp:new Date(Date.now()+(+x.days||30)*864e5).toISOString().slice(0,10)});go(load)()});
$("#q").oninput=paint;$("#f").onchange=paint;
$("#bb").onclick=go(async()=>{const r=await api("bans","POST",{ip:val("bi"),note:val("bn")});$("#bi").value="";$("#bn").value="";toast("Blocked"+(r.killed?" - kicked "+r.killed+" session(s)":""));load()});
$("#bt").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const ip=b.closest("tr").dataset.i;if(confirm("Unblock "+ip+"?")){await api("unban","POST",{ip});toast("Unblocked "+ip);load()}});
$("#cx").onclick=go(async()=>{if(confirm("Delete ALL expired accounts?")){const r=await api("accounts/cleanup","POST");toast("Deleted "+r.deleted+" account(s)");load()}});
$("#tb").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const u=b.closest("tr").dataset.u,k=b.dataset.a;
if(k=="e")return edit(u);
if(k=="b"){const a=L.find(x=>x.u==u)||{ips:[]};if(!a.ips.length||!confirm("Block IP(s) "+a.ips.join(", ")+" of "+u+"?"))return;for(const ip of a.ips)await api("bans","POST",{ip,note:"user "+u});toast("Blocked "+a.ips.join(", "));return load()}
if(k=="k"){await api("kick","POST",{u});toast("Kicked "+u);return load()}
if(k=="l"){await api("accounts/"+u,"PUT",{lock:b.dataset.v=="1"});toast(b.dataset.v=="1"?"Locked "+u:"Unlocked "+u);return load()}
if(k=="d"&&confirm("Delete "+u+"?")){await api("accounts/"+u,"DELETE");toast("Deleted "+u);load()}});
await load();timer=setInterval(()=>document.hidden||go(load)(),6000)},
async on(m){m.innerHTML=`<div class="card"><h2>Online sessions <span class="k" id="oc"></span></h2><div class="row"><div><input id="oq" placeholder="Filter by username or IP"></div><div style="flex:0 0 auto;min-width:0"><button class="s" id="orf">Refresh now</button></div></div><div class="tw"><table id="ot"></table></div><div class="k" style="margin-top:8px">Updates every 5 seconds. Kick ends a session; lock the account in the Accounts tab to stop reconnects.</div></div>`;
let S=[];
const paint=()=>{const q=val("oq").toLowerCase(),r=S.filter(x=>!q||x.u.includes(q)||x.ip.includes(q));
put($("#ot"),`<tr><th>User</th><th>Client IP</th><th>Via</th><th>Connected</th><th>PID</th><th class="wr"></th></tr>`+(r.map(x=>`<tr data-p="${e(x.pid)}" data-u="${e(x.u)}" data-i="${e(x.ip)}"><td>${e(x.u)}</td><td>${e(x.ip)}</td><td>${x.via=="ws"?"WebSocket":"SSH direct"}</td><td>${dur(x.secs)}</td><td>${e(x.pid)}</td><td class="wr" style="white-space:nowrap"><button class="s" data-a="p">Kick session</button> <button class="s" data-a="u">Kick user</button> <button class="d" data-a="i">Kick IP</button></td></tr>`).join("")||`<tr><td colspan="6">Nobody is online right now.</td></tr>`))};
const load=async()=>{const r=await api("sessions");S=r.sessions;$("#oc").textContent=`(${r.sessions.length} sessions, ${r.users} users, ${r.ips} IPs)`;paint()};
$("#oq").oninput=paint;$("#orf").onclick=go(load);
$("#ot").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const t=b.closest("tr"),k=b.dataset.a,body=k=="p"?{pid:t.dataset.p}:k=="u"?{u:t.dataset.u}:{ip:t.dataset.i};if(k!="p"&&!confirm("Kick all matching sessions?"))return;const r=await api("kick","POST",body);toast("Kicked "+r.killed+" session(s)");load()});
await load();timer=setInterval(()=>document.hidden||go(load)(),5000)},
async ban(m){const b=await api("banner");m.innerHTML=`<div class="card"><h2>SSH banner</h2><div class="k">HTML is allowed (for example &lt;font color="green"&gt;). Saved + applied to new connections right away (max 2000 bytes). Connected users stay online.</div><textarea id="bt" rows="10">${e(b.t)}</textarea><br><br><button class="f" id="bs">Save banner</button> <button class="s" id="bc">Clear</button></div>${foot}`;$("#bs").onclick=go(async()=>{await api("banner","PUT",{t:val("bt")});toast("Banner saved")});$("#bc").onclick=go(async()=>{$("#bt").value="";await api("banner","PUT",{t:""});toast("Banner cleared")})},
async tg(m){const draw=async(a)=>{const t=await api("tg"+(a?"?act="+a:""));m.innerHTML=`<div class="card"><h2>Telegram bot</h2><span class="b ${t.active?"on1":"off1"}">${t.active?"running":"stopped"}</span> ${t.token?`&nbsp; token ${e(t.token)} &nbsp; admin ${e(t.admin)}`:""}<div class="row" style="margin-top:12px;justify-content:flex-start"><button class="s" data-a="restart">Restart</button><button class="s" data-a="stop">Stop</button><button class="s" data-a="start">Start</button></div></div><div class="card"><h3>Connect bot</h3><label>Bot token (from @BotFather)</label><input id="tt"><label>Super admin Telegram ID</label><input id="ta" type="number"><br><br><button class="f" id="tc">Connect &amp; start</button></div>${foot}`;
m.querySelectorAll("[data-a]").forEach(b=>b.onclick=go(()=>draw(b.dataset.a)));$("#tc").onclick=go(async()=>{const r=await api("tg","POST",{token:val("tt"),admin:val("ta")});toast(r.ok?"Bot connected":"Failed: "+r.msg,!r.ok);draw()})};await draw()},
async set(m){const[o,ad]=await Promise.all([api("overview"),api("admins")]),c=o.cfg;m.innerHTML=`<div class="card"><h2>Ports &amp; domain</h2><div class="row"><div><label>Panel port</label><input id="sp" type="number" value="${c.panel_port}"></div><div><label>SSH port</label><input id="ss" type="number" value="${c.ssh_port}"></div><div><label>Domain</label><input id="sd" value="${e(c.domain)}"></div></div><label><input type="checkbox" id="sl" style="width:auto"> Issue Let's Encrypt SSL for a changed domain (DNS must point here)</label><br><button class="f" id="sv">Apply</button><div class="k" style="margin-top:8px">Changing the SSH port restarts Dropbear and disconnects live sessions. After a panel-port change, open the new port.</div></div>
<div class="card"><h2>Panel logins</h2><div class="tw"><table>${ad.map(a=>`<tr><td>${e(a.u)}</td><td><span class="b ${a.role=="admin"?"on1":"mu1"}">${a.role=="admin"?"admin":"user (view only)"}</span> ${a.role=="admin"?"":`<span class="b ${a.left!=null&&a.left<=0?"mu1":"on1"}">${a.left==null?"no expiry":a.left<=0?"expired":Math.ceil(a.left/86400)+" days left"}</span>`}</td><td>${a.role=="admin"?"":`<button class="s" data-e="${e(a.u)}">Add days</button> `}<button class="s" data-p="${e(a.u)}">Change password</button> <button class="d" data-x="${e(a.u)}">Delete</button></td></tr>`).join("")}</table></div><div class="row"><div><label>Username</label><input id="nu"></div><div><label>Password</label><input id="np" type="password"></div><div><label>Type</label><select id="nr"><option value="user">User (view only)</option><option value="admin">Admin (full access)</option></select></div><div><label>Key valid for (days, 0 = no expiry)</label><input id="nd" type="number" min="0" max="3650" value="30"></div></div><br><button id="nc">Create login</button> <button class="s" id="nn">Change my username</button></div>${foot}`;
$("#sv").onclick=go(async()=>{const r=await api("settings","POST",{panel_port:val("sp"),ssh_port:val("ss"),domain:val("sd"),ssl:$("#sl").checked});toast("Applied. "+r.msg);if(r.cfg.panel_port!=location.port*1&&location.port)setTimeout(()=>location.port=r.cfg.panel_port,4000)});
const ad_=go(async(b)=>{const r=await api("admin","POST",b);toast("Done");view()});$("#nc").onclick=()=>ad_({act:"create",u:val("nu"),p:val("np"),role:val("nr"),days:val("nd")});
$("#nn").onclick=()=>ad_({act:"rename",u:me,new:val("nu")});m.querySelectorAll("[data-p]").forEach(b=>b.onclick=()=>{const p=prompt("New password for "+b.dataset.p);p&&ad_({act:"password",u:b.dataset.p,p})});m.querySelectorAll("[data-e]").forEach(b=>b.onclick=()=>{const d=prompt("Add how many days to "+b.dataset.e+"?","30");d&&ad_({act:"extend",u:b.dataset.e,days:d})});m.querySelectorAll("[data-x]").forEach(b=>b.onclick=()=>confirm("Delete login?")&&ad_({act:"delete",u:b.dataset.x}))}};
boot();
</script></body></html>
UI_EOF

# ---- V5 THEMES: adds a "Themes" tab (14 luxury single/double color themes with flames) + SVG flame logo in header to the panel UI ----
# Installs /usr/local/bin/uitheme and applies it to the freshly written index.html. Remove with: uitheme off
cat > /usr/local/bin/uitheme <<'PYEOF'
#!/usr/bin/env python3
import os,sys,re
D=os.environ.get("PANEL_DIR","/opt/aliraza-panel");F=D+"/index.html";O=D+"/index.orig.html";MK="ALR_THEMES"
JS=r'''
/* ALR_THEMES */
(function(){
const st=document.querySelector("style");if(!st)return;const ORIG=st.textContent;
const KEEP=["#4ade80","#ff4d6d","#e11d48","#4a1522","#0d3a22"];
const TH=[
{id:"ice",k:1,n:"Ice Blue",d:"Original icy look",mh:198,ms:1,ah:198,as:1},
{id:"gold",k:1,n:"Royal Gold",d:"Warm golden luxury",mh:42,ms:.75,ah:42,as:.85},
{id:"crimson",k:1,n:"Crimson Velvet",d:"Deep red, royal fire",mh:352,ms:.9,ah:352,as:.9},
{id:"emerald",k:1,n:"Emerald Luxe",d:"Rich jewel green",mh:152,ms:.8,ah:152,as:.75},
{id:"amethyst",k:1,n:"Royal Amethyst",d:"Noble violet glow",mh:268,ms:.75,ah:268,as:.8},
{id:"rose",k:1,n:"Rose Gold",d:"Soft blush metallic",mh:8,ms:.55,ah:8,as:.6},
{id:"platinum",k:1,n:"Platinum Silver",d:"Cold steel and white",mh:215,ms:.12,ah:215,as:.15},
{id:"blackgold",k:2,n:"Black & Gold",d:"Onyx base, gold flames",mh:40,ms:.1,ah:43,as:.85},
{id:"burgundy",k:2,n:"Burgundy & Gold",d:"Wine base, gold accents",mh:345,ms:.85,ah:43,as:.85},
{id:"navyrose",k:2,n:"Midnight & Rose Gold",d:"Navy base, rose flames",mh:224,ms:.8,ah:10,as:.6},
{id:"emgold",k:2,n:"Emerald & Gold",d:"Green base, gold flames",mh:155,ms:.8,ah:43,as:.85},
{id:"purgold",k:2,n:"Royal Purple & Gold",d:"Violet base, gold flames",mh:270,ms:.8,ah:43,as:.85},
{id:"onyxred",k:2,n:"Onyx & Crimson",d:"Black base, red flames",mh:0,ms:.05,ah:355,as:.9},
{id:"sapphire",k:2,n:"Sapphire & Platinum",d:"Deep blue, silver flames",mh:218,ms:1,ah:220,as:.12}
];
function hsl(h){const r=parseInt(h.slice(0,2),16)/255,g=parseInt(h.slice(2,4),16)/255,b=parseInt(h.slice(4,6),16)/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),l=(mx+mn)/2;let hh=0,s=0;if(mx!==mn){const q=mx-mn;s=l>.5?q/(2-mx-mn):q/(mx+mn);hh=mx===r?(g-b)/q+(g<b?6:0):mx===g?(b-r)/q+2:(r-g)/q+4;hh/=6}return[hh,s,l]}
function rgb(h,s,l){const f=(p,q,t)=>{if(t<0)t+=1;if(t>1)t-=1;return t<1/6?p+(q-p)*6*t:t<.5?q:t<2/3?p+(q-p)*(2/3-t)*6:p},q=l<.5?l*(1+s):l+s-l*s,p=2*l-q;return[f(p,q,h+1/3),f(p,q,h),f(p,q,h-1/3)].map(x=>("0"+Math.round(x*255).toString(16)).slice(-2)).join("")}
function sh(hex,t){if(KEEP.indexOf("#"+hex.slice(0,6).toLowerCase())>-1&&hex.length==6)return hex;const v=hsl(hex),a=v[2]>=.45&&v[1]>.3,T=a?t.ah:t.mh,S=a?t.as:t.ms;let h=(v[0]+(T-198)/360)%1;if(h<0)h+=1;return rgb(h,Math.min(1,v[1]*S),v[2])+hex.slice(6)}
function xf(css,t){return css.replace(/#([0-9a-fA-F]{8}|[0-9a-fA-F]{6})\b/g,(m,h)=>KEEP.indexOf(m.toLowerCase())>-1?m:"#"+sh(h,t))}
const g=k=>{try{return localStorage.getItem(k)}catch(_){return null}},p=(k,v)=>{try{localStorage.setItem(k,v)}catch(_){}};
let cur=g("alr_theme")||"ice",fl=g("alr_fire")!=="0",em=g("alr_emb")!=="0";
function apply(){const t=TH.find(x=>x.id==cur)||TH[0];st.textContent=t.id=="ice"?ORIG:xf(ORIG,t);const mt=document.querySelector('meta[name="theme-color"]');if(mt)mt.content="#"+sh("050c0f",t);document.querySelectorAll(".fire").forEach(e=>e.style.display=fl?"":"none");document.querySelectorAll(".embers").forEach(e=>e.style.display=em?"":"none")}
apply();
function card(t){const c=x=>"#"+sh(x,t),bg=c("050c0f"),cd=c("0b1a21"),ln=c("265064"),a1=c("2face7"),a2=c("87d9f9"),f1=c("effbff"),f2=c("38a6e8"),on=t.id==cur;
return `<div class="tc" data-id="${t.id}" tabindex="0" role="button" style="cursor:pointer;border:${on?"2px solid "+a2:"1px solid var(--line)"};border-radius:14px;overflow:hidden;background:var(--card2)"><div style="position:relative;height:78px;background:${bg};overflow:hidden"><div style="position:absolute;left:-10%;right:-10%;bottom:-26px;height:70px;background:radial-gradient(ellipse at 50% 100%,${f1} 0%,${a2} 22%,${f2} 48%,transparent 72%);filter:blur(7px);opacity:.9"></div><div style="position:absolute;left:10px;top:9px;font-weight:800;font-size:13px;letter-spacing:1px;color:${a2}">ALIRAZA</div><div style="position:absolute;right:8px;top:8px;width:34px;height:14px;border-radius:7px;background:${a1}"></div><div style="position:absolute;left:10px;right:10px;top:30px;height:16px;border-radius:6px;background:${cd};border:1px solid ${ln}"></div></div><div style="padding:9px 11px 11px"><div style="font-weight:700;font-size:13.5px;color:var(--f3)">${t.n}</div><div class="k" style="margin-top:2px">${t.d}</div><div style="margin-top:7px;display:flex;gap:5px;align-items:center"><i style="width:14px;height:14px;border-radius:50%;background:${cd};border:1px solid ${ln};display:inline-block"></i><i style="width:14px;height:14px;border-radius:50%;background:${a1};display:inline-block"></i><i style="width:14px;height:14px;border-radius:50%;background:${a2};display:inline-block"></i>${on?'<span class="b on1" style="margin-left:auto">Active</span>':""}</div></div></div>`}
const grid=a=>`<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px">${a.map(card).join("")}</div>`;
if(typeof TABS!=="undefined"){delete TABS.set;TABS.theme="Themes";TABS.set="Settings"}
V.theme=async function(m){const draw=()=>{m.innerHTML=`<div class="card"><h2>Themes</h2><div class="k">Pick a look for this panel. It is saved on this device and applies to the login screen too.</div><div style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap"><button class="${fl?"f":"s"}" id="tf">Flames: ${fl?"ON":"OFF"}</button><button class="${em?"f":"s"}" id="te">Embers: ${em?"ON":"OFF"}</button></div></div><div class="card"><h2>Single color + flames</h2>${grid(TH.filter(x=>x.k==1))}</div><div class="card"><h2>Double color + flames</h2>${grid(TH.filter(x=>x.k==2))}</div>${foot}`;
m.querySelectorAll(".tc").forEach(e=>{const pick=()=>{cur=e.dataset.id;p("alr_theme",cur);apply();draw();toast("Theme: "+TH.find(x=>x.id==cur).n)};e.onclick=pick;e.onkeydown=ev=>{if(ev.key=="Enter")pick()}});
$("#tf").onclick=()=>{fl=!fl;p("alr_fire",fl?"1":"0");apply();draw()};$("#te").onclick=()=>{em=!em;p("alr_emb",em?"1":"0");apply();draw()}};draw()};
})();
'''
if len(sys.argv)>1 and sys.argv[1]=="off":
    if os.path.exists(O): open(F,"w").write(open(O).read());print("Themes section removed (original UI restored).")
    else: print("Nothing to restore.")
    sys.exit()
if not os.path.exists(F): sys.exit("Not found: "+F+" (panel not installed here?)")
cur=open(F).read()
if "--bg:#050c0f" in cur and MK not in cur: open(O,"w").write(cur)   # fresh install -> new pristine copy
if not os.path.exists(O): sys.exit("No clean copy found. Re-run the installer (menu.sh), then run this again.")
s=open(O).read()
if "--bg:#050c0f" not in s: sys.exit("Clean copy is not the original ice UI. Re-run the installer (menu.sh), then run this again.")
a='["core","on","acc"].includes(k)'
if a not in s: sys.exit("Panel version not recognised (nav filter not found).")
s=s.replace(a,'["core","on","acc","theme"].includes(k)',1)
SV="""<span class="logo"><svg class="alrlogo" viewBox="0 0 24 28" width="24" height="28" aria-hidden="true"><defs><linearGradient id="alrfg" x1="0" y1="1" x2="0" y2="0"><stop offset="0" class="fs1"/><stop offset=".55" class="fs2"/><stop offset="1" class="fs3"/></linearGradient></defs><path fill="url(#alrfg)" d="M12 1c.8 4.2 6.4 7.2 6.4 13.6A6.4 6.4 0 0 1 5.6 14.6c0-2.6 1.3-4.4 2.6-5.6.2 1.8 1 3 2.2 3C9.9 8.2 10.6 4.3 12 1z"/><path fill="#fff" fill-opacity=".85" d="M12 14c.5 1.8 2.6 3 2.6 5a2.6 2.6 0 0 1-5.2 0c0-1.4.8-2.1 1.4-2.8.3.9.8 1.2 1.2 1.2z"/></svg></span>"""
C1=".brand{background:none!important;-webkit-background-clip:border-box!important;background-clip:border-box!important;-webkit-text-fill-color:initial!important;color:var(--tx)}.brand .bt{background:linear-gradient(90deg,#adecfa,#46c2f2,#2face7,#adecfa);background-size:200% 100%;animation:shine 4s linear infinite;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent}"
C2=".alrlogo{vertical-align:-6px;margin-right:6px;filter:drop-shadow(0 0 5px #4dbaf1aa)}.fs1{stop-color:#38a6e8}.fs2{stop-color:#a5e4ff}.fs3{stop-color:#effbff}"
s=re.sub(r"""<div class="brand">.*?<small>""",lambda m:'<div class="brand">'+SV+'<span class="bt"> ALIRAZA</span><small>',s,1,re.S)
s=s.replace('<span class="logo">\U0001F52E</span>','<span class="logo">\U0001F525</span>')
s=s.replace("</style>",C1+C2+"</style>",1)
i=s.rfind("boot();\n</script>")
if i<0: sys.exit("Panel version not recognised (boot call not found).")
s=s[:i]+JS+s[i:]
open(F,"w").write(s)
print("OK: Themes section added. Open the panel, hard refresh, and tap 'Themes' in the menu.")
PYEOF
chmod +x /usr/local/bin/uitheme
uitheme || echo -e "${Y}Themes tab could not be added (panel still works). Run: uitheme${N}"

python3 -m venv /opt/aliraza-panel/venv && /opt/aliraza-panel/venv/bin/pip install -q flask flask-sock gunicorn psutil || { echo -e "${R}Panel libraries failed to install (pip). Check internet and re-run.${N}"; exit 1; }
echo -e "${Y}[4/6] Telegram bot libraries (background)...${N}"
( python3 -m venv /opt/rr-tgbot-venv && /opt/rr-tgbot-venv/bin/pip install -q "python-telegram-bot==20.7" ) &>/var/log/aliraza-tgvenv.log &
echo -e "${Y}[5/6] Config, SSL and Dropbear...${N}"
echo "{\"domain\":\"$DOMAIN\",\"panel_port\":$PP,\"ssh_port\":$SP}" > /etc/artricks/panel.json; echo "$DOMAIN" > /etc/artricks/domain.conf
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$DOMAIN" -keyout /etc/artricks/ssl/self.key -out /etc/artricks/ssl/self.crt 2>/dev/null
systemctl stop nginx 2>/dev/null
certbot certonly --standalone --preferred-challenges http --agree-tos --register-unsafely-without-email -n -d "$DOMAIN" || echo -e "${R}SSL failed - using self-signed (browser warning). Retry later from Settings.${N}"
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
printf '#!/bin/sh\nsystemctl stop nginx\n' > /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh
printf '#!/bin/sh\nsystemctl start nginx\n' > /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh
cd /opt/aliraza-panel
ADMIN_U="$AU" ADMIN_P="$AP" ./venv/bin/python - <<'PYI'
import os,app
from werkzeug.security import generate_password_hash as g
c=app.db();c.execute("delete from admins");c.execute("insert into admins(u,p,role) values(?,?,'admin')",(os.environ["ADMIN_U"],g(os.environ["ADMIN_P"])));c.commit()
print(app.apply_dropbear());print(app.apply_nginx())
PYI
echo -e "${Y}[6/6] Starting services...${N}"
if command -v ufw >/dev/null && ufw status | grep -q active; then for p in 80 443 $PP $SP 109 447 2299; do ufw allow $p/tcp; done; fi
systemctl daemon-reload; systemctl enable --now ws-proxy autokill aliraza-panel aliraza-tune aliraza-watchdog aliraza-ban-ssh aliraza-ban; systemctl restart nginx
echo -e "${Y}Waiting for Telegram bot libraries to finish...${N}"; wait
echo -e "\n${G}==================== INSTALLED ====================${N}"
echo -e " Panel URL : ${Y}https://$DOMAIN:$PP${N}"
echo -e " Username  : ${Y}$AU${N}"
echo -e " Password  : ${Y}$AP${N}   (login on the 'Admin' tab)"
echo -e " View-only users: Settings > Panel logins > Type 'User (view only)', they log in on the 'User' tab"
echo -e " SSH port  : ${Y}$SP${N} (also 109, 447) | WS 80 | WS+SSL 443"
sleep 2
echo -e "\n${Y}--- Self-check ---${N}"
BAD=0
for svc in nginx dropbear ws-proxy autokill aliraza-panel aliraza-watchdog aliraza-ban-ssh; do
  if systemctl is-active --quiet $svc; then echo -e " ${G}[OK]${N}   service $svc"; else echo -e " ${R}[FAIL]${N} service $svc"; BAD=1; journalctl -u $svc -n 8 --no-pager 2>/dev/null | cut -c1-160; fi
done
for prt in $PP $SP 109 447 80 443 12026 2082 2299; do
  if ss -tln 2>/dev/null | grep -q ":$prt "; then echo -e " ${G}[OK]${N}   port $prt listening"; else echo -e " ${R}[FAIL]${N} port $prt not listening"; BAD=1; fi
done
CODE=$(curl -sk -o /dev/null -m 6 -w '%{http_code}' "https://127.0.0.1:$PP/" 2>/dev/null)
if [[ "$CODE" == "200" ]]; then echo -e " ${G}[OK]${N}   panel answers locally (HTTP 200)"; else echo -e " ${R}[FAIL]${N} panel local test (HTTP ${CODE:-none})"; BAD=1; fi
IDENT=$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/109; head -n1 <&3' 2>/dev/null | tr -d '\r')
if [[ "$IDENT" == "SSH-2.0-AliRaza-server" ]]; then echo -e " ${G}[OK]${N}   SSH ident: $IDENT"; else echo -e " ${R}[WARN]${N} SSH ident: ${IDENT:-unknown} (custom build missing, see /var/log/aliraza-dropbear-build.log)"; fi
echo -e "${Y}Open in your VPS provider's cloud firewall (TCP): 80, 443, $PP, $SP, 109, 447${N}"
[[ $BAD -eq 0 ]] && echo -e "${G}All checks passed.${N}" || echo -e "${R}Some checks failed - send the lines above to support.${N}"
echo -e " Created by ALIRAZA | Support: https://t.me/ar_tricks"
echo -e "${G}===================================================${N}"
