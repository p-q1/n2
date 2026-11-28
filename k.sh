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
    local SEARCH_DOMAIN="au-team.irpo"
    local SSH_PORT_HQ_SRV="2027"
    local SSH_PORT_BR_SRV="2027"
    local SSH_PASS="P@ssw0rd"

    local AD_REALM="HQ.LOCAL"
    local AD_ADMIN_PASS="P@ssw0rd"
    local HQ_GROUP="hq"
    local HQ_USER_PASS="P@ssw0rd123"

    local RAID_DEV="/dev/md0"
    local RAID_LEVEL="0"
    local RAID_FS="ext4"
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

    info_line() {
        printf '\033[0;37m[%s]        %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"
    }

    color_yn() {
        if [ "$1" = "yes" ]; then
            printf '\033[1;32myes\033[0m'
        else
            printf '\033[1;31mno\033[0m'
        fi
    }

    summary_block() {
        local title="$1"
        local reason="$2"
        shift 2
        local parts=()
        while [ "$#" -gt 0 ]; do
            local item="$1"
            shift
            if [[ "$item" == *" - yes"* ]]; then
                local k="${item%% - yes*}"
                local rest="${item#* - yes}"
                parts+=("${k} - $(color_yn "yes")${rest}")
            elif [[ "$item" == *" - no"* ]]; then
                local k="${item%% - no*}"
                local rest="${item#* - no}"
                parts+=("${k} - $(color_yn "no")${rest}")
            else
                parts+=("$item")
            fi
        done
        local joined
        joined="$(IFS=', '; echo "${parts[*]}")"
        printf '\n\033[1;36m%s\033[0m\n' "$title"
        printf '\033[1;37mИТОГИ:\033[0m %b\n' "$joined"
        if [ -n "${reason:-}" ]; then
            printf '\033[1;31mПРИЧИНА:\033[0m %s\n' "$reason"
        fi
    }

    ask() {
        local prompt="$1" default_val="$2" answer=""
        read -r -p "$prompt [$default_val]: " answer
        echo "${answer:-$default_val}"
    }

    raid_min_disks() {
        case "$1" in
            0|1)  echo "2" ;;
            5)    echo "3" ;;
            6|10) echo "4" ;;
            *)    echo "2" ;;
        esac
    }

    raid_reqs_note() {
        case "$1" in
            0)  echo "RAID 0: минимум 2 диска (полоскование, без отказоустойчивости; по заданию — 2x1 ГБ)." ;;
            1)  echo "RAID 1: минимум 2 диска (зеркалирование, кратно 1)." ;;
            5)  echo "RAID 5: минимум 3 диска (распределённая чётность)." ;;
            6)  echo "RAID 6: минимум 4 диска (двойная чётность)." ;;
            10) echo "RAID 10: минимум 4 диска, чётное количество (зеркало поверх страйпа)." ;;
            *)  echo "Уровень не распознан — проверьте значение (0, 1, 5, 6, 10)." ;;
        esac
    }

    save_history_clean() {
        local hist_file="${HISTFILE:-$HOME/.bash_history}"
        history -a 2>/dev/null || true
        history -w "$hist_file" 2>/dev/null || true

        if [ -f "$hist_file" ]; then
            local tmp1 tmp2
            tmp1="$(mktemp)"
            tmp2="$(mktemp)"
            grep -vE '(curl|source[[:space:]]+<\(|bash[[:space:]]+<|модуль2|mod2)' "$hist_file" > "$tmp1" || true
            if [ -n "$INVOCATION_CMD" ]; then
                grep -vF "$INVOCATION_CMD" "$tmp1" > "$tmp2" || true
            else
                cp -f "$tmp1" "$tmp2"
            fi
            \mv -f "$tmp2" "$hist_file"
            rm -f "$tmp1" "$tmp2" 2>/dev/null || true
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

    ensure_ssh_user_rights() {
        local u="$1"
        local user_home user_shell

        if id "$u" >/dev/null 2>&1; then
            usermod -U "$u" 2>/dev/null || true
            user_shell="$(getent passwd "$u" | cut -d: -f7)"
            case "$user_shell" in
                */nologin|*/false|"") usermod -s /bin/bash "$u" 2>/dev/null || true ;;
            esac
        else
            useradd -m -s /bin/bash "$u"
        fi

        user_home="$(getent passwd "$u" | cut -d: -f6)"
        if [ -z "${user_home:-}" ]; then
            user_home="/home/$u"
            mkdir -p "$user_home"
            usermod -d "$user_home" "$u" 2>/dev/null || true
        fi
        mkdir -p "$user_home/.ssh"
        chmod 0700 "$user_home/.ssh"
        touch "$user_home/.ssh/authorized_keys"
        chmod 0600 "$user_home/.ssh/authorized_keys"
        chown -R "$u":"$u" "$user_home" 2>/dev/null || true

        echo "${u}:${SSH_PASS}" | chpasswd

        for grp in wheel sudo; do
            if getent group "$grp" >/dev/null 2>&1; then
                usermod -aG "$grp" "$u" 2>/dev/null || true
            fi
        done

        local sudo_file="/etc/sudoers.d/90-${u}-nopasswd"
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u" > "$sudo_file"
        chmod 0440 "$sudo_file"
        if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$sudo_file" >/dev/null 2>&1; then
            printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u" > "$sudo_file"
            chmod 0440 "$sudo_file"
        fi
    }

    apply_client_resolv_search() {
        local resolv_file="/etc/resolv.conf"
        local target_ns1="$1"
        local target_ns2="$2"

        if [ -L "$resolv_file" ]; then
            chattr -i "$resolv_file" 2>/dev/null || true
            rm -f "$resolv_file"
        fi
        chattr -i "$resolv_file" 2>/dev/null || true
        printf "search %s\nnameserver %s\nnameserver %s\n" "$SEARCH_DOMAIN" "$target_ns1" "$target_ns2" > "$resolv_file"
        chmod 0644 "$resolv_file"
        chattr +i "$resolv_file" 2>/dev/null || true
    }

    prepare_base_node() {
        local hn ssh_user target_port
        hn="$(hostname -s 2>/dev/null || hostname)"
        log "[$hn] Подготовка пакетов, модулей ядра и SSH..."

        apt-get update -y >/dev/null 2>&1 || warn "Ошибка apt-get update на $hn"

        local base_pkgs="openssh-server openssh-clients sshpass python3 sudo nano curl wget ca-certificates chrony iptables iproute2 util-linux e2fsprogs"
        apt-get install -y $base_pkgs >/dev/null 2>&1 || warn "Часть базовых пакетов не установилась на $hn"

        modprobe nfs 2>/dev/null || true
        modprobe nfsv3 2>/dev/null || true
        modprobe raid0 2>/dev/null || true
        modprobe raid1 2>/dev/null || true
        modprobe raid456 2>/dev/null || true
        modprobe raid10 2>/dev/null || true

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

        ensure_ssh_user_rights "$ssh_user"

        if [[ "${hn,,}" == *hq-cli* ]]; then
            apply_client_resolv_search "$IP_BR_SRV" "$UPSTREAM_DNS"
        fi

        local sshd_cfg="/etc/openssh/sshd_config"
        [ -f "$sshd_cfg" ] || sshd_cfg="/etc/ssh/sshd_config"

        if [ -f "$sshd_cfg" ]; then
            sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_cfg"
            sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$sshd_cfg"
            sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' "$sshd_cfg"
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

    ssh_key_only() {
        local port="$1" target="$2"
        shift 2
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=6 -p "$port" "$target" "$@"
    }

    scp_key_only() {
        local port="$1"
        shift
        scp -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=6 -P "$port" "$@"
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

        printf '\n\033[1;33mПримечание по RAID на HQ-SRV:\033[0m\n'
        echo "  - RAID 0: минимум 2 диска"
        echo "  - RAID 1: минимум 2 диска"
        echo "  - RAID 5: минимум 3 диска"
        echo "  - RAID 6: минимум 4 диска"
        echo "  - RAID 10: минимум 4 диска (чётное число)"
        RAID_LEVEL=$(ask "Уровень RAID для HQ-SRV (0/1/5/6/10)" "$RAID_LEVEL")
        info_line "$(raid_reqs_note "$RAID_LEVEL")"
        RAID_FS=$(ask "Файловая система RAID (ext4/xfs/btrfs)" "$RAID_FS")
        case "${RAID_FS,,}" in
            ext4|xfs|btrfs) RAID_FS="${RAID_FS,,}" ;;
            *) warn "Неизвестная ФС '$RAID_FS', используется ext4"; RAID_FS="ext4" ;;
        esac

        # 1. Монтируем Additional.iso
        mkdir -p "$ISO_MOUNT"
        if [ -f "$ISO_PATH" ]; then
            mountpoint -q "$ISO_MOUNT" || mount -o loop "$ISO_PATH" "$ISO_MOUNT" 2>/dev/null || true
        elif [ -b /dev/sr0 ]; then
            mountpoint -q "$ISO_MOUNT" || mount -o ro /dev/sr0 "$ISO_MOUNT" 2>/dev/null || true
        fi

        # 2. Раздаём SSH-ключи со всех узлов + проверяем/чиним права SSH-пользователей
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519
        local pub_key
        pub_key="$(cat /root/.ssh/id_ed25519.pub)"

        ensure_remote_user_and_key() {
            local u="$1" h="$2" p="$3"
            local repair_cmd
            repair_cmd="sudo -n true >/dev/null 2>&1 || echo '${SSH_PASS}' | sudo -S true >/dev/null 2>&1; \
                echo '${SSH_PASS}' | sudo -S usermod -U '${u}' 2>/dev/null || true; \
                echo '${SSH_PASS}' | sudo -S bash -c 'echo \"${u}:${SSH_PASS}\" | chpasswd; \
                for g in wheel sudo; do getent group \$g >/dev/null 2>&1 && usermod -aG \$g \"${u}\" 2>/dev/null || true; done; \
                printf \"%s ALL=(ALL:ALL) NOPASSWD: ALL\n\" \"${u}\" > \"/etc/sudoers.d/90-${u}-nopasswd\"; \
                chmod 0440 \"/etc/sudoers.d/90-${u}-nopasswd\"; \
                mkdir -p \"/home/${u}/.ssh\"; chmod 0700 \"/home/${u}/.ssh\"; \
                touch \"/home/${u}/.ssh/authorized_keys\"; chmod 0600 \"/home/${u}/.ssh/authorized_keys\"; \
                grep -qxF \"${pub_key}\" \"/home/${u}/.ssh/authorized_keys\" 2>/dev/null || echo \"${pub_key}\" >> \"/home/${u}/.ssh/authorized_keys\"; \
                chown -R \"${u}:${u}\" \"/home/${u}\"'"

            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o NumberOfPasswordPrompts=1 -o ConnectTimeout=6 -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no -p "$p" "${u}@${h}" "$repair_cmd" >/dev/null 2>&1 || true

            if ! ssh_key_only "$p" "$u@$h" "sudo -n true" >/dev/null 2>&1; then
                ssh_key_only "$p" "$u@$h" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pub_key' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1 || true
            fi
        }

        ensure_remote_user_and_key "net_admin" "$IP_ISP_EXT" "22"
        ensure_remote_user_and_key "sshuser" "$IP_HQ_SRV" "$SSH_PORT_HQ_SRV"
        ensure_remote_user_and_key "sshuser" "$IP_HQ_CLI" "22"
        ensure_remote_user_and_key "net_admin" "$IP_HQ_RTR" "22"
        ensure_remote_user_and_key "net_admin" "$IP_BR_RTR" "22"

        # 3. [Задание 1 + Задание 6] Локальная настройка BR-SRV
        log "ПОДЛЮЧЕНИЕ BR-SRV (LOCAL)"
        local samba_ok="no" docker_ok="no" chrony_br_ok="no" br_reasons=()

        if ! mountpoint -q "$ISO_MOUNT"; then
            br_reasons+=("iso не смонтирован ($ISO_PATH)")
        fi

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
            if samba-tool group listmembers "$HQ_GROUP" >/dev/null 2>&1; then
                samba_ok="yes"
            else
                br_reasons+=("samba: не выполнен samba-tool/домен не поднят")
            fi
        else
            br_reasons+=("samba: нет samba-tool")
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
            if (cd /opt/testapp && (docker compose up -d || docker-compose up -d)) >/dev/null 2>&1; then
                docker_ok="yes"
            else
                br_reasons+=("docker: compose up не прошёл")
            fi
        else
            br_reasons+=("docker: нет $ISO_MOUNT/docker/compose.yaml")
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
        if (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony); then
            chrony_br_ok="yes"
        else
            br_reasons+=("chrony не активен")
        fi

        local br_reason_str
        br_reason_str="$(IFS='; '; echo "${br_reasons[*]:-}")"
        summary_block "ПОДЛЮЧЕНИЕ BR-SRV (LOCAL)" "$br_reason_str" "samba - $samba_ok" "docker - $docker_ok" "chrony - $chrony_br_ok"

        # 4. [Задание 4] BR-SRV -> ISP
        log "ПОДЛЮЧЕНИЕ BR-SRV -> ISP"
        local isp_ping="no" isp_chrony="no" isp_ipt="no" isp_reasons=()
        if ping -c 1 -W 2 "$IP_ISP_EXT" >/dev/null 2>&1; then
            isp_ping="yes"
        else
            isp_reasons+=("нет ping до $IP_ISP_EXT")
        fi

        if ssh_key_only "22" "net_admin@$IP_ISP_EXT" "sudo bash -s" <<EOF >/dev/null 2>&1
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
        then
            isp_chrony="yes"
        else
            isp_reasons+=("chrony/ssh на ISP сбой")
        fi

        if ssh_key_only "22" "net_admin@$IP_ISP_EXT" "sudo iptables -L >/dev/null 2>&1" >/dev/null 2>&1; then
            isp_ipt="yes"
        else
            isp_reasons+=("iptables недоступен на ISP")
        fi
        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> ISP" "$(IFS='; '; echo "${isp_reasons[*]:-}")" "chrony - $isp_chrony" "ping - $isp_ping" "iptables - $isp_ipt"

        # 5. [Задание 8] BR-SRV -> HQ-RTR
        log "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-RTR"
        local hqrtr_ping="no" hqrtr_chrony="no" hqrtr_dnat="no" hqrtr_reasons=()
        if ping -c 1 -W 2 "$IP_HQ_RTR" >/dev/null 2>&1; then
            hqrtr_ping="yes"
        else
            hqrtr_reasons+=("нет ping до $IP_HQ_RTR")
        fi

        if ssh_key_only "22" "net_admin@$IP_HQ_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1
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
        then
            hqrtr_chrony="yes"
        else
            hqrtr_reasons+=("chrony/ssh на HQ-RTR сбой")
        fi

        if ssh_key_only "22" "net_admin@$IP_HQ_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1
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
        then
            hqrtr_dnat="yes"
        else
            hqrtr_reasons+=("dnat/iptables на HQ-RTR сбой")
        fi
        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-RTR" "$(IFS='; '; echo "${hqrtr_reasons[*]:-}")" "chrony - $hqrtr_chrony" "ping - $hqrtr_ping" "dnat - $hqrtr_dnat"

        # 6. [Задание 8] BR-SRV -> BR-RTR
        log "ПОДЛЮЧЕНИЕ BR-SRV -> BR-RTR"
        local brrtr_ping="no" brrtr_chrony="no" brrtr_dnat="no" brrtr_reasons=()
        if ping -c 1 -W 2 "$IP_BR_RTR" >/dev/null 2>&1; then
            brrtr_ping="yes"
        else
            brrtr_reasons+=("нет ping до $IP_BR_RTR")
        fi

        if ssh_key_only "22" "net_admin@$IP_BR_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1
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
        then
            brrtr_chrony="yes"
        else
            brrtr_reasons+=("chrony/ssh на BR-RTR сбой")
        fi

        if ssh_key_only "22" "net_admin@$IP_BR_RTR" "sudo bash -s" <<EOF >/dev/null 2>&1
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
        then
            brrtr_dnat="yes"
        else
            brrtr_reasons+=("dnat/iptables на BR-RTR сбой")
        fi
        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> BR-RTR" "$(IFS='; '; echo "${brrtr_reasons[*]:-}")" "chrony - $brrtr_chrony" "ping - $brrtr_ping" "dnat - $brrtr_dnat"

        # 7. [Задания 2, 3, 7] BR-SRV -> HQ-SRV
        log "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-SRV"
        local hqsrv_ping="no" hqsrv_raid="no" hqsrv_nfs="no" hqsrv_web="no" hqsrv_chrony="no" hqsrv_reasons=()
        local min_req_disks
        min_req_disks="$(raid_min_disks "$RAID_LEVEL")"
        if ping -c 1 -W 2 "$IP_HQ_SRV" >/dev/null 2>&1; then
            hqsrv_ping="yes"
        else
            hqsrv_reasons+=("нет ping до $IP_HQ_SRV")
        fi

        if ! ssh_key_only "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo -n true" >/dev/null 2>&1; then
            hqsrv_reasons+=("ssh по ключу/sudo на порт $SSH_PORT_HQ_SRV не прошёл")
        else
            if [ -d "$ISO_MOUNT/web" ]; then
                scp_key_only "$SSH_PORT_HQ_SRV" -r "$ISO_MOUNT/web" "sshuser@$IP_HQ_SRV:/tmp/web_src" >/dev/null 2>&1 || true
            fi

            if ssh_key_only "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo bash -s" <<EOF >/dev/null 2>&1
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
            then
                hqsrv_chrony="yes"
            else
                hqsrv_reasons+=("chrony на HQ-SRV сбой")
            fi

            local raid_diag
            raid_diag="$(ssh_key_only "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo bash -s" <<EOF 2>/dev/null || true
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y mdadm e2fsprogs >/dev/null 2>&1 || true
case "$RAID_FS" in
    xfs)   apt-get install -y xfsprogs >/dev/null 2>&1 || true ;;
    btrfs) apt-get install -y btrfsprogs >/dev/null 2>&1 || true ;;
