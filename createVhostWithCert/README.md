# Apache Reverse Proxy & SSL Automator

Questo script Bash automatizza la creazione di un **Virtual Host Apache** configurato come **Reverse Proxy**, gestendo automaticamente l'ottenimento del certificato **SSL Let's Encrypt** e l'applicazione di **restrizioni IP**.

L'approccio utilizzato è il metodo `certonly` con convalida `webroot`, che garantisce una configurazione pulita senza che Certbot modifichi arbitrariamente i file di sistema.

## 🚀 Caratteristiche

* **Verifica DNS:** Controlla che il dominio punti correttamente all'IP del server prima di iniziare.
* **Sanity Check del Backend:** Verifica che il server di destinazione (proxy) sia raggiungibile.
* **Isolamento ACME:** Utilizza una directory dedicata (`Alias`) per le sfide di Let's Encrypt, evitando conflitti con il proxy.
* **SSL Automatico:** Ottiene certificati validi tramite Certbot.
* **Whitelist IP:** Permette di limitare l'accesso al sito solo a determinati indirizzi IP.
* **Hardening:** Forza il reindirizzamento da HTTP a HTTPS.

## 📋 Prerequisiti

Lo script verificherà la presenza dei seguenti pacchetti, ma è consigliabile averli già installati:

* Apache2
* Certbot
* curl, dig (dnsutils)

Il server deve avere le porte **80** (HTTP) e **443** (HTTPS) aperte nel firewall.

## 📖 Utilizzo

Esegui lo script con privilegi di root:

```bash
sudo ./setup_proxy.sh <dominio> <proxy_url> <email_certbot> "[ip_autorizzati]"

```

### Esempi

**Accesso Pubblico (Senza restrizioni IP):**

```bash
sudo ./setup_proxy.sh app.example.com [http://127.0.0.1:3000](http://127.0.0.1:3000) admin@example.com

```

**Accesso Limitato (Whitelist IP):**

```bash
sudo ./setup_proxy.sh api.example.com [http://10.0.0.5:8080](http://10.0.0.5:8080) admin@example.com "1.2.3.4 5.6.7.8"

```

## 🛠 Come Funziona

1. **Validazione:** Lo script controlla i parametri, l'IP pubblico e la raggiungibilità del backend.
2. **Fase Temporanea:** Crea un VirtualHost minimale sulla porta 80 per rispondere alla sfida di Let's Encrypt tramite una directory dedicata in `/var/lib/letsencrypt`.
3. **Certificazione:** Esegue `certbot certonly` per ottenere i certificati SSL.
4. **Configurazione Finale:** Genera il file `.conf` definitivo in `/etc/apache2/sites-available/` con:

* Redirect permanente a HTTPS.
* Configurazione SSL con i percorsi corretti.
* Regole di ProxyPass.
* Blocco `<Proxy *>` per le restrizioni IP (se fornite).

5. **Attivazione:** Abilita il sito e ricarica Apache dopo un `configtest`.

## ⚠️ Note Importanti

* **Rinnovi:** Poiché lo script usa il metodo `webroot` salvando la configurazione in Certbot, i rinnovi automatici (tramite il cron/timer di certbot) funzioneranno correttamente senza ulteriori interventi.
* **Backend:** Assicurati che il tuo backend non blocchi le richieste provenienti dall'IP locale del server Apache.

## 📄 Licenza

Questo progetto è rilasciato sotto licenza MIT.
