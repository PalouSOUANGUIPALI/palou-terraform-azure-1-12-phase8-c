# Event Hub Consumer et Pushgateway

Guide sur le pipeline Event Hub → consumer.py → Pushgateway dans
Phase 8C — comment le service systemd `eventhub-consumer.service`
lit les métriques depuis Event Hub et les transmet à Pushgateway
pour affichage dans Grafana.

---

## Table des Matières

- [Event Hub Consumer et Pushgateway](#event-hub-consumer-et-pushgateway)
  - [Table des Matières](#table-des-matières)
  - [Vue d'Ensemble du Pipeline](#vue-densemble-du-pipeline)
  - [consumer.py — Le Process Consommateur](#consumerpy--le-process-consommateur)
    - [Rôle](#rôle)
    - [Format d'Exposition Prometheus](#format-dexposition-prometheus)
    - [Envoi vers Pushgateway](#envoi-vers-pushgateway)
    - [Gestion des Erreurs](#gestion-des-erreurs)
  - [eventhub-consumer.service — Systemd](#eventhub-consumerservice--systemd)
    - [Fichier de Service](#fichier-de-service)
    - [Commandes de Gestion](#commandes-de-gestion)
  - [Pushgateway — Collecte des Métriques](#pushgateway--collecte-des-métriques)
    - [Pourquoi Pushgateway et non Prometheus Direct](#pourquoi-pushgateway-et-non-prometheus-direct)
    - [Structure des Métriques dans Pushgateway](#structure-des-métriques-dans-pushgateway)
  - [Prometheus — Scrape du Pushgateway](#prometheus--scrape-du-pushgateway)
    - [Vérifier le Scrape depuis Prometheus](#vérifier-le-scrape-depuis-prometheus)
  - [Grafana — Visualisation](#grafana--visualisation)
    - [Dashboard Event Hub — Panels](#dashboard-event-hub--panels)
    - [Accès à Grafana](#accès-à-grafana)
  - [Flux Réseau entre les VMs](#flux-réseau-entre-les-vms)
    - [Règles NSG Requises](#règles-nsg-requises)
  - [Dans notre Phase 8C](#dans-notre-phase-8c)
    - [Démarrage du Pipeline](#démarrage-du-pipeline)
    - [Vérifier le Pipeline Complet](#vérifier-le-pipeline-complet)
    - [Points Clés à Retenir](#points-clés-à-retenir)

---

## Vue d'Ensemble du Pipeline

```
Flask app (VM app — snet-app)
  └── POST /metrics/emit
        └── EventHubProducerClient
              └── Event Hub app-metrics (PE snet-pe en prod)

consumer.py (VM app — snet-app — systemd)
  └── EventHubConsumerClient (consumer group : grafana)
        └── Event Hub app-metrics
              └── parse métrique JSON
                    └── HTTP POST → Pushgateway (VM monitoring — 9091)

VM monitoring (snet-monitoring) — Docker Compose
  ├── Pushgateway :9091
  │     └── stocke les métriques en mémoire
  ├── Prometheus :9090
  │     └── scrape Pushgateway toutes les 15 secondes
  └── Grafana :3000
        └── dashboard Event Hub (datasource : Prometheus)
```

Deux VMs distinctes, deux sous-réseaux distincts :

- **VM app (snet-app)** : Flask + consumer.py
- **VM monitoring (snet-monitoring)** : Pushgateway + Prometheus + Grafana

---

## consumer.py — Le Process Consommateur

`consumer.py` est un script Python autonome qui tourne en permanence
sur la VM app. Il n'est pas lié à Flask — c'est un processus séparé
géré par systemd.

### Rôle

```
1. Lire KEY_VAULT_URL depuis la variable d'environnement
2. ManagedIdentityCredential() → IMDS → Token AAD
3. Key Vault → GET eventhub-connection-string
4. Connexion à Event Hub (consumer group : grafana)
5. Boucle de réception :
     pour chaque événement :
       a. Parser le JSON (metric_name, value, tags)
       b. Formater en exposition Prometheus (text/plain)
       c. HTTP POST vers Pushgateway (http://{monitoring_ip}:9091)
       d. update_checkpoint() → marquer la position lue
```

### Format d'Exposition Prometheus

Le Pushgateway attend des métriques au format texte Prometheus :

```
# TYPE orders_processed gauge
orders_processed{env="dev",source="flask-app"} 42.0
# TYPE queue_depth gauge
queue_depth{env="dev"} 10.0
```

### Envoi vers Pushgateway

```python
import requests

def push_to_pushgateway(metric_name, value, tags, pushgateway_url):
    labels = ",".join(f'{k}="{v}"' for k, v in tags.items())
    payload = (
        f"# TYPE {metric_name} gauge\n"
        f"{metric_name}{{{labels}}} {value}\n"
    )
    job_name = "eventhub_consumer"
    url = f"{pushgateway_url}/metrics/job/{job_name}"
    response = requests.post(
        url,
        data=payload,
        headers={"Content-Type": "text/plain; version=0.0.4"}
    )
    response.raise_for_status()
```

### Gestion des Erreurs

Si le push vers Pushgateway échoue, l'événement n'est pas acquitté
(checkpoint non mis à jour) — il sera retraité au prochain cycle.

```python
async def on_event(partition_context, event):
    try:
        data = json.loads(event.body_as_str())
        push_to_pushgateway(
            metric_name=data["metric_name"],
            value=data["value"],
            tags=data.get("tags", {}),
            pushgateway_url=os.environ["PUSHGATEWAY_URL"]
        )
        # Checkpoint uniquement si le push a réussi
        await partition_context.update_checkpoint(event)
    except Exception as e:
        # Log l'erreur — pas de checkpoint → l'événement sera retraité
        logging.error(f"Erreur push Pushgateway : {e}")
```

---

## eventhub-consumer.service — Systemd

`consumer.py` est lancé et maintenu en vie par un service systemd.
Si le processus plante, systemd le redémarre automatiquement.

### Fichier de Service

```ini
[Unit]
Description=Event Hub Consumer - Phase 8C
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/opt/flask-app
Environment="KEY_VAULT_URL=https://phase8c-dev-kv.vault.azure.net/"
Environment="EVENTHUB_NAMESPACE=evhns-phase8c-dev"
Environment="EVENTHUB_NAME=app-metrics"
Environment="CONSUMER_GROUP=grafana"
Environment="PUSHGATEWAY_URL=http://10.0.2.4:9091"
ExecStart=/opt/flask-app/venv/bin/python3 /opt/flask-app/consumer.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Commandes de Gestion

```bash
# Sur la VM Flask (via Bastion)

# Vérifier l'état du service
systemctl status eventhub-consumer

# Voir les logs récents
journalctl -u eventhub-consumer -n 50 --no-pager

# Redémarrer après correction du code
sudo systemctl restart eventhub-consumer

# Activer au démarrage (normalement déjà fait par cloud-init)
sudo systemctl enable eventhub-consumer
```

---

## Pushgateway — Collecte des Métriques

Le Pushgateway est un composant de l'écosystème Prometheus conçu
pour les jobs de courte durée ou les processus qui ne peuvent pas
être scrappés directement (ils "poussent" leurs métriques).

Dans Phase 8C, consumer.py joue le rôle de "job" qui pousse les
métriques Event Hub vers le Pushgateway.

### Pourquoi Pushgateway et non Prometheus Direct

```
Option A — consumer.py expose un endpoint Prometheus
  consumer.py héberge un serveur HTTP :8000 avec /metrics
  Prometheus scrape directement consumer.py

  Problème : consumer.py est sur VM app (snet-app)
             Prometheus est sur VM monitoring (snet-monitoring)
             → NSG doit autoriser le scrape de snet-monitoring vers snet-app
             → Plus complexe, moins clean

Option B — consumer.py pousse vers Pushgateway (choisie)
  consumer.py pousse via HTTP POST vers Pushgateway
  Pushgateway est sur VM monitoring (snet-monitoring)
  Prometheus scrape Pushgateway (même VM — pas de NSG inter-subnet)

  Avantage : un seul flux réseau inter-subnet (consumer → Pushgateway)
             Le scrape Prometheus reste local à VM monitoring
```

### Structure des Métriques dans Pushgateway

Le Pushgateway stocke les métriques par job et par instance.

```
Endpoint : http://pushgateway:9091/metrics/job/{job_name}

Push : POST /metrics/job/eventhub_consumer
  → remplace toutes les métriques du job "eventhub_consumer"

Exposition : GET /metrics
  → retourne toutes les métriques stockées au format Prometheus
    (Prometheus scrape cet endpoint)
```

---

## Prometheus — Scrape du Pushgateway

Prometheus est configuré pour scraper le Pushgateway toutes les
15 secondes via `prometheus.yml`.

```yaml
scrape_configs:
  - job_name: "pushgateway"
    honor_labels: true
    static_configs:
      - targets: ["pushgateway:9091"]
```

`honor_labels: true` est important — il préserve les labels poussés
par consumer.py (comme `env`, `source`) plutôt que de les écraser
avec les labels du job Prometheus.

### Vérifier le Scrape depuis Prometheus

```bash
# Sur l'ordinateur — avec tunnel Bastion actif vers VM monitoring (port 2222)
# et port-forwarding SSH vers Prometheus (port 9090)

# Vérifier que Pushgateway est dans les targets Prometheus
curl -s http://localhost:9090/api/v1/targets \
  | python3 -m json.tool \
  | grep -A5 "pushgateway"

# Chercher une métrique Event Hub dans Prometheus
curl -s "http://localhost:9090/api/v1/query?query=orders_processed" \
  | python3 -m json.tool
```

---

## Grafana — Visualisation

Grafana est configuré avec Prometheus comme datasource et un dashboard
`dashboard-eventhub.json` provisionné automatiquement via
`grafana/provisioning/`.

### Dashboard Event Hub — Panels

```
Panel 1 : orders_processed   (gauge)
  Requête PromQL : orders_processed

Panel 2 : queue_depth         (gauge)
  Requête PromQL : queue_depth

Panel 3 : consumer_lag        (gauge)
  Requête PromQL : consumer_lag

Panel 4 : processing_time_ms  (time series)
  Requête PromQL : processing_time
```

### Accès à Grafana

```bash
# Terminal 1 — Sur l'ordinateur : tunnel Bastion vers VM monitoring
az network bastion tunnel \
  --name bastion-phase8c-dev \
  --resource-group rg-phase8c-dev \
  --target-resource-id <vm-monitoring-id> \
  --resource-port 22 \
  --port 2222

# Terminal 2 — Sur l'ordinateur : tunnel SSH + port-forwarding Grafana
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
  -L 3000:localhost:3000 -N

# Ouvrir dans le navigateur
open http://localhost:3000
# Login : admin / <mot de passe saisi lors de setup-monitoring.sh>
```

---

## Flux Réseau entre les VMs

```
VM app (snet-app : 10.x.1.4)
  │
  └── consumer.py
        └── HTTP POST http://10.x.2.4:9091/metrics/job/eventhub_consumer
              │
              └── NSG snet-monitoring inbound :
                    Allow TCP 9091 depuis snet-app → snet-monitoring

VM monitoring (snet-monitoring : 10.x.2.4)
  └── Pushgateway :9091
        └── Prometheus scrape :9091 (local — même VM — pas de NSG)
              └── Grafana requête Prometheus :9090 (local — même VM)
```

### Règles NSG Requises

```
NSG snet-monitoring inbound :
  Allow TCP 9091 depuis snet-app    (consumer.py → Pushgateway)
  Allow TCP 22   depuis AzureBastionSubnet  (SSH via Bastion)

NSG snet-app outbound :
  Allow TCP 9091 vers snet-monitoring  (consumer.py → Pushgateway)
```

---

## Dans notre Phase 8C

### Démarrage du Pipeline

```
1. git push → TFC déploie les deux VMs
2. cloud-init VM monitoring → Docker installe, répertoires créés
3. ./scripts/setup-monitoring.sh dev → copie monitoring/ sur la VM,
   demande GF_ADMIN_PASSWORD, lance docker compose up
4. cloud-init VM app → Flask + consumer.py installés, services démarrés
5. consumer.py se connecte à Event Hub (consumer group grafana)
6. Flask POST /metrics/emit → événements publiés dans Event Hub
7. consumer.py reçoit les événements → HTTP POST Pushgateway
8. Prometheus scrape Pushgateway → métriques disponibles
9. Grafana affiche le dashboard Event Hub
```

### Vérifier le Pipeline Complet

```bash
# Sur l'ordinateur — émettre quelques métriques
curl -X POST http://localhost:5000/metrics/emit \
  -H "Content-Type: application/json" \
  -d '{"metric_name": "orders_processed", "value": 42, "tags": {"env": "dev"}}'

# Vérifier que consumer.py a reçu et poussé les métriques
# (sur VM app via Bastion)
journalctl -u eventhub-consumer -n 20 --no-pager

# Vérifier que Pushgateway a reçu les métriques
# (sur ordinateur avec tunnel Bastion + SSH vers VM monitoring)
curl http://localhost:9091/metrics | grep orders_processed

# Vérifier dans Prometheus
curl "http://localhost:9090/api/v1/query?query=orders_processed"
```

### Points Clés à Retenir

- consumer.py est un **processus autonome** géré par systemd —
  il tourne en continu indépendamment de Flask
- Le **checkpointing** (`update_checkpoint`) est appelé uniquement
  après un push réussi vers Pushgateway — garantit qu'aucune métrique
  n'est perdue en cas d'erreur réseau transitoire
- Le Pushgateway **remplace** la valeur d'une métrique à chaque push —
  il ne cumule pas. La dernière valeur poussée est celle visible dans Grafana
- `honor_labels: true` dans Prometheus est essentiel pour préserver
  les labels poussés par consumer.py (env, source, etc.)
- `GF_ADMIN_PASSWORD` n'est jamais stocké dans le code — il est
  demandé interactivement par `setup-monitoring.sh` et injecté
  dans Docker Compose via variable d'environnement au démarrage
- Si consumer.py ne reçoit pas de métriques, vérifier :
  1. `systemctl status eventhub-consumer` sur VM app
  2. La résolution DNS d'Event Hub depuis VM app
  3. La connectivité TCP vers Pushgateway depuis VM app

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
