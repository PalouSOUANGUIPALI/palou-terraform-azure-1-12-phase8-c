# Quick Start - Phase 8C

## Commande de Création de Structure

```bash
mkdir -p ~/phase8c-messaging/{app,assets,docs,monitoring/grafana/provisioning/{datasources,dashboards},modules/{networking,compute,service-bus,event-hub,key-vault,monitoring},environments/{dev,staging,prod},scripts,tests} && \
cd ~/phase8c-messaging && \
touch modules/networking/{main.tf,variables.tf,outputs.tf,nsg-rules.tf} && \
touch modules/compute/{main.tf,variables.tf,outputs.tf,cloud-init-app.tftpl,cloud-init-monitoring.tftpl} && \
touch modules/service-bus/{main.tf,variables.tf,outputs.tf,queues.tf,topics.tf,private-endpoint.tf,diagnostic.tf} && \
touch modules/event-hub/{main.tf,variables.tf,outputs.tf,eventhub.tf,private-endpoint.tf,diagnostic.tf} && \
touch modules/key-vault/{main.tf,variables.tf,outputs.tf,rbac.tf,secrets.tf,private-endpoint.tf,diagnostic.tf} && \
touch modules/monitoring/{main.tf,variables.tf,outputs.tf} && \
for env in dev staging prod; do touch environments/$env/{backend.tf,providers.tf,variables.tf,terraform.tfvars,main.tf,outputs.tf}; done && \
touch app/{main.py,consumer.py,consumer-startup.sh,requirements.txt,startup.sh} && \
touch assets/architecture-phase8c.png && \
touch monitoring/{docker-compose.yml,prometheus.yml} && \
touch monitoring/grafana/provisioning/datasources/datasource.yml && \
touch monitoring/grafana/provisioning/dashboards/{dashboard.yml,dashboard-eventhub.json} && \
touch docs/{01_service-bus.md,02_event-hub.md,03_queues-topics-subscriptions.md,04_dead-letter-queue.md,05_private-endpoints.md,06_managed-identity.md,07_event-hub-consumer-pushgateway.md,08_messaging-patterns.md,09_observability.md,10_guide-exploration.md} && \
touch scripts/{README.md,setup-azure.sh,setup-monitoring.sh,deploy-dev.sh,deploy-staging.sh,deploy-prod.sh,deploy-all.sh,validate.sh,generate-traffic.sh,destroy-env.sh,destroy-all.sh} && \
touch tests/{test-all.sh,test-private-endpoint.sh,test-mi-auth.sh,test-servicebus.sh,test-eventhub.sh} && \
touch {.gitignore,CONCEPTS.md,QUICK-START.md,README.md,SETUP.md} && \
chmod +x scripts/*.sh tests/*.sh && \
echo "Structure Phase 8C créée avec 3 environnements (dev, staging, prod)"
```

## Vérification

```bash
cd ~/phase8c-messaging
find . -type f | wc -l
```

Résultat attendu : **92 fichiers**

## Comptage par Dossier

```bash
echo "=== Comptage Phase 8C ==="
echo "app         : $(find app -type f | wc -l) fichier(s)"
echo "assets      : $(find assets -type f | wc -l) fichier(s)"
echo "docs        : $(find docs -type f | wc -l) fichier(s)"
echo "monitoring  : $(find monitoring -type f | wc -l) fichier(s)"
echo "modules     : $(find modules -type f | wc -l) fichier(s)"
echo "environments: $(find environments -type f | wc -l) fichier(s)"
echo "scripts     : $(find scripts -type f | wc -l) fichier(s)"
echo "tests       : $(find tests -type f | wc -l) fichier(s)"
echo "racine      : $(find . -maxdepth 1 -type f | wc -l) fichier(s)"
echo "=========================="
echo "TOTAL       : $(find . -type f | wc -l) fichier(s)"
```

Résultat attendu :

