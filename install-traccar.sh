#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Rede7Telecom - Instalador Automático do Traccar
# Ubuntu Server 24.04 / Debian com systemd
# Traccar + MySQL
# ============================================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
fatal() { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }

trap 'echo -e "\n${RED}[ERRO]${NC} Falha na linha $LINENO. Consulte: /var/log/rede7-traccar-install.log"' ERR

exec > >(tee -a /var/log/rede7-traccar-install.log) 2>&1

clear
echo "============================================================"
echo "          Rede7Telecom - Traccar Installer"
echo "============================================================"
echo "     Instalação automática do servidor de rastreamento"
echo "               Traccar + MySQL"
echo "============================================================"
echo

[[ $EUID -eq 0 ]] || fatal "Execute como root."

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
else
    fatal "Não foi possível identificar o sistema operacional."
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *) fatal "Sistema não suportado: ${PRETTY_NAME:-desconhecido}." ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)
        TRACCAR_URL="https://www.traccar.org/download/traccar-linux-64-latest.zip"
        ;;
    aarch64|arm64)
        TRACCAR_URL="https://www.traccar.org/download/traccar-linux-arm-latest.zip"
        ;;
    *)
        fatal "Arquitetura não suportada: $ARCH."
        ;;
esac

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-127.0.0.1}"
DB_NAME="traccar"
DB_USER="traccar"
DB_PASS="$(openssl rand -hex 16)"
WORKDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "Servidor detectado: ${PRETTY_NAME:-Linux}"
echo "Arquitetura: $ARCH"
echo "IP principal: $SERVER_IP"
echo

if systemctl is-active --quiet traccar 2>/dev/null || [[ -d /opt/traccar ]]; then
    warn "Foi encontrada uma instalação existente do Traccar."
    read -r -p "Deseja continuar e substituir a configuração? [s/N]: " CONFIRM
    [[ "${CONFIRM,,}" == "s" ]] || fatal "Instalação cancelada."
fi

info "[1/9] Atualizando repositórios..."
apt-get update

info "[2/9] Instalando dependências..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget unzip mysql-server ufw

info "[3/9] Iniciando MySQL..."
systemctl enable --now mysql

info "[4/9] Criando banco de dados..."
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
  IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';

ALTER USER '${DB_USER}'@'localhost'
  IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

info "[5/9] Baixando o Traccar mais recente..."
cd "$WORKDIR"
wget -q --show-progress -O traccar.zip "$TRACCAR_URL"
unzip -q traccar.zip

INSTALLER="$(find "$WORKDIR" -maxdepth 2 -type f -name 'traccar.run' | head -n1)"
[[ -n "$INSTALLER" ]] || fatal "O instalador traccar.run não foi encontrado."

chmod +x "$INSTALLER"

info "[6/9] Instalando o Traccar..."
systemctl stop traccar 2>/dev/null || true
"$INSTALLER"

[[ -d /opt/traccar ]] || fatal "A pasta /opt/traccar não foi criada."

info "[7/9] Configurando o banco MySQL..."
mkdir -p /opt/traccar/conf

if [[ -f /opt/traccar/conf/traccar.xml ]]; then
    cp -a /opt/traccar/conf/traccar.xml \
        "/opt/traccar/conf/traccar.xml.backup-$(date +%Y%m%d-%H%M%S)"
fi

cat > /opt/traccar/conf/traccar.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>

<properties>
    <entry key='database.driver'>com.mysql.cj.jdbc.Driver</entry>
    <entry key='database.url'>jdbc:mysql://localhost/${DB_NAME}?zeroDateTimeBehavior=round&amp;serverTimezone=UTC&amp;allowPublicKeyRetrieval=true&amp;useSSL=false&amp;allowMultiQueries=true&amp;autoReconnect=true&amp;useUnicode=yes&amp;characterEncoding=UTF-8&amp;sessionVariables=sql_mode=''</entry>
    <entry key='database.user'>${DB_USER}</entry>
    <entry key='database.password'>${DB_PASS}</entry>
</properties>
EOF

chown root:root /opt/traccar/conf/traccar.xml
chmod 640 /opt/traccar/conf/traccar.xml

info "[8/9] Configurando firewall..."
if ufw status | grep -q "Status: active"; then
    ufw allow 8082/tcp comment "Traccar Web"
    ufw allow 5000:5200/tcp comment "Traccar Protocols TCP"
    ufw allow 5000:5200/udp comment "Traccar Protocols UDP"
    ok "Portas liberadas no UFW ativo."
else
    warn "O UFW está inativo. Nenhuma regra foi aplicada."
    warn "Quando ativar o firewall, libere TCP 8082 e as portas dos rastreadores utilizados."
fi

info "[9/9] Iniciando serviços..."
systemctl daemon-reload
systemctl enable traccar
systemctl restart traccar

sleep 8

mkdir -p /root/rede7-credentials
cat > /root/rede7-credentials/traccar.txt <<EOF
Rede7Telecom - Credenciais Traccar
==================================
Painel: http://${SERVER_IP}:8082
Banco: ${DB_NAME}
Usuário do banco: ${DB_USER}
Senha do banco: ${DB_PASS}
Arquivo de configuração: /opt/traccar/conf/traccar.xml
Log do instalador: /var/log/rede7-traccar-install.log
EOF
chmod 600 /root/rede7-credentials/traccar.txt

if systemctl is-active --quiet traccar; then
    ok "Serviço Traccar está ativo."
else
    journalctl -u traccar --no-pager -n 50 || true
    fatal "O Traccar não iniciou corretamente."
fi

if ss -lnt | awk '{print $4}' | grep -qE '(^|:)8082$'; then
    ok "Painel web respondendo na porta 8082."
else
    warn "O serviço iniciou, mas a porta 8082 ainda não apareceu. Aguarde alguns segundos."
fi

echo
echo "============================================================"
echo "            INSTALAÇÃO CONCLUÍDA COM SUCESSO"
echo "============================================================"
echo
echo "Painel Traccar:"
echo "  http://${SERVER_IP}:8082"
echo
echo "Primeiro acesso:"
echo "  Crie o usuário administrador na tela inicial."
echo
echo "Banco de dados:"
echo "  Banco:   ${DB_NAME}"
echo "  Usuário: ${DB_USER}"
echo "  Senha:   ${DB_PASS}"
echo
echo "Credenciais salvas em:"
echo "  /root/rede7-credentials/traccar.txt"
echo
echo "Comandos úteis:"
echo "  systemctl status traccar"
echo "  journalctl -u traccar -f"
echo "  systemctl restart traccar"
echo
echo "============================================================"
