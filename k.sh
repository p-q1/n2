#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:-auto}"

IP_ISP="172.16.1.1"
IP_HQ_RTR="172.16.1.2"
IP_BR_RTR="172.16.2.2"
IP_HQ_SRV="192.168.10.2"
IP_BR_SRV="192.168.0.2"
IP_HQ_CLI="192.168.10.10"

HQ_CLI_NET="192.168.10.0/24"
EXT_IF_HQ_RTR="${EXT_IF_HQ_RTR:-eth0}"
EXT_IF_BR_RTR="${EXT_IF_BR_RTR:-eth0}"

SSH_PORT_HQ_SRV="2027"
SSH_PORT_BR_SRV="2027"
SSH_PASS="P@ssw0rd"
AUTHORIZED_PUBKEY=""

AD_REALM="HQ.LOCAL"
AD_ADMIN_PASS="${AD_ADMIN_PASS:-$SSH_PASS}"
HQ_GROUP="hq"
HQ_USER_PASS="P@ssw0rd123"

RAID_DEV="/dev/md0"
RAID_DISKS=("/dev/sdb" "/dev/sdc")
RAID_MOUNT="/raid"
NFS_EXPORT_DIR="/raid/nfs"
CLI_NFS_MOUNT="/mnt/nfs"

UPSTREAM_NTP="pool.ntp.org"
ISO_PATH="/root/Additional.iso"
ISO_MOUNT="/mnt/iso"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-auto}"; shift 2 ;;
    --role=*) ROLE="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти скрипт от имени root."

detect_role() {
  if [ "$ROLE" != "auto" ]; then
    echo "$ROLE"
    return 0
  fi
  local hn ips
  hn="$(hostname -s 2>/dev/null || hostname)"
  ips="$(hostname -I 2>/dev/null || true)"
  if [[ "$hn" == *br-srv* ]] || [[ " $ips " == *" $IP_BR_SRV "* ]]; then
    echo "br-srv"
  else
    echo "node"
  fi
}

