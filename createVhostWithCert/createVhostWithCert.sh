#!/bin/bash

# Script per creare Virtual Host Apache (Reverse Proxy) con Let's Encrypt (certonly)
# Ottimizzato per Rinnovo Automatico e Sicurezza.

usage() {
  echo "Uso: $0 <dominio> <proxy_url> <email_certbot> [ip_autorizzati]"
  exit 1
}

if [ "$#" -lt 3 ]; then usage; fi

DOMAIN="$1"
PROXY_URL="${2%/}"
CERT_EMAIL="$3"
AUTHORIZED_IP_LIST="${4:-}"
LE_BASE_DIR="/var/lib/letsencrypt"
ACME_ROOT="$LE_BASE_DIR/.well-known/acme-challenge"
OUTPUT_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"

if [ -f "$OUTPUT_FILE" ]; then
  echo "❌ VirtualHost già esistente: $OUTPUT_FILE"
  exit 1
fi

if [ "$EUID" -ne 0 ]; then echo "❌ Esegui come root"; exit 1; fi

# --- Fase 1: Certificato SSL ---
TEMP_CONF="/etc/apache2/sites-available/temp-cert-$DOMAIN.conf"

SUCCESS=false
cleanup() {
  if [ "$SUCCESS" = false ]; then
    echo "🧹 Errore rilevato. Pulizia in corso..."
    
    # 1. Rimuoviamo sempre il sito temporaneo se presente
    if [ -f "/etc/apache2/sites-enabled/temp-cert-$DOMAIN.conf" ]; then
      a2dissite "temp-cert-$DOMAIN.conf" >/dev/null 2>&1
    fi
    [ -f "$TEMP_CONF" ] && rm -f "$TEMP_CONF"

    # 2. Gestione OUTPUT_FILE finale
    if [ -f "$OUTPUT_FILE" ]; then
      # Se il certificato NON esiste, il fallimento è avvenuto durante Certbot.
      # Cancelliamo il file per rendere lo script rilanciabile.
      if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        rm -f "$OUTPUT_FILE"
        echo "🗑️ Configurazione rimossa (certificato non ancora ottenuto)."
      else
        # Se il certificato ESISTE, il fallimento è nel configtest o reload finale.
        # Teniamo il file per debug e disattiviamo solo il link.
        a2dissite "${DOMAIN}.conf" >/dev/null 2>&1
        echo "⚠️ Configurazione mantenuta in sites-available per debug (Certificato SSL già emesso)."
      fi
    fi

    # 3. Ripristino Apache
    if systemctl is-active --quiet apache2; then
        systemctl reload apache2 >/dev/null 2>&1
    elif apache2ctl configtest >/dev/null 2>&1; then
        systemctl start apache2 >/dev/null 2>&1
    fi
  fi
}

set -Euo pipefail
# La trap osserva errori (ERR), interruzioni (INT) e uscite anticipate
trap cleanup ERR INT TERM

# --- Verifica stato iniziale Apache ---
echo "🔍 Controllo integrità configurazione attuale..."
if ! apache2ctl configtest >/dev/null 2>&1; then
    echo "❌ Errore: La configurazione attuale di Apache è già corrotta!"
    echo "Riparala prima di lanciare questo script."
    exit 1
fi

APACHE_WAS_NOT_RUNNING=false
if ! systemctl is-active --quiet apache2; then
    echo "⚠️ Apache non è attivo. Provo ad avviarlo..."
    APACHE_WAS_NOT_RUNNING=true
    if ! systemctl start apache2; then
        echo "❌ Errore: Impossibile avviare Apache. Controlla i log con 'journalctl -xe'."
        exit 1
    fi
fi

# --- Configurazione Hook per Rinnovo Automatico ---
# Creiamo l'hook di reload solo se non esiste già
HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/reload-apache.sh"

if [ ! -f "$HOOK_PATH" ]; then
    echo "🔧 Configurazione hook di reload per Certbot..."
    cat <<EOF > "$HOOK_PATH"
#!/bin/bash
# Ricarica Apache dopo un rinnovo di certificato riuscito
systemctl reload apache2
EOF
    chmod +x "$HOOK_PATH"
else
    echo "✅ Hook di reload già presente, salto creazione."
fi

# --- Preparazione Ambiente ---
mkdir -p "$ACME_ROOT"
chown -R root:www-data /var/lib/letsencrypt
chmod -R 755 /var/lib/letsencrypt

# --- Verifica DNS ---
# Otteniamo l'IP pubblico visto dall'esterno
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)

# Otteniamo l'IP risolto dal DNS per il dominio
RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)

