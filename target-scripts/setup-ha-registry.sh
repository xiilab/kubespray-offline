#!/bin/bash
# ============================================
# setup-ha-registry.sh
# HA Registry 통합 설정 스크립트
# ============================================
#
# 이 스크립트는 HA Registry 설정의 모든 단계를 통합합니다.
# 각 노드에서 개별 실행하거나, install.sh에서 원격 호출됩니다.
#
# 사용법:
#   # MASTER 노드
#   ./setup-ha-registry.sh --master \
#       --vip 10.61.3.200 \
#       --nfs-server 10.61.3.100 \
#       --nfs-path /kube_storage/registry \
#       --local-ip 10.61.3.11 \
#       --peer-ip 10.61.3.12
#
#   # BACKUP 노드
#   ./setup-ha-registry.sh --backup \
#       --vip 10.61.3.200 \
#       --nfs-server 10.61.3.100 \
#       --nfs-path /kube_storage/registry \
#       --local-ip 10.61.3.12 \
#       --peer-ip 10.61.3.11
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 기본값
STATE="MASTER"
PRIORITY="100"

# 사용법 출력
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

HA Registry 설정 통합 스크립트

Options:
    --master            MASTER 노드로 설정 (priority=100)
    --backup            BACKUP 노드로 설정 (priority=90)
    --vip <IP>          Registry VIP 주소 (필수)
    --nfs-server <IP>   NFS 서버 주소 (필수)
    --nfs-path <PATH>   NFS 경로 (필수)
    --local-ip <IP>     이 노드의 IP 주소 (필수)
    --peer-ip <IP>      상대 노드의 IP 주소 (필수)
    --priority <N>      Keepalived priority (기본: MASTER=100, BACKUP=90)
    --skip-nfs          NFS 마운트 단계 생략
    --start             설정 후 Keepalived 즉시 시작
    -h, --help          도움말 출력

Examples:
    # MASTER 노드 설정 (setup-all.sh 실행 후)
    $0 --master --vip 10.61.3.200 --nfs-server 10.61.3.100 \\
       --nfs-path /kube_storage/registry \\
       --local-ip 10.61.3.11 --peer-ip 10.61.3.12 --start

    # BACKUP 노드 설정
    $0 --backup --vip 10.61.3.200 --nfs-server 10.61.3.100 \\
       --nfs-path /kube_storage/registry \\
       --local-ip 10.61.3.12 --peer-ip 10.61.3.11 --start
EOF
    exit 1
}

# 인자 파싱
SKIP_NFS=false
START_NOW=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --master)
            STATE="MASTER"
            PRIORITY="100"
            shift
            ;;
        --backup)
            STATE="BACKUP"
            PRIORITY="90"
            shift
            ;;
        --vip)
            REGISTRY_VIP="$2"
            shift 2
            ;;
        --nfs-server)
            NFS_SERVER="$2"
            shift 2
            ;;
        --nfs-path)
            NFS_PATH="$2"
            shift 2
            ;;
        --local-ip)
            LOCAL_IP="$2"
            shift 2
            ;;
        --peer-ip)
            PEER_IP="$2"
            shift 2
            ;;
        --priority)
            PRIORITY="$2"
            shift 2
            ;;
        --skip-nfs)
            SKIP_NFS=true
            shift
            ;;
        --start)
            START_NOW=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# 필수 인자 확인
if [ -z "$REGISTRY_VIP" ] || [ -z "$LOCAL_IP" ] || [ -z "$PEER_IP" ]; then
    echo "ERROR: Missing required arguments"
    echo ""
    usage
fi

if [ "$SKIP_NFS" = false ] && ([ -z "$NFS_SERVER" ] || [ -z "$NFS_PATH" ]); then
    echo "ERROR: NFS server and path required (or use --skip-nfs)"
    echo ""
    usage
fi

echo "============================================"
echo "HA Registry Setup"
echo "============================================"
echo "Role:         ${STATE} (priority=${PRIORITY})"
echo "VIP:          ${REGISTRY_VIP}"
echo "Local IP:     ${LOCAL_IP}"
echo "Peer IP:      ${PEER_IP}"
if [ "$SKIP_NFS" = false ]; then
    echo "NFS Server:   ${NFS_SERVER}"
    echo "NFS Path:     ${NFS_PATH}"
fi
echo "============================================"
echo ""

# Step 1: NFS 마운트 (SKIP_NFS가 아닌 경우)
if [ "$SKIP_NFS" = false ]; then
    echo ">>> Step 1: NFS Mount"
    echo "--------------------------------------------"

    if [ -f "$SCRIPT_DIR/setup-nfs-registry.sh" ]; then
        export NFS_SERVER NFS_PATH
        "$SCRIPT_DIR/setup-nfs-registry.sh"
    else
        echo "ERROR: setup-nfs-registry.sh not found in $SCRIPT_DIR"
        exit 1
    fi
    echo ""
else
    echo ">>> Step 1: NFS Mount (SKIPPED)"
    echo ""
fi

# Step 2: Keepalived 설치
echo ">>> Step 2: Keepalived Installation"
echo "--------------------------------------------"

if [ -f "$SCRIPT_DIR/install-keepalived.sh" ]; then
    export REGISTRY_VIP LOCAL_IP PEER_IP STATE PRIORITY
    "$SCRIPT_DIR/install-keepalived.sh"
else
    echo "ERROR: install-keepalived.sh not found in $SCRIPT_DIR"
    exit 1
fi
echo ""

# Step 3: Keepalived 시작 (옵션)
if [ "$START_NOW" = true ]; then
    echo ">>> Step 3: Starting Keepalived"
    echo "--------------------------------------------"

    # MASTER 노드인 경우, 기존 Registry 중지
    if [ "$STATE" = "MASTER" ]; then
        echo "Stopping existing registry (if any)..."
        sudo /usr/local/bin/nerdctl stop registry 2>/dev/null || true
        sudo /usr/local/bin/nerdctl rm registry 2>/dev/null || true
    fi

    echo "Starting keepalived service..."
    sudo systemctl start keepalived

    # 상태 확인
    sleep 3
    echo ""
    echo "Keepalived status:"
    sudo systemctl status keepalived --no-pager -l || true
    echo ""

    # VIP 확인
    echo "VIP status:"
    if ip addr show | grep -q "$REGISTRY_VIP"; then
        echo "VIP $REGISTRY_VIP is assigned to this node"
    else
        echo "VIP $REGISTRY_VIP is NOT on this node (expected for BACKUP)"
    fi
    echo ""
else
    echo ">>> Step 3: Keepalived Start (SKIPPED - use --start to auto-start)"
    echo ""
    echo "To start manually:"
    echo "  sudo systemctl start keepalived"
    echo ""
fi

echo "============================================"
echo "HA Registry Setup Complete"
echo "============================================"
echo ""
echo "Verification commands:"
echo "  # Check VIP location"
echo "  ip addr show | grep $REGISTRY_VIP"
echo ""
echo "  # Check keepalived status"
echo "  sudo systemctl status keepalived"
echo ""
echo "  # Check registry access via VIP"
echo "  curl http://${REGISTRY_VIP}:35000/v2/_catalog"
echo ""
echo "  # View transition logs"
echo "  tail -f /var/log/keepalived-registry.log"
echo ""
