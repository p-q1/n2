#!/bin/bash

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Ошибка запуска: используйте source <(curl -sL ...)"
    return 1 2>/dev/null || exit 1
fi

m2_main() {
    set -u
    trap 'set +u' RETURN

    if [ "$EUID" -ne 0 ]; then
        echo "Нужны права root (sudo -i)"
        return 1
    fi

    local DOMAIN_REALM="AU-TEAM.IRPO"
    local DOMAIN_NAME="au-team.irpo"
    local WORKGROUP_NAME="AU-TEAM"
    local SSH_PORT_DEFAULT="2027"
    local NTP_UPSTREAM="pool.ntp.org"
    local ISO_MOUNT="/mnt/iso"

    local HQ_RTR_IP="172.16.1.2"
    local BR_RTR_IP="172.16.2.2"
    local HQ_SRV_IP="192.168.100.2"
    local BR_SRV_IP="192.168.0.2"
    local HQ_CLI_NET="192.168.200.0/28"
    local HQ_CLI_IP_FALLBACK="192.168.200.2"

    m2_hist() {
        history -s "$1" 2>/dev/null || true
        echo "$1" >> "$HOME/.bash_history"
    }

    m2_run() {
        eval "$1"
        m2_hist "$1"
    }

    m2_ask() {
        local p="$1" d="$2" v
        read -r -p "$p [$d]: " v
        echo "${v:-$d}"
    }

    m2_ask_secret() {
        local p="$1" d="$2" v
        read -r -s -p "$p [$d]: " v
        echo ""
        echo "${v:-$d}"
    }

    m2_ask_yn() {
        local p="$1" d="$2" v
        while true; do
            read -r -p "$p [$d]: " v
            v="${v:-$d}"
            case "${v,,}" in
                д|да|y|yes) echo "y"; return 0 ;;
                н|нет|n|no) echo "n"; return 0 ;;
            esac
        done
    }

    m2_detect_role() {
        local hn
        hn="$(hostname -s 2>/dev/null || hostname)"
        case "${hn,,}" in
            *isp*)    echo "ISP" ;;
            *hq-rtr*) echo "HQ-RTR" ;;
            *br-rtr*) echo "BR-RTR" ;;
            *br-fw*)  echo "BR-FW" ;;
            *hq-srv*) echo "HQ-SRV" ;;
            *br-srv*) echo "BR-SRV" ;;
            *hq-cli*) echo "HQ-CLI" ;;
            *)        echo "" ;;
        esac
    }

    m2_discover_state() {
        echo "Состояние узла:"
        echo "Хост: $(hostname -f 2>/dev/null || hostname)"
        echo "Адреса:"
        ip -4 -br a 2>/dev/null || true
        echo "Маршруты:"
        ip -4 route 2>/dev/null || true

        local svcs="chronyd nfs-server docker httpd2 apache2 mariadb nginx named bind dhcpd frr samba"
        local active_list=""
        local s
        for s in $svcs; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                active_list="$active_list $s"
            fi
        done
        echo "Активные службы:${active_list:- нет}"

        if [ -f /etc/resolv.conf ]; then
            local ns
            ns="$(awk '/^nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ')"
            echo "DNS nameserver: ${ns:-не задан}"
        fi
    }

    m2_role_pkg_list() {
        local role="$1"
        case "$role" in
            ISP)
                echo "chrony nginx openssl iptables"
                ;;
            HQ-RTR|BR-RTR)
                echo "chrony iptables"
                ;;
            HQ-SRV)
                echo "chrony mdadm nfs-server nfs-utils rpcbind apache2 apache2-mod_php8.3 php8.3-mysqlnd-mysqli mariadb-server"
                ;;
            BR-SRV)
                echo "chrony sshpass ansible docker-engine docker-compose-v2 task-samba-dc"
                ;;
            HQ-CLI)
                echo "chrony nfs-utils nfs-clients rpcbind task-auth-ad-sssd"
                ;;
            *)
                echo "chrony"
                ;;
        esac
    }

    m2_check_packages() {
        local role="$1"
        local req_pkgs missing="" pkg
        req_pkgs="$(m2_role_pkg_list "$role")"

        for pkg in $req_pkgs; do
            if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                missing="$missing $pkg"
            fi
        done

        if [ "$role" = "HQ-CLI" ]; then
            if ! dpkg -s yandex-browser-stable >/dev/null 2>&1 && ! dpkg -s yandex-browser >/dev/null 2>&1; then
                missing="$missing yandex-browser-stable"
            fi
        fi

        if [ -n "$missing" ]; then
            echo "Не установлены пакеты для $role:$missing"
            if [ "$(m2_ask_yn "Остановить скрипт для ручной установки пакетов? (д/н)" "д")" = "y" ]; then
                echo "Скрипт остановлен. Установите недостающие пакеты и запустите скрипт снова."
                return 1
            fi
        else
            echo "Все нужные пакеты для $role уже установлены."
        fi
        return 0
    }

    m2_mount_iso() {
        mkdir -p "$ISO_MOUNT"
        if mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
            return 0
        fi
        local dev
        for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
            if [ -b "$dev" ]; then
                if mount -o ro "$dev" "$ISO_MOUNT" 2>/dev/null; then
                    echo "Смонтирован $dev в $ISO_MOUNT"
                    return 0
                fi
            fi
        done
        echo "Образ Additional.iso не найден или не смонтирован."
        return 1
    }

    m2_install_role_pkgs() {
        local role="$1"
        local pkgs
        pkgs="$(m2_role_pkg_list "$role")"

        m2_run "apt-get update && apt-get install -y $pkgs"

        if [ "$role" = "HQ-CLI" ]; then
            if apt-cache show yandex-browser-stable >/dev/null 2>&1; then
                m2_run "apt-get install -y yandex-browser-stable"
            elif apt-cache show yandex-browser >/dev/null 2>&1; then
                m2_run "apt-get install -y yandex-browser"
            else
                echo "Пакет Яндекс Браузера не найден в текущих репозиториях apt."
            fi
        fi
    }

    m2_step1_samba_ad() {
        local role="$1"
        if [ "$role" = "BR-SRV" ]; then
            echo "Настройка Samba DC и пользователей на BR-SRV"
            local admin_pass user_pass
            admin_pass="$(m2_ask_secret "Пароль Администратора домена" "P@ssw0rd")"
            user_pass="$(m2_ask_secret "Пароль для hquser1..5" "P@ssw0rd")"

            if ! systemctl is-active --quiet samba 2>/dev/null; then
                if [ -z "$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null)" ]; then
                    echo "nameserver $HQ_SRV_IP" > /etc/resolv.conf
                fi
                systemctl stop samba 2>/dev/null || true
                rm -f /etc/samba/smb.conf
                rm -rf /var/lib/samba/* /var/cache/samba/*
                mkdir -p /var/lib/samba/sysvol
                hostnamectl set-hostname "br-srv.${DOMAIN_NAME}" 2>/dev/null || true
                samba-tool domain provision \
                    --use-rfc2307 \
                    --realm="$DOMAIN_REALM" \
                    --domain="$WORKGROUP_NAME" \
                    --server-role=dc \
                    --dns-backend=SAMBA_INTERNAL \
                    --dns-forwarder="$HQ_SRV_IP" \
                    --adminpass="$admin_pass"
                [ -f /var/lib/samba/private/krb5.conf ] && cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
                echo "nameserver 127.0.0.1" > /etc/resolv.conf
                m2_run "systemctl enable --now samba"
            fi

            samba-tool domain passwordsettings set \
                --min-pwd-length=8 \
                --account-lockout-threshold=5 \
                --account-lockout-duration=30 \
                --reset-account-lockout-after=30 2>/dev/null || true

            samba-tool group add hq 2>/dev/null || true
            local i uname
            for i in 1 2 3 4 5; do
                uname="hquser${i}"
                samba-tool user create "$uname" "$user_pass" 2>/dev/null || true
                samba-tool group addmembers hq "$uname" 2>/dev/null || true
            done
            samba-tool group listmembers hq 2>/dev/null || true
        elif [ "$role" = "HQ-CLI" ]; then
            echo "Ввод HQ-CLI в домен и настройка sudo для группы hq"
            local admin_pass
            admin_pass="$(m2_ask_secret "Пароль Администратора домена" "P@ssw0rd")"

            if command -v system-auth >/dev/null 2>&1; then
                system-auth write ad "$DOMAIN_NAME" "hq-cli" "$WORKGROUP_NAME" Administrator "$admin_pass" 2>/dev/null || true
            fi

            if command -v net >/dev/null 2>&1; then
                net ads join -U "Administrator%${admin_pass}" 2>/dev/null || true
                net ads testjoin 2>/dev/null || true
            fi

            control sudo public 2>/dev/null || true
            local gid_num
            gid_num="$(getent group hq 2>/dev/null | awk -F: '{print $3}')"
            if [ -z "$gid_num" ]; then
                gid_num="$(id hquser1 2>/dev/null | sed -n 's/.*gid=\([0-9]\+\).*/\1/p')"
            fi
            if [ -n "$gid_num" ]; then
                cat > /etc/sudoers.d/hq_group <<EOF
%#${gid_num} ALL=(root) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
            else
                cat > /etc/sudoers.d/hq_group <<EOF
%hq ALL=(root) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
            fi
            chmod 0440 /etc/sudoers.d/hq_group
            visudo -c 2>/dev/null || true
        else
            echo "Пункт 1 выполняется на BR-SRV и HQ-CLI"
        fi
    }

    m2_step2_raid() {
        echo "Настройка RAID 0 (md0) на /raid"
        local root_disk d1 d2 disks
        root_disk="$(lsblk -ndo pkname "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null | head -n1)"
        disks="$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk -v r="$root_disk" '$2=="disk" && $1!=r && $1!~/^loop|^sr|^md/ {print "/dev/"$1}')"
        d1="$(echo "$disks" | sed -n '1p')"
        d2="$(echo "$disks" | sed -n '2p')"

        if [ -z "$d1" ] || [ -z "$d2" ]; then
            echo "Не найдено два свободных диска для RAID. Проверьте lsblk."
            lsblk
            return 1
        fi

        echo "Используются диски: $d1 и $d2"
        mdadm --zero-superblock --force "$d1" "$d2" 2>/dev/null || true
        wipefs --all --force "$d1" "$d2" 2>/dev/null || true

        if [ ! -e /dev/md0 ]; then
            m2_run "mdadm --create /dev/md0 --level=0 --raid-devices=2 $d1 $d2 --run"
        fi

        mkfs -t ext4 -F /dev/md0 2>/dev/null || true
        mkdir -p /etc/mdadm /raid
        echo "DEVICE partitions" > /etc/mdadm/mdadm.conf
        mdadm --detail --scan 2>/dev/null | awk '/ARRAY/ {print}' >> /etc/mdadm/mdadm.conf

        if ! grep -q '[[:space:]]/raid[[:space:]]' /etc/fstab 2>/dev/null; then
            echo "/dev/md0 /raid ext4 defaults 0 0" >> /etc/fstab
        fi
        m2_run "mount -a"
        df -h /raid
    }

    m2_step3_nfs() {
        local role="$1"
        if [ "$role" = "HQ-SRV" ]; then
            echo "Настройка NFS-сервера на HQ-SRV"
            mkdir -p /raid/nfs
            chmod 0777 /raid/nfs

            if ! grep -q "^/raid/nfs[[:space:]]" /etc/exports 2>/dev/null; then
                echo "/raid/nfs ${HQ_CLI_NET}(rw,no_root_squash,sync)" >> /etc/exports
            fi
            m2_run "exportfs -arv"
            m2_run "systemctl enable --now nfs-server"
        elif [ "$role" = "HQ-CLI" ]; then
            echo "Настройка NFS-клиента на HQ-CLI"
            mkdir -p /mnt/nfs
            chmod 0777 /mnt/nfs
            if ! grep -q "[[:space:]]/mnt/nfs[[:space:]]" /etc/fstab 2>/dev/null; then
                echo "${HQ_SRV_IP}:/raid/nfs /mnt/nfs nfs defaults 0 0" >> /etc/fstab
            fi
            m2_run "mount -a"
            df -h /mnt/nfs
        else
            echo "Пункт 3 выполняется на HQ-SRV и HQ-CLI"
        fi
    }

    m2_step4_chrony() {
        local role="$1"
        echo "Настройка chrony ($role)"

        if [ "$role" = "ISP" ]; then
            cat > /etc/chrony.conf <<EOF
pool $NTP_UPSTREAM iburst
server 127.0.0.1 iburst prefer
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow 0/0
local stratum 5
EOF
        else
            cat > /etc/chrony.conf <<EOF
server ${HQ_RTR_IP} iburst prefer
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
        fi

        m2_run "systemctl enable --now chronyd"
        m2_run "systemctl restart chronyd"
        chronyc sources 2>/dev/null || true
    }

    m2_step5_ansible() {
        echo "Настройка Ansible на BR-SRV"
        if [ ! -f /root/.ssh/ansible ]; then
            mkdir -p /root/.ssh
            chmod 0700 /root/.ssh
            ssh-keygen -t ed25519 -f /root/.ssh/ansible -N ""
        fi

        mkdir -p /etc/ansible
        cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = /usr/bin/python3
EOF

        cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=${HQ_SRV_IP} ansible_user=sshuser ansible_port=${SSH_PORT_DEFAULT}

[clients]
hq-cli ansible_host=${HQ_CLI_IP_FALLBACK} ansible_user=sshuser

[routers]
hq-rtr ansible_host=${HQ_RTR_IP} ansible_user=net_admin
br-rtr ansible_host=${BR_RTR_IP} ansible_user=net_admin

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=/root/.ssh/ansible
EOF

        echo "Ключ /root/.ssh/ansible.pub готов. Скопируйте его на хосты при необходимости:"
        echo "ssh-copy-id -i /root/.ssh/ansible.pub -p ${SSH_PORT_DEFAULT} sshuser@${HQ_SRV_IP}"
        echo "ssh-copy-id -i /root/.ssh/ansible.pub sshuser@${HQ_CLI_IP_FALLBACK}"
        echo "ssh-copy-id -i /root/.ssh/ansible.pub net_admin@${HQ_RTR_IP}"
        echo "ssh-copy-id -i /root/.ssh/ansible.pub net_admin@${BR_RTR_IP}"

        if [ "$(m2_ask_yn "Запустить проверку из /etc/ansible (ansible all -m ping)? (д/н)" "н")" = "y" ]; then
            (cd /etc/ansible && ansible all -m ping) 2>/dev/null || true
        fi
    }

    m2_step6_docker_app() {
        echo "Развёртывание testapp в Docker на BR-SRV"
        m2_run "systemctl enable --now docker"

        mkdir -p /root/testapp
        if m2_mount_iso; then
            if [ -d "$ISO_MOUNT/docker" ]; then
                cp -a "$ISO_MOUNT/docker/." /root/testapp/
            else
                echo "Внимание: каталог $ISO_MOUNT/docker не найден в образе."
            fi

            if [ -f "$ISO_MOUNT/compose.yaml" ]; then
                cp -f "$ISO_MOUNT/compose.yaml" /root/testapp/compose.yaml
            elif [ -f "$ISO_MOUNT/docker/compose.yaml" ]; then
                cp -f "$ISO_MOUNT/docker/compose.yaml" /root/testapp/compose.yaml
            else
                echo "Внимание: compose.yaml не найден в образе."
            fi
        fi

        local tar_found=0
        local f
        for f in /root/testapp/*.tar; do
            if [ -f "$f" ]; then
                tar_found=1
                docker load -i "$f"
            fi
        done
        if [ "$tar_found" -eq 0 ]; then
            echo "Внимание: .tar-образы не найдены в /root/testapp."
        fi

        if [ -f /root/testapp/compose.yaml ]; then
            (cd /root/testapp && docker compose -p testapp up -d)
        else
            echo "Пропуск docker compose up: нет /root/testapp/compose.yaml"
        fi
        docker ps 2>/dev/null || true
    }

    m2_step7_web_app() {
        echo "Развёртывание веб-приложения на HQ-SRV"
        m2_run "systemctl enable --now mariadb"

        mariadb -u root <<'SQL'
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
FLUSH PRIVILEGES;
SQL

        mkdir -p /var/www/html
        rm -f /var/www/html/index.html

        if m2_mount_iso; then
            if [ -f "$ISO_MOUNT/web/dump.sql" ]; then
                mariadb -u root webdb < "$ISO_MOUNT/web/dump.sql"
            else
                echo "Внимание: $ISO_MOUNT/web/dump.sql не найден в образе."
            fi

            if [ -f "$ISO_MOUNT/web/index.php" ]; then
                cp -f "$ISO_MOUNT/web/index.php" /var/www/html/index.php
            else
                echo "Внимание: $ISO_MOUNT/web/index.php не найден в образе."
            fi

            if [ -f "$ISO_MOUNT/web/logo.png" ]; then
                cp -f "$ISO_MOUNT/web/logo.png" /var/www/html/logo.png
            else
                echo "Внимание: $ISO_MOUNT/web/logo.png не найден в образе."
            fi
        fi

        if [ -f /var/www/html/index.php ]; then
            sed -i -E \
                -e "s/('|\")webdb('|\")/'webdb'/g" \
                -e "s/('|\")web('|\")/'web'/g" \
                -e "s/('|\")P@ssword('|\")/'P@ssw0rd'/g" \
                -e "s/('|\")P@ssw0rd('|\")/'P@ssw0rd'/g" \
                /var/www/html/index.php
            chmod 0644 /var/www/html/index.php
        fi
        [ -f /var/www/html/logo.png ] && chmod 0644 /var/www/html/logo.png

        m2_run "systemctl enable --now httpd2"
        m2_run "systemctl restart httpd2"
    }

    m2_step8_dnat() {
        local role="$1"
        if [ "$role" = "HQ-RTR" ]; then
            echo "Настройка DNAT на HQ-RTR"
            iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 -j DNAT --to-destination "${HQ_SRV_IP}:80"
            iptables -t nat -I PREROUTING 1 -p tcp --dport "${SSH_PORT_DEFAULT}" -j DNAT --to-destination "${HQ_SRV_IP}:${SSH_PORT_DEFAULT}"
            mkdir -p /etc/sysconfig
            m2_run "iptables-save > /etc/sysconfig/iptables"
        elif [ "$role" = "BR-RTR" ]; then
            echo "Настройка DNAT на BR-RTR"
            iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 -j DNAT --to-destination "${BR_SRV_IP}:8080"
            iptables -t nat -I PREROUTING 1 -p tcp --dport "${SSH_PORT_DEFAULT}" -j DNAT --to-destination "${BR_SRV_IP}:${SSH_PORT_DEFAULT}"
            mkdir -p /etc/sysconfig
            m2_run "iptables-save > /etc/sysconfig/iptables"
        else
            echo "Пункт 8 выполняется на HQ-RTR и BR-RTR"
        fi
    }

    m2_step_nginx_optional() {
        local role="$1"
        if [ "$role" = "ISP" ]; then
            local auth_user auth_pass isp_ip
            auth_user="$(m2_ask "Логин для Basic Auth" "admin")"
            auth_pass="$(m2_ask_secret "Пароль для Basic Auth" "P@ssw0rd")"
            isp_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
            isp_ip="${isp_ip:-172.16.1.1}"

            mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled.d /etc/nginx
            if command -v htpasswd >/dev/null 2>&1; then
                htpasswd -bc /etc/nginx/.htpasswd "$auth_user" "$auth_pass"
            elif command -v openssl >/dev/null 2>&1; then
                printf "%s:%s\n" "$auth_user" "$(openssl passwd -apr1 "$auth_pass" 2>/dev/null || openssl passwd -6 "$auth_pass")" > /etc/nginx/.htpasswd
            fi

            cat > /etc/nginx/sites-available.d/proxy.conf <<EOF
server {
    listen 80;
    server_name web.${DOMAIN_NAME};

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://${HQ_SRV_IP}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 80;
    server_name docker.${DOMAIN_NAME};

    location / {
        proxy_pass http://${BR_SRV_IP}:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
            ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
            m2_run "systemctl enable --now nginx"
            m2_run "systemctl restart nginx"
            echo "На HQ-CLI добавьте в /etc/hosts: ${isp_ip} web.${DOMAIN_NAME} docker.${DOMAIN_NAME}"
        elif [ "$role" = "HQ-CLI" ]; then
            local isp_ip
            isp_ip="$(m2_ask "IP адрес ISP для /etc/hosts" "172.16.1.1")"
            if ! grep -q "web.${DOMAIN_NAME}" /etc/hosts 2>/dev/null; then
                echo "${isp_ip} web.${DOMAIN_NAME} docker.${DOMAIN_NAME}" >> /etc/hosts
            fi
        fi
    }

    clear
    m2_discover_state
    echo ""

    local ROLE
    ROLE="$(m2_detect_role)"
    if [ -n "$ROLE" ]; then
        ROLE="$(m2_ask "Определена роль машины" "$ROLE")"
    else
        echo "Выберите машину:"
        select ROLE in ISP HQ-RTR BR-RTR BR-FW HQ-SRV BR-SRV HQ-CLI; do
            [ -n "$ROLE" ] && break
        done
    fi

    echo ""
    echo "Выберите действие:"
    echo "1 — Проверить пакеты, при необходимости доставить и выполнить задачи для $ROLE"
    echo "2 — Только проверить пакеты (с возможностью остановить скрипт)"
    echo "3 — Выбрать конкретный пункт (1..8 или n для nginx)"
    local MODE
    MODE="$(m2_ask "Режим" "1")"

    if [ "$MODE" = "2" ]; then
        m2_check_packages "$ROLE" || return 1
    elif [ "$MODE" = "3" ]; then
        m2_check_packages "$ROLE" || return 1
        local ITEM
        ITEM="$(m2_ask "Пункт (1..8, n)" "1")"
        case "$ITEM" in
            1) m2_step1_samba_ad "$ROLE" ;;
            2) m2_step2_raid ;;
            3) m2_step3_nfs "$ROLE" ;;
            4) m2_step4_chrony "$ROLE" ;;
            5) m2_step5_ansible ;;
            6) m2_step6_docker_app ;;
            7) m2_step7_web_app ;;
            8) m2_step8_dnat "$ROLE" ;;
            n|N) m2_step_nginx_optional "$ROLE" ;;
        esac
    else
        m2_check_packages "$ROLE" || return 1
        if [ "$(m2_ask_yn "Запустить автоустановку недостающих пакетов через apt? (д/н)" "н")" = "y" ]; then
            m2_install_role_pkgs "$ROLE"
        fi
        case "$ROLE" in
            ISP)
                m2_step4_chrony "$ROLE"
                if [ "$(m2_ask_yn "Настроить reverse-proxy и auth_basic в nginx? (д/н)" "н")" = "y" ]; then
                    m2_step_nginx_optional "$ROLE"
                fi
                ;;
            HQ-RTR)
                m2_step4_chrony "$ROLE"
                m2_step8_dnat "$ROLE"
                ;;
            BR-RTR)
                m2_step4_chrony "$ROLE"
                m2_step8_dnat "$ROLE"
                ;;
            HQ-SRV)
                m2_step2_raid
                m2_step3_nfs "$ROLE"
                m2_step4_chrony "$ROLE"
                m2_step7_web_app
                ;;
            BR-SRV)
                m2_step1_samba_ad "$ROLE"
                m2_step4_chrony "$ROLE"
                m2_step5_ansible
                m2_step6_docker_app
                ;;
            HQ-CLI)
                m2_step1_samba_ad "$ROLE"
                m2_step3_nfs "$ROLE"
                m2_step4_chrony "$ROLE"
                if [ "$(m2_ask_yn "Прописать web/docker.${DOMAIN_NAME} в /etc/hosts? (д/н)" "н")" = "y" ]; then
                    m2_step_nginx_optional "$ROLE"
                fi
                ;;
            BR-FW)
                echo "Для BR-FW отдельные задачи Модуля 2 не указаны."
                ;;
        esac
    fi

    history -a
    if [ -f "$HOME/.bash_history" ]; then
        sed -i -E '/(curl|clck\.ru|source[[:space:]]+<\(|module2\.sh|githubusercontent|bash[[:space:]]+<)/d' "$HOME/.bash_history"
    fi
    history -c
    history -r "$HOME/.bash_history"

    echo ""
    echo "Готово для $ROLE."
}

m2_main "$@"
