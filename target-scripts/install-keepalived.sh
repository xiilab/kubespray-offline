#!/bin/bash
# ============================================
# install-keepalived.sh
# Keepalived 설치 및 HA Registry 설정
# ============================================
#
# 사용법:
#   export REGISTRY_VIP="10.61.3.200"
#   export LOCAL_IP="10.61.3.11"
#   export PEER_IP="10.61.3.12"
#   export STATE="MASTER"       # or BACKUP
#   export PRIORITY="100"       # MASTER=100, BACKUP=90
#   ./install-keepalived.sh
#

set -e

# 필수 환경변수 확인
REGISTRY_VIP="${REGISTRY_VIP:?REGISTRY_VIP is required}"
LOCAL_IP="${LOCAL_IP:?LOCAL_IP is required}"
PEER_IP="${PEER_IP:?PEER_IP is required}"
PRIORITY="${PRIORITY:-100}"
STATE="${STATE:-MASTER}"
INTERFACE="${INTERFACE:-auto}"
AUTH_PASS="${AUTH_PASS:-registry_ha_secret}"
REGISTRY_PORT="${REGISTRY_PORT:-35000}"
REGISTRY_DIR="${REGISTRY_DIR:-/var/lib/registry}"

echo "============================================"
echo "Keepalived Installation for HA Registry"
echo "============================================"
echo "State:        ${STATE}"
echo "Priority:     ${PRIORITY}"
echo "VIP:          ${REGISTRY_VIP}"
echo "Local IP:     ${LOCAL_IP}"
echo "Peer IP:      ${PEER_IP}"
echo "============================================"

# 1. Keepalived 설치
echo ""
echo "==> Installing Keepalived..."
if command -v apt-get &> /dev/null; then
    if ! dpkg -l | grep -q keepalived; then
        apt-get update -qq
        apt-get install -y keepalived
    else
        echo "keepalived already installed"
    fi
elif command -v yum &> /dev/null; then
    if ! rpm -q keepalived &> /dev/null; then
        yum install -y keepalived
    else
        echo "keepalived already installed"
    fi
elif command -v dnf &> /dev/null; then
    if ! rpm -q keepalived &> /dev/null; then
        dnf install -y keepalived
    else
        echo "keepalived already installed"
    fi
else
    echo "ERROR: Unknown package manager"
    exit 1
fi

# 2. 네트워크 인터페이스 자동 감지
echo ""
echo "==> Detecting network interface..."
if [ "$INTERFACE" = "auto" ]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
    fi
fi
echo "Using interface: $INTERFACE"

# VIP 서브넷 마스크 추출 (기본값 /24)
VIP_CIDR="${REGISTRY_VIP}/24"

# 3. notify 스크립트 생성
echo ""
echo "==> Creating notify scripts..."

# notify-master.sh
cat > /etc/keepalived/notify-master.sh << 'MASTEREOF'
#!/bin/bash
# ============================================
# notify-master.sh
# MASTER 승격 시 Registry 시작
# ============================================

LOG="/var/log/keepalived-registry.log"
REGISTRY_NAME="registry"
REGISTRY_PORT="${REGISTRY_PORT:-35000}"
REGISTRY_DIR="${REGISTRY_DIR:-/var/lib/registry}"
REGISTRY_IMAGE="registry:2.8.3"
NERDCTL="/usr/local/bin/nerdctl"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MASTER] $1" | tee -a "$LOG"
}

log "============================================"
log "Becoming MASTER - Starting Registry"
log "============================================"

# NFS 마운트 확인
if ! mountpoint -q "$REGISTRY_DIR"; then
    log "WARNING: NFS not mounted at $REGISTRY_DIR, attempting mount..."
    mount -a
    sleep 2
    if ! mountpoint -q "$REGISTRY_DIR"; then
        log "ERROR: NFS mount failed - Registry data may not be available"
        # NFS 없이도 Registry 시작 시도 (로컬 데이터 사용)
    fi
fi
log "Storage: $REGISTRY_DIR ($(mountpoint -q "$REGISTRY_DIR" && echo 'NFS' || echo 'LOCAL'))"

# 기존 Registry 정리
log "Stopping any existing registry..."
sudo $NERDCTL stop "$REGISTRY_NAME" 2>/dev/null || true
sudo $NERDCTL rm "$REGISTRY_NAME" 2>/dev/null || true

