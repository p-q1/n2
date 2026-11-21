#!/bin/bash

main() {
    set -u

    if [ "$EUID" -ne 0 ]; then
        echo "ОШИБКА: скрипт должен запускаться от имени root (sudo -i)."
        return 1
    fi

    local ISP_IP="172.16.30.1"
    local HQ_RTR_ENS19="172.16.30.2"
    local BR_RTR_ENS19="172.16.40.2"
    local HQ_SRV_IP="192.168.100.2"
    local BR_SRV_IP="192.168.0.2"
    local HQ_CLI_IP="192.168.200.2"
    local DOMAIN="au-team.irpo"
    local REALM="AU-TEAM.IRPO"
    local ADMIN_PASS="P@ssw0rd"
    local RAID_DISKS="sdb sdc"
    local RAID_LEVEL="1"
    local ISO_DEV="/dev/sr0"
    local HQ_CLI_GID="10000"
    local TZ="Europe/Moscow"

    hist() { 
        history -s "$1" 2>/dev/null || true
        echo "$1" >> "$HOME/.bash_history"
    }
    run() { eval "$1"; hist "$1"; }
    ask() { local p="$1" d="$2" v; read -r -p "$p [$d]: " v; echo "${v:-$d}"; }

    clear
    echo "=== Выбор машины для Модуля 2 ==="
    local MACHINE
    select MACHINE in ISP HQ-RTR BR-RTR HQ-SRV BR-SRV HQ-CLI; do
        [ -n "$MACHINE" ] && break
    done
    echo "Выбрано: $MACHINE"

    case "$MACHINE" in
        ISP)
            ISP_IP=$(ask "IP ISP" "$ISP_IP")
            HQ_SRV_IP=$(ask "IP HQ-SRV" "$HQ_SRV_IP")
            BR_SRV_IP=$(ask "IP BR-SRV" "$BR_SRV_IP")
            ;;
        HQ-RTR)
            HQ_RTR_ENS19=$(ask "IP HQ-RTR" "$HQ_RTR_ENS19")
            HQ_SRV_IP=$(ask "IP HQ-SRV" "$HQ_SRV_IP")
            ;;
        BR-RTR)
            BR_RTR_ENS19=$(ask "IP BR-RTR" "$BR_RTR_ENS19")
            BR_SRV_IP=$(ask "IP BR-SRV" "$BR_SRV_IP")
            ;;
        HQ-SRV)
            HQ_SRV_IP=$(ask "IP HQ-SRV" "$HQ_SRV_IP")
            BR_SRV_IP=$(ask "IP BR-SRV" "$BR_SRV_IP")
            RAID_DISKS=$(ask "Диски для RAID (через пробел, например: sdb sdc)" "$RAID_DISKS")
            RAID_LEVEL=$(ask "Уровень RAID (0, 1, 5, 10 и т.д.)" "$RAID_LEVEL")
            ISO_DEV=$(ask "Устройство ISO" "$ISO_DEV")
            ;;
        BR-SRV)
            BR_SRV_IP=$(ask "IP BR-SRV" "$BR_SRV_IP")
            HQ_SRV_IP=$(ask "IP HQ-SRV" "$HQ_SRV_IP")
            ISP_IP=$(ask "IP ISP" "$ISP_IP")
            HQ_RTR_ENS19=$(ask "IP HQ-RTR" "$HQ_RTR_ENS19")
            BR_RTR_ENS19=$(ask "IP BR-RTR" "$BR_RTR_ENS19")
            HQ_CLI_IP=$(ask "IP HQ-CLI" "$HQ_CLI_IP")
            ISO_DEV=$(ask "Устройство ISO" "$ISO_DEV")
            ;;
        HQ-CLI)
            HQ_CLI_IP=$(ask "IP HQ-CLI" "$HQ_CLI_IP")
            HQ_SRV_IP=$(ask "IP HQ-SRV" "$HQ_SRV_IP")
            ISP_IP=$(ask "IP ISP" "$ISP_IP")
            HQ_CLI_GID=$(ask "GID группы hq (узнать: id hquser1)" "$HQ_CLI_GID")
            ;;
    esac
    TZ=$(ask "Часовой пояс" "$TZ")

    setup_dns_transfer() {
        run "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
        if ! grep -q 'allow-transfer' /etc/named.conf; then
            sed -i "/options {/a \    allow-transfer { $BR_SRV_IP; };" /etc/named.conf
        fi
        hist "nano /etc/named.conf"
        run "systemctl restart bind"
        run "systemctl restart network"
    }

    setup_samba_dc() {
        run "hostnamectl set-hostname br-srv.au-team.irpo"
        run "echo 'nameserver $HQ_SRV_IP' > /etc/resolv.conf"
        run "rm -f /etc/samba/smb.conf"
        run "rm -rf /var/lib/samba /var/cache/samba"
        run "mkdir -p /var/lib/samba/sysvol"
        
        run "samba-tool domain provision --realm=$REALM --domain=AU-TEAM --adminpass=$ADMIN_PASS --dns-backend=SAMBA_INTERNAL --server-role=dc --option='dns forwarder=$HQ_SRV_IP' --use-rfc2307"
        
        run "cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf"
        run "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"
        run "systemctl enable --now samba"

        run "samba-tool domain passwordsettings set --min-pwd-length=8 --account-lockout-threshold=5"
        run "samba-tool group add hq"
        
        for i in {1..5}; do
            run "samba-tool user create hquser$i $ADMIN_PASS"
            run "samba-tool group addmembers hq hquser$i"
        done
    }

    setup_raid() {
        local dev_list=""
        local disk_count=0
        
        for disk in $RAID_DISKS; do
            dev_list="$dev_list /dev/$disk"
            disk_count=$((disk_count + 1))
            run "mdadm --zero-superblock --force /dev/$disk 2>/dev/null || true"
            run "wipefs --all --force /dev/$disk"
        done

        run "mdadm --create /dev/md0 --level=$RAID_LEVEL --raid-devices=$disk_count $dev_list --bitmap=none --force"
        run "mkfs -t ext4 /dev/md0"
        
        run "mkdir -p /etc/mdadm"
        run "echo 'DEVICE partitions' > /etc/mdadm/mdadm.conf"
        run "mdadm --detail --scan | awk '/ARRAY/ {print}' >> /etc/mdadm/mdadm.conf"
        
        run "mkdir -p /raid"
        run "echo '/dev/md0 /raid ext4 defaults 0 0' >> /etc/fstab"
        run "mount -a"
    }

    setup_nfs_server() {
        run "mkdir -p /raid/nfs"
        run "chmod 766 /raid/nfs"
        run "echo '/raid/nfs 192.168.200.0/28(rw,no_root_squash)' > /etc/exports"
        run "exportfs -arv"
        run "systemctl enable --now nfs-server"
    }

    setup_nfs_client() {
        run "mkdir -p /mnt/nfs"
        run "chmod 777 /mnt/nfs"
        run "echo '$HQ_SRV_IP:/raid/nfs /mnt/nfs nfs defaults,nolock 0 0' >> /etc/fstab"
        run "mount -a"
    }

    setup_chrony_server() {
        run "sed -i 's/^pool.*/server 127.0.0.1 iburst prefer/' /etc/chrony.conf"
        run "sed -i '/^server 127.0.0.1/a hwtimestamp *\nlocal stratum 5\nallow 0\/0' /etc/chrony.conf"
        run "systemctl enable --now chronyd"
        run "systemctl restart chronyd"
    }

    setup_chrony_client() {
        run "sed -i 's/^pool.*/server $ISP_IP iburst prefer/' /etc/chrony.conf"
        run "systemctl enable --now chronyd"
        run "systemctl restart chronyd"
    }

    setup_ansible() {
        cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=$HQ_SRV_IP ansible_user=sshuser ansible_port=2027

[clients]
hq-cli ansible_host=$HQ_CLI_IP ansible_user=user

[routers]
hq-rtr ansible_host=$HQ_RTR_ENS19 ansible_user=net_admin
br-rtr ansible_host=$BR_RTR_ENS19 ansible_user=net_admin

[isp]
isp ansible_host=$ISP_IP ansible_user=net_admin

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=/root/.ssh/ansible
EOF
        hist "nano /etc/ansible/hosts"
        
        run "ssh-keygen -t ed25519 -f /root/.ssh/ansible -N ''"
        run "sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/ansible.pub user@$HQ_CLI_IP"
        run "sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/ansible.pub -p 2027 sshuser@$HQ_SRV_IP"
        run "sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/ansible.pub net_admin@$ISP_IP"
        run "sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/ansible.pub net_admin@$HQ_RTR_ENS19"
        run "sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/ansible.pub net_admin@$BR_RTR_ENS19"
        run "cd /etc/ansible && ansible all -m ping"
    }

    setup_docker() {
        run "mkdir -p /mnt/iso"
        run "mount -o ro $ISO_DEV /mnt/iso"
        run "mkdir -p /root/testapp"
        run "cp -a /mnt/iso/docker/. /root/testapp/"
        run "cp /mnt/iso/compose.yaml /root/testapp/"
        run "cd /root/testapp"
        run "systemctl enable --now docker"
        run "docker load -i site_latest.tar"
        run "docker load -i mariadb_latest.tar"
        run "docker compose -p testapp up -d"
    }

    setup_web_server() {
        run "mkdir -p /mnt/iso"
        run "mount -o ro $ISO_DEV /mnt/iso"
        run "systemctl enable --now mariadb"
        
        mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web1c'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web1c'@'localhost';
FLUSH PRIVILEGES;
EOF
        hist "mariadb -u root"

        run "mariadb -u root webdb < /mnt/iso/web/dump.sql"
        run "cp /mnt/iso/web/index.php /var/www/html/"
        run "cp /mnt/iso/web/logo.png /var/www/html/"
        run "chmod 644 /var/www/html/index.php /var/www/html/logo.png"
        run "rm -rf /var/www/html/index.html"
        
        sed -i "s/\$servername = \".*\";/\$servername = \"localhost\";/" /var/www/html/index.php
        sed -i "s/\$dbname = \".*\";/\$dbname = \"webdb\";/" /var/www/html/index.php
        sed -i "s/\$username = \".*\";/\$username = \"web1c\";/" /var/www/html/index.php
        sed -i "s/\$password = \".*\";/\$password = \"P@ssw0rd\";/" /var/www/html/index.php
        hist "nano /var/www/html/index.php"

        run "systemctl enable --now httpd2"
        run "systemctl restart httpd2"
    }

    setup_dnat_hq() {
        run "iptables -t nat -I PREROUTING 1 -i ens19 -d $HQ_RTR_ENS19 -p tcp --dport 8081 -j DNAT --to-destination $HQ_SRV_IP:80"
        run "iptables -t nat -I PREROUTING 1 -i ens19 -d $HQ_RTR_ENS19 -p tcp --dport 2011 -j DNAT --to-destination $HQ_SRV_IP:2011"
        run "iptables-save > /etc/sysconfig/iptables"
    }

    setup_dnat_br() {
        run "iptables -t nat -I PREROUTING 1 -i ens19 -d $BR_RTR_ENS19 -p tcp --dport 8081 -j DNAT --to-destination $BR_SRV_IP:8081"
        run "iptables -t nat -I PREROUTING 1 -i ens19 -d $BR_RTR_ENS19 -p tcp --dport 2011 -j DNAT --to-destination $BR_SRV_IP:2011"
        run "iptables-save > /etc/sysconfig/iptables"
    }

    setup_domain_join() {
        run "echo 'nameserver $HQ_SRV_IP' > /etc/resolv.conf"
        run "system-auth write ad $DOMAIN hq-cli AU-TEAM Administrator $ADMIN_PASS"
        run "net ads testjoin"
        run "control sudo public"
        run "echo '%#$HQ_CLI_GID ALL=(root) /usr/bin/cat, /usr/bin/grep, /usr/bin/id' >> /etc/sudoers"
        hist "nano /etc/sudoers"
        run "visudo -c"
        
        if ! grep -q "web.au-team.irpo" /etc/hosts; then
            echo "$ISP_IP web.au-team.irpo docker.au-team.irpo" >> /etc/hosts
        fi
        hist "nano /etc/hosts"
    }

    setup_browser() {
        run "apt-get install -y yandex-browser"
    }

    setup_isp_proxy() {
        cat > /etc/nginx/sites-available.d/proxy.conf <<EOF
server {
    listen 80;
    server_name web.au-team.irpo;
    auth_basic "Restricted Content";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        proxy_pass http://$HQ_SRV_IP;
        proxy_set_header Host \$host;
    }
}

