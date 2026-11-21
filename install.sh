#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2015,SC2031,SC1091,SC2153
# =============================================================================
#  L1 Diag - instalador do servidor de velocidade do provedor
#
#  Instala o LibreSpeed (speedtest-go) com HTTPS, como serviço do systemd, para
#  o teste de velocidade do app L1 Diag. Ao final, mostra o registro DNS (BIND)
#  que faz o app encontrar o servidor sozinho.
#
#  Uso:
#    curl -fsSL https://raw.githubusercontent.com/wilsonritt/l1-speed-server/main/install.sh -o install.sh
#    sudo bash install.sh              # instala ou reconfigura
#    sudo bash install.sh --code X     # usa os dados do painel L1 Diag ISP e registra lá no fim
#    sudo bash install.sh --uninstall  # remove
#
#  Sem perguntas (todas as variáveis L1S_* estão no README):
#    sudo L1S_HOST=speed1.provedor.com.br L1S_NAME="Provedor 10G" L1S_PORT=8443 \
#         L1S_CERT=letsencrypt L1S_EMAIL=noc@provedor.com.br bash install.sh --yes
# =============================================================================
set -Eeuo pipefail

VERSION_SCRIPT="1.1.1"
APP="l1speed"
INSTALL_DIR="/opt/l1speed"
CONF_DIR="/etc/l1speed"
TLS_DIR="$CONF_DIR/tls"
ANSWERS="$CONF_DIR/install.conf"
SETTINGS="$CONF_DIR/settings.toml"
UNIT="/etc/systemd/system/$APP.service"
SYSCTL_FILE="/etc/sysctl.d/90-l1speed.conf"
LE_HOOK="/etc/letsencrypt/renewal-hooks/deploy/l1speed.sh"
DNS_NOTES="$CONF_DIR/DNS-BIND.txt"
TXT_NAME="_speedtest.l1diag.l1sistemas.com.br"
ISP_URL="${L1S_ISP_URL:-https://isp.l1diag.l1sistemas.com.br}"
CODE="${L1S_CODE:-}"
FROM_PANEL=0
UPSTREAM_REPO="librespeed/speedtest-go"
SUGGESTED_PORTS=(8443 9443 10443 18443)

ASSUME_YES=0
PANEL_OK=0
ACTION="install"

# ----------------------------------------------------------------------------- saída

if [[ -t 1 ]]; then
    B=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else
    B=""; RED=""; GRN=""; YEL=""; BLU=""; RST=""
fi

step()  { printf '\n%s==> %s%s\n' "$B$BLU" "$*" "$RST"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '    %s!%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()   { printf '\n%sErro:%s %s\n' "$RED$B" "$RST" "$*" >&2; exit 1; }

trap 'die "falha na linha $LINENO: $BASH_COMMAND"' ERR

# Lê do terminal mesmo quando o script vem por "curl | bash".
TTY=/dev/tty
# Sem terminal de verdade (cron, CI), usa os padrões e as variáveis L1S_*.
{ : < "$TTY"; } 2>/dev/null || TTY=/nonexistent
ask() { # ask VAR "Pergunta" "padrão"
    local __var=$1 __q=$2 __def=${3-} __ans
    if [[ $ASSUME_YES -eq 1 || ! -r $TTY ]]; then
        printf -v "$__var" '%s' "$__def"; return
    fi
    if [[ -n $__def ]]; then
        read -r -p "    $__q [$__def]: " __ans < "$TTY" || true
    else
        read -r -p "    $__q: " __ans < "$TTY" || true
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

interactive() { [[ $ASSUME_YES -eq 0 && -r $TTY ]]; }
confirm() { # confirm "Pergunta" s|n
    local __ans __def=${2:-s}
    if [[ $ASSUME_YES -eq 1 || ! -r $TTY ]]; then [[ $__def == s ]]; return; fi
    local hint="[S/n]"; [[ $__def == n ]] && hint="[s/N]"
    read -r -p "    $1 $hint: " __ans < "$TTY" || true
    __ans=${__ans:-$__def}
    [[ ${__ans,,} == s* || ${__ans,,} == y* ]]
}

# ----------------------------------------------------------------------------- argumentos

while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)           ACTION="uninstall" ;;
        --yes|-y)              ASSUME_YES=1 ;;
        --code)                [[ $# -ge 2 ]] || die "--code precisa do código gerado no painel."; CODE=$2; shift ;;
        --code=*)              CODE=${1#*=} ;;
        --help|-h)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "opção desconhecida: $1 (use --help)" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "rode como root: sudo bash $0"

# ----------------------------------------------------------------------------- sistema

PKG=""
detect_system() {
    [[ $(uname -s) == Linux ]] || die "este instalador é para Linux."
    command -v systemctl >/dev/null || die "systemd não encontrado. O instalador precisa do systemd."
    if command -v apt-get >/dev/null; then PKG=apt
    elif command -v dnf >/dev/null; then PKG=dnf
    elif command -v yum >/dev/null; then PKG=yum
    else PKG=""
    fi
    case $(uname -m) in
        x86_64|amd64)  GOARCH=amd64 ;;
        aarch64|arm64) GOARCH=arm64 ;;
        armv7*)        GOARCH=armv7 ;;
        i386|i686)     GOARCH=386 ;;
        *) die "arquitetura não suportada: $(uname -m)" ;;
    esac
    local os="Linux"
    [[ -r /etc/os-release ]] && os=$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")
    ok "$os, $(uname -m)"
}

