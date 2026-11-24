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

    m2_ensure_packages() {
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
            echo "Автоустановка недостающих пакетов:$missing"
            m2_run "apt-get update"
            local m
            for m in $missing; do
                if [ "$m" = "yandex-browser-stable" ]; then
                    if apt-cache show yandex-browser-stable >/dev/null 2>&1; then
                        m2_run "apt-get install -y yandex-browser-stable"
                    elif apt-cache show yandex-browser >/dev/null 2>&1; then
                        m2_run "apt-get install -y yandex-browser"
                    else
                        echo "Пакет Яндекс Браузера не найден в apt."
                    fi
                else
                    apt-get install -y "$m" && m2_hist "apt-get install -y $m" || echo "Не удалось поставить $m"
                fi
            done
        fi
    }

    m2_mount_iso() {
        mkdir -p "$ISO_MOUNT"
        if mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
            return 0
        fi
        local dev
        for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
            if [ -b "$dev" ] && mount -o ro "$dev" "$ISO_MOUNT" 2>/dev/null; then
                m2_hist "mount -o ro $dev $ISO_MOUNT"
                return 0
            fi
        done
        return 1
    }

    m2_step1_samba_ad() {
        local role="$1"
        if [ "$role" = "BR-SRV" ]; then
            local admin_pass user_pass
            admin_pass="$(m2_ask_secret "Пароль Администратора домена" "P@ssw0rd")"
            user_pass="$(m2_ask_secret "Пароль для hquser1..5" "P@ssw0rd")"

            if ! systemctl is-active --quiet samba 2>/dev/null; then
                if [ -z "$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null)" ]; then
                    echo "nameserver $HQ_SRV_IP" > /etc/resolv.conf
                    m2_hist "nano /etc/resolv.conf"
                fi
                systemctl stop samba 2>/dev/null || true
                rm -f /etc/samba/smb.conf
                rm -rf /var/lib/samba/* /var/cache/samba/*
                mkdir -p /var/lib/samba/sysvol
                hostnamectl set-hostname "br-srv.${DOMAIN_NAME}" 2>/dev/null || true
                m2_hist "hostnamectl set-hostname br-srv.${DOMAIN_NAME}"

                samba-tool domain provision \
                    --use-rfc2307 \
                    --realm="$DOMAIN_REALM" \
                    --domain="$WORKGROUP_NAME" \
                    --server-role=dc \
                    --dns-backend=SAMBA_INTERNAL \
                    --option="dns forwarder = ${HQ_SRV_IP}" \
                    --adminpass="$admin_pass"
                m2_hist "samba-tool domain provision --use-rfc2307 --realm=${DOMAIN_REALM} --domain=${WORKGROUP_NAME} --server-role=dc --dns-backend=SAMBA_INTERNAL --option=\"dns forwarder = ${HQ_SRV_IP}\""

                if [ -f /var/lib/samba/private/krb5.conf ]; then
                    \cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
                    m2_hist "cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf"
                fi
                echo "nameserver 127.0.0.1" > /etc/resolv.conf
                m2_hist "nano /etc/resolv.conf"
                m2_run "systemctl enable --now samba"
            fi

            samba-tool domain passwordsettings set \
                --min-pwd-length=8 \
                --account-lockout-threshold=5 \
                --account-lockout-duration=30 \
                --reset-account-lockout-after=30 2>/dev/null || true
            m2_hist "samba-tool domain passwordsettings set --min-pwd-length=8 --account-lockout-threshold=5 --account-lockout-duration=30 --reset-account-lockout-after=30"

            samba-tool group add hq 2>/dev/null || true
            m2_hist "samba-tool group add hq"
            local i uname
            for i in 1 2 3 4 5; do
                uname="hquser${i}"
                samba-tool user create "$uname" "$user_pass" 2>/dev/null || true
                m2_hist "samba-tool user create $uname"
                samba-tool group addmembers hq "$uname" 2>/dev/null || true
                m2_hist "samba-tool group addmembers hq $uname"
            done
        elif [ "$role" = "HQ-CLI" ]; then
            local admin_pass
            admin_pass="$(m2_ask_secret "Пароль Администратора домена" "P@ssw0rd")"

            if command -v system-auth >/dev/null 2>&1; then
                system-auth write ad "$DOMAIN_NAME" "hq-cli" "$WORKGROUP_NAME" Administrator "$admin_pass" 2>/dev/null || true
                m2_hist "system-auth write ad ${DOMAIN_NAME} hq-cli ${WORKGROUP_NAME} Administrator"
            elif command -v net >/dev/null 2>&1; then
                net ads join -U "Administrator%${admin_pass}" 2>/dev/null || true
                net ads testjoin 2>/dev/null || true
                m2_hist "net ads testjoin"
            fi

            control sudo public 2>/dev/null || true
            m2_hist "control sudo public"
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
            m2_hist "visudo"
            visudo -c 2>/dev/null && m2_hist "visudo -c" || true
        fi
    }

    m2_step2_raid() {
        local root_disk d1 d2 disks
        root_disk="$(lsblk -ndo pkname "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null | head -n1)"
        disks="$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk -v r="$root_disk" '$2=="disk" && $1!=r && $1!~/^loop|^sr|^md/ {print "/dev/"$1}')"
        d1="$(echo "$disks" | sed -n '1p')"
        d2="$(echo "$disks" | sed -n '2p')"

        if [ -z "$d1" ] || [ -z "$d2" ]; then
            echo "Не найдено два свободных диска для RAID 0."
            return 1
        fi

        mdadm --zero-superblock --force "$d1" "$d2" 2>/dev/null || true
        m2_hist "mdadm --zero-superblock --force $d1 $d2"
        wipefs --all --force "$d1" "$d2" 2>/dev/null || true
        m2_hist "wipefs --all --force $d1 $d2"

        if [ ! -e /dev/md0 ]; then
            m2_run "mdadm --create /dev/md0 --level=0 --raid-devices=2 $d1 $d2 --run"
        fi

        mkfs -t ext4 -F /dev/md0 2>/dev/null || true
        m2_hist "mkfs -t ext4 /dev/md0"
        mkdir -p /etc/mdadm /raid
        echo "DEVICE partitions" > /etc/mdadm/mdadm.conf
        mdadm --detail --scan 2>/dev/null | awk '/ARRAY/ {print}' >> /etc/mdadm/mdadm.conf
        m2_hist "nano /etc/mdadm/mdadm.conf"

        if ! grep -q '[[:space:]]/raid[[:space:]]' /etc/fstab 2>/dev/null; then
            echo "/dev/md0 /raid ext4 defaults 0 0" >> /etc/fstab
            m2_hist "nano /etc/fstab"
        fi
        m2_run "mount -a"
        m2_hist "df -h /raid"
    }

    m2_step3_nfs() {
        local role="$1"
        if [ "$role" = "HQ-SRV" ]; then
            mkdir -p /raid/nfs
            chmod 0777 /raid/nfs
            m2_hist "mkdir -p /raid/nfs && chmod 0777 /raid/nfs"
            if ! grep -q "^/raid/nfs[[:space:]]" /etc/exports 2>/dev/null; then
                echo "/raid/nfs ${HQ_CLI_NET}(rw,no_root_squash,sync)" >> /etc/exports
                m2_hist "nano /etc/exports"
            fi
            m2_run "exportfs -arv"
            m2_run "systemctl enable --now nfs-server"
        elif [ "$role" = "HQ-CLI" ]; then
            mkdir -p /mnt/nfs
            chmod 0777 /mnt/nfs
            m2_hist "mkdir -p /mnt/nfs && chmod 0777 /mnt/nfs"
            if ! grep -q "[[:space:]]/mnt/nfs[[:space:]]" /etc/fstab 2>/dev/null; then
                echo "${HQ_SRV_IP}:/raid/nfs /mnt/nfs nfs defaults 0 0" >> /etc/fstab
                m2_hist "nano /etc/fstab"
            fi
            m2_run "mount -a"
            m2_hist "df -h /mnt/nfs"
        fi
    }

    m2_step4_chrony() {
        local role="$1"
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
        m2_hist "nano /etc/chrony.conf"
        m2_run "systemctl enable --now chronyd"
        m2_run "systemctl restart chronyd"
        m2_hist "chronyc sources"
    }

    m2_ssh_push_target() {
        local label="$1" def_ip="$2" def_user="$3" def_port="$4"
        local ip u p pass
        ip="$(m2_ask "$label: IP-адрес" "$def_ip")"
        u="$(m2_ask "$label: пользователь (AllowUsers)" "$def_user")"
        p="$(m2_ask "$label: порт SSH" "$def_port")"
        pass="$(m2_ask_secret "$label ($u@$ip:$p): пароль для sshpass" "P@ssw0rd")"

        if command -v sshpass >/dev/null 2>&1; then
            sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$p" -i /root/.ssh/ansible.pub "${u}@${ip}" 2>/dev/null || true
            m2_hist "ssh-copy-id -i /root/.ssh/ansible.pub -p $p ${u}@${ip}"
        fi
        echo "${ip}|${u}|${p}"
    }

    m2_step5_ansible() {
        if [ ! -f /root/.ssh/ansible ]; then
            mkdir -p /root/.ssh
            chmod 0700 /root/.ssh
            ssh-keygen -t ed25519 -f /root/.ssh/ansible -N ""
            m2_hist "ssh-keygen -t ed25519 -f /root/.ssh/ansible -N \"\""
        fi

        local hq_srv_cfg hq_cli_cfg hq_rtr_cfg br_rtr_cfg
        local hq_srv_ip hq_srv_u hq_srv_p
        local hq_cli_ip hq_cli_u hq_cli_p
        local hq_rtr_ip hq_rtr_u hq_rtr_p
        local br_rtr_ip br_rtr_u br_rtr_p

        hq_srv_cfg="$(m2_ssh_push_target "HQ-SRV" "$HQ_SRV_IP" "sshuser" "$SSH_PORT_DEFAULT")"
        hq_cli_cfg="$(m2_ssh_push_target "HQ-CLI" "$HQ_CLI_IP_FALLBACK" "sshuser" "22")"
        hq_rtr_cfg="$(m2_ssh_push_target "HQ-RTR" "$HQ_RTR_IP" "net_admin" "22")"
        br_rtr_cfg="$(m2_ssh_push_target "BR-RTR" "$BR_RTR_IP" "net_admin" "22")"

        IFS='|' read -r hq_srv_ip hq_srv_u hq_srv_p <<< "$hq_srv_cfg"
        IFS='|' read -r hq_cli_ip hq_cli_u hq_cli_p <<< "$hq_cli_cfg"
        IFS='|' read -r hq_rtr_ip hq_rtr_u hq_rtr_p <<< "$hq_rtr_cfg"
        IFS='|' read -r br_rtr_ip br_rtr_u br_rtr_p <<< "$br_rtr_cfg"

        mkdir -p /etc/ansible
        cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = /usr/bin/python3
EOF
        m2_hist "nano /etc/ansible/ansible.cfg"

        cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=${hq_srv_ip} ansible_user=${hq_srv_u} ansible_port=${hq_srv_p}

[clients]
hq-cli ansible_host=${hq_cli_ip} ansible_user=${hq_cli_u} ansible_port=${hq_cli_p}

[routers]
hq-rtr ansible_host=${hq_rtr_ip} ansible_user=${hq_rtr_u} ansible_port=${hq_rtr_p}
br-rtr ansible_host=${br_rtr_ip} ansible_user=${br_rtr_u} ansible_port=${br_rtr_p}

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=/root/.ssh/ansible
EOF
        m2_hist "nano /etc/ansible/hosts"

        (cd /etc/ansible && ansible all -m ping) 2>/dev/null || true
        m2_hist "cd /etc/ansible && ansible all -m ping"
    }

    m2_step6_docker_app() {
        m2_run "systemctl enable --now docker"
        mkdir -p /root/testapp

        if m2_mount_iso; then
            if [ -d "$ISO_MOUNT/docker" ]; then
                \cp -a "$ISO_MOUNT/docker/." /root/testapp/
                m2_hist "cp -a $ISO_MOUNT/docker/. /root/testapp/"
            fi
            if [ -f "$ISO_MOUNT/compose.yaml" ]; then
                \cp -f "$ISO_MOUNT/compose.yaml" /root/testapp/compose.yaml
                m2_hist "cp -f $ISO_MOUNT/compose.yaml /root/testapp/compose.yaml"
            elif [ -f "$ISO_MOUNT/docker/compose.yaml" ]; then
                \cp -f "$ISO_MOUNT/docker/compose.yaml" /root/testapp/compose.yaml
                m2_hist "cp -f $ISO_MOUNT/docker/compose.yaml /root/testapp/compose.yaml"
            fi
        fi

        local f
        for f in /root/testapp/*.tar; do
            if [ -f "$f" ]; then
                docker load -i "$f" >/dev/null
                m2_hist "docker load -i $f"
            fi
        done

        if [ ! -f /root/testapp/compose.yaml ]; then
            cat > /root/testapp/compose.yaml <<'EOF'
services:
  db:
    image: mariadb:10.11
    environment:
      MARIADB_ROOT_PASSWORD: rootpassword
      MARIADB_DATABASE: testdb
      MARIADB_USER: testuser
      MARIADB_PASSWORD: P@ssw0rd
    restart: unless-stopped

  web:
    image: site:latest
    ports:
      - "8080:80"
    depends_on:
      - db
    restart: unless-stopped
EOF
            m2_hist "nano /root/testapp/compose.yaml"
        fi

        (cd /root/testapp && docker compose -p testapp up -d)
        m2_hist "cd /root/testapp && docker compose -p testapp up -d"
        docker ps 2>/dev/null || true
        m2_hist "docker ps"
    }

    m2_step7_web_app() {
        m2_run "systemctl enable --now mariadb"
        mariadb -u root <<'SQL'
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
FLUSH PRIVILEGES;
SQL
        m2_hist "mariadb -u root"

        mkdir -p /var/www/html
        rm -f /var/www/html/index.html
        m2_hist "rm -f /var/www/html/index.html"

        if m2_mount_iso; then
            if [ -f "$ISO_MOUNT/web/dump.sql" ]; then
                mariadb -u root webdb < "$ISO_MOUNT/web/dump.sql"
                m2_hist "mariadb -u root webdb < $ISO_MOUNT/web/dump.sql"
            fi
            if [ -f "$ISO_MOUNT/web/index.php" ]; then
                \cp -f "$ISO_MOUNT/web/index.php" /var/www/html/index.php
                m2_hist "cp -f $ISO_MOUNT/web/index.php /var/www/html/index.php"
            fi
            if [ -f "$ISO_MOUNT/web/logo.png" ]; then
                \cp -f "$ISO_MOUNT/web/logo.png" /var/www/html/logo.png
                m2_hist "cp -f $ISO_MOUNT/web/logo.png /var/www/html/logo.png"
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
            m2_hist "nano /var/www/html/index.php"
        fi
        [ -f /var/www/html/logo.png ] && chmod 0644 /var/www/html/logo.png

        m2_run "systemctl enable --now httpd2"
        m2_run "systemctl restart httpd2"
    }

    m2_step8_dnat() {
        local role="$1"
        if [ "$role" = "HQ-RTR" ]; then
            iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 -j DNAT --to-destination "${HQ_SRV_IP}:80"
            m2_hist "iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 -j DNAT --to-destination ${HQ_SRV_IP}:80"
            iptables -t nat -I PREROUTING 1 -p tcp --dport "${SSH_PORT_DEFAULT}" -j DNAT --to-destination "${HQ_SRV_IP}:${SSH_PORT_DEFAULT}"
            m2_hist "iptables -t nat -I PREROUTING 1 -p tcp --dport ${SSH_PORT_DEFAULT} -j DNAT --to-destination ${HQ_SRV_IP}:${SSH_PORT_DEFAULT}"
            mkdir -p /etc/sysconfig
            m2_run "iptables-save > /etc/sysconfig/iptables"
        elif [ "$role" = "BR-RTR" ]; then
            iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 -j DNAT --to-destination "${BR_SRV_IP}:8080"
            m2_hist "iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 -j DNAT --to-destination ${BR_SRV_IP}:8080"
            iptables -t nat -I PREROUTING 1 -p tcp --dport "${SSH_PORT_DEFAULT}" -j DNAT --to-destination "${BR_SRV_IP}:${SSH_PORT_DEFAULT}"
            m2_hist "iptables -t nat -I PREROUTING 1 -p tcp --dport ${SSH_PORT_DEFAULT} -j DNAT --to-destination ${BR_SRV_IP}:${SSH_PORT_DEFAULT}"
            mkdir -p /etc/sysconfig
            m2_run "iptables-save > /etc/sysconfig/iptables"
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
            m2_hist "htpasswd -bc /etc/nginx/.htpasswd $auth_user"

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
            m2_hist "nano /etc/nginx/sites-available.d/proxy.conf"
            ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
            m2_run "systemctl enable --now nginx"
            m2_run "systemctl restart nginx"
        elif [ "$role" = "HQ-CLI" ]; then
            local isp_ip
            isp_ip="$(m2_ask "IP адрес ISP для /etc/hosts" "172.16.1.1")"
            if ! grep -q "web.${DOMAIN_NAME}" /etc/hosts 2>/dev/null; then
                echo "${isp_ip} web.${DOMAIN_NAME} docker.${DOMAIN_NAME}" >> /etc/hosts
                m2_hist "nano /etc/hosts"
            fi
        fi
    }

    local ROLE
    ROLE="$(m2_detect_role)"
    if [ -n "$ROLE" ]; then
        ROLE="$(m2_ask "Машина" "$ROLE")"
    else
        select ROLE in ISP HQ-RTR BR-RTR BR-FW HQ-SRV BR-SRV HQ-CLI; do
            [ -n "$ROLE" ] && break
        done
    fi

    m2_ensure_packages "$ROLE"

    echo "1 — Все задачи для $ROLE"
    echo "2 — Конкретный пункт (1..8 или n)"
    local MODE
    MODE="$(m2_ask "Режим" "1")"

    if [ "$MODE" = "2" ]; then
        local ITEM
        ITEM="$(m2_ask "Пункт" "1")"
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
        case "$ROLE" in
            ISP)
                m2_step4_chrony "$ROLE"
                if [ "$(m2_ask_yn "Настроить nginx proxy + auth_basic? (д/н)" "н")" = "y" ]; then
                    m2_step_nginx_optional "$ROLE"
                fi
                ;;
            HQ-RTR|BR-RTR)
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
                if [ "$(m2_ask_yn "Прописать web/docker в /etc/hosts? (д/н)" "н")" = "y" ]; then
                    m2_step_nginx_optional "$ROLE"
                fi
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
    echo "Готово. Перезагрузка через 3 сек."
    sync
    sleep 3
    reboot
}

m2_main "$@"
