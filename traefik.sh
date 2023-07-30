#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# all logic in the bottom

VERSION=0.1
TRAEFIK_NETWORK_NAME=web

## cert start============

# idea from: https://gist.github.com/vickramravichandran/c1190efbf9f1841234fcef624ef65956

function cert::makeRoot {
    set -euo pipefail

    if [[ ! -d root ]] ; then
      mkdir root
    fi

    # Create the Private Key for the Root Certificate
    openssl genrsa -out root/root.key 2048

    # Create the Root Certificate (CA)
    openssl req -new -x509 \
        -key root/root.key -sha256 -days 3650 \
        -out root/root.cert.pem \
        -subj "/C=US/ST=NY/L=NY/O=None/CN=Localhost Root Certificate"

    # Verify the Root Certificate
    openssl x509 -noout -text -in root/root.cert.pem
}


function cert::isValidDomain {
  set -euo pipefail
  if [[ "$1" =~ ^([a-z0-9|-]+\.)*[a-z0-9|-]+\.[a-z]+ ]] ; then
    return 0
  else
    return 1
  fi
}

function cert::makeSSL {
    set -euo pipefail

    KEY_NAME=$1
    if [[ ! -d $KEY_NAME ]] ; then
      mkdir "$KEY_NAME"
    fi
    DIRNAME=$KEY_NAME

    # Create the Private Key for the SSL Certificate
    openssl genrsa -out "$DIRNAME/$KEY_NAME".key 2048

    # Create the Certificate Signing Request (CSR)
    openssl req -new -sha256 \
        -key "$DIRNAME/$KEY_NAME".key \
        -out "$DIRNAME/$KEY_NAME".csr \
        -subj "/C=US/ST=NY/L=NY/O=None/CN=$KEY_NAME"

    # Create the Certificate Signed by the CA
    cat <<EOT > "$DIRNAME"/v3.txt
    authorityKeyIdentifier=keyid,issuer
    basicConstraints=CA:FALSE
    keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = @alt_names

    [alt_names]
    DNS.1 = $KEY_NAME
    DNS.2 = *.$KEY_NAME
EOT

    openssl x509 -req \
        -in "$DIRNAME/$KEY_NAME".csr \
        -CA root/root.cert.pem \
        -CAkey root/root.key \
        -CAcreateserial \
        -days 3650 -sha256 \
        -extfile "$DIRNAME"/v3.txt \
        -out "$DIRNAME/$KEY_NAME".crt

    rm "$DIRNAME"/v3.txt

    # Verify certificate
    openssl verify -CAfile root/root.cert.pem "$DIRNAME/$KEY_NAME".crt
}

function cert::checkOpenSslIsInstalled {
    if ! hash openssl 2>/dev/null; then
      echo 'openssl not found'
      read -pr "Try to install it? [Y/n]" -n 1
      if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "!!! Canceled by user."
        exit 1
      fi
      echo 'sudo apt-get isntall openssl'
      sudo apt-get isntall openssl

      if ! hash openssl 2>/dev/null; then
        echo 'openssl still not found'
        exit 1
      fi
    fi
}



## cert end==============

function writeDynamicConfigIfNotExists {
  if [ ! -f "dynamic_config.yml" ]; then
    echo "writing dynamic_config.yml"
    cat <<EOT >> dynamic_config.yml
tls:
  certificates:
    - certFile: /cert/$DOMAIN/$DOMAIN.crt
      keyFile: /cert/$DOMAIN/$DOMAIN.key
EOT
  fi
}

function writeTraefik_ymlIfNotExists {
    if [ ! -f "traefik.yml" ]; then
      echo "writing traefik.yml"
      cat <<EOT >> traefik.yml
global:
  checkNewVersion: true
  sendAnonymousUsage: true
log:
  level: DEBUG
  #filepath: "/etc/traefik/log/traefik.log" (if not use stdout)
accesslog:

api:
  dashboard: true
  debug: true
  insecure: true
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
ping:
  entryPoint: foobar
  manualRouting: true
  terminatingStatusCode: 42
providers:
  docker:
    exposedByDefault: false
    watch: true
    endpoint: "unix:///var/run/docker.sock"
    network: "web"
    defaultRule: "Host(\`{{ trimPrefix \`/\` .Name }}.$DOMAIN\`)"
  file:
    filename: "/etc/traefik/dynamic_config.yml"
    watch: true
EOT
    fi
}