# Registry 시작
log "Starting registry on port $REGISTRY_PORT..."
if sudo $NERDCTL run -d \
    --network host \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:${REGISTRY_PORT} \
    --restart always \
    --name "$REGISTRY_NAME" \
    -v "${REGISTRY_DIR}:/var/lib/registry" \
    "$REGISTRY_IMAGE"; then
    log "Registry container started"
else
    log "ERROR: Failed to start registry container"
    exit 1
fi

# 시작 확인 (최대 30초)
log "Waiting for registry to be ready..."
for i in {1..30}; do
    if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" > /dev/null 2>&1; then
        log "Registry is ready (${i}s)"
        log "============================================"
        exit 0
    fi
    sleep 1
done

log "ERROR: Registry failed to start within 30 seconds"
exit 1
MASTEREOF

# notify-backup.sh
cat > /etc/keepalived/notify-backup.sh << 'BACKUPEOF'
#!/bin/bash
# ============================================
# notify-backup.sh
# BACKUP 강등 또는 FAULT 시 Registry 중지
# ============================================

LOG="/var/log/keepalived-registry.log"
NERDCTL="/usr/local/bin/nerdctl"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [BACKUP] $1" | tee -a "$LOG"
}

log "============================================"
log "Becoming BACKUP/FAULT - Stopping Registry"
log "============================================"

# Registry 강제 중지 (단일 Writer 보장)
log "Stopping registry..."
sudo $NERDCTL stop registry 2>/dev/null || true
sudo $NERDCTL rm registry 2>/dev/null || true

log "Registry stopped"
log "============================================"
exit 0
BACKUPEOF

# 실행 권한 설정
chmod +x /etc/keepalived/notify-master.sh
chmod +x /etc/keepalived/notify-backup.sh
echo "Created: /etc/keepalived/notify-master.sh"
echo "Created: /etc/keepalived/notify-backup.sh"

# 4. keepalived.conf 생성
echo ""
echo "==> Creating keepalived.conf..."

cat > /etc/keepalived/keepalived.conf << EOF
# ============================================
# Keepalived Configuration for HA Registry
# Generated by install-keepalived.sh
# ============================================

global_defs {
    router_id REGISTRY_HA_$(hostname -s)
    script_user root
    enable_script_security
    # 로그 설정
    notification_email_from keepalived@$(hostname -f)
}

vrrp_instance VI_REGISTRY {
    state ${STATE}
    interface ${INTERFACE}
    virtual_router_id 52          # kube-vip(51)과 다른 ID
    priority ${PRIORITY}
    advert_int 2                  # 2초 간격 advertisement

    # GARP 설정 (ARP 캐시 갱신 가속화)
    garp_master_delay 1
    garp_master_repeat 3
    garp_master_refresh 5

    # Unicast VRRP (multicast 차단 환경 대응)
    unicast_src_ip ${LOCAL_IP}
    unicast_peer {
        ${PEER_IP}
    }

    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }

    virtual_ipaddress {
        ${VIP_CIDR}
    }

    # 상태 전환 시 notify 스크립트 실행
    notify_master "/etc/keepalived/notify-master.sh"
    notify_backup "/etc/keepalived/notify-backup.sh"
    notify_fault  "/etc/keepalived/notify-backup.sh"
}
EOF

echo "Created: /etc/keepalived/keepalived.conf"

# 5. 환경변수를 notify 스크립트에 주입
echo ""
echo "==> Injecting environment variables..."

# notify-master.sh에 환경변수 설정
sed -i "s|REGISTRY_PORT:-35000|REGISTRY_PORT:-${REGISTRY_PORT}|g" /etc/keepalived/notify-master.sh
sed -i "s|REGISTRY_DIR:-/var/lib/registry|REGISTRY_DIR:-${REGISTRY_DIR}|g" /etc/keepalived/notify-master.sh

# 6. 설정 검증
echo ""
echo "==> Validating configuration..."
if keepalived --config-test 2>/dev/null; then
    echo "Configuration: VALID"
else
    echo "WARNING: Could not validate configuration (older keepalived version)"
fi

# 7. 서비스 활성화 (시작은 하지 않음)
echo ""
echo "==> Enabling keepalived service..."
systemctl enable keepalived

echo ""
echo "============================================"
echo "Keepalived Installation Complete"
echo "============================================"
echo ""
echo "To start keepalived:"
echo "  sudo systemctl start keepalived"
echo ""
echo "To check status:"
echo "  sudo systemctl status keepalived"
echo "  ip addr show | grep ${REGISTRY_VIP}"
echo ""
echo "Log file:"
echo "  /var/log/keepalived-registry.log"
echo ""
