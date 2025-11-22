#!/bin/bash
# Kubespray version to download. Use "master" for latest master branch.
KUBESPRAY_VERSION=${KUBESPRAY_VERSION:-2.29.0}
#KUBESPRAY_VERSION=${KUBESPRAY_VERSION:-master}

# Versions of containerd related binaries used in `install-containerd.sh`
# These version must be same as kubespray.
# Refer `roles/kubespray_defaults/vars/main/checksums.yml` of kubespray.
#
# 버전별로 자동 설정됨
case "$KUBESPRAY_VERSION" in
    2.24.3)
        # Kubernetes v1.28.14 (RHEL8 환경 최적화)
        RUNC_VERSION=1.1.14
        CONTAINERD_VERSION=1.7.22
        NERDCTL_VERSION=1.7.7
        CNI_VERSION=1.3.0
        ;;
    2.29.0)
        # Kubernetes v1.33.5 (최신 버전)
        RUNC_VERSION=1.3.2
        CONTAINERD_VERSION=2.1.4
        NERDCTL_VERSION=2.1.6
        CNI_VERSION=1.8.0
        ;;
    *)
        echo "❌ 지원하지 않는 Kubespray 버전: $KUBESPRAY_VERSION"
        echo "   지원 버전: 2.24.3, 2.29.0"
        exit 1
        ;;
esac

# Some container versions, must be same as ../imagelists/images.txt
NGINX_VERSION=1.29.2
REGISTRY_VERSION=2.8.3

# container registry port
REGISTRY_PORT=${REGISTRY_PORT:-35000}

# nginx http server port
NGINX_PORT=${NGINX_PORT:-36000}

# Additional container registry hosts
ADDITIONAL_CONTAINER_REGISTRY_LIST=${ADDITIONAL_CONTAINER_REGISTRY_LIST:-"myregistry.io"}

# Output directory for downloaded files
# Can be customized for version-specific directories (e.g., outputs-2.28.1)
OUTPUT_DIR=${OUTPUT_DIR:-outputs}
