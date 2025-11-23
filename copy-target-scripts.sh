#!/bin/bash
umask 022

echo "==> Copy target scripts"

# config.sh를 제외한 모든 파일 복사
for file in target-scripts/*; do
    if [ "$(basename "$file")" != "config.sh" ]; then
        /bin/cp -f -r "$file" ${OUTPUT_DIR}/
    fi
done

# config.sh는 KUBESPRAY_VERSION 기본값을 현재 버전으로 치환하여 복사
echo "==> Adjust config.sh default KUBESPRAY_VERSION to ${KUBESPRAY_VERSION}"
sed "s/^KUBESPRAY_VERSION=\${KUBESPRAY_VERSION:-[^}]*}/KUBESPRAY_VERSION=\${KUBESPRAY_VERSION:-${KUBESPRAY_VERSION}}/" \
    target-scripts/config.sh > ${OUTPUT_DIR}/config.sh
chmod +x ${OUTPUT_DIR}/config.sh
