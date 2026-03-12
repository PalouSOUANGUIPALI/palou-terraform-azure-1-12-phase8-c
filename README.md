# Phase 8C - Messaging et Integration

## Vue d'Ensemble

Cette phase déploie une architecture **multi-environnement avec messagerie
asynchrone et streaming d'événements** sur Azure avec :

- **Azure Service Bus** (queues + topics + subscriptions + Dead-Letter Queue)
  pour la messagerie fiable avec garanties de livraison
- **Azure Event Hub** pour le streaming de métriques avec consumer groups
  indépendants
- **Azure Key Vault** pour la distribution sécurisée des connection strings
- **Managed Identity** pour l'authentification AAD à Key Vault sans secret
- **Private Endpoints** pour l'accès privé à Key Vault (et Service Bus en prod)
- **Application Flask** avec azure-servicebus, azure-eventhub et azure-identity SDK
- **Pipeline Event Hub → Pushgateway → Prometheus → Grafana** pour l'observabilité
  applicative en temps réel
- **Azure Bastion** pour l'accès SSH sécurisé aux deux VMs (zero-trust)
- **Log Analytics Workspace** pour la centralisation des logs et métriques
- **Cloud-Init** pour l'initialisation automatisée des VMs app et monitoring

Les patterns **queue point-à-point** (orders), **publish/subscribe avec
filtres SQL** (events → sub-logs / sub-alerts) et **Dead-Letter Queue**
(retraitement des messages en erreur) sont implémentés dans Flask et
observables via les endpoints dédiés.

---

## Architecture

```
  rg-phase8c-dev
  │
  ├── vnet-phase8c-dev (10.0.0.0/16)
  │   │
  │   ├── AzureBastionSubnet ──── Azure Bastion (Standard SKU)
  │   │
  │   ├── snet-app ──── NSG ──── VM app (Ubuntu 22.04)
  │   │                          ├── Managed Identity (system-assigned)
  │   │                          ├── Flask + azure-servicebus + azure-eventhub
  │   │                          ├── azure-identity + azure-keyvault-secrets
  │   │                          ├── systemd : flask-app
  │   │                          └── systemd : eventhub-consumer
  │   │
  │   ├── snet-monitoring ── NSG ── VM monitoring (Ubuntu 22.04)
  │   │                             ├── Docker Compose
  │   │                             ├── Prometheus  :9090
  │   │                             ├── Grafana     :3000
  │   │                             └── Pushgateway :9091
  │   │
  │   └── snet-pe ──── NSG ───── Private Endpoint Key Vault
  │                               (+ PE Service Bus en prod)
  │
  ├── Service Bus Namespace (Standard dev/staging, Premium prod)
  │   ├── local_auth_enabled : false
  │   ├── Queue : orders  (+ Dead-Letter Queue auto)
  │   └── Topic : events
  │       ├── Subscription : sub-logs    (Boolean True — tous les messages)
  │       └── Subscription : sub-alerts  (SQL : level = 'critical')
  │
  ├── Event Hub Namespace (Standard, 2TU dev/staging, 4TU prod)
  │   └── Event Hub : app-metrics (2 partitions)
  │       ├── Consumer Group : $Default
  │       └── Consumer Group : grafana
  │
  ├── Key Vault
  │   ├── publicNetworkAccess : Enabled (requis pour TFC)
  │   ├── secret : servicebus-connection-string
  │   └── secret : eventhub-connection-string
  │
  ├── Zone DNS privée : privatelink.servicebus.windows.net  (prod)
  ├── Zone DNS privée : privatelink.vaultcore.azure.net
  ├── Log Analytics Workspace
  └── RBAC
      ├── Key Vault Secrets User → VM app MI → Key Vault
      └── Monitoring Metrics Publisher → VM monitoring MI → Resource Group

  rg-phase8c-staging  (même structure, 10.1.0.0/16)
  rg-phase8c-prod     (même structure, 10.2.0.0/16)
```

---

## Patterns Messaging

### Flux de connexion

