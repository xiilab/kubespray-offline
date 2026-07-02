#!/bin/bash
#
# 이미지 아카이브(images/*.tar.gz)를 로컬 레지스트리로 푸시한다.
#
# skopeo copy 방식: tarball -> registry 직접 복사.
#   기존 nerdctl load + push 방식은 containerd content store에 한 번,
#   레지스트리에 또 한 번 저장되어 이미지가 중복 적재됐다(디스크 낭비).
#   skopeo는 containerd를 거치지 않으므로 중복 적재가 없다.
#
source ./config.sh

LOCAL_REGISTRY=${LOCAL_REGISTRY:-"localhost:${REGISTRY_PORT}"}
SKOPEO=/usr/local/bin/skopeo

BASEDIR="."
if [ ! -d images ] && [ -d ../outputs ]; then
    BASEDIR="../outputs"  # for tests
fi

# 번들에 포함된 skopeo 바이너리를 설치하고 copy에 필요한 policy.json을 생성한다.
setup_skopeo() {
    if [ ! -x "$SKOPEO" ]; then
        local arch bin
        case "$(uname -m)" in
            x86_64)  arch=amd64 ;;
            aarch64) arch=arm64 ;;
            *)       arch=amd64 ;;
        esac
        bin=$(ls "$BASEDIR"/files/skopeo/*/skopeo-linux-${arch} 2>/dev/null | head -1)
        if [ -z "$bin" ]; then
            echo "ERROR: skopeo 바이너리를 찾을 수 없습니다: $BASEDIR/files/skopeo/*/skopeo-linux-${arch}"
            exit 1
        fi
        echo "===> Installing skopeo: $bin -> $SKOPEO"
        sudo cp "$bin" "$SKOPEO" || exit 1
        sudo chmod +x "$SKOPEO" || exit 1
    fi

    # skopeo copy는 signature policy가 없으면 실패한다. 최소 허용 정책을 만든다.
    if [ ! -f /etc/containers/policy.json ]; then
        echo "===> Creating /etc/containers/policy.json"
        sudo mkdir -p /etc/containers
        echo '{"default":[{"type":"insecureAcceptAnything"}]}' | sudo tee /etc/containers/policy.json >/dev/null
    fi
}

# docker-archive의 manifest.json RepoTags에서 원본 이미지 ref를 추출한다.
archive_ref() {
    tar -xzOf "$1" manifest.json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    tags = d[0].get("RepoTags") or []
    print(tags[0] if tags else "")
except Exception:
    print("")
'
}

copy_images() {
    for image in "$BASEDIR"/images/*.tar.gz; do
        [ -e "$image" ] || continue

        ref=$(archive_ref "$image")
        if [ -z "$ref" ]; then
            echo "WARN: RepoTag가 없어 건너뜁니다: $image"
            continue
        fi

        # kubespray 규칙: 알려진 레지스트리 prefix를 제거한 뒤 로컬 레지스트리를 붙인다.
        newImage=$ref
        for repo in registry.k8s.io k8s.gcr.io gcr.io ghcr.io docker.io quay.io $ADDITIONAL_CONTAINER_REGISTRY_LIST; do
            newImage=$(echo "${newImage}" | sed s@^${repo}/@@)
        done
        newImage=${LOCAL_REGISTRY}/${newImage}

        echo "===> skopeo copy ${ref} -> ${newImage}"
        sudo $SKOPEO copy --dest-tls-verify=false \
            docker-archive:"$image" docker://"${newImage}" || exit 1
    done
}

setup_skopeo
copy_images
