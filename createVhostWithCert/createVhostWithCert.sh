#!/bin/bash

# Script per creare Virtual Host Apache (Reverse Proxy) con Let's Encrypt (certonly)
# Controllo backend e restrizioni IP inclusi.

usage() {
  echo "Uso: $0 <dominio> <proxy_url> <email_certbot> [ip_autorizzati]"
  echo "Esempio: $0 mydomain.com http://127.0.0.1:8080 admin@example.com '1.2.3.4 5.6.7.8'"
  exit 1
}

if [ "$#" -lt 3 ]; then usage; fi

DOMAIN="$1"
PROXY_URL="${2%/}" # Rimuove lo slash finale
CERT_EMAIL="$3"
AUTHORIZED_IP_LIST="${4:-}"
LE_BASE_DIR="/var/lib/letsencrypt"
ACME_ROOT="$LE_BASE_DIR/.well-known/acme-challenge"
OUTPUT_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"

mkdir -p "$ACME_ROOT"
chown -R www-data:www-data /var/lib/letsencrypt
chmod -R 755 /var/lib/letsencrypt

# --- 1. Controlli Preliminari ---
if [ "$EUID" -ne 0 ]; then 
  echo "❌ Errore: Esegui come root (sudo)."
  exit 1
fi

# Verifica comandi necessari
for cmd in certbot apache2ctl a2enmod a2ensite curl dig; do
  if ! command -v "$cmd" >/dev/null; then
    echo "❌ Errore: Comando '$cmd' mancante."
    exit 1
  fi
done

# --- 2. Verifica DNS ---
RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
SERVER_IP=$(curl -s https://api.ipify.org)

if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
  echo "❌ Errore DNS: $DOMAIN ($RESOLVED_IP) non punta a questo server ($SERVER_IP)."
  exit 1
fi

# --- 3. Verifica Raggiungibilità Backend (Non interattivo) ---
echo "🔍 Verifica backend: $PROXY_URL..."
if ! curl -s -o /dev/null --connect-timeout 5 "$PROXY_URL"; then
  echo "❌ Errore: il backend $PROXY_URL non risponde. Interrompo per sicurezza."
  exit 1
fi

# --- 4. Abilitazione Moduli Apache ---
echo "⚙️ Abilitazione moduli Apache..."
a2enmod proxy proxy_http ssl rewrite headers >/dev/null

# --- 5. Fase 1: Certificato SSL (Certonly) ---
TEMP_CONF="/etc/apache2/sites-available/temp-cert-$DOMAIN.conf"
cat <<EOF > "$TEMP_CONF"
<VirtualHost *:80>
    ServerName $DOMAIN

    Alias /.well-known/acme-challenge/ $ACME_ROOT/

    <Directory "$ACME_ROOT">
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite "temp-cert-$DOMAIN.conf" >/dev/null
systemctl reload apache2

echo "🔒 Richiesta certificato Let's Encrypt..."
if ! certbot certonly --webroot -w "$LE_BASE_DIR" -d "$DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"; then
    echo "❌ Errore: Certbot ha fallito l'ottenimento del certificato."
    a2dissite "temp-cert-$DOMAIN.conf"
    rm "$TEMP_CONF"
    systemctl reload apache2
    exit 1
fi

test -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem || {
  echo "❌ Certificato non trovato, abort."
  exit 1
}


# Pulizia configurazione temporanea
a2dissite "temp-cert-$DOMAIN.conf" >/dev/null
rm "$TEMP_CONF"

# --- 6. Fase 2: Creazione Virtual Host Finale ---
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
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =$DOMAIN
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem

    # Restrizioni Accesso (se specificate)
    $(echo -e "$IP_BLOCK")

    ProxyPreserveHost On
    ProxyPass        "/" "$PROXY_URL/"
    ProxyPassReverse "/" "$PROXY_URL/"

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

# --- 7. Attivazione Finale ---
a2ensite "${DOMAIN}.conf" >/dev/null
if apache2ctl configtest 2>/dev/null; then
    systemctl reload apache2
    echo "✅ Successo! $DOMAIN è attivo."
    echo "🔗 Proxy: $PROXY_URL"
    [ -n "$AUTHORIZED_IP_LIST" ] && echo "🔒 Accesso limitato IP."
else
    echo "❌ Errore: Configurazione Apache non valida. Controlla $OUTPUT_FILE"
    exit 1
fi