pkg_install() {
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        yum) yum install -y -q "$@" >/dev/null ;;
        *) die "instale manualmente: $*" ;;
    esac
}

ensure_tools() {
    local missing=()
    for t in curl tar sha256sum ss openssl; do command -v "$t" >/dev/null || missing+=("$t"); done
    if ((${#missing[@]})); then
        info "Instalando: ${missing[*]}"
        local pkgs=()
        for t in "${missing[@]}"; do
            case $t in
                ss) [[ $PKG == apt ]] && pkgs+=(iproute2) || pkgs+=(iproute) ;;
                sha256sum) pkgs+=(coreutils) ;;
                *) pkgs+=("$t") ;;
            esac
        done
        pkg_install "${pkgs[@]}"
    fi
    ok "ferramentas necessárias presentes"
}

# ----------------------------------------------------------------------------- perguntas

valid_host() { [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; }

port_in_use() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

port_owner() {
    local who
    who=$(ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | sed 's/users:(("//' || true)
    printf '%s' "${who:-outro programa}"
}

list_ports() {
    info "Portas TCP em uso neste servidor:"
    ss -Hltnp 2>/dev/null | awk '{print $4, $6}' | sed -E 's/.*:([0-9]+) users:\(\("([^"]+)".*/\1 \2/; s/.*:([0-9]+) ?$/\1 -/' \
        | sort -n -u -k1,1 | while read -r p proc; do printf '      %-6s %s\n' "$p" "${proc:--}"; done
}

# ----------------------------------------------------------------------------- painel L1 Diag ISP

json_str() { grep -o "\"$1\": *\"[^\"]*\"" <<<"$2" | head -1 | sed 's/.*: *"\(.*\)"/\1/' || true; }
json_num() { grep -o "\"$1\": *[0-9]*" <<<"$2" | head -1 | grep -o '[0-9]*$' || true; }

fetch_panel() {
    [[ -n $CODE ]] || return 0
    step "Buscando os dados no painel L1 Diag ISP"
    local resp
    resp=$(curl -fsS --max-time 20 "$ISP_URL/v1/install/$CODE" 2>/dev/null) \
        || die "o painel não reconheceu o código (vencido ou já trocado?). Gere outro em $ISP_URL/painel"
    local host name site prio prov
    host=$(json_str host "$resp"); name=$(json_str name "$resp"); site=$(json_str site "$resp")
    prio=$(json_num prio "$resp"); prov=$(json_str provider "$resp")
    valid_host "$host" || die "resposta inesperada do painel: $resp"
    L1S_HOST=$host; L1S_NAME=${name:-$host}; L1S_SITE=$site; L1S_PRIO=${prio:-10}
    FROM_PANEL=1
    ok "$prov: $L1S_NAME ($host)"
}

register_done() {
    (( FROM_PANEL )) || return 0
    step "Registrando no painel L1 Diag ISP"
    local url="https://$HOST:$PORT/" resp msg
    [[ $PORT == 443 ]] && url="https://$HOST/"
    resp=$(curl -sS --max-time 40 -X POST -H 'Content-Type: application/json' \
        --data "{\"url\":\"$url\"}" "$ISP_URL/v1/install/$CODE/complete" 2>&1) || true
    msg=$(json_str message "$resp"); [[ -n $msg ]] || msg=$(json_str error "$resp")
    if grep -q '"ok": *true' <<<"$resp"; then
        ok "${msg:-registrado}"
        PANEL_OK=1
    else
        warn "${msg:-o painel não respondeu: $resp}"
        warn "Depois de corrigir, use \"Testar agora\" no painel ou rode este instalador de novo com o mesmo código."
    fi
}

ask_answers() {
    step "Configuração"
    [[ -r $ANSWERS ]] && { info "Respostas anteriores carregadas de $ANSWERS"; . "$ANSWERS"; }

    # Nome do servidor
    local host=${L1S_HOST:-${HOST:-}}
    if (( FROM_PANEL )); then info ""; info "Nome do servidor (do painel): $host"; fi
    while (( ! FROM_PANEL )); do
        info ""
        info "Nome público (DNS) deste servidor, com certificado HTTPS. Ex.: speed1.provedor.com.br"
        ask host "Nome do servidor" "$host"
        host=${host,,}
        valid_host "$host" && break
        warn "nome inválido: '$host'"; host=""
        interactive || die "defina L1S_HOST com um nome DNS válido."
    done
    HOST=$host
    check_host_resolves "$HOST"

    # Nome no app
    info ""
    info "Nome que aparece no app L1 Diag durante o teste. Ex.: Provedor Exemplo 10G"
    ask NAME "Nome no teste" "${L1S_NAME:-${NAME:-Speedtest $HOST}}"
    NAME=${NAME//[;\"]/}

    # Site do provedor
    info ""
    info "Site do provedor (opcional). Vai no registro DNS, para o app poder mostrar quem é o provedor."
    ask SITE "Site do provedor" "${L1S_SITE:-${SITE:-}}"
    SITE=${SITE//[;\" ]/}
    if [[ -n $SITE && $SITE != http*://* ]]; then SITE="https://$SITE"; fi

    # Porta
    info ""
    list_ports
    local suggested=${L1S_PORT:-${PORT:-}}
    if [[ -z $suggested ]]; then
        for p in "${SUGGESTED_PORTS[@]}"; do port_in_use "$p" || { suggested=$p; break; }; done
    fi
    info ""
    info "Porta HTTPS do teste. Evite 8080 e 5060 se o OoklaServer roda aqui."
    while :; do
        ask PORT "Porta" "$suggested"
        if ! [[ $PORT =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
            warn "porta inválida: $PORT"; interactive || die "L1S_PORT inválida."; continue
        fi
        if port_in_use "$PORT" && [[ $(port_owner "$PORT") != speedtest-back* ]]; then
            warn "a porta $PORT já está em uso por $(port_owner "$PORT")."
            interactive || die "porta $PORT ocupada."
            continue
        fi
        break
    done

    # Prioridade
    info ""
    info "Prioridade no DNS: o app testa primeiro o menor número. Use 10 no servidor de 10G e 20 no de 1G."
    ask PRIO "Prioridade" "${L1S_PRIO:-${PRIO:-10}}"
    [[ $PRIO =~ ^[0-9]+$ ]] || PRIO=10

    # Certificado
    ask_certificate

    # Ajustes de rede
    info ""
    info "Ajustes de rede (buffers TCP e BBR) ajudam a chegar a 10 Gbps. São seguros para um servidor dedicado."
    if [[ -n ${L1S_TUNE:-} ]]; then TUNE=$L1S_TUNE
    elif confirm "Aplicar os ajustes de rede?" "${TUNE:-s}"; then TUNE=s; else TUNE=n; fi

    step "Resumo"
    info "Servidor:     https://$HOST:$PORT/"
    info "Nome no app:  $NAME"
    [[ -n $SITE ]] && info "Site:         $SITE"
    info "Prioridade:   $PRIO"
    info "Certificado:  $(cert_label)"
    info "Ajustes TCP:  $([[ $TUNE == s ]] && echo sim || echo não)"
    confirm "Instalar com essas opções?" s || die "instalação cancelada."
}

check_host_resolves() {
    local resolved locals
    resolved=$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
    if [[ -z $resolved ]]; then
        warn "$1 ainda não resolve no DNS. Crie o registro A/AAAA antes de pedir o certificado."
        return
    fi
    locals=$(ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
    for ip in $resolved; do
        if [[ " $locals " == *" $ip "* ]]; then ok "$1 aponta para este servidor ($ip)"; return; fi
    done
    warn "$1 resolve para $resolved, que não é um endereço desta máquina (normal se houver NAT)."
}

# ----------------------------------------------------------------------------- certificado

CERT_MODE=""; CERT_SRC=""; KEY_SRC=""; EMAIL=""; WEBROOT=""
cert_label() {
    case $CERT_MODE in
        letsencrypt) if [[ -n $WEBROOT ]]; then echo "Let's Encrypt (webroot $WEBROOT)"; else echo "Let's Encrypt (standalone na porta 80)"; fi ;;
        existing)    echo "Let's Encrypt já emitido para $HOST" ;;
        files)       echo "arquivos $CERT_SRC" ;;
    esac
}

ask_certificate() {
    info ""
    CERT_MODE=${L1S_CERT:-${CERT_MODE:-}}
    EMAIL=${L1S_EMAIL:-${EMAIL:-}}
    CERT_SRC=${L1S_CERT_FILE:-${CERT_SRC:-}}
    KEY_SRC=${L1S_KEY_FILE:-${KEY_SRC:-}}
    WEBROOT=${L1S_WEBROOT:-${WEBROOT:-}}

    if [[ -z ${L1S_CERT:-} && -s /etc/letsencrypt/live/$HOST/fullchain.pem ]]; then
        if confirm "Já existe certificado Let's Encrypt para $HOST. Usar esse?" s; then CERT_MODE=existing; return; fi
    fi
    if [[ -z ${L1S_CERT:-} ]]; then
        info "Certificado HTTPS (o app só aceita certificado válido, não autoassinado):"
        info "  1) Emitir agora com Let's Encrypt (grátis, renova sozinho)"
        info "  2) Usar arquivos de certificado que já tenho"
        local choice def=1
        [[ $CERT_MODE == files ]] && def=2
        ask choice "Opção" "$def"
        [[ $choice == 2 ]] && CERT_MODE=files || CERT_MODE=letsencrypt
    fi

    if [[ $CERT_MODE == letsencrypt ]]; then
        while :; do
            ask EMAIL "E-mail para avisos do Let's Encrypt" "$EMAIL"
            [[ $EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
            interactive || die "informe um e-mail válido em L1S_EMAIL."
            warn "e-mail inválido."; EMAIL=""
        done
        if port_in_use 80; then
            warn "a porta 80 está em uso por $(port_owner 80); o modo standalone não funciona."
            info "Informe a pasta pública (webroot) do site que responde em http://$HOST/"
            while :; do
                ask WEBROOT "Webroot" "${WEBROOT:-/var/www/html}"
                [[ -d $WEBROOT ]] && break
                interactive || die "pasta $WEBROOT não existe."
                warn "pasta $WEBROOT não existe."; WEBROOT=""
            done
        else
            WEBROOT=""
            info "A porta 80 está livre: o Let's Encrypt vai usá-la por alguns segundos agora e a cada renovação."
            info "Ela precisa estar liberada no firewall da borda para a internet."
        fi
    elif [[ $CERT_MODE == files ]]; then
        while :; do
            ask CERT_SRC "Arquivo do certificado (fullchain, PEM)" "$CERT_SRC"
            [[ -s $CERT_SRC ]] && break
            interactive || die "certificado não encontrado: $CERT_SRC"
            warn "arquivo não encontrado: $CERT_SRC"; CERT_SRC=""
        done
        while :; do
            ask KEY_SRC "Arquivo da chave privada (PEM)" "$KEY_SRC"
            [[ -s $KEY_SRC ]] && break
            interactive || die "chave não encontrada: $KEY_SRC"
            warn "arquivo não encontrado: $KEY_SRC"; KEY_SRC=""
        done
        openssl x509 -in "$CERT_SRC" -noout -checkhost "$HOST" 2>/dev/null | grep -q "does match" \
            || warn "o certificado não parece valer para $HOST."
        openssl x509 -in "$CERT_SRC" -noout -checkend 0 >/dev/null || die "o certificado está vencido."
    else
        die "L1S_CERT deve ser letsencrypt ou files."
    fi
}

obtain_certificate() {
    step "Certificado HTTPS"
    install -d -m 0750 -o root -g "$APP" "$CONF_DIR" "$TLS_DIR"
    case $CERT_MODE in
        letsencrypt)
            command -v certbot >/dev/null || { info "Instalando o certbot"; pkg_install certbot; }
            local args=(certonly --non-interactive --agree-tos -m "$EMAIL" -d "$HOST" --keep-until-expiring)
            if [[ -n $WEBROOT ]]; then args+=(--webroot -w "$WEBROOT"); else args+=(--standalone); fi
            certbot "${args[@]}" || die "o Let's Encrypt não emitiu o certificado. Confira se $HOST aponta para este servidor e se a porta 80 chega até aqui."
            CERT_MODE=existing
            ;&
        existing)
            install_le_hook
            copy_cert "/etc/letsencrypt/live/$HOST/fullchain.pem" "/etc/letsencrypt/live/$HOST/privkey.pem"
            ;;
        files)
            copy_cert "$CERT_SRC" "$KEY_SRC"
            warn "renovação por sua conta: ao trocar o certificado, rode de novo este instalador."
            ;;
    esac
    ok "certificado válido até $(openssl x509 -in "$TLS_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
}

copy_cert() {
    install -m 0640 -o root -g "$APP" "$1" "$TLS_DIR/fullchain.pem"
    install -m 0640 -o root -g "$APP" "$2" "$TLS_DIR/privkey.pem"
}

install_le_hook() {
    install -d "$(dirname "$LE_HOOK")"
    cat > "$LE_HOOK" <<EOF
#!/bin/sh
# Copia o certificado renovado para o servidor de velocidade do L1 Diag e reinicia o serviço.
[ "\${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/$HOST" ] || exit 0
install -m 0640 -o root -g $APP "\$RENEWED_LINEAGE/fullchain.pem" $TLS_DIR/fullchain.pem
install -m 0640 -o root -g $APP "\$RENEWED_LINEAGE/privkey.pem" $TLS_DIR/privkey.pem
systemctl restart $APP
EOF
    chmod 0755 "$LE_HOOK"
    ok "renovação automática configurada"
}

# ----------------------------------------------------------------------------- binário

download_backend() {
    step "Baixando o LibreSpeed (speedtest-go)"
    local tmp; tmp=$(mktemp -d); WORK_TMP=$tmp; trap 'rm -rf "${WORK_TMP:-}"' EXIT
    local archive="$tmp/backend.tar.gz"

    if [[ -n ${L1S_BACKEND_FILE:-} ]]; then
        cp "$L1S_BACKEND_FILE" "$archive"
        info "usando arquivo local $L1S_BACKEND_FILE"
    else
        local tag url="" sums="" suffix="_linux_${GOARCH}.tar.gz"
        local api="https://api.github.com/repos/$UPSTREAM_REPO/releases/${L1S_BACKEND_VERSION:+tags/v${L1S_BACKEND_VERSION#v}}"
        [[ -z ${L1S_BACKEND_VERSION:-} ]] && api+="latest"
        local release; release=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api" 2>/dev/null || true)
        if [[ -n $release ]]; then
            tag=$(grep -m1 '"tag_name"' <<<"$release" | cut -d'"' -f4 || true)
            url=$(grep -o '"browser_download_url": *"[^"]*'"$suffix"'"' <<<"$release" | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)
            sums=$(grep -o '"browser_download_url": *"[^"]*checksums.txt"' <<<"$release" | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)
        fi
        if [[ -z $url ]]; then
            # Sem a API (limite de consultas ou bloqueio): descobre a versão pelo redirecionamento da página.
            if [[ -n ${L1S_BACKEND_VERSION:-} ]]; then tag="v${L1S_BACKEND_VERSION#v}"
            else tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$UPSTREAM_REPO/releases/latest" 2>/dev/null | sed 's|.*/tag/||' || true)
            fi
            [[ $tag == v* ]] || die "não foi possível descobrir a versão do speedtest-go no GitHub."
            local base="https://github.com/$UPSTREAM_REPO/releases/download/$tag"
            url="$base/speedtest-go_${tag#v}$suffix"
            sums="$base/checksums.txt"
        fi
        info "versão $tag: $(basename "$url")"
        curl -fsSL "$url" -o "$archive" || die "falha ao baixar $url"
        if [[ -n $sums ]]; then
            local expected; expected=$(curl -fsSL "$sums" | grep " $(basename "$url")\$" | awk '{print $1}')
            [[ -n $expected ]] || die "o pacote não está em checksums.txt."
            echo "$expected  $archive" | sha256sum -c --quiet - || die "checksum não confere; download corrompido."
            ok "checksum SHA-256 conferido"
        fi
        echo "$tag" > "$tmp/version"
    fi

    tar -xzf "$archive" -C "$tmp"
    local bin; bin=$(find "$tmp" -type f -name 'speedtest-backend*' -perm -u+x | head -1)
    [[ -n $bin ]] || bin=$(find "$tmp" -type f -name 'speedtest-backend*' | head -1)
    [[ -n $bin ]] || die "o pacote não contém speedtest-backend."
    install -d -m 0755 "$INSTALL_DIR"
    install -m 0755 "$bin" "$INSTALL_DIR/speedtest-backend.new"
    mv -f "$INSTALL_DIR/speedtest-backend.new" "$INSTALL_DIR/speedtest-backend"
    [[ -r $tmp/version ]] && cp "$tmp/version" "$INSTALL_DIR/VERSION"
    ok "instalado em $INSTALL_DIR"
}

# ----------------------------------------------------------------------------- configuração e serviço

create_user() {
    id "$APP" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$APP"
}

write_settings() {
    step "Configurando o serviço"
    install -d -m 0750 -o root -g "$APP" "$CONF_DIR"
    local stats_pw; stats_pw=$(openssl rand -hex 16)
    cat > "$SETTINGS" <<EOF
# Gerado pelo instalador do L1 Diag ($VERSION_SCRIPT). Para mudar, rode o instalador de novo.
bind_address=""
listen_port=$PORT
proxyprotocol_port=0
server_lat=0
server_lng=0
ipinfo_api_key=""
assets_path=""
statistics_password="$stats_pw"
redact_ip_addresses=true
# Não grava resultados nem endereços IP.
database_type="none"
database_hostname=""
database_name=""
database_username=""
database_password=""
database_file=""
enable_tls=true
# HTTP/1.1: o app abre várias conexões TCP em paralelo.
enable_http2=false
tls_cert_file="$TLS_DIR/fullchain.pem"
tls_key_file="$TLS_DIR/privkey.pem"
EOF
    chown root:"$APP" "$SETTINGS"; chmod 0640 "$SETTINGS"

    cat > "$UNIT" <<EOF
[Unit]
Description=Servidor de velocidade do L1 Diag (LibreSpeed)
After=network-online.target
Wants=network-online.target

[Service]
User=$APP
Group=$APP
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/speedtest-backend -c $SETTINGS
Restart=always
RestartSec=3
LimitNOFILE=65536
# Permite portas abaixo de 1024 (ex.: 443) sem rodar como root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ReadOnlyPaths=$CONF_DIR

[Install]
WantedBy=multi-user.target
EOF
    ok "configuração em $SETTINGS"
}

apply_tuning() {
    if [[ $TUNE != s ]]; then rm -f "$SYSCTL_FILE"; return; fi
    step "Ajustes de rede"
    {
        echo "# Gerado pelo instalador do L1 Diag: buffers TCP para testes de até 10 Gbps."
        echo "net.core.rmem_max = 134217728"
        echo "net.core.wmem_max = 134217728"
        echo "net.ipv4.tcp_rmem = 4096 131072 134217728"
        echo "net.ipv4.tcp_wmem = 4096 65536 134217728"
        echo "net.core.netdev_max_backlog = 250000"
        echo "net.ipv4.tcp_mtu_probing = 1"
        if modprobe tcp_bbr 2>/dev/null || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$SYSCTL_FILE"
    sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "alguns ajustes não foram aceitos pelo kernel (ok em contêiner)."
    ok "ajustes em $SYSCTL_FILE"
}

open_firewall() {
    step "Firewall"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$PORT/tcp" comment "L1 Diag speedtest" >/dev/null && ok "ufw: porta $PORT/tcp liberada"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd -q --permanent --add-port="$PORT/tcp" && firewall-cmd -q --reload && ok "firewalld: porta $PORT/tcp liberada"
    else
        info "nenhum ufw ou firewalld ativo. Se houver outro firewall (iptables, nftables, borda), libere $PORT/tcp."
    fi
}

start_service() {
    step "Iniciando o serviço"
    systemctl daemon-reload
    systemctl enable "$APP" >/dev/null 2>&1
    systemctl restart "$APP"
    for _ in $(seq 1 20); do port_in_use "$PORT" && break; sleep 0.5; done
    port_in_use "$PORT" || { journalctl -u "$APP" -n 20 --no-pager 2>/dev/null || true; die "o serviço não abriu a porta $PORT."; }
    ok "serviço $APP ativo na porta $PORT"
}

self_test() {
    step "Testando"
    local base="https://$HOST:$PORT" code size
    # Direto no serviço local: sem proxy e, nesta etapa, sem validar o certificado.
    local r=(--noproxy '*' --max-time 30 --resolve "$HOST:$PORT:127.0.0.1")
    code=$(curl -ksS -o /dev/null -w '%{http_code}' "${r[@]}" "$base/backend/empty" || true)
    [[ $code == 200 ]] || die "/backend/empty respondeu '$code'. Veja: journalctl -u $APP"
    ok "latência (/backend/empty): HTTP 200"
    read -r code size < <(curl -ksS -o /dev/null -w '%{http_code} %{size_download}\n' "${r[@]}" "$base/backend/garbage?ckSize=4" || true)
    [[ $code == 200 && ${size%.*} -gt 1000000 ]] || die "/backend/garbage respondeu '$code' com ${size:-0} bytes."
    ok "download (/backend/garbage): HTTP 200, $((${size%.*} / 1048576)) MB"
    code=$(head -c 4194304 /dev/zero | curl -ksS -o /dev/null -w '%{http_code}' -X POST --data-binary @- "${r[@]}" "$base/backend/empty" || true)
    if [[ $code == 200 ]]; then ok "upload (POST /backend/empty): HTTP 200"; else warn "upload respondeu '$code'."; fi
    # Agora como o app faz: o certificado precisa ser válido para o nome.
    if curl -sS -o /dev/null "${r[@]}" "$base/backend/empty" 2>/dev/null; then
        ok "certificado aceito para $HOST"
    else
        warn "o certificado não foi aceito para $HOST (o app recusa). Confira se o arquivo traz a cadeia completa (fullchain) e se o nome bate."
        CERT_WARNING=1
    fi
}

save_answers() {
    cat > "$ANSWERS" <<EOF
# Respostas da última instalação (reutilizadas ao rodar o instalador de novo).
HOST=$(printf '%q' "$HOST")
NAME=$(printf '%q' "$NAME")
SITE=$(printf '%q' "$SITE")
PORT=$(printf '%q' "$PORT")
PRIO=$(printf '%q' "$PRIO")
TUNE=$(printf '%q' "$TUNE")
CERT_MODE=$(printf '%q' "$([[ $CERT_MODE == existing ]] && echo letsencrypt || echo "$CERT_MODE")")
EMAIL=$(printf '%q' "$EMAIL")
WEBROOT=$(printf '%q' "$WEBROOT")
CERT_SRC=$(printf '%q' "$CERT_SRC")
KEY_SRC=$(printf '%q' "$KEY_SRC")
EOF
    chmod 0600 "$ANSWERS"
}

# ----------------------------------------------------------------------------- DNS

txt_value() {
    local v="v=l1speed1; url=https://$HOST:$PORT/; nome=$NAME; prio=$PRIO"
    [[ -n $SITE ]] && v+="; site=$SITE"
    if ((${#v} > 255)); then v="v=l1speed1; url=https://$HOST:$PORT/; nome=$NAME; prio=$PRIO"; fi
    printf '%s' "$v"
}

print_dns() {
    local txt; txt=$(txt_value)
    local serial; serial=$(date +%Y%m%d)01
    local hp=$HOST; [[ $PORT != 443 ]] && hp+=":$PORT"
    local head guide app
    if (( PANEL_OK )); then
        head="==============================================================================
 Pronto: o servidor está no diretório L1 Diag ISP
==============================================================================

Os clientes que saem pelas redes aprovadas do provedor já usam este servidor,
com qualquer DNS. Não é preciso mexer no DNS.

O registro TXT abaixo é OPCIONAL. Ele serve de reserva quando o app não
alcança o diretório, e cobre clientes que saem por um IP que ainda não está
nas redes aprovadas do painel. O app procura este TXT no DNS do cliente:"
        app="--- No app --------------------------------------------------------------------

Num celular que sai por uma rede aprovada (Wi-Fi de um cliente, por exemplo):
Velocidade > Servidor > Automático deve mostrar \"$NAME\".
De qualquer rede: Servidor > Servidor do provedor, digitando $hp"
    else
        head="==============================================================================
 Falta só o DNS: registro TXT nos resolvers (BIND) que atendem os clientes
==============================================================================

O app L1 Diag procura este TXT no DNS da conexão do cliente:"
        app="--- No app --------------------------------------------------------------------

Velocidade > Servidor > Automático: deve aparecer \"$NAME\".
Antes do DNS, já dá para testar em Servidor > Servidor do provedor,
digitando: $hp"
    fi
    guide=$(cat <<EOF
  Nome:  $TXT_NAME
  Valor: "$txt"

Com mais de um servidor, crie um TXT para cada um (o app testa primeiro o menor prio).

IMPORTANTE: crie a zona SÓ para o nome exato acima. Não crie zona nem RPZ
para l1sistemas.com.br ou *.l1sistemas.com.br, ou os clientes perdem
o acesso aos sites e serviços da L1.

--- Opção A (recomendada): zona local só para o nome do teste --------------

1) Em named.conf.local (ou em cada "view" que atende clientes):

zone "$TXT_NAME" {
    type primary;              // "type master;" no BIND 9.16 ou anterior
    file "/etc/bind/db.l1diag-speedtest";
};

2) Arquivo /etc/bind/db.l1diag-speedtest (troque ns1.provedor.com.br pelo
   nome do seu servidor DNS):

\$TTL 300
@  IN SOA ns1.provedor.com.br. hostmaster.provedor.com.br. (
       $serial ; serial
       3600 600 86400 300 )
   IN NS  ns1.provedor.com.br.
   IN TXT "$txt"

3) Validar e carregar:

sudo named-checkconf
sudo named-checkzone $TXT_NAME /etc/bind/db.l1diag-speedtest
sudo rndc reconfig

--- Opção B: provedor que já usa RPZ ----------------------------------------

Acrescente na zona RPZ (troque rpz.provedor pelo nome dela), aumente o
serial e rode "sudo rndc reload rpz.provedor":

$TXT_NAME.rpz.provedor. 300 IN TXT "$txt"

--- Conferir ------------------------------------------------------------------

dig @IP_DO_RESOLVER TXT $TXT_NAME +short
dig @IP_DO_RESOLVER l1sistemas.com.br +short   # deve dar o mesmo que:
dig @1.1.1.1 l1sistemas.com.br +short
EOF
)
    printf '%s\n\n%s\n\n%s\n' "$head" "$guide" "$app" > "$DNS_NOTES"
    if (( PANEL_OK )); then
        printf '\n%s%s\n\n  Nome:  %s\n  Valor: "%s"\n\nO passo a passo para BIND (zona só para esse nome, ou RPZ) está em\n%s\n\n%s%s\n' \
            "$B" "$head" "$TXT_NAME" "$txt" "$DNS_NOTES" "$app" "$RST"
    else
        printf '\n%s%s\n\n%s\n\n%s\n\nEste texto foi salvo em %s%s\n' "$B" "$head" "$guide" "$app" "$DNS_NOTES" "$RST"
    fi
}

# ----------------------------------------------------------------------------- remover

uninstall() {
    step "Removendo o servidor de velocidade do L1 Diag"
    local port=""
    [[ -r $ANSWERS ]] && port=$(. "$ANSWERS"; echo "$PORT")
    (( ASSUME_YES )) || confirm "Remover o serviço, o binário e a configuração?" n || die "cancelado."
    systemctl disable --now "$APP" >/dev/null 2>&1 || true
    rm -f "$UNIT" "$SYSCTL_FILE" "$LE_HOOK"
    systemctl daemon-reload || true
    if [[ -n $port ]]; then
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then ufw delete allow "$port/tcp" >/dev/null 2>&1 || true; fi
        if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd -q --permanent --remove-port="$port/tcp" 2>/dev/null && firewall-cmd -q --reload || true
        fi
    fi
    rm -rf "$INSTALL_DIR" "$CONF_DIR"
    userdel "$APP" >/dev/null 2>&1 || true
    ok "removido. O certificado do Let's Encrypt foi mantido em /etc/letsencrypt."
    info "Lembre de apagar o registro TXT $TXT_NAME do DNS."
}

# ----------------------------------------------------------------------------- principal

main() {
    CERT_WARNING=0
    printf '%sL1 Diag - servidor de velocidade do provedor%s (instalador %s)\n' "$B" "$RST" "$VERSION_SCRIPT"
    step "Verificando o sistema"
    detect_system
    if [[ $ACTION == uninstall ]]; then uninstall; exit 0; fi
    ensure_tools
    fetch_panel
    ask_answers
    create_user
    download_backend
    obtain_certificate
    write_settings
    apply_tuning
    open_firewall
    start_service
    self_test
    save_answers
    register_done
    print_dns
    printf '\n%s✓ Instalação concluída.%s Servidor: https://%s:%s/\n' "$GRN$B" "$RST" "$HOST" "$PORT"
    if (( CERT_WARNING )); then warn "corrija o certificado antes de configurar o DNS: o app não aceita o atual."; fi
}

main
