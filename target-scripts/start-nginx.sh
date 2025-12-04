#!/bin/bash

source ./config.sh

BASEDIR="."
if [ ! -d images ] && [ -d ../outputs ]; then
    BASEDIR="../outputs"  # for tests
fi
BASEDIR=$(cd $BASEDIR; pwd)
NERDCTL="sudo /usr/local/bin/nerdctl"

NGINX_IMAGE=nginx:${NGINX_VERSION}

echo "===> Generate nginx config (port: ${NGINX_PORT})"
cat > ${BASEDIR}/nginx-runtime.conf << EOF
server {
    listen       ${NGINX_PORT};
    listen  [::]:${NGINX_PORT};
    server_name  localhost;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
    }

    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }

    sendfile off;
}
EOF

echo "===> Stop nginx"
$NERDCTL container update --restart no nginx 2>/dev/null
$NERDCTL container stop nginx 2>/dev/null
$NERDCTL container rm nginx 2>/dev/null

echo "===> Start nginx (host network mode)"
$NERDCTL container run -d \
    --network host \
    --restart always \
    --name nginx \
    -v ${BASEDIR}:/usr/share/nginx/html \
    -v ${BASEDIR}/nginx-runtime.conf:/etc/nginx/conf.d/default.conf \
    ${NGINX_IMAGE} || exit 1