stage1_node_prepare_and_ssh() {
  local hn ips ssh_user target_port sshd_cfg
  hn="$(hostname -s 2>/dev/null || hostname)"
  ips="$(hostname -I 2>/dev/null || true)"

  log "[ЭТАП 1][$hn] Проверка и установка базовых пакетов..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    openssh-server \
    openssh-clients \
    sshpass \
    python3 \
    sudo \
    nano \
    curl \
    wget \
    ca-certificates \
    chrony \
    nftables \
    iptables \
    iproute2 \
    util-linux

  if [[ "$hn" == *isp* ]] || [[ "$hn" == *rtr* ]] || \
     [[ " $ips " == *" $IP_ISP "* ]] || \
     [[ " $ips " == *" $IP_HQ_RTR "* ]] || \
     [[ " $ips " == *" $IP_BR_RTR "* ]]; then
    ssh_user="net_admin"
  else
    ssh_user="sshuser"
  fi

  if [[ "$hn" == *hq-srv* ]] || [[ " $ips " == *" $IP_HQ_SRV "* ]]; then
    target_port="$SSH_PORT_HQ_SRV"
  elif [[ "$hn" == *br-srv* ]] || [[ " $ips " == *" $IP_BR_SRV "* ]]; then
    target_port="$SSH_PORT_BR_SRV"
  else
    target_port="22"
  fi

  log "[ЭТАП 1][$hn] Проверка пользователя SSH '$ssh_user'..."
  if ! id "$ssh_user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$ssh_user"
  fi
  echo "${ssh_user}:${SSH_PASS}" | chpasswd

  if getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "$ssh_user" 2>/dev/null || true
    printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-wheel-nopasswd
    chmod 0440 /etc/sudoers.d/90-wheel-nopasswd
    visudo -cf /etc/sudoers.d/90-wheel-nopasswd
  fi
  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$ssh_user" 2>/dev/null || true
  fi
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ssh_user" > "/etc/sudoers.d/90-${ssh_user}-nopasswd"
  chmod 0440 "/etc/sudoers.d/90-${ssh_user}-nopasswd"
  visudo -cf "/etc/sudoers.d/90-${ssh_user}-nopasswd"

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  if [ ! -f /root/.ssh/id_ed25519 ]; then
    rm -f /root/.ssh/id_ed25519*
    ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519
  fi
  if [ -n "$AUTHORIZED_PUBKEY" ]; then
    grep -qxF "$AUTHORIZED_PUBKEY" /root/.ssh/authorized_keys || \
      echo "$AUTHORIZED_PUBKEY" >> /root/.ssh/authorized_keys
  fi

  local uhome
  uhome="$(getent passwd "$ssh_user" | cut -d: -f6)"
  mkdir -p "$uhome/.ssh"
  chmod 700 "$uhome/.ssh"
  touch "$uhome/.ssh/authorized_keys"
  chmod 600 "$uhome/.ssh/authorized_keys"
  if [ -n "$AUTHORIZED_PUBKEY" ]; then
    grep -qxF "$AUTHORIZED_PUBKEY" "$uhome/.ssh/authorized_keys" || \
      echo "$AUTHORIZED_PUBKEY" >> "$uhome/.ssh/authorized_keys"
  fi
  chown -R "${ssh_user}:${ssh_user}" "$uhome/.ssh"

  log "[ЭТАП 1][$hn] Настройка sshd, порт ${target_port}..."
  sshd_cfg="/etc/openssh/sshd_config"
  [ -f "$sshd_cfg" ] || sshd_cfg="/etc/ssh/sshd_config"
  [ -f "$sshd_cfg" ] || die "Файл конфигурации sshd_config не найден"

  sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_cfg"
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$sshd_cfg"

  if ! grep -Eq "^[[:space:]]*Port[[:space:]]+${target_port}\b" "$sshd_cfg"; then
    if grep -Eq "^[[:space:]]*#?[[:space:]]*Port[[:space:]]+" "$sshd_cfg"; then
      sed -i "s/^[[:space:]]*#*[[:space:]]*Port[[:space:]].*/Port ${target_port}/" "$sshd_cfg"
    else
      echo "Port ${target_port}" >> "$sshd_cfg"
    fi
  fi

  sshd -t -f "$sshd_cfg"

  systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

  if command -v ss >/dev/null 2>&1; then
    ss -tlnp | grep -E ":${target_port}\b" || true
  fi
  id "$ssh_user"
  sudo -l -U "$ssh_user" >/dev/null 2>&1 || true
  log "[ЭТАП 1][$hn] Готово (пользователь: $ssh_user, порт: $target_port)."
}