function writeDockeromposeIfNotExists {
    if [ ! -f "docker-compose.yml" ]; then
      echo "writing docker-compose.yml"
      cat <<EOT >> docker-compose.yml
version: "3.3"
services:
  traefik:
    image: "traefik:v2.9"
    container_name: "traefik"
    ports:
      - 80:80
      - 443:443
      - 8080:8080
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml
      - ./dynamic_config.yml:/etc/traefik/dynamic_config.yml
      - ./cert:/cert:ro
    restart: always
    hostname: traefik
    networks:
      - web
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(\`dashboard.$DOMAIN\`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls=true"
      - "traefik.http.routers.dashboard.service=api@internal"

  whoami:
    image: "traefik/whoami"
    container_name: "simple-service"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whoami-s.rule=Host(\`whoami.$DOMAIN\`)"
      - "traefik.http.routers.whoami-s.entrypoints=websecure"
      - "traefik.http.routers.whoami-s.tls=true"
      - "traefik.http.routers.whoami.rule=Host(\`whoami.$DOMAIN\`)"
      - "traefik.http.routers.whoami.entrypoints=web"
    networks:
      - web

networks:
  web:
    external: true
EOT
    fi
}

function writeDockerComposeExampleIfNotExists {
    if [ ! -f "docker-compose-example.yml" ]; then
      echo "writing docker-compose-example.yml"
      cat <<EOT >> docker-compose-example.yml
version: "3.3"
services:
  whoami:
    image: "traefik/whoami"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whoami-s.rule=Host(\`whoami.$DOMAIN\`)"
      - "traefik.http.routers.whoami-s.entrypoints=websecure"
      - "traefik.http.routers.whoami-s.tls=true"
      - "traefik.http.routers.whoami.rule=Host(\`whoami.$DOMAIN\`)"
      - "traefik.http.routers.whoami.entrypoints=web"
    networks:
      - web

networks:
  web:
    external: true
EOT
    fi
}

function makeCert {
  [ -d cert ] ||  mkdir "cert"
  cd cert
  # make root cert

  cert::checkOpenSslIsInstalled

  # make root cert
  if [[ ! -f root/root.key ]] || [[ ! -f root/root.cert.pem ]] ; then
    echo 'generating root certificate and key'
    cert::makeRoot
  fi

  # make domain cert
  if [ $# -gt 0 ] && [ -n "$1" ]; then
    if ! cert::isValidDomain "$1" && [ "$1" != "localhost" ]; then
        echo "invalid domain: $1"
        exit 1
    fi
      cert::makeSSL "$1"
  else
    echo 'pass domain for making ssl'
  fi

  cd ..
}

function createNetworkIfNotExists() {
    docker network inspect $TRAEFIK_NETWORK_NAME >/dev/null 2>&1 || \
        docker network create --driver bridge $TRAEFIK_NETWORK_NAME
}


echo "This is traefik script v$VERSION"

if [ ! "$(find ./cert -mindepth 1 -maxdepth 1 -type d | wc -l)" -gt 1 ]; then
  echo 'Enter 2nd level domain for local development. for example "dev.local"'
  while true; do
    read -rp "Enter domain: [dev.local]"
    if [ -z "$REPLY" ]; then
      REPLY="dev.local"
    fi
    if [[ "$REPLY" =~ ^[a-z0-9|-]+\.[a-z]+ ]]; then
      DOMAIN=$REPLY
      break
    else
      echo 'incorrect domain'
    fi
  done
  echo "traefik will be configured for using domain $DOMAIN"
  makeCert "$DOMAIN"
  writeDynamicConfigIfNotExists
  writeDockeromposeIfNotExists
  writeTraefik_ymlIfNotExists
fi

writeDockerComposeExampleIfNotExists

createNetworkIfNotExists

docker compose up -d

cat <<EOT
Done

Next steps:

1. import root certificate from file cert/root/root.cert.pem into browser

2. Configure your docker composer as shown in docker-compose-example.yml
EOT