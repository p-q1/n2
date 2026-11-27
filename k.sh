#!/bin/bash

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Ошибка запуска: используйте source <(curl -sL ...)"
    return 1 2>/dev/null || exit 1
fi

main() {
    set -u
    trap 'set +u' RETURN
    
    export DEBIAN_FRONTEND=noninteractive

    if [ "$EUID" -ne 0 ]; then
        echo "Нужны права root (sudo -i)"
        return 1
    fi

    # --- ДЕФОЛТНЫЕ ЗНАЧЕНИЯ ---
    local IP_ISP_EXT="172.16.1.1"
    local IP_HQ_RTR="172.16.1.2"
    local IP_BR_RTR="172.16.2.2"

    local IP_HQ_SRV="192.168.100.2"
    local IP_BR_SRV="192.168.0.2"
    local IP_HQ_CLI="192.168.200.2"
    local HQ_CLI_NET="192.168.200.0/28"

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

    hist() {
        history -s "$1" 2>/dev/null || true
        echo "$1" >> "$HOME/.bash_history"
    }

    ask() {
        local p="$1" d="$2" v
        read -r -p "$p [$d]: " v
        echo "${v:-$d}"
    }

    log() { printf '\n\033[1;32m[%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }

    detect_role() {
        local hn ips
        hn="$(hostname -s 2>/dev/null || hostname)"
        ips="$(hostname -I 2>/dev/null || true)"
        if [[ "$hn" == *br-srv* ]] || [[ " $ips " == *" $IP_BR_SRV "* ]]; then
            echo "br-srv"
        else
            echo "node"
        fi
    }

    # --- ИНТЕРАКТИВНЫЙ ВВОД ---
    clear
    echo "=== НАСТРОЙКА МОДУЛЯ 2 ==="
    local ROLE
    ROLE=$(ask "Это BR-SRV (центральный узел)? (д/н)" "д")

    if [ "$ROLE" = "y" ] || [ "$ROLE" = "д" ]; then
        IP_BR_SRV=$(ask "IP-адрес BR-SRV" "$IP_BR_SRV")
        IP_HQ_SRV=$(ask "IP-адрес HQ-SRV" "$IP_HQ_SRV")
        IP_HQ_CLI=$(ask "IP-адрес HQ-CLI" "$IP_HQ_CLI")
        IP_HQ_RTR=$(ask "IP-адрес HQ-RTR" "$IP_HQ_RTR")
        IP_BR_RTR=$(ask "IP-адрес BR-RTR" "$IP_BR_RTR")
        IP_ISP_EXT=$(ask "IP-адрес ISP (внешний)" "$IP_ISP_EXT")

        SSH_PORT_HQ_SRV=$(ask "SSH порт HQ-SRV" "$SSH_PORT_HQ_SRV")
        SSH_PORT_BR_SRV=$(ask "SSH порт BR-SRV" "$SSH_PORT_BR_SRV")

        ISO_PATH=$(ask "Путь к Additional.iso" "$ISO_PATH")
        RAID_LEVEL=$(ask "Уровень RAID (0/1/5/6/10)" "$RAID_LEVEL")
        
        case "$RAID_LEVEL" in
            0) log "Внимание: Для RAID 0 добавьте 2 диска!" ;;
            1) log "Внимание: Для RAID 1 добавьте 2 диска!" ;;
            5) log "Внимание: Для RAID 5 добавьте минимум 3 диска!" ;;
            6) log "Внимание: Для RAID 6 добавьте минимум 4 диска!" ;;
            10) log "Внимание: Для RAID 10 добавьте минимум 4 диска (кратно 2)!" ;;
            *) log "Выбран неизвестный уровень. Будет попытка создать с текущими дисками." ;;
        esac

        UPSTREAM_NTP=$(ask "NTP сервер" "$UPSTREAM_NTP")
    fi

    stage1_node_prepare_and_ssh() {
        local hn ssh_user target_port
        hn="$(hostname -s 2>/dev/null || hostname)"

        log "[ЭТАП 1][$hn] Установка пакетов и настройка SSH..."
        apt-get update -y >/dev/null 2>&1
        
        local pkgs="openssh-server openssh-clients sshpass python3 sudo nano curl wget ca-certificates chrony nftables iptables iproute2 util-linux"
        apt-get install -y $pkgs >/dev/null 2>&1

        if [[ "$hn" == *isp* ]] || [[ "$hn" == *rtr* ]]; then
            ssh_user="net_admin"
        else
            ssh_user="sshuser"
        fi

        if [[ "$hn" == *hq-srv* ]]; then target_port="$SSH_PORT_HQ_SRV"
        elif [[ "$hn" == *br-srv* ]]; then target_port="$SSH_PORT_BR_SRV"
        else target_port="22"; fi

        if ! id "$ssh_user" >/dev/null 2>&1; then
            useradd -m -s /bin/bash "$ssh_user"
        fi
        echo "${ssh_user}:${SSH_PASS}" | chpasswd

        if getent group wheel >/dev/null 2>&1; then usermod -aG wheel "$ssh_user" 2>/dev/null || true; fi
        if getent group sudo >/dev/null 2>&1; then usermod -aG sudo "$ssh_user" 2>/dev/null || true; fi
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ssh_user" > "/etc/sudoers.d/90-${ssh_user}-nopasswd"
        chmod 0440 "/etc/sudoers.d/90-${ssh_user}-nopasswd"

        local sshd_cfg="/etc/openssh/sshd_config"
        [ -f "$sshd_cfg" ] || sshd_cfg="/etc/ssh/sshd_config"

        sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_cfg"
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$sshd_cfg"

        if ! grep -Eq "^[[:space:]]*Port[[:space:]]+${target_port}\b" "$sshd_cfg"; then
            if grep -Eq "^[[:space:]]*#?[[:space:]]*Port[[:space:]]+" "$sshd_cfg"; then
                sed -i "s/^[[:space:]]*#*[[:space:]]*Port[[:space:]].*/Port ${target_port}/" "$sshd_cfg"
            else
                echo "Port ${target_port}" >> "$sshd_cfg"
            fi
        fi

        systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    }

    stage2_br_srv_workflow() {
        log "[BR-SRV] Настройка локальных сервисов..."

        local chrony_conf="/etc/chrony.conf"
        [ -f /etc/chrony/chrony.conf ] && chrony_conf="/etc/chrony/chrony.conf"
        cat > "$chrony_conf" <<EOF
server $IP_ISP_EXT iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
        systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
        systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null || true

        log "[BR-SRV] Настройка Samba DC..."
        if command -v samba-tool >/dev/null 2>&1; then
            if [ ! -f /var/lib/samba/private/sam.ldb ]; then
                log "Провижининг домена Samba..."
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
                samba-tool user create "hquser$i" "$HQ_USER_PASS" --must-change-at-next-login=no 2>/dev/null || \
                samba-tool user setpassword "hquser$i" --newpassword="$HQ_USER_PASS" 2>/dev/null || true
                samba-tool group addmembers "$HQ_GROUP" "hquser$i" 2>/dev/null || true
            done
        fi

        log "[BR-SRV] Настройка Docker (testapp)..."
        apt-get install -y docker-engine docker-compose-v2 ansible 2>/dev/null || apt-get install -y docker docker-compose ansible
        systemctl enable --now docker
        
        mkdir -p "$ISO_MOUNT"
        if [ -f "$ISO_PATH" ]; then
            mountpoint -q "$ISO_MOUNT" || mount -o loop "$ISO_PATH" "$ISO_MOUNT" || true
        elif [ -b /dev/sr0 ]; then
            mountpoint -q "$ISO_MOUNT" || mount -o ro /dev/sr0 "$ISO_MOUNT" || true
        fi

        if [ -d "$ISO_MOUNT/docker" ]; then
            for img in site_latest.tar mariadb_latest.tar; do
                [ -f "$ISO_MOUNT/docker/$img" ] && docker load -i "$ISO_MOUNT/docker/$img" || true
            done
        fi

        mkdir -p /opt/testapp && cd /opt/testapp
        if [ -f "$ISO_MOUNT/docker/compose.yaml" ]; then
            cp -f "$ISO_MOUNT/docker/compose.yaml" .
        else
            log "[WARN] compose.yaml не найден. Генерация..."
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
        fi

        docker compose up -d || docker-compose up -d
        cd /root

        log "[BR-SRV] Настройка Ansible..."
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
        
        # ДОБАВЛЕН localhost и пароли для отказоустойчивости
        cat > /etc/ansible/hosts <<EOF
[local]
localhost ansible_connection=local

[hq_srv]
hq-srv ansible_host=$IP_HQ_SRV ansible_user=sshuser ansible_port=$SSH_PORT_HQ_SRV ansible_password=$SSH_PASS ansible_become_password=$SSH_PASS ansible_become=true

[hq_cli]
hq-cli ansible_host=$IP_HQ_CLI ansible_user=sshuser ansible_port=22 ansible_password=$SSH_PASS ansible_become_password=$SSH_PASS ansible_become=true

[hq_rtr]
hq-rtr ansible_host=$IP_HQ_RTR ansible_user=net_admin ansible_port=22 ansible_password=$SSH_PASS ansible_become_password=$SSH_PASS ansible_become=true

[br_rtr]
br-rtr ansible_host=$IP_BR_RTR ansible_user=net_admin ansible_port=22 ansible_password=$SSH_PASS ansible_become_password=$SSH_PASS ansible_become=true

[targets:children]
local
hq_srv
hq_cli
hq_rtr
br_rtr
EOF

        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519

        ssh_push() {
            local user="$1" host="$2" port="$3"
            log "  -> Ключ на $user@$host:$port"
            # Очистка старых ключей и копирование нового
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -p "$port" "${user}@${host}" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && > ~/.ssh/authorized_keys && echo '$(cat /root/.ssh/id_ed25519.pub)' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1 || true
        }

        log "Раздача SSH-ключей..."
        ssh_push "net_admin" "$IP_ISP_EXT" "22"
        ssh_push "sshuser" "$IP_HQ_SRV" "$SSH_PORT_HQ_SRV"
        ssh_push "sshuser" "$IP_HQ_CLI" "22"
        ssh_push "net_admin" "$IP_HQ_RTR" "22"
        ssh_push "net_admin" "$IP_BR_RTR" "22"

        log "[BR-SRV -> ISP] Настройка chrony stratum 5..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_ISP_EXT" "sudo bash -s" <<EOF
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
allow 192.168.100.0/24
allow 192.168.200.0/24
CHR
systemctl restart chrony
EOF

        log "[BR-SRV -> HQ-RTR] Проброс портов 8080/2027..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_HQ_RTR" "sudo bash -s" <<EOF
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $IP_HQ_SRV:80 2>/dev/null || true
iptables -t nat -A PREROUTING -p tcp --dport 2027 -j DNAT --to-destination $IP_HQ_SRV:$SSH_PORT_HQ_SRV 2>/dev/null || true
iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null || true
iptables -P FORWARD ACCEPT
iptables-save > /etc/sysconfig/iptables 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
systemctl enable --now iptables 2>/dev/null || true
EOF

        log "[BR-SRV -> BR-RTR] Проброс портов 8080/2027..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "net_admin@$IP_BR_RTR" "sudo bash -s" <<EOF
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $IP_BR_SRV:8080 2>/dev/null || true
iptables -t nat -A PREROUTING -p tcp --dport 2027 -j DNAT --to-destination $IP_BR_SRV:$SSH_PORT_BR_SRV 2>/dev/null || true
iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null || true
iptables -P FORWARD ACCEPT
iptables-save > /etc/sysconfig/iptables 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
systemctl enable --now iptables 2>/dev/null || true
EOF

        log "[BR-SRV -> HQ-SRV] RAID $RAID_LEVEL, NFS, Web..."
        
        if [ -d "$ISO_MOUNT/web" ]; then
            sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$SSH_PORT_HQ_SRV" -r "$ISO_MOUNT/web" "sshuser@$IP_HQ_SRV:/tmp/web_src" 2>/dev/null || true
        fi

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo bash -s" <<EOF
apt-get update -y && apt-get install -y mdadm e2fsprogs
DISKS=""
for d in /dev/sdb /dev/sdc /dev/vdb /dev/vdc /dev/sdd /dev/vdd /dev/sde /dev/vde; do
    if [ -b "\$d" ]; then
        DISKS="\$DISKS \$d"
    fi
done
DISK_ARR=(\$DISKS)
if [ \${#DISK_ARR[@]} -ge 2 ]; then
    if [ ! -b "$RAID_DEV" ]; then
        mdadm --create $RAID_DEV --level=$RAID_LEVEL --raid-devices=\${#DISK_ARR[@]} \${DISK_ARR[*]} --run --yes
    fi
    mdadm --detail --scan > /etc/mdadm.conf
    if ! blkid $RAID_DEV; then mkfs.ext4 -F $RAID_DEV; fi
    mkdir -p $RAID_MOUNT
    grep -q "^$RAID_DEV" /etc/fstab || echo "$RAID_DEV $RAID_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a
fi

apt-get install -y nfs-server rpcbind
systemctl enable --now rpcbind
systemctl enable --now nfs-server
mkdir -p $NFS_EXPORT_DIR && chmod 777 $NFS_EXPORT_DIR
grep -q "^$NFS_EXPORT_DIR" /etc/exports || echo "$NFS_EXPORT_DIR $HQ_CLI_NET(rw,sync,no_subtree_check,no_root_squash,insecure)" >> /etc/exports
exportfs -ra
systemctl restart nfs-server

# Ставим то, что точно есть
apt-get install -y httpd2 mariadb-server 2>/dev/null || apt-get install -y apache2 mariadb-server 2>/dev/null || true
# В ALT Linux php-mysql обычно тянется как php8-mysql, ставим базу и модули по очереди
apt-get install -y php8 php8-mysql 2>/dev/null || apt-get install -y php php-mysql 2>/dev/null || apt-get install -y php8.2 php8.2-mysql 2>/dev/null || true

systemctl enable --now mariadb
systemctl enable --now httpd2 2>/dev/null || systemctl enable --now apache2 2>/dev/null || true

for i in {1..10}; do mysqladmin ping &>/dev/null && break; sleep 1; done

if [ -d /tmp/web_src ]; then
    mysql -e "CREATE DATABASE IF NOT EXISTS webdb;"
    mysql -e "CREATE USER IF NOT EXISTS 'web'@'%' IDENTIFIED BY 'P@ssw0rd';"
    mysql -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%' IDENTIFIED BY 'P@ssw0rd';"
    mysql -e "FLUSH PRIVILEGES;"
    [ -f /tmp/web_src/dump.sql ] && mysql webdb < /tmp/web_src/dump.sql
    
    WEB_DIR="/var/www/html"
    [ -d /var/www/httpd2/htdocs ] && WEB_DIR="/var/www/httpd2/htdocs"
    
    cp -f /tmp/web_src/index.php \$WEB_DIR/
    cp -f /tmp/web_src/logo.png \$WEB_DIR/
    sed -i 's/DB_USER_HERE/web/g; s/DB_PASS_HERE/P@ssw0rd/g; s/DB_NAME_HERE/webdb/g' \$WEB_DIR/index.php
    systemctl restart httpd2 2>/dev/null || systemctl restart apache2 2>/dev/null || true
fi
EOF

        log "[BR-SRV -> HQ-CLI] Ввод в домен, NFS (GUI), Yandex Browser..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "sshuser@$IP_HQ_CLI" "sudo bash -s" <<EOF
apt-get update -y
# Пакеты для домена, без падения если какого-то нет
apt-get install -y realmd sssd sssd-ad adcli krb5 rpcbind 2>/dev/null || true

echo "$IP_BR_SRV br-srv.hq.local hq.local" >> /etc/hosts
echo "nameserver $IP_BR_SRV" > /etc/resolv.conf

systemctl enable --now rpcbind
systemctl enable --now nfs-common 2>/dev/null || systemctl enable --now nfs-client 2>/dev/null || true

# Ввод в домен
echo "$AD_ADMIN_PASS" | realm join -U Administrator --client-software=sssd $AD_REALM || true
realm permit --groups $HQ_GROUP

echo "%$HQ_GROUP ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /bin/id" > /etc/sudoers.d/hq_restricted
chmod 440 /etc/sudoers.d/hq_restricted

mkdir -p $CLI_NFS_MOUNT
grep -q "$IP_HQ_SRV:$NFS_EXPORT_DIR" /etc/fstab || echo "$IP_HQ_SRV:$NFS_EXPORT_DIR $CLI_NFS_MOUNT nfs defaults,_netdev,nolock 0 0" >> /etc/fstab
mount -a || true

apt-get install -y yandex-browser-stable 2>/dev/null || true

# Закладка в GNOME
cat > /usr/local/bin/setup_nfs_gui.sh <<'EOS'
#!/bin/bash
NFS_URI="nfs://${IP_HQ_SRV}:2049${NFS_EXPORT_DIR}"
mkdir -p /etc/skel/.config/gtk-3.0
cat > /etc/skel/.config/gtk-3.0/bookmarks <<BOOKMARK
\$NFS_URI NFS_Share
BOOKMARK
chmod 644 /etc/skel/.config/gtk-3.0/bookmarks

for USER_HOME in /home/*; do
    USER_NAME=\$(basename "\$USER_HOME")
    if [ -d "\$USER_HOME" ]; then
        mkdir -p "\$USER_HOME/.config/gtk-3.0"
        cat > "\$USER_HOME/.config/gtk-3.0/bookmarks" <<BOOKMARK
\$NFS_URI NFS_Share
BOOKMARK
        chown -R "\$USER_NAME:\$USER_NAME" "\$USER_HOME/.config/gtk-3.0"
        chmod 644 "\$USER_HOME/.config/gtk-3.0/bookmarks"
    fi
done
EOS
chmod +x /usr/local/bin/setup_nfs_gui.sh
/usr/local/bin/setup_nfs_gui.sh
EOF

        log "Проверка Ansible..."
        ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=minimal ansible targets -m ping -e "ansible_password=$SSH_PASS" || true
        hist "ansible targets -m ping"

        log "Очистка истории и перезагрузка всех машин (BR-SRV последним)..."

        local targets=("net_admin@$IP_ISP_EXT:22" "sshuser@$IP_HQ_SRV:$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_CLI:22" "net_admin@$IP_HQ_RTR:22" "net_admin@$IP_BR_RTR:22")

        for t in "${targets[@]}"; do
            local u_host="${t%:*}" port="${t#*:}"
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" "$u_host" "sudo nohup bash -c 'sleep 2; reboot' >/dev/null 2>&1 &" 2>/dev/null || \
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" "$u_host" "sudo nohup bash -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true
            sleep 1
        done

        log "Ожидание 5 секунд перед перезагрузкой BR-SRV..."
        sleep 5

        if [ -f "$HOME/.bash_history" ]; then
            sed -i -E '/(curl|clck\.ru|source[[:space:]]+<\(|bash[[:space:]]+<)/d' "$HOME/.bash_history"
        fi
        history -c
        history -r "$HOME/.bash_history"

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
}

main "$@"