```
=== Comptage Phase 8C ===
app         : 5 fichier(s)
assets      : 1 fichier(s)
docs        : 10 fichier(s)
monitoring  : 5 fichier(s)
modules     : 32 fichier(s)
environments: 18 fichier(s)   (3 envs x 6 fichiers)
scripts     : 11 fichier(s)   (10 scripts + README.md)
tests       : 5 fichier(s)
racine      : 5 fichier(s)
==========================
TOTAL       : 92 fichier(s)
```

Détail des modules :

```
modules/
  networking/   → main.tf, variables.tf, outputs.tf, nsg-rules.tf           (4)
  compute/      → main.tf, variables.tf, outputs.tf,                        (5)
                   cloud-init-app.tftpl, cloud-init-monitoring.tftpl
  service-bus/  → main.tf, variables.tf, outputs.tf,                        (7)
                   queues.tf, topics.tf, private-endpoint.tf, diagnostic.tf
  event-hub/    → main.tf, variables.tf, outputs.tf,                        (6)
                   eventhub.tf, private-endpoint.tf, diagnostic.tf
  key-vault/    → main.tf, variables.tf, outputs.tf,                        (7)
                   rbac.tf, secrets.tf, private-endpoint.tf, diagnostic.tf
  monitoring/   → main.tf, variables.tf, outputs.tf                         (3)
```

Détail du dossier monitoring/ :

```
monitoring/
  docker-compose.yml
  prometheus.yml
  grafana/
    provisioning/
      datasources/
        datasource.yml
      dashboards/
        dashboard.yml
        dashboard-eventhub.json
```

Détail des docs :

```
docs/
  01_service-bus.md
  02_event-hub.md
  03_queues-topics-subscriptions.md
  04_dead-letter-queue.md
  05_private-endpoints.md
  06_managed-identity.md
  07_event-hub-consumer-pushgateway.md
  08_messaging-patterns.md
  09_observability.md
  10_guide-exploration.md
```

Fichiers racine :

```
.gitignore
CONCEPTS.md
QUICK-START.md
README.md
SETUP.md
```

Différences structurelles avec la Phase 8B :

```
Phase 8B                            Phase 8C
--------                            --------
modules/cosmos-db/      (6)      →  remplacé par service-bus/ (7 fichiers)
modules/redis/          (5)      →  remplacé par event-hub/ (6 fichiers)
modules/compute/        (4)      →  modules/compute/ (5) + cloud-init x2
1 VM (Flask)                     →  2 VMs (Flask + Monitoring)
3 subnets                        →  4 subnets (+ snet-monitoring)
app/ (3 fichiers)                →  app/ (5 fichiers) + consumer.py
                                 →  monitoring/ (nouveau, 5 fichiers)
scripts/ 10 fichiers             →  scripts/ 11 fichiers (+ setup-monitoring.sh)
2 zones DNS privées              →  2 zones DNS privées (servicebus partagée SB+EH)
```

## Déploiement en 5 Minutes

```bash
# 1. Rendre les scripts exécutables
chmod +x scripts/*.sh tests/*.sh

# 2. Vérifier la clé SSH
ls ~/.ssh/id_rsa_azure.pub || ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure

# 3. Configurer Azure + TFC (crée les 3 workspaces TFC, injecte les 7 variables)
./scripts/setup-azure.sh

# 4. Premier push
git add .
git commit -m "Phase 8C initial"
git push

# 5. Déployer dev
./scripts/deploy-dev.sh
# Approuver dans TFC

# 6. Configurer le monitoring dev (après déploiement de la VM monitoring)
./scripts/setup-monitoring.sh dev
# Le script demandera le mot de passe Grafana interactivement

# 7. Déployer staging
./scripts/deploy-staging.sh
# Approuver dans TFC
./scripts/setup-monitoring.sh staging

# 8. Déployer prod
./scripts/deploy-prod.sh
# Approuver dans TFC (saisir "oui" pour confirmer)
./scripts/setup-monitoring.sh prod

# 9. Valider l'infrastructure
./scripts/validate.sh dev

# 10. Ouvrir les tunnels (dans des terminaux séparés)
# Voir section "Accès à l'Application Flask" ci-dessous

# 11. Exécuter tous les tests
./tests/test-all.sh dev

# 12. Générer du trafic et observer le pipeline Event Hub → Grafana
./scripts/generate-traffic.sh dev 15
```

