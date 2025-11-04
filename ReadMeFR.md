# 📡 Script Failover 4G pour Proxmox VE

**Version** : 2.0  
**Date** : Décembre 2024  
**Auteur** : Script de basculement automatique sur connexion 4G en cas de panne de la box Internet principale  
**Environnement** : Proxmox VE avec clé 4G USB et ZeroTier

---

## 📖 Table des matières

1. [Principe général](#-principe-général)
2. [Architecture réseau](#-architecture-réseau)
3. [Prérequis](#-prérequis)
4. [Installation](#-installation)
5. [Configuration](#-configuration)
6. [Fonctionnement détaillé](#-fonctionnement-détaillé)
7. [Documentation technique](#-documentation-technique)
8. [Port Forwarding vs MASQUERADE](#-port-forwarding-vs-masquerade)
9. [Maintenance](#-maintenance)
10. [Dépannage](#-dépannage)
11. [Notes pour le futur](#-notes-pour-le-futur)

---

## 🎯 Principe général

Ce script assure la **haute disponibilité** d'un serveur Proxmox VE en basculant automatiquement sur une connexion 4G si la box Internet principale devient inaccessible.

### Fonctionnement en bref

```
┌─────────────────────────────────────────────────────────────┐
│                    Conditions normales                      │
│                                                             │
│  [VM/LXC] ──→ [Host PVE] ──→ [Box Internet] ──→ Internet  │
│                     ↓                                        │
│                 [Clé 4G]  (en veille, bloquée)             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Box Internet DOWN                        │
│                                                             │
│  [VM/LXC] ──→ [Host PVE] ──→ [Clé 4G] ──→ Internet        │
│                     ↑                                        │
│                 Bascule automatique                         │
│                 + Notification Telegram                     │
│                 + Désactivation backups PBS                 │
└─────────────────────────────────────────────────────────────┘
```

### Caractéristiques principales

- ✅ **Bascule automatique** : Détection de panne et activation 4G sans intervention
- ✅ **Retour automatique** : Retour sur box dès qu'elle revient
- ✅ **Économie data** : 4G bloquée en veille, désactivation backups PBS
- ✅ **Monitoring** : Test périodique 4G même en veille, alertes consommation data
- ✅ **Accès distant** : Services accessibles via ZeroTier en mode 4G
- ✅ **Notifications** : Alertes Telegram pour tous les événements
- ✅ **Sécurité** : Seules les machines critiques peuvent utiliser la 4G

---

## 🏗️ Architecture réseau

### Réseaux

| Réseau | Description | Gateway |
|--------|-------------|---------|
| `192.168.2.0/24` | Réseau local principal (box) | 192.168.2.254 |
| `192.168.8.0/24` | Réseau clé 4G | 192.168.8.1 |
| `192.168.12.0/24` | Réseau ZeroTier (VPN) | - |

### Machines

| Machine | IP Locale | IP ZeroTier | Rôle |
|---------|-----------|-------------|------|
| **Host Proxmox** | 192.168.2.28 | 192.168.12.28 | Serveur principal, routeur |
| **NGINX Proxy** | 192.168.2.33 | - | Reverse proxy (port 81) |
| **Home Assistant** | 192.168.2.29 | - | Domotique (port 8123) |
| **PBS** | 192.168.2.25 | - | Backup server |
| **Debian GUI** | 192.168.2.39 | - | Accès interface modem |
| **Clé 4G** | 192.168.8.100 | - | Interface failover |
| **Client distant** | - | 192.168.12.50 | Smartphone/PC (test ZT) |

### Schéma complet

```
                    ┌──────────────────────────────────┐
                    │      Internet (WAN)              │
                    └────────────┬─────────────────────┘
                                 │
                    ┌────────────┴─────────────┐
                    │                          │
            ┌───────▼────────┐        ┌───────▼────────┐
            │  Box Internet  │        │   Clé 4G USB   │
            │ 192.168.2.254  │        │  192.168.8.1   │
            └───────┬────────┘        └───────┬────────┘
                    │ vmbr0                   │ enx001e101f0000
                    │                         │
            ┌───────▼─────────────────────────▼───────┐
            │        Host Proxmox VE                  │
            │     192.168.2.28 (local)                │
            │     192.168.8.100 (4G)                  │
            │     192.168.12.28 (ZeroTier)            │
            │                                         │
            │  [Script Failover 4G]                   │
            │   - Monitoring box                      │
            │   - Bascule routage                     │
            │   - NAT/Port forwarding                 │
            └─────────┬───────────────────────────────┘
                      │
        ┌─────────────┼─────────────┬──────────────┐
        │             │             │              │
    ┌───▼───┐    ┌───▼───┐    ┌───▼───┐     ┌───▼───┐
    │ NGINX │    │ HASS  │    │  PBS  │     │Debian │
    │  .33  │    │  .29  │    │  .25  │     │  .39  │
    └───────┘    └───────┘    └───────┘     └───────┘

    
    ┌──────────────────────────────────────────────────┐
    │            ZeroTier Network                      │
    │         (Accès distant sécurisé)                 │
    │                                                  │
    │  [Client] ──→ 192.168.12.28:8123 ──→ HASS      │
    │  [Client] ──→ 192.168.12.28:81   ──→ NGINX     │
    └──────────────────────────────────────────────────┘
```

---

## 🔧 Prérequis

### Matériel

- ✅ Serveur Proxmox VE (testé sur PVE 7.x/8.x)
- ✅ Clé 4G USB avec mode modem (ex: Huawei E3372)
- ✅ Carte SIM data avec abonnement actif
- ✅ Box Internet avec connexion Ethernet

### Logiciel

```bash
# Paquets requis
apt install -y iptables jq vnstat wget netcat-openbsd curl

# ZeroTier (pour accès distant)
curl -s https://install.zerotier.com | bash
zerotier-cli join <NETWORK_ID>
```

### Configuration système

```bash
# 1. Activer le forwarding IP
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 2. Identifier l'interface 4G
ip link show
# Chercher une interface commençant par "enx" ou "usb"

# 3. Configurer ZeroTier Central
# Sur https://my.zerotier.com :
# - Créer un réseau
# - Ajouter route managée : 192.168.2.0/24 via 192.168.12.28
# - Autoriser les membres (cocher "Auth")
```

### Abonnement 4G

- ⚠️ **APN configuré** dans la clé 4G
- ⚠️ **Forfait data adapté** (recommandé : 5-10 GB/mois)
- ⚠️ **Pas de blocage ICMP** (certains opérateurs bloquent le ping)

---

## 📥 Installation

### Étape 1 : Télécharger le script

```bash
# Créer le répertoire
mkdir -p /usr/local/bin

# Copier le script (depuis l'artifact)
nano /usr/local/bin/4g-failover.sh
# Coller le contenu du script

# Rendre exécutable
chmod +x /usr/local/bin/4g-failover.sh
```

### Étape 2 : Configuration

```bash
# Créer le fichier de configuration
nano /etc/4g-failover.conf
```

Contenu minimal :

```bash
#!/bin/bash
# Configuration Failover 4G

# === INTERFACES ===
INTERFACE_MAIN="vmbr0"
INTERFACE_4G="enx001e101f0000"  # À adapter selon votre clé

# === RÉSEAUX ===
GATEWAY_BOX="192.168.2.254"
IP_4G="192.168.8.100"
GATEWAY_4G="192.168.8.1"
NETMASK_4G="24"

# === ZEROTIER ===
ZT_HOST_IP="192.168.12.28"
ZT_REMOTE_PEER="192.168.12.50"  # IP d'un appareil distant
ZT_TEST_ENABLED="true"

# === MACHINES AUTORISÉES (MASQUERADE) ===
NGINX_IP="192.168.2.33"
HASS_IP="192.168.2.29"
PBS_IP="192.168.2.25"
DEBIAN_GUI_IP="192.168.2.39"

# === PBS ===
PBS_CTID="1011"
LXC_PBS_ENABLED="true"

# === TELEGRAM ===
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_CHAT_ID="987654321"

# === TESTS ===
CHECK_HOSTS=("8.8.8.8" "1.1.1.1")
CHECK_INTERVAL="30"
FAIL_COUNT_THRESHOLD="3"
FOURG_CHECK_INTERVAL="1800"  # 30 minutes

# === ALERTES DATA ===
DATA_ALERT_THRESHOLD_1="500"   # Premier seuil (MB)
DATA_ALERT_THRESHOLD_2="900"   # Second seuil (MB)
DATA_RESET_DAY="1"             # Jour de reset (1-31)

# === DEBUG ===
DEBUG="false"
```

### Étape 3 : Service systemd

```bash
# Créer le service
nano /etc/systemd/system/4g-failover.service
```

Contenu :

```ini
[Unit]
Description=4G Failover Monitoring pour Proxmox
After=network-online.target zerotier-one.service pve-cluster.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/4g-failover.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=4g-failover

# Variables d'environnement
Environment="LOG_FILE=/var/log/4g-failover.log"

[Install]
WantedBy=multi-user.target
```

### Étape 4 : Activation

```bash
# Recharger systemd
systemctl daemon-reload

# Activer au démarrage
systemctl enable 4g-failover

# Démarrer le service
systemctl start 4g-failover

# Vérifier le statut
systemctl status 4g-failover

# Suivre les logs
tail -f /var/log/4g-failover.log
```

---

## ⚙️ Configuration

### Variables principales

| Variable | Description | Exemple | Obligatoire |
|----------|-------------|---------|-------------|
| `INTERFACE_MAIN` | Interface réseau principale | `vmbr0` | ✅ |
| `INTERFACE_4G` | Interface clé 4G | `enx001e101f0000` | ✅ |
| `IP_4G` | IP statique 4G | `192.168.8.100` | ✅ |
| `GATEWAY_4G` | Gateway clé 4G | `192.168.8.1` | ✅ |
| `GATEWAY_BOX` | Gateway box Internet | `192.168.2.254` | ✅ |
| `ZT_HOST_IP` | IP ZeroTier du host | `192.168.12.28` | ✅ |
| `ZT_REMOTE_PEER` | IP ZT appareil test | `192.168.12.50` | ✅ |
| `NGINX_IP` | IP NGINX Proxy | `192.168.2.33` | ✅ |
| `HASS_IP` | IP Home Assistant | `192.168.2.29` | ✅ |
| `PBS_IP` | IP PBS | `192.168.2.25` | ✅ |
| `DEBIAN_GUI_IP` | IP Debian GUI | `192.168.2.39` | ✅ |
| `PBS_CTID` | ID container PBS | `1011` | ✅ |
| `TELEGRAM_BOT_TOKEN` | Token bot Telegram | `123:ABC...` | ❌ |
| `CHECK_INTERVAL` | Intervalle tests (s) | `30` | ❌ |
| `FAIL_COUNT_THRESHOLD` | Échecs avant bascule | `3` | ❌ |
| `DEBUG` | Mode debug | `false` | ❌ |

### Port Forwarding ZeroTier

À modifier dans le script (ligne ~74) :

```bash
declare -A PORT_FORWARDS=(
    ["8123"]="192.168.2.29:8123"  # Home Assistant
    ["81"]="192.168.2.33:81"       # NGINX
    ["8007"]="192.168.2.25:8007"   # PBS (optionnel)
)
```

### Bot Telegram

```bash
# 1. Créer un bot
# Parler à @BotFather sur Telegram
# /newbot -> suivre instructions -> obtenir TOKEN

# 2. Obtenir votre CHAT_ID
# Parler à @userinfobot -> /start -> noter ID

# 3. Configurer
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_CHAT_ID="987654321"
```

---

## 🔄 Fonctionnement détaillé

### Cycle de vie

```
┌──────────────────────────────────────────────────────────┐
│                   DÉMARRAGE                              │
│  1. Vérification dépendances                             │
│  2. Configuration interface 4G (UP + IP statique)        │
│  3. Blocage trafic 4G (sauf 192.168.8.1)                │
│  4. Restauration état (si redémarrage en 4G)            │
└──────────────────┬───────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────┐
│              BOUCLE PRINCIPALE (toutes les 30s)          │
│                                                          │
│  ┌────────────────────────────────────────────┐         │
│  │ Test connectivité BOX (ping 8.8.8.8)      │         │
│  └────────────┬───────────────────────────────┘         │
│               │                                          │
│       ┌───────┴──────┐                                   │
│       │ BOX OK ?     │                                   │
│       └───┬──────┬───┘                                   │
│           │      │                                       │
│          OUI    NON                                      │
│           │      │                                       │
│           │      ▼                                       │
│           │   fail_count++                               │
│           │      │                                       │
│           │   ┌──┴──────────────────┐                   │
│           │   │ fail_count >= 3 ?   │                   │
│           │   └──┬──────────────┬───┘                   │
│           │      │              │                        │
│           │     OUI            NON                       │
│           │      │              │                        │
│           │      ▼              └──→ Continuer           │
│           │   ACTIVATION 4G                              │
│           │   - Déblocage iptables                       │
│           │   - Route default via 4G                     │
│           │   - NAT MASQUERADE x4 machines               │
│           │   - Port forwarding ZT                       │
│           │   - Désactivation PBS                        │
│           │   - Notification Telegram                    │
│           │                                              │
│           ▼                                              │
│   ┌─────────────────┐                                    │
│   │ État actuel 4G? │                                    │
│   └─────┬───────────┘                                    │
│         │                                                │
│        OUI                                               │
│         │                                                │
│         ▼                                                │
│   DÉSACTIVATION 4G                                       │
│   - Routes de test supprimées                            │
│   - Route default via box                                │
│   - Suppression NAT/Port forward                         │
│   - Reblocage iptables 4G                                │
│   - Réactivation PBS                                     │
│   - Notification Telegram                                │
│                                                          │
└──────────────────────────────────────────────────────────┘
│
├──→ Tests périodiques (toutes les 30 min)
│    - Test 4G en veille (connectivité Internet)
│    - Test ZeroTier peer distant
│    - Alertes si 4G down en veille
│
└──→ Vérification data (toutes les heures)
     - Lecture compteur vnstat
     - Alertes si > 500 MB ou > 900 MB
     - Reset automatique jour J du mois
```

### États possibles

| État | Description | Routes | 4G iptables | NAT | Port Forward |
|------|-------------|--------|-------------|-----|--------------|
| **box** | Normal | Default via box | Bloquée | ❌ | ❌ |
| **4g** | Failover | Default via 4G | Débloquée | ✅ x4 | ✅ |
| **transition** | Bascule | Tests en cours | Temporaire | ⏳ | ⏳ |

---

## 📚 Documentation technique

### Fichiers du système

| Fichier | Type | Description |
|---------|------|-------------|
| `/usr/local/bin/4g-failover.sh` | Script | Programme principal |
| `/etc/4g-failover.conf` | Config | Configuration utilisateur |
| `/etc/systemd/system/4g-failover.service` | Service | Service systemd |
| `/var/log/4g-failover.log` | Log | Journal événements |
| `/var/run/4g-failover.state` | État | État actuel (box/active) |
| `/var/run/4g-failover.pid` | PID | PID du processus |
| `/var/run/4g-failover.lock` | Lock | Protection singleton |
| `/var/run/4g-gateway.state` | État | Gateway 4G sauvegardée |
| `/var/run/4g-failover-pbs.state` | État | Jobs PBS désactivés |
| `/var/run/4g-failover-reset.state` | État | Date dernier reset data |

### Architecture du script

```
4g-failover.sh
├── CONFIGURATION (lignes 1-100)
│   ├── Variables globales
│   ├── Chargement /etc/4g-failover.conf
│   └── Configuration port forwarding
│
├── FONCTIONS UTILITAIRES (lignes 100-250)
│   ├── check_dependencies()
│   ├── check_singleton()
│   ├── validate_config()
│   ├── validate_interfaces()
│   ├── with_timeout()
│   ├── setup_log_rotation()
│   ├── log_message()
│   ├── debug_log()
│   └── send_telegram()
│
├── FONCTIONS RÉSEAU (lignes 250-450)
│   ├── setup_4g_static_ip()
│   ├── check_and_fix_resolv_conf()
│   ├── check_box_connectivity()
│   ├── check_4g_connectivity()
│   ├── test_port_connectivity()
│   └── test_forwarded_services()
│
├── FONCTIONS IPTABLES (lignes 450-550)
│   ├── iptables_rule_exists()
│   ├── iptables_block_exists()
│   ├── port_forward_exists()
│   ├── forward_rule_exists()
│   ├── block_4g_traffic()
│   ├── unblock_4g_for_test()
│   ├── unblock_4g_completely()
│   ├── setup_port_forwarding()
│   └── remove_port_forwarding()
│
├── FONCTIONS PBS (lignes 550-650)
│   ├── disable_pbs_sync()
│   └── enable_pbs_sync()
│
├── FONCTIONS MONITORING (lignes 650-700)
│   ├── init_vnstat_4g()
│   └── check_4g_data_usage()
│
├── FONCTIONS FAILOVER (lignes 700-800)
│   ├── activate_4g()
│   ├── deactivate_4g()
│   ├── restore_state()
│   └── cleanup()
│
└── BOUCLE PRINCIPALE (lignes 800-900)
    ├── Initialisation
    ├── Tests périodiques box
    ├── Bascule 4G si nécessaire
    ├── Tests périodiques 4G veille
    └── Vérification data
```

### Fonctions principales

#### `check_dependencies()`
**Objectif** : Vérifier présence de tous les paquets requis  
**Dépendances** : `iptables`, `ping`, `wget`, `ip`, `pct`, `jq`, `vnstat`, `timeout`, `nc`  
**Action** : Affiche erreur et exit si manquants

#### `check_singleton()`
**Objectif** : Empêcher plusieurs instances simultanées  
**Mécanisme** : Lock file `/var/run/4g-failover.lock` avec PID  
**Action** : Exit si déjà en cours

#### `setup_4g_static_ip()`
**Objectif** : Configurer IP statique sur interface 4G  
**Actions** :
- Vérifier interface UP
- Flush adresses existantes
- Ajouter `IP_4G/NETMASK_4G`
**Résultat** : Interface prête pour routage

#### `check_box_connectivity()`
**Objectif** : Tester si box Internet fonctionne  
**Méthode** : Ping via `INTERFACE_MAIN` vers `CHECK_HOSTS`  
**Retour** : 0 si OK, 1 si KO

#### `check_4g_connectivity()`
**Objectif** : Tester si 4G fonctionne (Internet + ZeroTier)  
**Méthodes** :
- wget (ICMP bloqué par opérateur 4G)
- Ping ZeroTier peer distant
**Retour** : 0 si OK, 1 si KO

#### `block_4g_traffic()`
**Objectif** : Bloquer tout trafic 4G sauf interface web modem  
**Règles iptables** :
```
ACCEPT  -o enx... -d 192.168.8.1
DROP    -o enx...
```

#### `setup_port_forwarding()`
**Objectif** : Configurer redirection ports ZeroTier vers services internes  
**Règles iptables** :
```
PREROUTING  : DNAT  ZT:8123 → 192.168.2.29:8123
FORWARD     : ACCEPT vers services
POSTROUTING : MASQUERADE sortie vers vmbr0
```

#### `activate_4g(mode)`
**Objectif** : Basculer sur connexion 4G  
**Paramètres** :
- `mode="failover"` : Failover complet (NAT + port forward)
- `mode="test"` : Test uniquement (sans NAT)

**Actions** :
1. Vérifier IP 4G configurée
2. Débloquer iptables 4G
3. Attendre stabilisation (max 25s)
4. Tester connectivité
5. Basculer route default
6. Ajouter routes test box
7. **Si mode failover** :
   - Ajouter NAT MASQUERADE (4 machines)
   - Configurer port forwarding ZT
   - Tester services
   - Désactiver PBS
   - Notifier Telegram

#### `deactivate_4g()`
**Objectif** : Retour sur box Internet  
**Actions** :
1. Supprimer routes test box
2. Supprimer route default 4G
3. Restaurer route default box
4. Supprimer NAT MASQUERADE
5. Supprimer port forwarding ZT
6. Rebloquer iptables 4G
7. Réactiver PBS
8. Notifier Telegram

#### `disable_pbs_sync()` / `enable_pbs_sync()`
**Objectif** : Suspendre/reprendre backups PBS pour économie data  
**Méthode** :
- Liste jobs via `proxmox-backup-manager`
- Sauvegarde schedules dans `/var/run/4g-failover-pbs.state`
- Supprime schedules (`--delete schedule`)
- Restaure à la désactivation 4G

#### `check_4g_data_usage()`
**Objectif** : Surveiller consommation data 4G  
**Source** : vnstat (compteur interface)  
**Actions** :
- Lecture RX + TX
- Ajout `DATA_INITIAL_MB` (migration mois)
- Alertes si > seuils (500 MB, 900 MB)
- Reset automatique jour `DATA_RESET_DAY`
- Max 3 alertes par seuil (anti-spam)

### Tables iptables utilisées

#### Table NAT

| Chaîne | Règle | Objectif |
|--------|-------|----------|
| **OUTPUT** | `ACCEPT -o enx... -d 192.168.8.1` | Host peut accéder modem |
| **OUTPUT** | `DROP -o enx...` | Host ne peut pas sortir en 4G |
| **PREROUTING** | `DNAT -i zt+ --dport 8123 → 192.168.2.29:8123` | Port forward HASS |
| **PREROUTING** | `DNAT -i zt+ --dport 81 → 192.168.2.33:81` | Port forward NGINX |
| **POSTROUTING** | `MASQUERADE -s 192.168.2.33/32 -o enx...` | NGINX sort via 4G |
| **POSTROUTING** | `MASQUERADE -s 192.168.2.29/32 -o enx...` | HASS sort via 4G |
| **POSTROUTING** | `MASQUERADE -s 192.168.2.25/32 -o enx...` | PBS sort via 4G |
| **POSTROUTING** | `MASQUERADE -s 192.168.2.39/32 -o enx...` | Debian sort via 4G |
| **POSTROUTING** | `MASQUERADE -o vmbr0 -d 192.168.2.29 -p tcp --dport 8123` | NAT services ZT |

#### Table FILTER

| Chaîne | Règle | Objectif |
|--------|-------|----------|
| **FORWARD** | `ACCEPT -d 192.168.2.29 -p tcp --dport 8123` | Accepter vers HASS |
| **FORWARD** | `ACCEPT -d 192.168.2.33 -p tcp --dport 81` | Accepter vers NGINX |

---

## 🔀 Port Forwarding vs MASQUERADE

### Comprendre la différence

Les deux mécanismes sont **complémentaires** et agissent sur des **directions de connexion différentes**.

#### Port Forwarding (DNAT)

**Direction** : Connexion **ENTRANTE** (initiée de l'extérieur)  
**Table iptables** : `nat PREROUTING`  
**Action** : Redirige un port du host vers une machine interne

```
┌─────────────────────────────────────────────────────────┐
│  CLIENT EXTERNE (ZeroTier)                              │
│  192.168.12.50                                          │
└────────────────┬────────────────────────────────────────┘
                 │ Initie connexion
                 ▼
         ┌───────────────────┐
         │  Host PVE (ZT)    │
         │  192.168.12.28    │
         │       :8123       │  ← Port exposé
         └───────┬───────────┘
                 │ DNAT (Port Forward)
                 ▼
         ┌───────────────────┐
         │  Home Assistant   │
         │  192.168.2.29     │
         │      :8123        │  ← Port réel
         └───────────────────
