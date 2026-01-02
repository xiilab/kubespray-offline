#!/bin/bash
# ============================================
# setup-nfs-registry.sh
# NFS 마운트 for Registry HA
# ============================================
#
# 사용법:
#   export NFS_SERVER="10.61.3.100"
#   export NFS_PATH="/kube_storage/registry"
#   ./setup-nfs-registry.sh
#
# 또는:
#   ./setup-nfs-registry.sh 10.61.3.100 /kube_storage/registry
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 인자 또는 환경변수에서 설정 읽기
NFS_SERVER="${1:-${NFS_SERVER:?NFS_SERVER is required}}"
NFS_PATH="${2:-${NFS_PATH:?NFS_PATH is required}}"
REGISTRY_DIR="${REGISTRY_DIR:-/var/lib/registry}"

echo "============================================"
echo "NFS Registry Setup"
echo "============================================"
echo "NFS Server: ${NFS_SERVER}"
echo "NFS Path:   ${NFS_PATH}"
echo "Mount Dir:  ${REGISTRY_DIR}"
echo "============================================"

# 로컬 패키지에서 설치하는 함수
install_from_local_rhel() {
    local pkg_name="$1"
    local pkg_dir="$SCRIPT_DIR/rpms/local"

    if [ -d "$pkg_dir" ]; then
        echo "Searching for $pkg_name in $pkg_dir..."
        local pkg_file=$(find "$pkg_dir" -name "${pkg_name}*.rpm" 2>/dev/null | head -1)
        if [ -n "$pkg_file" ]; then
            echo "Found: $pkg_file"
            rpm -ivh --nodeps "$pkg_file" || yum localinstall -y "$pkg_file"
            return 0
        fi
    fi
    return 1
}

install_from_local_ubuntu() {
    local pkg_name="$1"
    local pkg_dir="$SCRIPT_DIR/debs/local"

    if [ -d "$pkg_dir" ]; then
        echo "Searching for $pkg_name in $pkg_dir..."
        local pkg_file=$(find "$pkg_dir" -name "${pkg_name}*.deb" 2>/dev/null | head -1)
        if [ -n "$pkg_file" ]; then
            echo "Found: $pkg_file"
            dpkg -i "$pkg_file" || apt-get install -f -y
            return 0
        fi
    fi
    return 1
}

# 1. NFS 클라이언트 패키지 설치
echo ""
echo "==> Installing NFS client packages..."

if command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    if dpkg -l | grep -q "^ii.*nfs-common"; then
        echo "nfs-common already installed"
    else
        echo "Installing nfs-common..."
        # 먼저 로컬 패키지에서 시도
        if ! install_from_local_ubuntu "nfs-common"; then
            echo "Local package not found, trying apt-get..."
            apt-get update -qq && apt-get install -y nfs-common
        fi
    fi
elif command -v dnf &> /dev/null; then
    # Fedora/RHEL 8+
    if rpm -q nfs-utils &> /dev/null; then
        echo "nfs-utils already installed"
    else
        echo "Installing nfs-utils..."
        if ! install_from_local_rhel "nfs-utils"; then
            echo "Local package not found, trying dnf..."
            dnf install -y nfs-utils
        fi
    fi
elif command -v yum &> /dev/null; then
    # RHEL/CentOS 7
    if rpm -q nfs-utils &> /dev/null; then
        echo "nfs-utils already installed"
    else
        echo "Installing nfs-utils..."
        if ! install_from_local_rhel "nfs-utils"; then
            echo "Local package not found, trying yum..."
            yum install -y nfs-utils
        fi
    fi
else
    echo "WARNING: Unknown package manager, assuming NFS client is installed"
fi

# 2. 마운트 디렉토리 생성
echo ""
echo "==> Creating mount directory..."
if [ ! -d "$REGISTRY_DIR" ]; then
    mkdir -p "$REGISTRY_DIR"
    echo "Created: $REGISTRY_DIR"
else
    echo "Already exists: $REGISTRY_DIR"
fi

# 3. 이미 마운트되어 있으면 스킵
echo ""
echo "==> Checking mount status..."
if mountpoint -q "$REGISTRY_DIR"; then
    echo "Already mounted: $REGISTRY_DIR"
    echo ""
    echo "Current mount:"
    mount | grep "$REGISTRY_DIR"
    echo ""
    echo "============================================"
    echo "NFS Setup: Already configured"
    echo "============================================"
    exit 0
fi

# 4. NFS 서버 연결 테스트
echo ""
echo "==> Testing NFS server connection..."
if ! showmount -e "$NFS_SERVER" &> /dev/null; then
    echo "WARNING: Cannot query NFS exports from $NFS_SERVER"
    echo "This might be due to firewall rules, continuing anyway..."
fi

# 5. fstab 등록 (중복 방지)
echo ""
echo "==> Configuring /etc/fstab..."
FSTAB_ENTRY="${NFS_SERVER}:${NFS_PATH}  ${REGISTRY_DIR}  nfs  defaults,_netdev,nofail  0  0"

if grep -q "$REGISTRY_DIR" /etc/fstab; then
    echo "Entry already exists in /etc/fstab"
    grep "$REGISTRY_DIR" /etc/fstab
else
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "Added to /etc/fstab:"
    echo "  $FSTAB_ENTRY"
fi

# 6. 마운트 실행
echo ""
echo "==> Mounting NFS..."
if ! mount "$REGISTRY_DIR"; then
    echo ""
    echo "ERROR: Mount failed. Please check:"
    echo "  1. NFS server is running: systemctl status nfs-server"
    echo "  2. Export exists: showmount -e $NFS_SERVER"
    echo "  3. Firewall allows NFS: firewall-cmd --list-all"
    echo "  4. Export permissions in /etc/exports"
    exit 1
fi

# 7. 마운트 검증
echo ""
echo "==> Verifying mount..."
if mountpoint -q "$REGISTRY_DIR"; then
    echo "Mount successful!"
    echo ""
    echo "Mount info:"
    mount | grep "$REGISTRY_DIR"
    echo ""
    echo "Disk usage:"
    df -h "$REGISTRY_DIR"
else
    echo "ERROR: Mount verification failed"
    exit 1
fi

# 8. 쓰기 권한 테스트
echo ""
echo "==> Testing write permission..."
TEST_FILE="$REGISTRY_DIR/.write_test_$$"
if touch "$TEST_FILE" 2>/dev/null; then
    rm -f "$TEST_FILE"
    echo "Write permission: OK"
else
    echo "WARNING: Cannot write to $REGISTRY_DIR"
    echo "Please check NFS export permissions (no_root_squash may be needed)"
fi

echo ""
echo "============================================"
echo "NFS Setup Complete"
echo "============================================"