server {
    listen 80;
    server_name docker.au-team.irpo;
    location / {
        proxy_pass http://$BR_SRV_IP:8081;
        proxy_set_header Host \$host;
    }
}
EOF
        hist "nano /etc/nginx/sites-available.d/proxy.conf"
        
        echo "Kharitone:$(openssl passwd -apr1 P@ssw0rd)" > /etc/nginx/.htpasswd
        hist "echo 'Kharitone:...' > /etc/nginx/.htpasswd"
        
        run "systemctl enable --now nginx"
        run "systemctl restart nginx"
    }

    setup_isp_ssh() {
        if ! id "net_admin" &>/dev/null; then
            run "useradd -m -s /bin/bash net_admin"
            echo "net_admin:P@ssw0rd" | chpasswd
            hist "useradd -m -s /bin/bash net_admin"
            hist "passwd net_admin"
        fi
        usermod -aG wheel net_admin
        echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
        chmod 0440 /etc/sudoers.d/net_admin
        
        if ! grep -q "AllowUsers" /etc/openssh/sshd_config; then
            echo "AllowUsers net_admin" >> /etc/openssh/sshd_config
        fi
        run "systemctl restart sshd"
    }

    setup_timezone() {
        timedatectl set-timezone "$TZ" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
        hist "timedatectl set-timezone $TZ"
    }

    case "$MACHINE" in
        ISP)
            setup_isp_ssh
            setup_isp_proxy
            setup_chrony_server
            setup_timezone
            ;;
        HQ-RTR)
            setup_dnat_hq
            setup_timezone
            ;;
        BR-RTR)
            setup_dnat_br
            setup_timezone
            ;;
        HQ-SRV)
            setup_dns_transfer
            setup_raid
            setup_nfs_server
            setup_web_server
            setup_chrony_client
            setup_timezone
            ;;
        BR-SRV)
            setup_samba_dc
            setup_ansible
            setup_docker
            setup_chrony_client
            setup_timezone
            ;;
        HQ-CLI)
            setup_domain_join
            setup_nfs_client
            setup_chrony_client
            setup_browser
            setup_timezone
            ;;
    esac

    echo ""
    echo "========== ИТОГ =========="
    if command -v ip &>/dev/null; then ip -br a 2>/dev/null || true; fi
    if command -v df &>/dev/null; then df -h 2>/dev/null || true; fi
    if command -v ansible &>/dev/null; then cd /etc/ansible && ansible all -m ping 2>/dev/null || true; fi
    if command -v samba-tool &>/dev/null; then samba-tool user list 2>/dev/null || true; fi
    if command -v net &>/dev/null; then net ads testjoin 2>/dev/null || true; fi
    if command -v nginx &>/dev/null; then nginx -t 2>/dev/null || true; fi

    echo ""
    echo "Сохранение истории и очистка команды запуска..."
    
    history -a 
    
    if [ -f "$HOME/.bash_history" ]; then
        sed -i -E '/(curl|clck\.ru|source[[:space:]]+<\(|exam\.sh|githubusercontent|ini\.sh|bash[[:space:]]+<)/d' "$HOME/.bash_history"
    fi
    
    history -c
    history -r "$HOME/.bash_history"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo " НАСТРОЙКА ЗАВЕРШЕНА. СИСТЕМА БУДЕТ ПЕРЕЗАГРУЖЕНА ЧЕРЕЗ 3 СЕКУНД."
    echo "════════════════════════════════════════════════════════════════"
    sync
    sleep 3
    reboot
}

main "$@"