## Accès à l'Application Flask

L'accès à Flask nécessite **deux tunnels ouverts en parallèle**.

### Étape 1 — Tunnel Bastion vers VM app

```bash
ENV=dev
RG=rg-phase8c-$ENV

BASTION=$(az network bastion list \
  --resource-group $RG \
  --query "[0].name" -o tsv)

VM_APP_ID=$(az vm show \
  --resource-group $RG \
  --name "vm-phase8c-${ENV}-app" \
  --query id -o tsv)

# Terminal 1 — laisser ouvert
az network bastion tunnel \
  --name $BASTION \
  --resource-group $RG \
  --target-resource-id $VM_APP_ID \
  --resource-port 22 \
  --port 2223
```

### Étape 2 — Tunnel SSH avec port-forwarding Flask

```bash
# Terminal 2 — laisser ouvert
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \
  -L 5000:localhost:5000 -N
```

### Étape 3 — Appels Flask

```bash
# Terminal 3 — depuis l'ordinateur

# Health check
curl http://localhost:5000/health

# Envoyer un message dans la queue orders
curl -X POST http://localhost:5000/api/messages/send \
  -H 'Content-Type: application/json' \
  -d '{"order_id": "001", "product": "laptop", "quantity": 1}'

# Recevoir un message (PEEK_LOCK)
curl http://localhost:5000/api/messages/receive

# Lire la Dead-Letter Queue
curl http://localhost:5000/api/messages/dlq

# Retraiter un message en DLQ
curl -X POST http://localhost:5000/api/messages/dlq/reprocess

# Publier sur le topic events (reçu par sub-logs uniquement — level = 'info')
curl -X POST http://localhost:5000/api/events/publish \
  -H 'Content-Type: application/json' \
  -d '{"type": "order-processed", "level": "info", "order_id": "001"}'

# Publier sur le topic events (reçu par sub-logs ET sub-alerts — level = 'critical')
curl -X POST http://localhost:5000/api/events/publish \
  -H 'Content-Type: application/json' \
  -d '{"type": "payment-failed", "level": "critical", "order_id": "001"}'

# Lire depuis les subscriptions
curl http://localhost:5000/api/events/subscribe/sub-logs
curl http://localhost:5000/api/events/subscribe/sub-alerts

# Émettre des métriques vers Event Hub → pipeline Grafana
curl -X POST http://localhost:5000/api/metrics/emit \
  -H 'Content-Type: application/json' \
  -d '{"name": "orders_processed", "value": 42, "labels": {"env": "dev"}}'
```

| Environnement | Port Bastion tunnel | Port Flask local | URL                   |
| ------------- | ------------------- | ---------------- | --------------------- |
| dev           | 2223                | 5000             | http://localhost:5000 |
| staging       | 2223                | 5001             | http://localhost:5001 |
| prod          | 2223                | 5002             | http://localhost:5002 |

Endpoints Flask disponibles :

| Endpoint                    | Méthode | Rôle                                             |
| --------------------------- | ------- | ------------------------------------------------ |
| /health                     | GET     | Statut Service Bus, Event Hub et Key Vault       |
| /api/messages/send          | POST    | Envoie un message dans la queue orders           |
| /api/messages/receive       | GET     | Reçoit un message de la queue orders (PEEK_LOCK) |
| /api/messages/dlq           | GET     | Lit les messages de la dead-letter queue         |
| /api/messages/dlq/reprocess | POST    | Renvoie le premier message DLQ dans orders       |
| /api/events/publish         | POST    | Publie un événement sur le topic events          |
| /api/events/subscribe/<sub> | GET     | Reçoit depuis sub-logs ou sub-alerts             |
| /api/metrics/emit           | POST    | Envoie des métriques vers Event Hub app-metrics  |