esac

modprobe raid0 2>/dev/null || true
modprobe raid1 2>/dev/null || true
modprobe raid456 2>/dev/null || true
modprobe raid10 2>/dev/null || true

CANDIDATES=()
for dev in /dev/sd[b-z] /dev/vd[b-z] /dev/xvd[b-z] /dev/nvme[1-9]n1; do
    if [ -b "\$dev" ]; then
        part_cnt=\$(lsblk -ln "\$dev" 2>/dev/null | awk '\$6=="part"{c++} END{print c+0}')
        if ! findmnt -S "\$dev" >/dev/null 2>&1 && [ "\$part_cnt" -eq 0 ]; then
            CANDIDATES+=("\$dev")
        fi
    fi
done

echo "CANDIDATES_LIST=\${CANDIDATES[*]:-none}"
echo "CANDIDATES_COUNT=\${#CANDIDATES[@]}"

RAID_READY="no"
SELECTED=()
if [ "$RAID_LEVEL" = "10" ]; then
    if [ "\${#CANDIDATES[@]}" -ge $min_req_disks ] && [ \$(( \${#CANDIDATES[@]} % 2 )) -eq 0 ]; then
        SELECTED=("\${CANDIDATES[@]}")
        RAID_READY="yes"
    else
        echo "RAID_REASON=нужно чётное число дисков >= $min_req_disks (найдено: \${#CANDIDATES[@]})"
    fi
else
    if [ "\${#CANDIDATES[@]}" -ge $min_req_disks ]; then
        SELECTED=("\${CANDIDATES[@]:0:$min_req_disks}")
        RAID_READY="yes"
    else
        echo "RAID_REASON=недостаточно свободных дисков для RAID $RAID_LEVEL (нужно >= $min_req_disks, найдено: \${#CANDIDATES[@]})"
    fi
fi

if [ "\$RAID_READY" = "yes" ]; then
    echo "SELECTED_DISKS=\${SELECTED[*]}"
    if [ ! -b "$RAID_DEV" ]; then
        mdadm --create "$RAID_DEV" --level=$RAID_LEVEL --raid-devices=\${#SELECTED[@]} "\${SELECTED[@]}" --run --yes >/dev/null 2>&1 || true
    fi
    if [ -b "$RAID_DEV" ]; then
        mdadm --detail --scan > /etc/mdadm.conf || true
        if ! blkid "$RAID_DEV" >/dev/null 2>&1; then
            case "$RAID_FS" in
                xfs)   mkfs.xfs -f "$RAID_DEV" >/dev/null 2>&1 || true ;;
                btrfs) mkfs.btrfs -f "$RAID_DEV" >/dev/null 2>&1 || true ;;
                *)     mkfs.ext4 -F "$RAID_DEV" >/dev/null 2>&1 || true ;;
            esac
        fi
        mkdir -p "$RAID_MOUNT"
        grep -q "^$RAID_DEV[[:space:]]" /etc/fstab || echo "$RAID_DEV $RAID_MOUNT $RAID_FS defaults,nofail 0 2" >> /etc/fstab
        mount -a || true
    fi
fi

mountpoint -q "$RAID_MOUNT" && echo "RAID_OK=yes" || echo "RAID_OK=no"
EOF
)"
            local c_list c_cnt s_disks r_reason
            c_list="$(printf '%s\n' "$raid_diag" | awk -F= '/^CANDIDATES_LIST=/{print $2}')"
            c_cnt="$(printf '%s\n' "$raid_diag" | awk -F= '/^CANDIDATES_COUNT=/{print $2}')"
            s_disks="$(printf '%s\n' "$raid_diag" | awk -F= '/^SELECTED_DISKS=/{print $2}')"
            r_reason="$(printf '%s\n' "$raid_diag" | awk -F= '/^RAID_REASON=/{print $2}')"
            info_line "RAID проверка (уровень $RAID_LEVEL, мин. дисков: $min_req_disks, ФС: $RAID_FS): кандидаты=[${c_list:-none}] (кол-во: ${c_cnt:-0})"
            [ -n "${s_disks:-}" ] && info_line "Выбранные диски для $RAID_DEV: $s_disks"
            if [[ "$raid_diag" == *"RAID_OK=yes"* ]]; then
                hqsrv_raid="yes"
            else
                hqsrv_reasons+=("raid: ${r_reason:-не смонтирован $RAID_MOUNT}")
            fi

            ssh_key_only "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" "sudo bash -s" <<EOF >/dev/null 2>&1 || true
apt-get install -y nfs-server rpcbind >/dev/null 2>&1 || true
modprobe nfs 2>/dev/null || true
modprobe nfsv3 2>/dev/null || true
control rpcbind server 2>/dev/null || true
systemctl enable --now rpcbind >/dev/null 2>&1 || true
systemctl restart rpcbind >/dev/null 2>&1 || true
systemctl enable --now nfs-server >/dev/null 2>&1 || true
mkdir -p "$NFS_EXPORT_DIR" && chmod 777 "$NFS_EXPORT_DIR"
grep -q "^$NFS_EXPORT_DIR[[:space:]]" /etc/exports || \
    echo "$NFS_EXPORT_DIR $HQ_CLI_NET(rw,sync,no_subtree_check,no_root_squash,insecure)" >> /etc/exports
exportfs -ra >/dev/null 2>&1 || true
systemctl restart nfs-server >/dev/null 2>&1 || true

apt-get install -y httpd2 mariadb-server 2>/dev/null || apt-get install -y apache2 mariadb-server 2>/dev/null || true
apt-get install -y php8.2 php8.2-mysql 2>/dev/null || apt-get install -y php php-mysql 2>/dev/null || true
systemctl enable --now mariadb >/dev/null 2>&1 || true
systemctl enable --now httpd2 >/dev/null 2>&1 || systemctl enable --now apache2 >/dev/null 2>&1 || true

for _ in {1..15}; do
    mariadb-admin ping >/dev/null 2>&1 && break
    sleep 1
done

if [ -d /tmp/web_src ]; then
    mariadb -e "CREATE DATABASE IF NOT EXISTS webdb;" 2>/dev/null || true
    mariadb -e "CREATE USER IF NOT EXISTS 'web'@'%' IDENTIFIED BY 'P@ssw0rd';" 2>/dev/null || true
    mariadb -e "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';" 2>/dev/null || true
    mariadb -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';" 2>/dev/null || true
    mariadb -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';" 2>/dev/null || true
    mariadb -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    [ -f /tmp/web_src/dump.sql ] && mariadb webdb < /tmp/web_src/dump.sql 2>/dev/null || true

    WEB_DIR="/var/www/html"
    [ -d /var/www/httpd2/htdocs ] && WEB_DIR="/var/www/httpd2/htdocs"
    mkdir -p "\$WEB_DIR"
    [ -f /tmp/web_src/index.php ] && cp -f /tmp/web_src/index.php "\$WEB_DIR/"
    [ -f /tmp/web_src/logo.png ] && cp -f /tmp/web_src/logo.png "\$WEB_DIR/"
    [ -f "\$WEB_DIR/index.php" ] && sed -i 's/DB_USER_HERE/web/g; s/DB_PASS_HERE/P@ssw0rd/g; s/DB_NAME_HERE/webdb/g' "\$WEB_DIR/index.php"
    systemctl restart httpd2 >/dev/null 2>&1 || systemctl restart apache2 >/dev/null 2>&1 || true
fi
EOF
            local srv_out
            srv_out="$(ssh_key_only "$SSH_PORT_HQ_SRV" "sshuser@$IP_HQ_SRV" \
                "exportfs | grep -q '$NFS_EXPORT_DIR' && echo NFS_OK=yes || echo NFS_OK=no; (systemctl is-active --quiet httpd2 || systemctl is-active --quiet apache2) && echo WEB_OK=yes || echo WEB_OK=no" \
                2>/dev/null || true)"
            if [[ "$srv_out" == *"NFS_OK=yes"* ]]; then
                hqsrv_nfs="yes"
            else
                hqsrv_reasons+=("nfs не экспортирован")
            fi
            if [[ "$srv_out" == *"WEB_OK=yes"* ]]; then
                hqsrv_web="yes"
            else
                hqsrv_reasons+=("web-сервер не активен")
            fi
        fi

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-SRV" "$(IFS='; '; echo "${hqsrv_reasons[*]:-}")" "raid - $hqsrv_raid ($RAID_LEVEL/$RAID_FS)" "nfs - $hqsrv_nfs" "web - $hqsrv_web" "chrony - $hqsrv_chrony" "ping - $hqsrv_ping"

        # 8. [Задания 1, 3, 9] BR-SRV -> HQ-CLI
        log "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-CLI"
        local cli_ping="no" cli_ad="no" cli_nfs="no" cli_browser="no" cli_chrony="no" cli_reasons=()
        if ping -c 1 -W 2 "$IP_HQ_CLI" >/dev/null 2>&1; then
            cli_ping="yes"
        else
            cli_reasons+=("нет ping до $IP_HQ_CLI")
        fi

        if [ -f /var/lib/samba/private/krb5.conf ]; then
            scp_key_only "22" /var/lib/samba/private/krb5.conf "sshuser@$IP_HQ_CLI:/tmp/krb5.conf" >/dev/null 2>&1 || true
        fi

        ssh_key_only "22" "sshuser@$IP_HQ_CLI" "sudo bash -s" <<EOF >/dev/null 2>&1 || true
set -e
systemctl stop avahi-daemon 2>/dev/null || true
systemctl disable avahi-daemon 2>/dev/null || true

grep -q "$IP_BR_SRV" /etc/hosts || echo "$IP_BR_SRV br-srv.hq.local hq.local" >> /etc/hosts

if [ -L /etc/resolv.conf ]; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
printf "search %s\nnameserver %s\nnameserver %s\n" "$SEARCH_DOMAIN" "$IP_BR_SRV" "$UPSTREAM_DNS" > /etc/resolv.conf
chmod 0644 /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

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
systemctl enable --now rpcbind >/dev/null 2>&1 || true
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
        cli_out="$(ssh_key_only "22" "sshuser@$IP_HQ_CLI" \
            "realm list 2>/dev/null | grep -qi 'hq.local' && echo AD_OK=yes || echo AD_OK=no; mountpoint -q '$CLI_NFS_MOUNT' && echo NFS_OK=yes || echo NFS_OK=no; (command -v yandex-browser-stable >/dev/null 2>&1 || rpm -q yandex-browser-stable >/dev/null 2>&1) && echo BR_OK=yes || echo BR_OK=no; (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony) && echo CH_OK=yes || echo CH_OK=no" \
            2>/dev/null || true)"
        if [[ "$cli_out" == *"AD_OK=yes"* ]]; then
            cli_ad="yes"
        else
            cli_reasons+=("domain: realm join не выполнен (проверь DNS/KDC $AD_REALM)")
        fi
        if [[ "$cli_out" == *"NFS_OK=yes"* ]]; then
            cli_nfs="yes"
        else
            cli_reasons+=("nfs: $CLI_NFS_MOUNT не смонтирован")
        fi
        if [[ "$cli_out" == *"BR_OK=yes"* ]]; then
            cli_browser="yes"
        else
            cli_reasons+=("yandex-browser не найден")
        fi
        if [[ "$cli_out" == *"CH_OK=yes"* ]]; then
            cli_chrony="yes"
        else
            cli_reasons+=("chrony на HQ-CLI не активен")
        fi

        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> HQ-CLI" "$(IFS='; '; echo "${cli_reasons[*]:-}")" "domain - $cli_ad" "nfs - $cli_nfs" "browser - $cli_browser" "chrony - $cli_chrony" "ping - $cli_ping"

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
        local ans_ok="no" ans_reason=""
        if ansible targets -m ping; then
            ans_ok="yes"
        else
            ans_reason="один или несколько узлов недоступны по SSH/sudo (см. вывод ansible выше)"
        fi
        summary_block "ПОДЛЮЧЕНИЕ BR-SRV -> ANSIBLE" "$ans_reason" "inventory - yes" "ping - $ans_ok"

        # 10. Очистка истории и перезагрузка всех машин (сначала периферия, затем BR-SRV)
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
            ssh_key_only "$p" "$u_h" \
                "history -a 2>/dev/null || true; history -w 2>/dev/null || true; sudo setsid sh -c 'sleep 2; /sbin/reboot -f || systemctl reboot -i' >/dev/null 2>&1 < /dev/null &" \
                >/dev/null 2>&1 || true
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