```
DÉMARRAGE FLASK (une seule fois)
  VM app
    └── ManagedIdentityCredential()
          └── IMDS (169.254.169.254)
                └── Token AAD (scope : vault.azure.net)
                      └── Key Vault (via Private Endpoint)
                            ├── GET servicebus-connection-string
                            └── GET eventhub-connection-string

QUEUE POINT-À-POINT (POST /api/messages/send → GET /api/messages/receive)
  VM app
    ├── ServiceBusClient → get_queue_sender("orders") → send_messages()
    └── ServiceBusClient → get_queue_receiver("orders") → receive_messages()
                            (PEEK_LOCK → complete après traitement)

PUBLISH/SUBSCRIBE (POST /api/events/publish → GET /api/events/subscribe/<sub>)
  VM app
    └── ServiceBusClient → get_topic_sender("events")
          └── message + application_properties={"level": "critical"}
                ├── sub-logs   : reçoit tous les messages
                └── sub-alerts : reçoit uniquement level = 'critical'

PIPELINE MÉTRIQUES (POST /api/metrics/emit → Grafana)
  VM app
    └── EventHubProducerClient → Event Hub app-metrics
          └── consumer.py (systemd — consumer group : grafana)
                └── parse JSON → HTTP POST Pushgateway :9091
                      → Prometheus scrape :9090
                        → Grafana dashboard :3000
```

### Application Flask

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

### Exemples d'appels

