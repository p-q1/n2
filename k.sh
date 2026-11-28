#!/bin/bash
# Модуль 2 — Демо 2027 (ALT Linux)
# Порядок запуска: сначала на всех узлах КРОМЕ BR-SRV, в самом конце — на BR-SRV.
# Запуск: source /путь/к/скрипту.sh

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Ошибка: запускайте скрипт через source, например: source $0"
    return 1 2>/dev/null || exit 1
fi

mod2_run() {
    set -u
    trap 'set +u' RETURN

    export DEBIAN_FRONTEND=noninteractive

    if [ "$EUID" -ne 0 ]; then
        echo "Ошибка: требуются права root (выполните sudo -i)."
        return 1
    fi

    local IP_ISP_EXT="172.16.1.1"
    local IP_HQ_RTR="172.16.1.2"
    local IP_BR_RTR="172.16.2.2"

    local IP_HQ_SRV="192.168.100.2"
    local IP_BR_SRV="192.168.0.2"
    local IP_HQ_CLI="192.168.200.2"
    local HQ_CLI_NET="192.168.200.0/28"

    local UPSTREAM_DNS="8.8.8.8"
    local SSH_PORT_HQ_SRV="2027"
    local SSH_PORT_BR_SRV="2027"
    local SSH_PASS="P@ssw0rd"

    local AD_REALM="HQ.LOCAL"
    local AD_ADMIN_PASS="P@ssw0rd"
    local HQ_GROUP="hq"
    local HQ_USER_PASS="P@ssw0rd123"

    local RAID_DEV="/dev/md0"
    local RAID_LEVEL="0"
    local RAID_MOUNT="/raid"
    local NFS_EXPORT_DIR="/raid/nfs"
    local CLI_NFS_MOUNT="/mnt/nfs"

    local UPSTREAM_NTP="pool.ntp.org"
    local ISO_PATH="/root/Additional.iso"
    local ISO_MOUNT="/mnt/iso"

    local INVOCATION_CMD
    INVOCATION_CMD="$(fc -ln -1 2>/dev/null | sed 's/^[[:space:]]*//')"

    log() {
        printf '\n\033[1;32m[%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"
    }

    warn() {
        printf '\033[1;33m[%s] [WARN] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"
    }

    summary_block() {
        local title="$1"
        shift
        printf '\n\033[1;36m%s\033[0m\n' "$title"
        printf '\033[1;37mИТОГИ: %s\033[0m\n' "$*"
    }

    ask() {
        local prompt="$1" default_val="$2" answer=""
        read -r -p "$prompt [$default_val]: " answer
        echo "${answer:-$default_val}"
    }

    save_history_clean() {
        local hist_file="${HISTFILE:-$HOME/.bash_history}"
        history -a 2>/dev/null || true
        history -w "$hist_file" 2>/dev/null || true

        if [ -f "$hist_file" ]; then
            local tmp_hist
            tmp_hist="$(mktemp)"
            grep -vE '(curl|source[[:space:]]+<\(|bash[[:space:]]+<|модуль2|mod2)' "$hist_file" > "$tmp_hist" || true
            if [ -n "$INVOCATION_CMD" ]; then
                grep -vF "$INVOCATION_CMD" "$tmp_hist" > "${tmp_hist}.2" || true
                mv "${tmp_hist}.2" "$tmp_hist"
            fi
            mv "$tmp_hist" "$hist_file"
        fi

        history -c 2>/dev/null || true
        history -r "$hist_file" 2>/dev/null || true
    }

    detect_role() {
        local hn ips
        hn="$(hostname -s 2>/dev/null || hostname)"
        ips="$(hostname -I 2>/dev/null || true)"
        if [[ "${hn,,}" == *br-srv* ]] || [[ " $ips " == *" $IP_BR_SRV "* ]]; then
            echo "br-srv"
        else
            echo "node"
        fi
    }

    prepare_base_node() {
        local hn ssh_user target_port
        hn="$(hostname -s 2>/dev/null || hostname)"
        log "[$hn] Подготовка пакетов, модулей ядра и SSH..."

        apt-get update -y >/dev/null 2>&1 || warn "Ошибка apt-get update на $hn"

        local base_pkgs="openssh-server openssh-clients sshpass python3 sudo nano curl wget ca-certificates chrony iptables iproute2 util-linux"
        apt-get install -y $base_pkgs >/dev/null 2>&1 || warn "Часть базовых пакетов не установилась на $hn"

        modprobe nfs 2>/dev/null || true
        modprobe nfsv3 2>/dev/null || true
        modprobe raid0 2>/dev/null || true
        modprobe raid1 2>/dev/null || true

        if [[ "${hn,,}" == *isp* ]] || [[ "${hn,,}" == *rtr* ]]; then
            ssh_user="net_admin"
        else
            ssh_user="sshuser"
        fi

        if [[ "${hn,,}" == *hq-srv* ]]; then
            target_port="$SSH_PORT_HQ_SRV"
        elif [[ "${hn,,}" == *br-srv* ]]; then
            target_port="$SSH_PORT_BR_SRV"
        else
            target_port="22"
        fi

        if ! id "$ssh_user" >/dev/null 2>&1; then
            useradd -m -s /bin/bash "$ssh_user"
        fi
        echo "${ssh_user}:${SSH_PASS}" | chpasswd

        for grp in wheel sudo; do
            if getent group "$grp" >/dev/null 2>&1; then
                usermod -aG "$grp" "$ssh_user" 2>/dev/null || true
            fi
        done
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ssh_user" > "/etc/sudoers.d/90-${ssh_user}-nopasswd"
        chmod 0440 "/etc/sudoers.d/90-${ssh_user}-nopasswd"

        local sshd_cfg="/etc/openssh/sshd_config"
        [ -f "$sshd_cfg" ] || sshd_cfg="/etc/ssh/sshd_config"

        if [ -f "$sshd_cfg" ]; then
            sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_cfg"
            sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$sshd_cfg"
            if ! grep -Eq "^[[:space:]]*Port[[:space:]]+${target_port}\b" "$sshd_cfg"; then
                if grep -Eq "^[[:space:]]*#?[[:space:]]*Port[[:space:]]+" "$sshd_cfg"; then
                    sed -i "s/^[[:space:]]*#*[[:space:]]*Port[[:space:]].*/Port ${target_port}/" "$sshd_cfg"
                else
                    echo "Port ${target_port}" >> "$sshd_cfg"
                fi
            fi
        fi

        systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    }

    run_br_srv_orchestration() {
        clear
        echo "=== МОДУЛЬ 2: ЦЕНТРАЛЬНАЯ НАСТРОЙКА С BR-SRV ==="

        IP_BR_SRV=$(ask "IP-адрес BR-SRV" "$IP_BR_SRV")
        IP_HQ_SRV=$(ask "IP-адрес HQ-SRV" "$IP_HQ_SRV")
        IP_HQ_CLI=$(ask "IP-адрес HQ-CLI" "$IP_HQ_CLI")
        IP_HQ_RTR=$(ask "IP-адрес HQ-RTR" "$IP_HQ_RTR")
        IP_BR_RTR=$(ask "IP-адрес BR-RTR" "$IP_BR_RTR")
        IP_ISP_EXT=$(ask "IP-адрес ISP" "$IP_ISP_EXT")
        SSH_PORT_HQ_SRV=$(ask "SSH порт HQ-SRV" "$SSH_PORT_HQ_SRV")
        SSH_PORT_BR_SRV=$(ask "SSH порт BR-SRV" "$SSH_PORT_BR_SRV")
        ISO_PATH=$(ask "Путь к Additional.iso" "$ISO_PATH")
        UPSTREAM_NTP=$(ask "Вышестоящий NTP для ISP" "$UPSTREAM_NTP")

        # 1. Монтируем Additional.iso
        mkdir -p "$ISO_MOUNT"
        if [ -f "$ISO_PATH" ]; then
            mountpoint -q "$ISO_MOUNT" || mount -o loop "$ISO_PATH" "$ISO_MOUNT" || warn "Не удалось смонтировать $ISO_PATH"
        elif [ -b /dev/sr0 ]; then
            mountpoint -q "$ISO_MOUNT" || mount -o ro /dev/sr0 "$ISO_MOUNT" || warn "Не удалось смонтировать /dev/sr0"
        fi

        # 2. Раздаём SSH-ключи
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519

        push_key() {
            local u="$1" h="$2" p="$3"
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no -p "$p" "${u}@${h}" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$(cat /root/.ssh/id_ed25519.pub)' ~/.ssh/authorized_keys 2>/dev/null || echo '$(cat /root/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
                >/dev/null 2>&1 || true
        }

        push_key "net_admin" "$IP_ISP_EXT" "22"
        push_key "sshuser" "$IP_HQ_SRV" "$SSH_PORT_HQ_SRV"
        push_key "sshuser" "$IP_HQ_CLI" "22"
        push_key "net_admin" "$IP_HQ_RTR" "22"
        push_key "net_admin" "$IP_BR_RTR" "22"

        # 3. [Задание 1 + Задание 6] Локальная настройка BR-SRV (Samba DC, Docker testapp, chrony)
        log "ПОДЛЮЧЕНИЕ BR-SRV (LOCAL)"
        local samba_ok="no" docker_ok="no" chrony_br_ok="no"

        if command -v samba-tool >/dev/null 2>&1; then
            systemctl enable --now samba 2>/dev/null || true
            sleep 2
            samba-tool domain passwordsettings set --min-pwd-length=8 --complexity=off 2>/dev/null || \
                samba-tool domain passwordsettings set --min-pwd-length=8 2>/dev/null || true
            samba-tool domain passwordsettings set --account-lockout-threshold=5 2>/dev/null || true
            samba-tool group add "$HQ_GROUP" 2>/dev/null || true
            for i in 1 2 3 4 5; do
                samba-tool user create "hquser${i}" "$HQ_USER_PASS" --must-change-at-next-login=no 2>/dev/null || \
                    samba-tool user setpassword "hquser${i}" --newpassword="$HQ_USER_PASS" 2>/dev/null || true
                samba-tool group addmembers "$HQ_GROUP" "hquser${i}" 2>/dev/null || true
            done
            samba-tool group listmembers "$HQ_GROUP" >/dev/null 2>&1 && samba_ok="yes"
        fi

        apt-get install -y docker-engine docker-compose-v2 2>/dev/null || apt-get install -y docker docker-compose 2>/dev/null || true
        systemctl enable --now docker 2>/dev/null || true
        if [ -d "$ISO_MOUNT/docker" ]; then
            for img in site_latest.tar mariadb_latest.tar; do
                [ -f "$ISO_MOUNT/docker/$img" ] && docker load -i "$ISO_MOUNT/docker/$img" >/dev/null 2>&1 || true
            done
        fi
        mkdir -p /opt/testapp
        if [ -f "$ISO_MOUNT/docker/compose.yaml" ]; then
            cp -f "$ISO_MOUNT/docker/compose.yaml" /opt/testapp/compose.yaml
            (cd /opt/testapp && (docker compose up -d || docker-compose up -d)) >/dev/null 2>&1 && docker_ok="yes"
        fi

        local br_chrony="/etc/chrony.conf"
        [ -f /etc/chrony/chrony.conf ] && br_chrony="/etc/chrony/chrony.conf"
        cat > "$br_chrony" <<EOF
server $IP_ISP_EXT iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
        systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
        systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
        (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony) && chrony_br_ok="yes"

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV (LOCAL)" "samba - $samba_ok, docker - $docker_ok, chrony - $chrony_br_ok"

        # 4. [Задание 4] BR-SRV -> ISP (chrony stratum 5)
        log "ПОДЛЮЧЕНИЕ BR-SRV -> ISP"
        local isp_ping="no" isp_chrony="no" isp_ipt="no"
        if ping -c 1 -W 2 "$IP_ISP_EXT" >/dev/null 2>&1; then isp_ping="yes"; fi

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_ISP_EXT" "sudo bash -s" <<EOF >/dev/null 2>&1 && isp_chrony="yes"
set -e
CHRONY_CONF="/etc/chrony.conf"
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF="/etc/chrony/chrony.conf"
cat > "\$CHRONY_CONF" <<CHR
server $UPSTREAM_NTP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
local stratum 5
allow 172.16.0.0/12
allow 192.168.0.0/16
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony
EOF

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_ISP_EXT" \
            "sudo iptables -L >/dev/null 2>&1" >/dev/null 2>&1 && isp_ipt="yes"

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> ISP" "chrony - $isp_chrony, ping - $isp_ping, iptables - $isp_ipt"

        # 5. [Задание 8] BR-SRV -> HQ-RTR (DNAT 8080, 2027)
        log "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-RTR"
        local hqrtr_ping="no" hqrtr_chrony="no" hqrtr_dnat="no"
        if ping -c 1 -W 2 "$IP_HQ_RTR" >/dev/null 2>&1; then hqrtr_ping="yes"; fi

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_HQ_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1 && hqrtr_chrony="yes"
set -e
CHRONY_CONF="/etc/chrony.conf"
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF="/etc/chrony/chrony.conf"
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP_EXT iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony
EOF

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_HQ_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1 && hqrtr_dnat="yes"
set -e
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
iptables -t nat -C PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $IP_HQ_SRV:80 2>/dev/null || \
    iptables -t nat -I PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $IP_HQ_SRV:80
iptables -t nat -C PREROUTING -p tcp --dport 2027 -j DNAT --to-destination $IP_HQ_SRV:$SSH_PORT_HQ_SRV 2>/dev/null || \
    iptables -t nat -I PREROUTING -p tcp --dport 2027 -j DNAT --to-destination $IP_HQ_SRV:$SSH_PORT_HQ_SRV
iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE
iptables -P FORWARD ACCEPT
iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
systemctl enable --now iptables 2>/dev/null || true
EOF

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-RTR" "chrony - $hqrtr_chrony, ping - $hqrtr_ping, dnat - $hqrtr_dnat"

        # 6. [Задание 8] BR-SRV -> BR-RTR (DNAT 8080, 2027)
        log "ПОДЛЮЧЕНИЕ BR-SRV -> BR-RTR"
        local brrtr_ping="no" brrtr_chrony="no" brrtr_dnat="no"
        if ping -c 1 -W 2 "$IP_BR_RTR" >/dev/null 2>&1; then brrtr_ping="yes"; fi

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_BR_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1 && brrtr_chrony="yes"
set -e
CHRONY_CONF="/etc/chrony.conf"
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF="/etc/chrony/chrony.conf"
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP_EXT iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony
EOF

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_BR_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1 && brrtr_dnat="yes"
set -e
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
iptables -t nat -C PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $IP_BR_SRV:8080 2>/dev/null || \
    iptables -t nat -I PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $IP_BR_SRV:8080
iptables -t nat -C PREROUTING -p tcp --dport 2027 -j DNAT --to-destination $IP_BR_SRV:$SSH_PORT_BR_SRV 2>/dev/null || \
    iptables -t nat -I PREROUTING -p tcp --dport 2027 -j DNAT --to-destination $IP_BR_SRV:$SSH_PORT_BR_SRV
iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE
iptables -P FORWARD ACCEPT
iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
systemctl enable --now iptables 2>/dev/null || true
EOF

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> BR-RTR" "chrony - $brrtr_chrony, ping - $brrtr_ping, dnat - $brrtr_dnat"

        # 7. [Задания 2, 3, 7] BR-SRV -> HQ-SRV (RAID 0, NFS, Apache + MariaDB)
        log "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-SRV"
        local hqsrv_ping="no" hqsrv_raid="no" hqsrv_nfs="no" hqsrv_web="no" hqsrv_chrony="no"
        if ping -c 1 -W 2 "$IP_HQ_SRV" >/dev/null 2>&1; then hqsrv_ping="yes"; fi

        if [ -d "$ISO_MOUNT/web" ]; then
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$SSH_PORT_HQ_SRV" \
                -r "$ISO_MOUNT/web" "sshuser@$IP_HQ_SRV:/tmp/web_src" >/dev/null 2>&1 || true
        fi

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo bash -s" <<EOF >/dev/null 2>&1 && hqsrv_chrony="yes"
CHRONY_CONF="/etc/chrony.conf"
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF="/etc/chrony/chrony.conf"
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP_EXT iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
EOF

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo bash -s" <<EOF
set -e
apt-get update -y >/dev/null 2>&1
apt-get install -y mdadm e2fsprogs nfs-server rpcbind >/dev/null 2>&1

modprobe raid0 2>/dev/null || true
DISKS=()
for d in /dev/sdb /dev/sdc /dev/vdb /dev/vdc; do
    if [ -b "\$d" ]; then DISKS+=("\$d"); fi
done
if [ \${#DISKS[@]} -ge 2 ]; then
    if [ ! -b "$RAID_DEV" ]; then
        mdadm --create "$RAID_DEV" --level=$RAID_LEVEL --raid-devices=\${#DISKS[@]} "\${DISKS[@]}" --run --yes >/dev/null
    fi
    mdadm --detail --scan > /etc/mdadm.conf
    if ! blkid "$RAID_DEV" >/dev/null 2>&1; then
        mkfs.ext4 -F "$RAID_DEV" >/dev/null
    fi
    mkdir -p "$RAID_MOUNT"
    grep -q "^$RAID_DEV[[:space:]]" /etc/fstab || echo "$RAID_DEV $RAID_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a
fi
mountpoint -q "$RAID_MOUNT" && echo "RAID_OK=yes" || echo "RAID_OK=no"

modprobe nfs 2>/dev/null || true
modprobe nfsv3 2>/dev/null || true
control rpcbind server 2>/dev/null || true
systemctl enable --now rpcbind >/dev/null 2>&1
systemctl restart rpcbind >/dev/null 2>&1
systemctl enable --now nfs-server >/dev/null 2>&1
mkdir -p "$NFS_EXPORT_DIR" && chmod 777 "$NFS_EXPORT_DIR"
grep -q "^$NFS_EXPORT_DIR[[:space:]]" /etc/exports || \
    echo "$NFS_EXPORT_DIR $HQ_CLI_NET(rw,sync,no_subtree_check,no_root_squash,insecure)" >> /etc/exports
exportfs -ra >/dev/null 2>&1
systemctl restart nfs-server >/dev/null 2>&1
exportfs | grep -q "$NFS_EXPORT_DIR" && echo "NFS_OK=yes" || echo "NFS_OK=no"

apt-get install -y httpd2 mariadb-server 2>/dev/null || apt-get install -y apache2 mariadb-server 2>/dev/null || true
apt-get install -y php8.2 php8.2-mysql 2>/dev/null || apt-get install -y php php-mysql 2>/dev/null || true
systemctl enable --now mariadb >/dev/null 2>&1
systemctl enable --now httpd2 >/dev/null 2>&1 || systemctl enable --now apache2 >/dev/null 2>&1 || true

for _ in {1..15}; do
    mariadb-admin ping >/dev/null 2>&1 && break
    sleep 1
done

if [ -d /tmp/web_src ]; then
    mariadb -e "CREATE DATABASE IF NOT EXISTS webdb;"
    mariadb -e "CREATE USER IF NOT EXISTS 'web'@'%' IDENTIFIED BY 'P@ssw0rd';"
    mariadb -e "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';"
    mariadb -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';"
    mariadb -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';"
    mariadb -e "FLUSH PRIVILEGES;"
    [ -f /tmp/web_src/dump.sql ] && mariadb webdb < /tmp/web_src/dump.sql

    WEB_DIR="/var/www/html"
    [ -d /var/www/httpd2/htdocs ] && WEB_DIR="/var/www/httpd2/htdocs"
    mkdir -p "\$WEB_DIR"
    [ -f /tmp/web_src/index.php ] && cp -f /tmp/web_src/index.php "\$WEB_DIR/"
    [ -f /tmp/web_src/logo.png ] && cp -f /tmp/web_src/logo.png "\$WEB_DIR/"
    [ -f "\$WEB_DIR/index.php" ] && sed -i 's/DB_USER_HERE/web/g; s/DB_PASS_HERE/P@ssw0rd/g; s/DB_NAME_HERE/webdb/g' "\$WEB_DIR/index.php"
    systemctl restart httpd2 >/dev/null 2>&1 || systemctl restart apache2 >/dev/null 2>&1 || true
fi
(systemctl is-active --quiet httpd2 || systemctl is-active --quiet apache2) && mariadb-admin ping >/dev/null 2>&1 && echo "WEB_OK=yes" || echo "WEB_OK=no"
EOF
        local srv_out
        srv_out="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" \
            "mountpoint -q '$RAID_MOUNT' && echo RAID_OK=yes || echo RAID_OK=no; exportfs | grep -q '$NFS_EXPORT_DIR' && echo NFS_OK=yes || echo NFS_OK=no; (systemctl is-active --quiet httpd2 || systemctl is-active --quiet apache2) && echo WEB_OK=yes || echo WEB_OK=no" 2>/dev/null || true)"
        [[ "$srv_out" == *"RAID_OK=yes"* ]] && hqsrv_raid="yes"
        [[ "$srv_out" == *"NFS_OK=yes"* ]] && hqsrv_nfs="yes"
        [[ "$srv_out" == *"WEB_OK=yes"* ]] && hqsrv_web="yes"

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-SRV" "raid - $hqsrv_raid, nfs - $hqsrv_nfs, web - $hqsrv_web, chrony - $hqsrv_chrony, ping - $hqsrv_ping"

        # 8. [Задания 1, 3, 9] BR-SRV -> HQ-CLI
        log "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-CLI"
        local cli_ping="no" cli_ad="no" cli_nfs="no" cli_browser="no" cli_chrony="no"
        if ping -c 1 -W 2 "$IP_HQ_CLI" >/dev/null 2>&1; then cli_ping="yes"; fi

        if [ -f /var/lib/samba/private/krb5.conf ]; then
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 22 \
                /var/lib/samba/private/krb5.conf "sshuser@$IP_HQ_CLI:/tmp/krb5.conf" >/dev/null 2>&1 || true
        fi

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "sshuser@$IP_HQ_CLI" "sudo bash -s" <<EOF >/dev/null 2>&1 || true
set -e
systemctl stop avahi-daemon 2>/dev/null || true
systemctl disable avahi-daemon 2>/dev/null || true

grep -q "$IP_BR_SRV" /etc/hosts || echo "$IP_BR_SRV br-srv.hq.local hq.local" >> /etc/hosts
printf "nameserver %s\nnameserver %s\n" "$IP_BR_SRV" "$UPSTREAM_DNS" > /etc/resolv.conf

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y realmd sssd sssd-ad adcli nfs-clients rpcbind krb5 2>/dev/null || \
    apt-get install -y realmd sssd sssd-ad adcli nfs-clients rpcbind krb5-utils 2>/dev/null || true

if [ -f /tmp/krb5.conf ]; then
    cp -f /tmp/krb5.conf /etc/krb5.conf
    sed -i 's/dns_lookup_kdc = false/dns_lookup_kdc = true/' /etc/krb5.conf 2>/dev/null || true
    sed -i 's/dns_lookup_realm = true/dns_lookup_realm = false/' /etc/krb5.conf 2>/dev/null || true
fi

CHRONY_CONF="/etc/chrony.conf"
[ -f /etc/chrony/chrony.conf ] && CHRONY_CONF="/etc/chrony/chrony.conf"
cat > "\$CHRONY_CONF" <<CHR
server $IP_ISP_EXT iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHR
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

modprobe nfs 2>/dev/null || true
modprobe nfsv3 2>/dev/null || true
systemctl enable --now rpcbind >/dev/null 2>&1
systemctl enable --now nfs-client.target 2>/dev/null || systemctl enable --now nfs-client 2>/dev/null || true

echo "$AD_ADMIN_PASS" | realm join -U Administrator --client-software=sssd "$AD_REALM" 2>/dev/null || true
realm permit --groups "$HQ_GROUP" 2>/dev/null || true

echo "%$HQ_GROUP ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /bin/id" > /etc/sudoers.d/hq_restricted
chmod 0440 /etc/sudoers.d/hq_restricted

mkdir -p "$CLI_NFS_MOUNT"
grep -q "$IP_HQ_SRV:$NFS_EXPORT_DIR" /etc/fstab || \
    echo "$IP_HQ_SRV:$NFS_EXPORT_DIR $CLI_NFS_MOUNT nfs nfsvers=3,proto=tcp,intr,soft,_netdev 0 0" >> /etc/fstab
mount -a 2>/dev/null || true

mkdir -p /etc/skel/.config/gtk-3.0
echo "nfs://${IP_HQ_SRV}${NFS_EXPORT_DIR} NFS_Share" > /etc/skel/.config/gtk-3.0/bookmarks
chmod 0644 /etc/skel/.config/gtk-3.0/bookmarks
for uhome in /home/*; do
    if [ -d "\$uhome" ]; then
        uname=\$(basename "\$uhome")
        mkdir -p "\$uhome/.config/gtk-3.0"
        echo "nfs://${IP_HQ_SRV}${NFS_EXPORT_DIR} NFS_Share" > "\$uhome/.config/gtk-3.0/bookmarks"
        chown -R "\$uname:\$uname" "\$uhome/.config/gtk-3.0"
        chmod 0644 "\$uhome/.config/gtk-3.0/bookmarks"
    fi
done

apt-get install -y yandex-browser-stable 2>/dev/null || true
EOF
        local cli_out
        cli_out="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "sshuser@$IP_HQ_CLI" \
            "realm list 2>/dev/null | grep -qi 'hq.local' && echo AD_OK=yes || echo AD_OK=no; mountpoint -q '$CLI_NFS_MOUNT' && echo NFS_OK=yes || echo NFS_OK=no; (command -v yandex-browser-stable >/dev/null 2>&1 || rpm -q yandex-browser-stable >/dev/null 2>&1) && echo BR_OK=yes || echo BR_OK=no; (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony) && echo CH_OK=yes || echo CH_OK=no" 2>/dev/null || true)"
        [[ "$cli_out" == *"AD_OK=yes"* ]] && cli_ad="yes"
        [[ "$cli_out" == *"NFS_OK=yes"* ]] && cli_nfs="yes"
        [[ "$cli_out" == *"BR_OK=yes"* ]] && cli_browser="yes"
        [[ "$cli_out" == *"CH_OK=yes"* ]] && cli_chrony="yes"

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-CLI" "domain - $cli_ad, nfs - $cli_nfs, browser - $cli_browser, chrony - $cli_chrony, ping - $cli_ping"

        # 9. [Задание 5] Ansible на BR-SRV
        log "ПОДЛЮЧЕНИЕ BR-SRV -> ANSIBLE (/etc/ansible)"
        apt-get install -y ansible >/dev/null 2>&1 || true
        mkdir -p /etc/ansible
        cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = /usr/bin/python3
deprecation_warnings = False
command_warnings = False
timeout = 15
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
        local ans_ok="no"
        ansible targets -m ping && ans_ok="yes"
        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> ANSIBLE" "inventory - yes, ping - $ans_ok"

        # 10. Очистка истории и перезагрузка всех машин
        log "Сохранение истории, очистка строки запуска и перезагрузка всех машин..."

        local remote_nodes=(
            "net_admin@$IP_ISP_EXT:22"
            "sshuser@$IP_HQ_SRV:$SSH_PORT_HQ_SRV"
            "sshuser@$IP_HQ_CLI:22"
            "net_admin@$IP_HQ_RTR:22"
            "net_admin@$IP_BR_RTR:22"
        )

        for entry in "${remote_nodes[@]}"; do
            local u_h="${entry%:*}" p="${entry#*:}"
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$p" "$u_h" \
                "history -a 2>/dev/null || true; history -w 2>/dev/null || true; sudo setsid sh -c 'sleep 2; /sbin/reboot -f || systemctl reboot -i' >/dev/null 2>&1 < /dev/null &" \
                2>/dev/null || true
            sleep 1
        done

        sleep 4
        save_history_clean
        sync
        reboot
    }

    local ROLE
    ROLE="$(detect_role)"

    if [ "$ROLE" = "br-srv" ]; then
        prepare_base_node
        run_br_srv_orchestration
    else
        prepare_base_node
        save_history_clean
        log "Базовая подготовка узла завершена. Ожидайте запуск скрипта на BR-SRV."
    fi
}

mod2_run