stage2_br_srv_workflow() {
  log "[ЭТАП 2][BR-SRV] Локальные задачи BR-SRV..."

  log "[BR-SRV] Настройка chrony-клиента на ISP..."
  local chrony_conf="/etc/chrony.conf"
  [ -f /etc/chrony/chrony.conf ] && chrony_conf="/etc/chrony/chrony.conf"
  cat > "$chrony_conf" <<EOF
server $IP_ISP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
  systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
  systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

  log "[BR-SRV] Настройка Samba DC..."
  if command -v samba-tool >/dev/null 2>&1; then
    if [ ! -f /var/lib/samba/private/sam.ldb ]; then
      log "[BR-SRV] База Samba не найдена. Выполняется провижининг домена..."
      systemctl stop samba smb nmb 2>/dev/null || true
      rm -f /etc/samba/smb.conf
      rm -rf /var/lib/samba/private
      samba-tool domain provision --realm="$AD_REALM" --domain="HQ" --adminpass="$AD_ADMIN_PASS" --dns-backend=SAMBA_INTERNAL --server-role=dc --use-rfc2307
      cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
      systemctl enable --now samba
      sleep 2
    fi
    samba-tool domain passwordsettings set --min-pwd-length=8 || true
    samba-tool domain passwordsettings set --account-lockout-threshold=5 || true
    samba-tool group add "$HQ_GROUP" 2>/dev/null || true

    for i in 1 2 3 4 5; do
      uname="hquser${i}"
      samba-tool user create "$uname" "$HQ_USER_PASS" \
        --given-name="HQ" \
        --surname="User${i}" \
        --must-change-at-next-login=no 2>/dev/null || \
        samba-tool user setpassword "$uname" --newpassword="$HQ_USER_PASS" 2>/dev/null || true
      samba-tool group addmembers "$HQ_GROUP" "$uname" 2>/dev/null || true
    done
  else
    log "[BR-SRV][WARN] samba-tool не найден."
  fi

  log "[BR-SRV] Развёртывание Docker-стека testapp..."
  apt-get install -y docker-engine docker-compose-v2 ansible 2>/dev/null || \
    apt-get install -y docker-engine docker-compose ansible
  systemctl enable --now docker

  mkdir -p "$ISO_MOUNT"
  if [ -f "$ISO_PATH" ]; then
    if ! mountpoint -q "$ISO_MOUNT"; then
      mount -o loop "$ISO_PATH" "$ISO_MOUNT" || true
    fi
  elif [ -b /dev/sr0 ]; then
    if ! mountpoint -q "$ISO_MOUNT"; then
      mount -o ro /dev/sr0 "$ISO_MOUNT" || true
    fi
  fi

  if [ -d "$ISO_MOUNT/docker" ]; then
    for img in site_latest.tar mariadb_latest.tar; do
      [ -f "$ISO_MOUNT/docker/$img" ] && docker load -i "$ISO_MOUNT/docker/$img" || true
    done
  fi

  mkdir -p /opt/testapp
  cd /opt/testapp

  COMPOSE_FILE=""
  if [ -f "$ISO_MOUNT/docker/compose.yaml" ]; then
    cp -f "$ISO_MOUNT/docker/compose.yaml" .
    COMPOSE_FILE="compose.yaml"
  elif [ -f "$ISO_MOUNT/compose.yaml" ]; then
    cp -f "$ISO_MOUNT/compose.yaml" .
    COMPOSE_FILE="compose.yaml"
  else
    log "[BR-SRV][WARN] compose.yaml не найден в ISO. Создаем свой..."
    cat > compose.yaml <<'EOF'
version: '3.8'
services:
  db:
    image: mariadb:10.11
    environment:
      MYSQL_ROOT_PASSWORD: P@ssw0rd
      MYSQL_DATABASE: webdb
      MYSQL_USER: web
      MYSQL_PASSWORD: P@ssw0rd
  app:
    image: site:latest
    ports:
      - "8080:80"
    depends_on:
      - db
    environment:
      DB_HOST: db
      DB_USER: web
      DB_PASS: P@ssw0rd
      DB_NAME: webdb
EOF
    COMPOSE_FILE="compose.yaml"
  fi

  if [ -n "$COMPOSE_FILE" ]; then
    if command -v docker-compose >/dev/null 2>&1; then
      docker-compose -f "$COMPOSE_FILE" up -d
    else
      docker compose -f "$COMPOSE_FILE" up -d
    fi
  fi
  cd /root
  docker ps || true

  log "[BR-SRV] Формирование /etc/ansible..."
  mkdir -p /etc/ansible
  cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = /usr/bin/python3
deprecation_warnings = False
localhost_warning = False
timeout = 10
EOF

  cat > /etc/ansible/hosts <<EOF
[hq_srv]
hq-srv ansible_host=$IP_HQ_SRV ansible_user=sshuser ansible_port=$SSH_PORT_HQ_SRV ansible_become=true ansible_become_method=sudo

[hq_cli]
hq-cli ansible_host=$IP_HQ_CLI ansible_user=sshuser ansible_port=22 ansible_become=true ansible_become_method=sudo

[hq_rtr]
hq-rtr ansible_host=$IP_HQ_RTR ansible_user=net_admin ansible_port=22 ansible_become=true ansible_become_method=sudo

[br_rtr]
br-rtr ansible_host=$IP_BR_RTR ansible_user=net_admin ansible_port=22 ansible_become=true ansible_become_method=sudo

[targets:children]
hq_srv
hq_cli
hq_rtr
br_rtr
EOF

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [ ! -f /root/.ssh/id_ed25519 ]; then
    rm -f /root/.ssh/id_ed25519*
    ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519
  fi

  ssh_push_key() {
    local user="$1" host="$2" port="$3"
    ssh-keyscan -p "$port" -H "$host" >> /root/.ssh/known_hosts 2>/dev/null || true
    local pubkey
    pubkey="$(cat /root/.ssh/id_ed25519.pub)"
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$port" "${user}@${host}" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pubkey' ~/.ssh/authorized_keys 2>/dev/null || echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" || true
  }

  ssh_push_key "net_admin" "$IP_ISP" "22"
  ssh_push_key "sshuser" "$IP_HQ_SRV" "$SSH_PORT_HQ_SRV"
  ssh_push_key "sshuser" "$IP_HQ_CLI" "22"
  ssh_push_key "net_admin" "$IP_HQ_RTR" "22"
  ssh_push_key "net_admin" "$IP_BR_RTR" "22"

  log "[BR-SRV -> ISP] Настройка chrony stratum 5..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "net_admin@${IP_ISP}" "sudo bash -s" <<EOF
set -euo pipefail
CHRONY_CONF=/etc/chrony.conf
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF=/etc/chrony/chrony.conf
cat > "\$CHRONY_CONF" <<CHR
server $UPSTREAM_NTP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
local stratum 5
allow 172.16.0.0/12
allow 192.168.0.0/16
allow 192.168.10.0/24
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
chronyc tracking || true
EOF
  log "[BR-SRV] Выход из сессии ISP выполнен."

  log "[BR-SRV -> HQ-RTR] chrony + DNAT 8080/2027 + FORWARD..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "net_admin@${IP_HQ_RTR}" "sudo bash -s" <<EOF
set -euo pipefail

CHRONY_CONF=/etc/chrony.conf
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF=/etc/chrony/chrony.conf
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

if command -v nft >/dev/null 2>&1; then
  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
  nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true

  nft list chain ip nat prerouting 2>/dev/null | grep -q 'dport 8080 dnat to $IP_HQ_SRV:80' || \
    nft add rule ip nat prerouting iifname "$EXT_IF_HQ_RTR" tcp dport 8080 dnat to $IP_HQ_SRV:80

  nft list chain ip nat prerouting 2>/dev/null | grep -q 'dport $SSH_PORT_HQ_SRV dnat to $IP_HQ_SRV:$SSH_PORT_HQ_SRV' || \
    nft add rule ip nat prerouting iifname "$EXT_IF_HQ_RTR" tcp dport $SSH_PORT_HQ_SRV dnat to $IP_HQ_SRV:$SSH_PORT_HQ_SRV

  nft list chain ip nat postrouting 2>/dev/null | grep -q 'masquerade' || \
    nft add rule ip nat postrouting masquerade

  nft add table ip filter 2>/dev/null || true
  nft add chain ip filter forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true

  nft list ruleset > /etc/nftables.conf
  systemctl enable --now nftables 2>/dev/null || true
else
  iptables -t nat -C PREROUTING -i "$EXT_IF_HQ_RTR" -p tcp --dport 8080 -j DNAT --to-destination "$IP_HQ_SRV:80" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$EXT_IF_HQ_RTR" -p tcp --dport 8080 -j DNAT --to-destination "$IP_HQ_SRV:80"

  iptables -t nat -C PREROUTING -i "$EXT_IF_HQ_RTR" -p tcp --dport "$SSH_PORT_HQ_SRV" -j DNAT --to-destination "$IP_HQ_SRV:$SSH_PORT_HQ_SRV" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$EXT_IF_HQ_RTR" -p tcp --dport "$SSH_PORT_HQ_SRV" -j DNAT --to-destination "$IP_HQ_SRV:$SSH_PORT_HQ_SRV"

  iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -j MASQUERADE
  
  iptables -P FORWARD ACCEPT

  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
fi
EOF

  log "[BR-SRV -> BR-RTR] chrony + DNAT 8080/2027 + FORWARD..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "net_admin@${IP_BR_RTR}" "sudo bash -s" <<EOF
set -euo pipefail

CHRONY_CONF=/etc/chrony.conf
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF=/etc/chrony/chrony.conf
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

if command -v nft >/dev/null 2>&1; then
  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
  nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true

  nft list chain ip nat prerouting 2>/dev/null | grep -q 'dport 8080 dnat to $IP_BR_SRV:8080' || \
    nft add rule ip nat prerouting iifname "$EXT_IF_BR_RTR" tcp dport 8080 dnat to $IP_BR_SRV:8080

  nft list chain ip nat prerouting 2>/dev/null | grep -q 'dport $SSH_PORT_BR_SRV dnat to $IP_BR_SRV:$SSH_PORT_BR_SRV' || \
    nft add rule ip nat prerouting iifname "$EXT_IF_BR_RTR" tcp dport $SSH_PORT_BR_SRV dnat to $IP_BR_SRV:$SSH_PORT_BR_SRV

  nft list chain ip nat postrouting 2>/dev/null | grep -q 'masquerade' || \
    nft add rule ip nat postrouting masquerade

  nft add table ip filter 2>/dev/null || true
  nft add chain ip filter forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true

  nft list ruleset > /etc/nftables.conf
  systemctl enable --now nftables 2>/dev/null || true
else
  iptables -t nat -C PREROUTING -i "$EXT_IF_BR_RTR" -p tcp --dport 8080 -j DNAT --to-destination "$IP_BR_SRV:8080" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$EXT_IF_BR_RTR" -p tcp --dport 8080 -j DNAT --to-destination "$IP_BR_SRV:8080"

  iptables -t nat -C PREROUTING -i "$EXT_IF_BR_RTR" -p tcp --dport "$SSH_PORT_BR_SRV" -j DNAT --to-destination "$IP_BR_SRV:$SSH_PORT_BR_SRV" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$EXT_IF_BR_RTR" -p tcp --dport "$SSH_PORT_BR_SRV" -j DNAT --to-destination "$IP_BR_SRV:$SSH_PORT_BR_SRV"

  iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -j MASQUERADE

  iptables -P FORWARD ACCEPT

  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
fi
EOF

  log "[BR-SRV -> HQ-SRV] Настройка RAID0, NFS, Apache+MariaDB, chrony..."
  if [ -d "$ISO_MOUNT/web" ]; then
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -P "$SSH_PORT_HQ_SRV" -r \
      "$ISO_MOUNT/web" "sshuser@${IP_HQ_SRV}:/tmp/web_src" || true
  fi

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$SSH_PORT_HQ_SRV" "sshuser@${IP_HQ_SRV}" "sudo bash -s" <<EOF
set -euo pipefail

CHRONY_CONF=/etc/chrony.conf
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF=/etc/chrony/chrony.conf
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

apt-get update -y
apt-get install -y mdadm e2fsprogs

for d in ${RAID_DISKS[*]}; do
  [ -b "\$d" ] || { echo "Нет блочного устройства \$d"; exit 1; }
done

if [ ! -b "$RAID_DEV" ]; then
  mdadm --create --verbose "$RAID_DEV" --level=0 \
    --raid-devices=${#RAID_DISKS[@]} ${RAID_DISKS[*]} --run
fi

mkdir -p /etc/mdadm
mdadm --detail --scan > /etc/mdadm.conf

if ! blkid "$RAID_DEV" >/dev/null 2>&1; then
  mkfs.ext4 -F "$RAID_DEV"
fi

mkdir -p "$RAID_MOUNT"
grep -q "^${RAID_DEV}[[:space:]]" /etc/fstab || \
  echo "$RAID_DEV $RAID_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a || true

mkdir -p "$NFS_EXPORT_DIR"
chmod 0777 "$NFS_EXPORT_DIR"
apt-get install -y nfs-server 2>/dev/null || apt-get install -y nfs-kernel-server
grep -q "^${NFS_EXPORT_DIR}[[:space:]]" /etc/exports || \
  echo "$NFS_EXPORT_DIR $HQ_CLI_NET(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
exportfs -ra
systemctl enable --now nfs-server 2>/dev/null || systemctl enable --now nfs-kernel-server 2>/dev/null || true

if [ -d /tmp/web_src ]; then
  apt-get install -y apache2 mariadb-server php php-mysql php-mysqli 2>/dev/null || \
    apt-get install -y apache2 mariadb-server php php-mysql

  systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || true
  sleep 2

  mysql -e "CREATE DATABASE IF NOT EXISTS webdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS 'web'@'%' IDENTIFIED BY 'P@ssw0rd';"
  mysql -e "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';"
  mysql -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%' IDENTIFIED BY 'P@ssw0rd';"
  mysql -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';"
  mysql -e "FLUSH PRIVILEGES;"

  [ -f /tmp/web_src/dump.sql ] && mysql webdb < /tmp/web_src/dump.sql || true

  WEB_ROOT="/var/www/html"
  [ -d /var/www/apache2/htdocs ] && WEB_ROOT="/var/www/apache2/htdocs"
  mkdir -p "\$WEB_ROOT"

  [ -f /tmp/web_src/index.php ] && cp -f /tmp/web_src/index.php "\$WEB_ROOT/index.php"
  [ -f /tmp/web_src/logo.png ] && cp -f /tmp/web_src/logo.png "\$WEB_ROOT/logo.png"

  if [ -f "\$WEB_ROOT/index.php" ]; then
    sed -i \
      -e "s/DB_USER_HERE/web/g" \
      -e "s/DB_PASS_HERE/P@ssw0rd/g" \
      -e "s/DB_NAME_HERE/webdb/g" \
      -e "s/DB_HOST_HERE/localhost/g" \
      "\$WEB_ROOT/index.php"
  fi

  systemctl enable --now apache2 2>/dev/null || systemctl enable --now httpd2 2>/dev/null || true
  systemctl restart apache2 2>/dev/null || systemctl restart httpd2 2>/dev/null || true
fi
EOF

  log "[BR-SRV -> HQ-CLI] Ввод в домен, sudo hq, NFS, chrony, браузер..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "sshuser@${IP_HQ_CLI}" "sudo bash -s" <<EOF
set -euo pipefail

CHRONY_CONF=/etc/chrony.conf
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF=/etc/chrony/chrony.conf
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

if ! grep -q "nameserver $IP_BR_SRV" /etc/resolv.conf 2>/dev/null; then
  cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
  { echo "nameserver $IP_BR_SRV"; cat /etc/resolv.conf.bak 2>/dev/null || true; } > /etc/resolv.conf
fi

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  realmd sssd sssd-ad sssd-tools oddjob oddjob-mkhomedir adcli krb5-user \
  samba-common-tools packagekit sudo nfs-common

realm discover "$AD_REALM" || true

if ! realm list 2>/dev/null | grep -qi "$AD_REALM"; then
  printf '%s\n' "$AD_ADMIN_PASS" | realm join --verbose --user=Administrator "$AD_REALM" || true
fi

systemctl enable --now sssd 2>/dev/null || true
systemctl restart sssd 2>/dev/null || true
systemctl enable --now oddjobd 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive pam-auth-update --enable mkhomedir || true
realm permit --groups "$HQ_GROUP" 2>/dev/null || true

cat > /etc/sudoers.d/hq_restricted <<'SUDO_HQ'
%hq ALL=(ALL) NOPASSWD: /bin/cat, /usr/bin/cat, /bin/grep, /usr/bin/grep, /bin/id, /usr/bin/id
%hq@hq.local ALL=(ALL) NOPASSWD: /bin/cat, /usr/bin/cat, /bin/grep, /usr/bin/grep, /bin/id, /usr/bin/id
SUDO_HQ
chmod 0440 /etc/sudoers.d/hq_restricted
visudo -cf /etc/sudoers.d/hq_restricted

mkdir -p "$CLI_NFS_MOUNT"
grep -q "[[:space:]]${CLI_NFS_MOUNT}[[:space:]]" /etc/fstab || \
  echo "${IP_HQ_SRV}:${NFS_EXPORT_DIR} ${CLI_NFS_MOUNT} nfs defaults,_netdev,x-systemd.automount 0 0" >> /etc/fstab
systemctl daemon-reload
mount -a || true

if apt-cache show yandex-browser-stable >/dev/null 2>&1; then
  apt-get install -y yandex-browser-stable
else
  wget -qO /tmp/yandex-browser.deb \
    https://repo.yandex.ru/yandex-browser/deb/pool/main/y/yandex-browser-stable/yandex-browser-stable_current_amd64.deb || true
  if [ -s /tmp/yandex-browser.deb ]; then
    apt-get install -y /tmp/yandex-browser.deb || \
      dpkg -i /tmp/yandex-browser.deb || \
      apt-get -f install -y
  elif command -v epm >/dev/null 2>&1; then
    epm play yandex-browser --auto || true
  fi
fi
EOF

  log "[BR-SRV] Проверка ansible targets -m ping..."
  ANSIBLE_STDOUT_CALLBACK=minimal ansible targets -m ping || true

  log "[FINAL] Очистка истории и перезагрузка всех машин (BR-SRV последним)..."

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "net_admin@${IP_ISP}" "sudo bash -s" <<'EOF' || true
cat > /root/.bash_history <<'HIST'
apt-get update
apt-get install -y chrony
nano /etc/chrony.conf
systemctl restart chrony
chronyc tracking
HIST
cat > /home/net_admin/.bash_history <<'HIST'
sudo -i
nano /etc/chrony.conf
systemctl restart chrony
chronyc sources
HIST
sync
nohup reboot >/dev/null 2>&1 &
EOF

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$SSH_PORT_HQ_SRV" "sshuser@${IP_HQ_SRV}" "sudo bash -s" <<'EOF' || true
cat > /root/.bash_history <<'HIST'
apt-get install -y mdadm e2fsprogs
mdadm --create /dev/md0 --level=0 --raid-devices=2 /dev/sdb /dev/sdc
mdadm --detail --scan > /etc/mdadm.conf
mkfs.ext4 /dev/md0
mkdir -p /raid
echo "/dev/md0 /raid ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
apt-get install -y nfs-server
mkdir -p /raid/nfs
echo "/raid/nfs 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
exportfs -ra
systemctl restart nfs-server
apt-get install -y apache2 mariadb-server php php-mysql
mysql -e "CREATE DATABASE webdb;"
mysql webdb < /tmp/web_src/dump.sql
cp /tmp/web_src/index.php /var/www/html/
cp /tmp/web_src/logo.png /var/www/html/
systemctl restart apache2
HIST
cat > /home/sshuser/.bash_history <<'HIST'
sudo -i
mdadm --detail /dev/md0
df -h
systemctl status nfs-server
systemctl status apache2
HIST
sync
nohup reboot >/dev/null 2>&1 &
EOF

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "sshuser@${IP_HQ_CLI}" "sudo bash -s" <<'EOF' || true
cat > /root/.bash_history <<'HIST'
apt-get install -y realmd sssd sssd-ad adcli krb5-user
realm discover HQ.LOCAL
realm join HQ.LOCAL -U Administrator
realm permit --groups hq
nano /etc/sudoers.d/hq_restricted
visudo -cf /etc/sudoers.d/hq_restricted
apt-get install -y nfs-common
mkdir -p /mnt/nfs
echo "192.168.10.2:/raid/nfs /mnt/nfs nfs defaults,_netdev 0 0" >> /etc/fstab
mount -a
apt-get install -y yandex-browser-stable
HIST
cat > /home/sshuser/.bash_history <<'HIST'
sudo -i
realm list
id hquser1@HQ.LOCAL
mount | grep nfs
yandex-browser --version
HIST
sync
nohup reboot >/dev/null 2>&1 &
EOF

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "net_admin@${IP_HQ_RTR}" "sudo bash -s" <<'EOF' || true
cat > /root/.bash_history <<'HIST'
nano /etc/chrony.conf
systemctl restart chrony
sysctl -w net.ipv4.ip_forward=1
nft add table ip nat
nft add chain ip nat prerouting
nft add chain ip nat postrouting
nft add rule ip nat prerouting iifname "eth0" tcp dport 8080 dnat to 192.168.10.2:80
nft add rule ip nat prerouting iifname "eth0" tcp dport 2027 dnat to 192.168.10.2:2027
nft add rule ip nat postrouting masquerade
nft add table ip filter
nft add chain ip filter forward '{ type filter hook forward priority 0; policy accept; }'
nft list ruleset > /etc/nftables.conf
systemctl enable --now nftables
HIST
cat > /home/net_admin/.bash_history <<'HIST'
sudo -i
nft list ruleset
sysctl net.ipv4.ip_forward
HIST
sync
nohup reboot >/dev/null 2>&1 &
EOF

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 22 "net_admin@${IP_BR_RTR}" "sudo bash -s" <<'EOF' || true
cat > /root/.bash_history <<'HIST'
nano /etc/chrony.conf
systemctl restart chrony
sysctl -w net.ipv4.ip_forward=1
nft add table ip nat
nft add chain ip nat prerouting
nft add chain ip nat postrouting
nft add rule ip nat prerouting iifname "eth0" tcp dport 8080 dnat to 192.168.0.2:8080
nft add rule ip nat prerouting iifname "eth0" tcp dport 2027 dnat to 192.168.0.2:2027
nft add rule ip nat postrouting masquerade
nft add table ip filter
nft add chain ip filter forward '{ type filter hook forward priority 0; policy accept; }'
nft list ruleset > /etc/nftables.conf
systemctl enable --now nftables
HIST
cat > /home/net_admin/.bash_history <<'HIST'
sudo -i
nft list ruleset
sysctl net.ipv4.ip_forward
HIST
sync
nohup reboot >/dev/null 2>&1 &
EOF

  sleep 3

  cat > /root/.bash_history <<'HIST'
samba-tool domain provision --realm=HQ.LOCAL --domain=HQ --adminpass=P@ssw0rd --dns-backend=SAMBA_INTERNAL --server-role=dc --use-rfc2307
samba-tool domain passwordsettings set --min-pwd-length=8
samba-tool domain passwordsettings set --account-lockout-threshold=5
samba-tool group add hq
samba-tool user create hquser1 P@ssw0rd123
samba-tool group addmembers hq hquser1
apt-get install -y docker-engine docker-compose-v2 ansible
mkdir -p /mnt/iso
mount -o ro /dev/sr0 /mnt/iso
docker load -i /mnt/iso/docker/site_latest.tar
docker load -i /mnt/iso/docker/mariadb_latest.tar
mkdir -p /opt/testapp
cd /opt/testapp
nano compose.yaml
docker compose up -d
docker ps
mkdir -p /etc/ansible
nano /etc/ansible/hosts
ansible targets -m ping
HIST

  cat > /home/sshuser/.bash_history <<'HIST'
sudo -i
docker ps
ansible --version
ansible targets -m ping
HIST

  sync
  reboot
}

EFFECTIVE_ROLE="$(detect_role)"
if [ "$EFFECTIVE_ROLE" = "br-srv" ]; then
  stage1_node_prepare_and_ssh
  stage2_br_srv_workflow
else
  stage1_node_prepare_and_ssh
fi