```bash
# Envoyer et recevoir un message (queue orders)
curl -X POST http://localhost:5000/api/messages/send \
  -H 'Content-Type: application/json' \
  -d '{"order_id": "001", "product": "laptop", "quantity": 1}'

curl http://localhost:5000/api/messages/receive

# Publier sur le topic events
# → reçu par sub-logs uniquement (level = 'info')
curl -X POST http://localhost:5000/api/events/publish \
  -H 'Content-Type: application/json' \
  -d '{"type": "order-processed", "level": "info", "order_id": "001"}'

# → reçu par sub-logs ET sub-alerts (level = 'critical')
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

### Dead-Letter Queue

Les messages qui dépassent `max_delivery_count` (10 tentatives) sont
automatiquement transférés dans `orders/$DeadLetterQueue`. L'endpoint
`/api/messages/dlq/reprocess` remet le premier message DLQ dans la
queue principale pour un nouveau cycle de traitement.

---

## Décisions Techniques

### Key Vault comme point de distribution des secrets

Les connection strings Service Bus et Event Hub sont stockés dans
Key Vault et lus par Flask au démarrage via Managed Identity. Ils
ne transitent jamais par le state Terraform ni par les variables TFC.
`public_network_access_enabled = true` est nécessaire pour que TFC
puisse créer les secrets lors du `terraform apply`.

### Managed Identity limitée à Key Vault

La MI de la VM app n'a qu'un seul rôle RBAC : `Key Vault Secrets User`
sur le Key Vault. Elle n'a pas de rôle direct sur Service Bus ni Event
Hub. L'accès passe exclusivement par les connection strings lus depuis
Key Vault — une seule surface d'attaque à gérer.

### local_auth_enabled = false sur Service Bus et Event Hub

L'authentification par SAS keys est désactivée sur les deux namespaces.
Seule l'authentification AAD est autorisée, via les connection strings
qui contiennent un token AAD et non une SAS key statique.

### Private Endpoints selon le SKU

En dev/staging (SKU Standard), Service Bus et Event Hub ne supportent
pas les Private Endpoints. L'isolation réseau repose sur
`local_auth_enabled = false` + authentification AAD obligatoire.
En prod (SKU Premium), Service Bus a un Private Endpoint dans `snet-pe`.
Key Vault a un Private Endpoint dans tous les environnements.

### Zone DNS privée partagée Service Bus / Event Hub

Service Bus et Event Hub partagent la zone DNS privée
`privatelink.servicebus.windows.net` — les deux namespaces ont
des FQDNs sous le même domaine `.servicebus.windows.net`.
Une seule zone DNS privée suffit pour les deux services en prod.

### Monitoring déployé en deux temps

La VM Monitoring est créée par Terraform (cloud-init installe Docker
et crée les répertoires). La stack Docker Compose est déployée
séparément par `setup-monitoring.sh` après chaque apply. Cette
séparation garantit que `GF_ADMIN_PASSWORD` n'est jamais dans TFC
ni dans le code source.

### eventhub-consumer comme service systemd indépendant

`consumer.py` est un processus Python autonome géré par systemd,
indépendant de Flask. Il utilise le consumer group `grafana` — distinct
de `$Default` — pour éviter toute interférence avec d'autres
consommateurs. Le checkpointing est mis à jour après chaque push
réussi vers Pushgateway.

### PUSHGATEWAY_URL injectée par Terraform

La variable d'environnement `PUSHGATEWAY_URL` est injectée dans
`eventhub-consumer.service` par Terraform via cloud-init. Sa valeur
est calculée avec `cidrhost(var.subnet_monitoring_prefix, 4)` —
Azure réserve toujours `.4` comme première IP disponible dans un
subnet. Cela garantit que consumer.py pointe vers la bonne VM
Monitoring quel que soit l'environnement.

### Modules avec fichiers dédiés

Les modules `service-bus`, `event-hub` et `key-vault` ont des fichiers
Terraform séparés par responsabilité (`queues.tf`, `topics.tf`,
`private-endpoint.tf`, `diagnostic.tf`, `rbac.tf`, `secrets.tf`)
plutôt qu'un seul `main.tf` monolithique.

### cloud-init : write_files dans /tmp/

`write_files` s'exécute avant `runcmd` en cloud-init. Les répertoires
de destination n'existent pas encore à ce stade. Les fichiers sont
écrits dans `/tmp/` puis copiés après `mkdir -p` dans `runcmd`.

---

## Environnements

| Env     | VNet CIDR   | VM app          | VM monitoring   | Service Bus | Event Hub    |
| ------- | ----------- | --------------- | --------------- | ----------- | ------------ |
| dev     | 10.0.0.0/16 | Standard_D2s_v6 | Standard_D2s_v6 | Standard    | Standard 2TU |
| staging | 10.1.0.0/16 | Standard_D2s_v6 | Standard_D2s_v6 | Standard    | Standard 2TU |
| prod    | 10.2.0.0/16 | Standard_D4s_v6 | Standard_D2s_v6 | Premium     | Standard 4TU |

---

## Structure du Projet

```
phase8c-messaging/
├── app/
│   ├── main.py                      (Flask + endpoints messaging)
│   ├── consumer.py                  (Event Hub consumer → Pushgateway)
│   ├── consumer-startup.sh          (Script de démarrage eventhub-consumer)
│   ├── requirements.txt             (Dépendances Python épinglées)
│   └── startup.sh                   (Script de démarrage Gunicorn)
├── assets/
│   └── architecture-phase8c.png    (Diagramme d'architecture)
├── docs/
│   ├── 01_service-bus.md
│   ├── 02_event-hub.md
│   ├── 03_queues-topics-subscriptions.md
│   ├── 04_dead-letter-queue.md
│   ├── 05_private-endpoints.md
│   ├── 06_managed-identity.md
│   ├── 07_event-hub-consumer-pushgateway.md
│   ├── 08_messaging-patterns.md
│   ├── 09_observability.md
│   └── 10_guide-exploration.md
├── monitoring/
│   ├── docker-compose.yml           (Prometheus + Grafana + Pushgateway)
│   ├── prometheus.yml               (Scrape config Pushgateway 15s)
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasource.yml   (Datasource Prometheus)
│           └── dashboards/
│               ├── dashboard.yml    (Provider dashboards Grafana)
│               └── dashboard-eventhub.json  (Dashboard métriques Event Hub)
├── modules/
│   ├── networking/                  (VNet + 4 Subnets + NSGs + DNS)
│   ├── compute/                     (2 VMs + MIs + cloud-init-app.tftpl
│   │                                 + cloud-init-monitoring.tftpl)
│   ├── service-bus/                 (Namespace + queues.tf + topics.tf
│   │                                 + private-endpoint.tf + diagnostic.tf)
│   ├── event-hub/                   (Namespace + eventhub.tf
│   │                                 + private-endpoint.tf + diagnostic.tf)
│   ├── key-vault/                   (KV + rbac.tf + secrets.tf
│   │                                 + private-endpoint.tf + diagnostic.tf)
│   └── monitoring/                  (Log Analytics Workspace)
├── environments/
│   ├── dev/                         (backend.tf, providers.tf, variables.tf,
│   │                                 terraform.tfvars, main.tf, outputs.tf)
│   ├── staging/                     (même structure)
│   └── prod/                        (même structure)
├── scripts/                         (11 fichiers : 10 scripts + README.md)
├── tests/                           (5 fichiers de tests)
├── .gitignore
├── CONCEPTS.md
├── README.md
├── SETUP.md
└── QUICK-START.md
```

---

## Ordre de Déploiement

```
1. deploy-dev.sh              → git push + approve TFC
2. setup-monitoring.sh dev    → copier monitoring/ sur VM + démarrer Docker Compose
3. deploy-staging.sh          → approve TFC
4. setup-monitoring.sh staging
5. deploy-prod.sh             → approve TFC (saisir "oui")
6. setup-monitoring.sh prod
7. validate.sh dev            → vérifier l'infrastructure
8. Tunnels Bastion            → deux terminaux pour Flask, deux pour Grafana
9. tests/test-all.sh dev      → valider Service Bus + Event Hub + Key Vault
10. generate-traffic.sh dev 15 → alimenter Log Analytics + pipeline Grafana
```

---

## Configuration Terraform Cloud

Organisation : `palou-terraform-azure-1-12-phase8-c`

### Workspaces

| Workspace       | Working Directory    | Auto-Apply |
| --------------- | -------------------- | ---------- |
| phase8c-dev     | environments/dev     | Non        |
| phase8c-staging | environments/staging | Non        |
| phase8c-prod    | environments/prod    | Non        |

### Variables sensitives par workspace

| Variable                     | dev | staging | prod |
| ---------------------------- | :-: | :-----: | :--: |
| subscription_id              | oui |   oui   | oui  |
| tenant_id                    | oui |   oui   | oui  |
| client_id                    | oui |   oui   | oui  |
| client_secret                | oui |   oui   | oui  |
| vm_ssh_public_key            | oui |   oui   | oui  |
| servicebus_connection_string | oui |   oui   | oui  |
| eventhub_connection_string   | oui |   oui   | oui  |

`GF_ADMIN_PASSWORD` (mot de passe Grafana) n'est **pas** dans TFC —
saisi interactivement par `setup-monitoring.sh`.

---

## Providers

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}
```

La Phase 8C utilise uniquement le provider `azurerm`. Comme en
Phase 8B, le provider `azuread` n'est pas nécessaire — l'authentification
passe par les connection strings dans Key Vault, sans configuration
d'administrateur AAD sur les services PaaS.

---

## Ordre de Destruction

```
1. prod
2. staging
3. dev
```

```bash
# Individuel
./scripts/destroy-env.sh prod
./scripts/destroy-env.sh staging
./scripts/destroy-env.sh dev

# Ou tout d'un coup (guidé)
./scripts/destroy-all.sh
```

Note : Key Vault est en soft-delete par défaut. Si vous redéployez
immédiatement avec le même nom, purgez le vault supprimé :

```bash
az keyvault purge --name phase8c-dev-kv --location francecentral
```

---

## Différences avec la Phase 8B

| Aspect                  | Phase 8B                            | Phase 8C                                           |
| ----------------------- | ----------------------------------- | -------------------------------------------------- |
| Services PaaS           | Cosmos DB + Redis                   | Service Bus + Event Hub                            |
| Type de communication   | Lecture/écriture de données         | Messagerie asynchrone + streaming                  |
| VMs                     | 1 (Flask)                           | 2 (Flask + Monitoring)                             |
| Subnets                 | 3                                   | 4 (+ snet-monitoring)                              |
| Services systemd        | flask-app                           | flask-app + eventhub-consumer                      |
| Stack observabilité     | Log Analytics uniquement            | Log Analytics + Prometheus + Grafana + Pushgateway |
| Cloud-init templates    | 1 (cloud-init.tftpl)                | 2 (cloud-init-app.tftpl + monitoring.tftpl)        |
| Étape post-déploiement  | aucune                              | setup-monitoring.sh (obligatoire)                  |
| Mot de passe Grafana    | N/A                                 | Saisi interactivement, jamais stocké               |
| Private Endpoints       | 3 (Cosmos DB + Redis + KV)          | 1 tous env (KV) + 1 prod (Service Bus)             |
| Zones DNS privées       | 3 (documents + redis.cache + vault) | 2 (servicebus partagée SB+EH, vaultcore)           |
| Variables TFC           | 5                                   | 7 (+ SB conn str + EH conn str)                    |
| Accès Flask depuis ordi | 1 tunnel (az bastion ssh -L)        | 2 tunnels (Bastion + SSH port-forward)             |

---

## Dépannage

### Flask ne démarre pas

```bash
# Sur la VM app via Bastion SSH
systemctl status flask-app
journalctl -u flask-app -n 100
sudo tail -50 /var/log/cloud-init-output.log
```

### eventhub-consumer ne démarre pas

```bash
systemctl status eventhub-consumer
journalctl -u eventhub-consumer -n 50 --no-pager
```

### Key Vault inaccessible au démarrage

Flask contacte Key Vault via Private Endpoint au démarrage.
Si la résolution DNS échoue ou si le RBAC est absent, Flask
s'arrête immédiatement avant d'accepter des requêtes.

```bash
# Sur la VM app : résolution DNS (doit retourner IP 10.x.3.x)
dig phase8c-dev-kv.vault.azure.net +short

# Sur ordinateur : vérifier le RBAC MI
MI_ID=$(az vm show -g rg-phase8c-dev \
  -n vm-phase8c-dev-app \
  --query "identity.principalId" -o tsv)
az role assignment list \
  --assignee "$MI_ID" \
  --scope $(az keyvault show --name phase8c-dev-kv --query "id" -o tsv) \
  --query "[].roleDefinitionName" -o tsv
# Attendu : Key Vault Secrets User
```

### Grafana n'affiche pas les métriques

```bash
# Sur la VM monitoring via Bastion SSH
docker compose -f /opt/monitoring/docker-compose.yml ps
docker compose -f /opt/monitoring/docker-compose.yml logs --tail=30 grafana
curl http://localhost:9091/metrics | grep -v "^#" | head -20
```

### Key Vault soft-delete : conflit de nom

```bash
az keyvault list-deleted \
  --query "[?name=='phase8c-dev-kv']" -o table
az keyvault purge --name phase8c-dev-kv --location francecentral
```

### Bastion : tunnel SSH impossible

```bash
az network bastion list \
  --resource-group rg-phase8c-dev \
  --query "[0].{sku:sku.name, state:provisioningState}" \
  -o table

az extension add --name ssh
az extension add --name bastion
```

---

## Principes

1. **Zero Trust** : aucune IP publique sur les VMs ni les services PaaS
2. **Zero Secret dans le code** : connection strings dans Key Vault,
   jamais dans le state Terraform ni les variables TFC
3. **GF_ADMIN_PASSWORD jamais stocké** : saisi interactivement lors
   de `setup-monitoring.sh`, non présent dans TFC ni dans git
4. **Messagerie découplée** : Service Bus découple producteurs et
   consommateurs — Flask envoie sans attendre que le destinataire soit prêt
5. **Consumer groups indépendants** : Event Hub permet à plusieurs
   consommateurs de lire le même flux sans interférence
6. **Infrastructure as Code** : tout est dans Terraform sauf
   `GF_ADMIN_PASSWORD` et le contenu de `monitoring/`
7. **Indépendance des phases** : aucune référence à une phase précédente
8. **Versions épinglées** : dépendances Python fixées pour éviter les conflits

---

## Coûts Estimés

| Ressource                              | Coût mensuel (USD) |
| -------------------------------------- | ------------------ |
| Azure Bastion Standard (3x)            | ~350               |
| VMs app (3x Standard_D2s_v6 / D4s_v6)  | ~60                |
| VMs monitoring (3x Standard_D2s_v6)    | ~45                |
| Service Bus (2x Standard + 1x Premium) | ~25                |
| Event Hub (2x 2TU + 1x 4TU Standard)   | ~45                |
| Key Vault (3x)                         | ~5                 |
| Log Analytics (3x workspaces)          | ~15                |
| Disques Premium LRS                    | ~25                |
| **Total**                              | **~570**           |

Pour minimiser les coûts : déployer, explorer, puis détruire
avec `./scripts/destroy-all.sh`.

---

## Leçons Apprises

- `public_network_access_enabled = true` est requis sur Key Vault
  pour que TFC puisse créer les secrets lors du `terraform apply` —
  TFC tourne dans le cloud, pas dans le VNet

- Service Bus et Event Hub partagent la zone DNS privée
  `privatelink.servicebus.windows.net` — une seule zone suffit pour
  les deux namespaces en prod

- `local_auth_enabled = false` désactive les SAS keys mais pas la
  connection string AAD — Flask continue à s'authentifier via la
  connection string stockée dans Key Vault

- Le SKU Basic d'Event Hub ne supporte qu'un seul consumer group
  (`$Default`) — le SKU Standard est requis pour le consumer group
  `grafana` utilisé par consumer.py

- La stack Docker Compose ne se lance pas via cloud-init — l'utilisation
  de `setup-monitoring.sh` après chaque apply est obligatoire pour
  démarrer Prometheus, Grafana et Pushgateway

- `write_files` dans cloud-init s'exécute avant `runcmd` — écrire
  dans `/tmp/` et copier dans `runcmd` après `mkdir -p`, jamais
  directement dans un répertoire qui n'existe pas encore

- Le checkpointing Event Hub (`update_checkpoint`) doit être appelé
  après chaque push réussi vers Pushgateway — sans lui, consumer.py
  rejoue tous les événements depuis le début à chaque redémarrage

- cloud-init ne s'exécute qu'une seule fois au premier boot — pour
  propager une correction dans `app/main.py` ou `app/consumer.py`
  sur une VM existante, appliquer le correctif manuellement et
  redémarrer le service concerné (`sudo systemctl restart flask-app`
  ou `sudo systemctl restart eventhub-consumer`) ; seule une VM
  recréée récupèrera automatiquement la version à jour via cloud-init

- Les fichiers du dossier `monitoring/` (dashboards, prometheus.yml)
  ne sont pas copiés par cloud-init — relancer `setup-monitoring.sh`
  pour propager les modifications sur la VM monitoring

- En dev/staging (Service Bus SKU Standard), le NSG de `snet-app` doit
  autoriser le trafic **AMQP sortant sur le port 5671** vers Internet —
  le SDK azure-servicebus utilise AMQP par défaut et non HTTPS ;
  sans cette règle, la connexion au namespace est refusée au niveau
  réseau malgré une authentification AAD correcte

- `PUSHGATEWAY_URL` doit correspondre à l'IP réelle de la VM Monitoring
  dans chaque environnement — la valeur est calculée par Terraform avec
  `cidrhost(var.subnet_monitoring_prefix, 4)` et injectée dans
  `eventhub-consumer.service` via cloud-init ; si cette variable pointe
  vers la mauvaise IP (par exemple l'IP de dev dans staging), consumer.py
  échoue silencieusement à pousser les métriques et Grafana reste vide

- Le volume Docker de Grafana peut conserver un UID de datasource
  périmé après un redéploiement — si les dashboards affichent
  "No data" malgré des métriques présentes dans Pushgateway, supprimer
  le volume et redémarrer : `docker compose down -v` suivi de
  `GF_ADMIN_PASSWORD='mot_de_passe' docker compose up -d`

- `validate.sh` ne peut pas lire les secrets Key Vault depuis
  l'ordinateur — seule la Managed Identity de la VM Flask a le rôle
  `Key Vault Secrets User` ; une réponse `Forbidden` de l'API Key Vault
  signifie que le secret existe mais que le compte local n'a pas
  l'autorisation de le lire (comportement attendu, avertissement) ;
  seule une réponse "secret introuvable" doit être traitée comme erreur

---

Auteur : Palou
Date : Mars 2026