if [ -z "$RESOLVED_IP" ]; then
    echo "❌ Errore: Il dominio $DOMAIN non risolve a nessun IP. Controlla i tuoi record DNS."
    exit 1
fi

# Controllo se SERVER_IP è un IP privato
IS_PRIVATE=false
if echo "$SERVER_IP" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'; then
    IS_PRIVATE=true
fi

if [ "$IS_PRIVATE" = true ]; then
    echo "⚠️ Rilevato IP locale ($SERVER_IP). Non posso verificare il DNS automaticamente."
    echo "Assicurati che l'IP pubblico del router ($RESOLVED_IP) punti a questa macchina via NAT sulla porta 80."
else
    # Se l'IP è pubblico, facciamo il controllo rigoroso
    if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
        echo "❌ Errore DNS: Il dominio $DOMAIN punta a $RESOLVED_IP, ma questo server esce con $SERVER_IP."
        exit 1
    fi
    echo "✅ Verifica DNS superata ($SERVER_IP)."
fi

if ! curl -s -o /dev/null --connect-timeout 5 "$PROXY_URL"; then
  echo "❌ Errore: Backend non raggiungibile."; exit 1
fi

# --- Abilitazione Moduli Apache ---
echo "⚙️ Abilitazione moduli Apache..."
# Usiamo una variabile per tracciare se dobbiamo ricaricare
RELOAD_NEEDED=false

for mod in proxy proxy_http ssl rewrite headers; do
  if ! apache2ctl -M | grep -q "${mod}_module"; then
    a2enmod "$mod" >/dev/null
    RELOAD_NEEDED=true
  fi
done

# Se abbiamo abilitato nuovi moduli, ricarichiamo Apache ORA.
# Questo assicura che le direttive SSL o Proxy siano riconosciute nei passaggi successivi.
if [ "$RELOAD_NEEDED" = true ]; then
    echo "🔄 Riavvio tecnico per caricamento moduli..."
    systemctl restart apache2
fi

cat <<EOF > "$TEMP_CONF"
<VirtualHost *:80>
    ServerName $DOMAIN
    Alias /.well-known/acme-challenge/ $ACME_ROOT/
    <Directory "$ACME_ROOT">
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite "temp-cert-$DOMAIN.conf" >/dev/null
systemctl reload apache2

if ! certbot certonly --webroot -w "$LE_BASE_DIR" -d "$DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"; then
    echo "❌ Certbot fallito"; exit 1
fi

a2dissite "temp-cert-$DOMAIN.conf" >/dev/null
rm "$TEMP_CONF"

# --- Fase 2: Configurazione Finale ---
IP_BLOCK=""
if [ -n "$AUTHORIZED_IP_LIST" ]; then
    IP_BLOCK="<Proxy *>\n        Require all denied"
    for ip in $AUTHORIZED_IP_LIST; do
        IP_BLOCK="$IP_BLOCK\n        Require ip $ip"
    done
    IP_BLOCK="$IP_BLOCK\n    </Proxy>"
fi

echo "📝 Generazione configurazione finale..."
cat <<EOF > "$OUTPUT_FILE"
<VirtualHost *:80>
    ServerName $DOMAIN

    # Permetti rinnovo senza redirect
    Alias /.well-known/acme-challenge/ $ACME_ROOT/
    
    RewriteEngine on
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge [NC]
    RewriteCond %{SERVER_NAME} =$DOMAIN
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]

    <Directory "$ACME_ROOT">
        Require all granted
    </Directory>
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem

    # Gestione Rinnovo SSL
    Alias /.well-known/acme-challenge/ $ACME_ROOT/
    <Directory "$ACME_ROOT">
        Require all granted
    </Directory>

    # Restrizioni Accesso
    $(echo -e "$IP_BLOCK")

    # Configurazione Proxy
    ProxyPreserveHost On
    
    # Escludi acme-challenge dal proxy
    ProxyPass /.well-known/acme-challenge !
    
    ProxyPass        "/" "$PROXY_URL/"
    ProxyPassReverse "/" "$PROXY_URL/"

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

echo "⚙️ Test della configurazione Apache..."
a2ensite "${DOMAIN}.conf" >/dev/null

if apache2ctl configtest 2>/dev/null; then
    # Se Apache è attivo ricarica, altrimenti avvia
    if systemctl is-active --quiet apache2; then
        systemctl reload apache2
    else
        systemctl start apache2
    fi
    SUCCESS=true
    echo "✅ Successo! $DOMAIN è attivo."
else
    echo "❌ Errore: Configurazione non valida. Rollback..."
    exit 1
fi
