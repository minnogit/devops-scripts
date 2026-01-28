# Apache Reverse Proxy & SSL Automator

Questo script Bash automatizza la creazione di un **VirtualHost Apache 2.4** configurato come **Reverse Proxy**, occupandosi in modo **robusto e ripetibile** dell’emissione e del **rinnovo automatico** dei certificati **Let’s Encrypt**, con supporto opzionale a **restrizioni IP**.

L’approccio adottato utilizza **Certbot in modalità `certonly --webroot`**, evitando qualsiasi modifica automatica ai VirtualHost da parte di Certbot e mantenendo **pieno controllo** sulla configurazione Apache.

---

## 🎯 Obiettivo

Ridurre al minimo:

* errori manuali
* configurazioni incoerenti
* problemi di rinnovo SSL nel tempo

in scenari reali dove è necessario creare **molti VirtualHost simili**, spesso sotto pressione operativa.

---

## 🚀 Caratteristiche principali

* **Verifica DNS preventiva**
  Lo script controlla che il dominio punti realmente al server prima di procedere.

* **Sanity check del backend**
  Evita di pubblicare un VirtualHost che punta a un servizio non raggiungibile.

* **Isolamento completo delle ACME challenge**
  Le richieste `.well-known/acme-challenge`:

  * non vengono inoltrate al backend
  * non subiscono redirect HTTP → HTTPS
  * sono sempre servite localmente da Apache

* **Compatibilità totale con reverse proxy**
  Gestione esplicita dei casi critici (`ProxyPass !`, `Alias`, `<Directory>`).

* **Rinnovo SSL automatico e sicuro**
  La configurazione finale è già pronta per funzionare con `certbot renew`.

* **Restrizioni IP opzionali**
  Accesso limitato tramite whitelist, senza interferire con il rinnovo dei certificati.

* **Hardening HTTP → HTTPS**
  Redirect permanente, con esclusione esplicita delle ACME challenge.

* **Gestione robusta degli errori e cleanup automatico**
  Interruzioni (CTRL+C, segnali di sistema) ed errori critici attivano
  automaticamente una procedura di rollback per evitare configurazioni
  parziali o incoerenti.

---

## 📋 Prerequisiti

Lo script verifica automaticamente la presenza dei comandi necessari, ma è consigliato avere già installato:

* Apache 2.4
* Certbot
* curl
* dig (dnsutils)

⚠️ Le porte **80 (HTTP)** e **443 (HTTPS)** devono essere accessibili dall’esterno
(almeno durante l’emissione e il rinnovo del certificato).

---

## 📖 Utilizzo

Eseguire lo script con privilegi di root:

```bash
sudo ./setup_proxy.sh <dominio> <proxy_url> <email_certbot> "[ip_autorizzati]"
```

### Esempi

**Accesso pubblico (senza restrizioni IP)**

```bash
sudo ./setup_proxy.sh app.example.com http://127.0.0.1:3000 admin@example.com
```

**Accesso limitato (whitelist IP)**

```bash
sudo ./setup_proxy.sh api.example.com http://10.0.0.5:8080 admin@example.com "1.2.3.4 5.6.7.8"
```

---

## 🛠 Come funziona

### 1️⃣ Validazioni iniziali

Lo script interrompe l’esecuzione se:

* il dominio non punta al server
* il backend non risponde
* Apache non supera il `configtest`

### 2️⃣ VirtualHost temporaneo (porta 80)

Viene creato un VirtualHost minimale che serve **solo**:

```bash
/.well-known/acme-challenge
```

Questo consente a Let’s Encrypt di validare il dominio senza esporre il backend.

### 3️⃣ Emissione certificato

Certbot viene eseguito in modalità:

```bash
certbot certonly --webroot
```

I file della challenge vengono scritti in `/var/lib/letsencrypt`, che Apache sa già come servire.

### 4️⃣ VirtualHost definitivo

Il VirtualHost finale include:

* redirect HTTP → HTTPS (con esclusione ACME)
* configurazione SSL
* reverse proxy verso il backend
* esclusione esplicita delle ACME challenge dal proxy
* restrizioni IP opzionali
* log dedicati

### 5️⃣ Attivazione sicura

Il sito viene abilitato **solo dopo** un `apache2ctl configtest` valido.
In caso di errore o interruzione, lo script esegue automaticamente un
rollback lasciando Apache in uno stato consistente.

---

## 🔄 Rinnovo automatico dei certificati

Poiché il metodo `webroot` viene **salvato nella configurazione di Certbot**, i rinnovi automatici funzionano tramite:

```bash
certbot renew
```

Durante il rinnovo:

* Certbot riscrive temporaneamente le ACME challenge
* Apache le serve localmente
* Apache è in grado di servire le ACME challenge perché la configurazione finale mantiene l'Alias verso la webroot di Certbot.
* il certificato viene aggiornato senza downtime

👉 È **fortemente consigliato** configurare un *deploy hook* per ricaricare Apache dopo il rinnovo:

```bash
/etc/letsencrypt/renewal-hooks/deploy/reload-apache.sh
```

```bash
#!/bin/bash
systemctl reload apache2
```

---

## ⚠️ Note importanti

* Le ACME challenge **non devono mai** essere:

  * proxate
  * bloccate da restrizioni IP
  * soggette a redirect forzati

* Le restrizioni IP si applicano **solo al traffico applicativo**, non al meccanismo di rinnovo SSL.

---

## 📄 Licenza

Questo progetto è rilasciato sotto licenza **MIT**.