## Accès au Monitoring (Grafana / Prometheus)

L'accès au monitoring nécessite également **deux tunnels**.

### Étape 1 — Tunnel Bastion vers VM monitoring

```bash
ENV=dev
RG=rg-phase8c-$ENV

VM_MONITORING_ID=$(az vm show \
  --resource-group $RG \
  --name "vm-phase8c-${ENV}-monitoring" \
  --query id -o tsv)

# Terminal 1 — laisser ouvert
az network bastion tunnel \
  --name $(az network bastion list -g $RG --query '[0].name' -o tsv) \
  --resource-group $RG \
  --target-resource-id $VM_MONITORING_ID \
  --resource-port 22 \
  --port 2222
```

### Étape 2 — Tunnel SSH avec port-forwarding

```bash
# Terminal 2 — laisser ouvert
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9091:localhost:9091 \
  -N
```

### Étape 3 — Accès depuis le navigateur

```
Grafana     : http://localhost:3000   (admin / mot de passe setup-monitoring.sh)
Prometheus  : http://localhost:9090
Pushgateway : http://localhost:9091
```

## Connexion SSH aux VMs

```bash
ENV=dev
RG=rg-phase8c-$ENV

# VM app
az network bastion ssh \
  --name $(az network bastion list -g $RG --query '[0].name' -o tsv) \
  --resource-group $RG \
  --target-resource-id $(az vm show -g $RG \
    -n "vm-phase8c-${ENV}-app" --query id -o tsv) \
  --auth-type ssh-key \
  --username azureuser \
  --ssh-key ~/.ssh/id_rsa_azure

# Sur VM app — vérifier les deux services
systemctl status flask-app
systemctl status eventhub-consumer
journalctl -u eventhub-consumer -n 30 --no-pager
sudo tail -30 /var/log/cloud-init-output.log

# VM monitoring
az network bastion ssh \
  --name $(az network bastion list -g $RG --query '[0].name' -o tsv) \
  --resource-group $RG \
  --target-resource-id $(az vm show -g $RG \
    -n "vm-phase8c-${ENV}-monitoring" --query id -o tsv) \
  --auth-type ssh-key \
  --username azureuser \
  --ssh-key ~/.ssh/id_rsa_azure

# Sur VM monitoring — vérifier Docker Compose
docker compose -f /opt/monitoring/docker-compose.yml ps
docker compose -f /opt/monitoring/docker-compose.yml logs --tail=20
```

## Workspaces Terraform Cloud

Organisation : `palou-terraform-azure-1-12-phase8-c`

| Workspace       | Environnement | Working Directory    |
| --------------- | ------------- | -------------------- |
| phase8c-dev     | dev           | environments/dev     |
| phase8c-staging | staging       | environments/staging |
| phase8c-prod    | prod          | environments/prod    |

Variables sensitives configurées automatiquement par `setup-azure.sh` :

| Variable                     | Description                        |
| ---------------------------- | ---------------------------------- |
| subscription_id              | ID de la souscription Azure        |
| tenant_id                    | ID du tenant Azure AD              |
| client_id                    | ID du Service Principal            |
| client_secret                | Secret du Service Principal        |
| vm_ssh_public_key            | Contenu de ~/.ssh/id_rsa_azure.pub |
| servicebus_connection_string | Connection string Service Bus      |
| eventhub_connection_string   | Connection string Event Hub        |

Note : `GF_ADMIN_PASSWORD` (mot de passe Grafana) n'est **jamais**
dans TFC — il est saisi interactivement lors de `setup-monitoring.sh`.

---

Auteur : Palou
Date : Mars 2026
