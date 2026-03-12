# Explication de l'Architecture : Phase 8C - Messaging et Integration

## Resource Group

Le **Resource Group** est le conteneur principal Azure.

- Il regroupe **toutes les ressources** d'un environnement
- Il permet de gérer, déployer ou supprimer l'infrastructure en une seule fois
- La Phase 8C utilise **3 Resource Groups** : un par environnement

| Resource Group     | Contenu                                                                            |
| ------------------ | ---------------------------------------------------------------------------------- |
| rg-phase8c-dev     | VM Flask, VM Monitoring, Service Bus, Event Hub, Key Vault, Bastion, Log Analytics |
| rg-phase8c-staging | idem, ressources dimensionnées pour la pré-prod                                    |
| rg-phase8c-prod    | idem, ressources dimensionnées pour la production                                  |

---

## Architecture

La Phase 8C utilise une topologie **à environnements indépendants** :

- Chaque environnement (dev, staging, prod) est **complètement autonome**
- Pas de hub-spoke, pas de peerings VNet entre environnements
- Chaque environnement déploie son propre VNet, ses services PaaS
  et son Log Analytics Workspace

```
  rg-phase8c-dev
  │
  ├── vnet-phase8c-dev (10.0.0.0/16)
  │   ├── AzureBastionSubnet  ── Azure Bastion
  │   ├── snet-app            ── VM Flask (Flask + eventhub-consumer.service)
  │   ├── snet-monitoring     ── VM Monitoring (Prometheus + Grafana + Pushgateway)
  │   └── snet-pe             ── Private Endpoints : Key Vault (+ Service Bus en prod)
  │
  ├── Service Bus Namespace (Standard en dev/staging, Premium en prod)
  │   ├── Queue : orders (+ Dead-Letter Queue auto)
  │   └── Topic : events
  │       ├── Subscription : sub-logs    (tous les messages)
  │       └── Subscription : sub-alerts  (filtre SQL : level = 'critical')
  │
  ├── Event Hub Namespace (Standard 2TU en dev/staging, 4TU en prod)
  │   └── Event Hub : app-metrics
  │       ├── Consumer Group : $Default
  │       └── Consumer Group : grafana
  │
  ├── Key Vault (Private Endpoint)
  ├── Log Analytics Workspace
  └── Managed Identity → Key Vault Secrets User → Key Vault

  rg-phase8c-staging  (même structure, 10.1.0.0/16)
  rg-phase8c-prod     (même structure, 10.2.0.0/16)
```

Différence structurelle avec la Phase 8B : deux VMs au lieu d'une,
quatre subnets au lieu de trois, et les services PaaS sont Service Bus
et Event Hub au lieu de Cosmos DB et Redis.

---

## Virtual Network (VNet)

Le **Virtual Network (VNet)** est le réseau privé Azure.

- Il permet la communication entre toutes les ressources
- Il isole l'infrastructure du reste d'Azure et d'Internet
- La Phase 8C déploie **3 VNets** : un par environnement

| VNet                 | CIDR        | Subnets                                                |
| -------------------- | ----------- | ------------------------------------------------------ |
| vnet-phase8c-dev     | 10.0.0.0/16 | AzureBastionSubnet, snet-app, snet-monitoring, snet-pe |
| vnet-phase8c-staging | 10.1.0.0/16 | idem                                                   |
| vnet-phase8c-prod    | 10.2.0.0/16 | idem                                                   |

La Phase 8C utilise **4 subnets** contre 3 en Phase 8B — le subnet
`snet-monitoring` est ajouté pour isoler la VM Monitoring.

---

## Subnets

Les **subnets** sont des sous-réseaux à l'intérieur du VNet.

Ils permettent :

- de séparer les rôles (VM applicative, VM monitoring, services PaaS, Bastion)
- de renforcer la sécurité via des NSG dédiés par zone
- de contrôler le trafic inter-VM (consumer.py → Pushgateway)

| Subnet             | Contenu                                    | Particularité                            |
| ------------------ | ------------------------------------------ | ---------------------------------------- |
| AzureBastionSubnet | Azure Bastion (nom imposé Azure)           | NSG avec règles Bastion obligatoires     |
| snet-app           | VM Flask + eventhub-consumer.service       | NSG zero-trust                           |
| snet-monitoring    | VM Monitoring (Prometheus + Grafana + PGW) | NSG — autorise TCP 9091 depuis snet-app  |
| snet-pe            | Private Endpoints Key Vault (+ SB en prod) | private_endpoint_network_policies activé |

---

## Network Security Groups (NSG)

Les **Network Security Groups (NSG)** sont des pare-feu réseau.

- Ils définissent les règles de trafic entrant et sortant
- Basés sur les ports, protocoles et adresses IP
- Attachés aux subnets

Règles clés dans la Phase 8C :

| Règle                           | Port | Source             | Destination          | Pourquoi                                  |
| ------------------------------- | ---- | ------------------ | -------------------- | ----------------------------------------- |
| Allow Bastion SSH (app)         | 22   | AzureBastionSubnet | snet-app             | Accès SSH via Bastion vers VM app         |
| Allow Bastion SSH (monitoring)  | 22   | AzureBastionSubnet | snet-monitoring      | Accès SSH via Bastion vers VM monitoring  |
| Allow App to Key Vault          | 443  | snet-app           | snet-pe              | Lecture secrets depuis Key Vault (PE)     |
| Allow App to Pushgateway        | 9091 | snet-app           | snet-monitoring      | consumer.py → Pushgateway métriques       |
| Allow App to AzureAD            | 443  | snet-app           | AzureActiveDirectory | Token IMDS pour Managed Identity          |
| Allow App to AzureMonitor       | 443  | snet-app           | AzureMonitor         | Envoi métriques Log Analytics             |
| Allow App Internet HTTP         | 80   | snet-app           | Internet             | cloud-init apt (installation paquets)     |
| Allow App Internet HTTPS        | 443  | snet-app           | Internet             | cloud-init pip + connexion SB/EH Standard |
| Allow Monitoring Internet HTTP  | 80   | snet-monitoring    | Internet             | cloud-init apt (installation Docker)      |
| Allow Monitoring Internet HTTPS | 443  | snet-monitoring    | Internet             | cloud-init pip + pull images Docker       |
| Deny All Inbound                | \*   | \*                 | \*                   | Zero-trust par défaut                     |
| Deny All Outbound               | \*   | \*                 | \*                   | Zero-trust par défaut                     |

En dev/staging (SKU Standard), Service Bus et Event Hub n'ont pas
de Private Endpoint — les connexions sortent par AMQP 5671 (Service Bus)
et HTTPS 443 vers Internet, protégées par authentification AAD.

---

## Virtual Machine Flask (VM app)

La **VM Flask** est le composant applicatif principal de la Phase 8C.

- Ubuntu 22.04 LTS, taille Standard_D2s_v6 (dev/staging) ou D4s_v6 (prod)
- Aucune IP publique — accès uniquement via Azure Bastion
- Managed Identity system-assigned pour l'authentification AAD
- Héberge **deux services systemd** : `flask-app` et `eventhub-consumer`
- Initialisée via **cloud-init-app.tftpl** au premier démarrage :
  - Installation de Python, Flask, azure-servicebus, azure-eventhub,
    azure-identity, azure-keyvault-secrets, gunicorn
  - Installation et activation de `eventhub-consumer.service`
  - Variables injectées par Terraform : `KEY_VAULT_URL` et `PUSHGATEWAY_URL`

L'application Flask expose les endpoints suivants :

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

---

## Virtual Machine Monitoring

La **VM Monitoring** est le composant d'observabilité de la Phase 8C.

- Ubuntu 22.04 LTS, taille Standard_D2s_v6 dans tous les environnements
- Aucune IP publique — accès uniquement via Azure Bastion
- Managed Identity system-assigned (rôle : Monitoring Metrics Publisher)
- Initialisée via **cloud-init-monitoring.tftpl** : installation de Docker
  et création des répertoires `/opt/monitoring/`
- La stack observabilité est déployée **après** le Terraform par
  `./scripts/setup-monitoring.sh` — le mot de passe Grafana est saisi
  interactivement et n'est jamais stocké dans le code ni dans TFC

Stack Docker Compose sur VM Monitoring :

| Composant   | Port | Rôle                                              |
| ----------- | ---- | ------------------------------------------------- |
| Prometheus  | 9090 | Scrape Pushgateway toutes les 15 secondes         |
| Grafana     | 3000 | Dashboard métriques Event Hub (datasource : Prom) |
| Pushgateway | 9091 | Reçoit les métriques poussées par consumer.py     |

---

## Managed Identity

La **Managed Identity** est une identité Azure AD liée au cycle
de vie de la VM.

- Type : **system-assigned** — créée et supprimée avec la VM
- Aucun secret, aucun mot de passe, aucune rotation manuelle
- Authentification via l'**IMDS** (Instance Metadata Service) :
  `http://169.254.169.254/metadata/identity/oauth2/token`

Dans la Phase 8C, la MI de la VM Flask accède uniquement à **Key Vault**
pour lire les connection strings de Service Bus et Event Hub :

```
VM Flask
  └── ManagedIdentityCredential (azure-identity)
        └── IMDS (169.254.169.254)
              └── scope: vault.azure.net  → Token Key Vault
                    └── Key Vault (via Private Endpoint)
                          ├── secret: servicebus-connection-string
                          └── secret: eventhub-connection-string
```

Rôles RBAC attribués :

| VM            | Rôle                         | Scope          | Pourquoi                                  |
| ------------- | ---------------------------- | -------------- | ----------------------------------------- |
| VM Flask      | Key Vault Secrets User       | Key Vault      | Lecture des deux connection strings       |
| VM Monitoring | Monitoring Metrics Publisher | Resource Group | Envoi métriques custom vers Azure Monitor |

La MI de la VM Flask n'a **pas** de rôle direct sur Service Bus ni
Event Hub — l'accès passe par les connection strings lus dans Key Vault.

---

## Azure Service Bus

**Azure Service Bus** est le service de messagerie cloud managé
par Azure.

- SKU **Standard** en dev/staging (queues + topics disponibles)
- SKU **Premium** en prod (+ Private Endpoint)
- `local_auth_enabled = false` — authentification AAD uniquement (pas de SAS keys)
- La VM Flask se connecte via la **connection string** stockée dans Key Vault

Structure des ressources messaging :

| Niveau       | Nom                     | Particularité                            |
| ------------ | ----------------------- | ---------------------------------------- |
| Namespace    | sbns-phase8c-\<env>     | SKU Standard/Premium selon environnement |
| Queue        | orders                  | max_delivery_count = 10, TTL = 14 jours  |
| DLQ          | orders/$DeadLetterQueue | Auto-créée par Azure                     |
| Topic        | events                  | max_size = 1024 Mo, TTL = 14 jours       |
| Subscription | sub-logs                | Filtre Boolean True — tous les messages  |
| Subscription | sub-alerts              | Filtre SQL : level = 'critical'          |

Le filtre SQL de sub-alerts s'applique sur `application_properties`
du message, pas sur le corps JSON. La propriété `level` doit être
passée dans `application_properties` lors de la publication.

---

## Azure Event Hub

**Azure Event Hub** est le service de streaming d'événements Azure.

- SKU **Standard 2 TU** en dev/staging, **Standard 4 TU** en prod
- Le SKU Basic ne supporte qu'un consumer group (`$Default`) —
  Standard est requis pour le consumer group `grafana`
- La VM Flask se connecte via la **connection string** stockée dans Key Vault

Structure des ressources Event Hub :

| Niveau         | Nom                  | Particularité                         |
| -------------- | -------------------- | ------------------------------------- |
| Namespace      | evhns-phase8c-\<env> | SKU Standard, 2 ou 4 Throughput Units |
| Event Hub      | app-metrics          | 2 partitions, rétention 1 jour        |
| Consumer Group | $Default             | Auto-créé par Azure                   |
| Consumer Group | grafana              | Utilisé par eventhub-consumer.service |

Note : Service Bus et Event Hub **partagent** la même zone DNS privée
`privatelink.servicebus.windows.net` — un seul enregistrement DNS pour
les deux namespaces.

---

## Azure Key Vault

**Azure Key Vault** est le service de gestion des secrets Azure.

Dans la Phase 8C, Key Vault joue le même rôle central qu'en Phase 8B :
il est le **point de distribution sécurisé des connection strings**.

- Déployé derrière un **Private Endpoint** dans `snet-pe`
- `public_network_access_enabled = true` — nécessaire pour que TFC
  puisse provisionner les secrets lors du `terraform apply`
- Modèle d'accès : **RBAC** (pas de politique d'accès legacy)
- Flask lit Key Vault **une seule fois au démarrage** via Managed Identity

Secrets stockés dans Key Vault :

| Nom du secret                | Valeur                                   | Créé par         |
| ---------------------------- | ---------------------------------------- | ---------------- |
| servicebus-connection-string | Endpoint=sb://...;SharedAccessKey=...    | Module key-vault |
| eventhub-connection-string   | Endpoint=sb://...;EntityPath=app-metrics | Module key-vault |

Ces secrets sont créés par Terraform à partir des outputs des modules
`service-bus` et `event-hub` — jamais saisis manuellement.

---

## Pipeline Event Hub → Grafana

Le pipeline de métriques est la nouveauté architecturale majeure de
la Phase 8C. Il connecte l'application Flask à Grafana via Event Hub.

```
Flask app (VM app)
  └── POST /api/metrics/emit
        └── EventHubProducerClient → Event Hub app-metrics

consumer.py (VM app — systemd : eventhub-consumer.service)
  └── EventHubConsumerClient (consumer group : grafana)
        └── Event Hub app-metrics
              └── parse métrique JSON
                    └── HTTP POST → Pushgateway (VM monitoring :9091)

VM monitoring — Docker Compose
  ├── Pushgateway :9091  → stocke les métriques en mémoire
  ├── Prometheus  :9090  → scrape Pushgateway toutes les 15s
  └── Grafana     :3000  → dashboard métriques Event Hub
```

`consumer.py` est un processus Python autonome géré par systemd.
Il lit depuis le consumer group `grafana` — indépendant de `$Default`.
Le checkpointing (`update_checkpoint`) est appelé après chaque push
réussi vers Pushgateway pour éviter de rejouer les événements au
redémarrage du service.

La variable d'environnement `PUSHGATEWAY_URL` est injectée dans
`eventhub-consumer.service` par Terraform via cloud-init, avec la
valeur `http://<IP_VM_MONITORING>:9091`. L'IP est calculée par
`cidrhost(var.subnet_monitoring_prefix, 4)` — toujours `.4` dans Azure.

---

## Private Endpoints

Le **Private Endpoint** est une interface réseau avec une IP privée
dans un subnet, permettant d'accéder à un service PaaS Azure sans
passer par Internet.

Dans la Phase 8C, les Private Endpoints varient selon l'environnement :

```
dev / staging :
  snet-pe
    └── NIC PE Key Vault  → privatelink.vaultcore.azure.net

prod :
  snet-pe
    ├── NIC PE Service Bus → privatelink.servicebus.windows.net
    └── NIC PE Key Vault   → privatelink.vaultcore.azure.net
```

En dev et staging (SKU Standard), Service Bus et Event Hub ne
supportent pas les Private Endpoints. L'isolation réseau repose sur
`local_auth_enabled = false` + `public_network_access_enabled = false`
avec authentification AAD obligatoire.

Zones DNS privées et résolution :

```
Key Vault FQDN : phase8c-dev-kv.vault.azure.net
  └── Zone DNS : privatelink.vaultcore.azure.net
      └── Enregistrement A → IP privée dans snet-pe (tous les env)

Service Bus FQDN (prod) : sbns-phase8c-prod.servicebus.windows.net
  └── Zone DNS : privatelink.servicebus.windows.net
      └── Enregistrement A → IP privée dans snet-pe

Event Hub FQDN : evhns-phase8c-prod.servicebus.windows.net
  └── Zone DNS partagée : privatelink.servicebus.windows.net
      └── Enregistrement A → IP privée dans snet-pe
```

---

## Azure Bastion

**Azure Bastion** permet l'accès sécurisé aux VMs.

- Connexion SSH via tunnel SSH natif (`az network bastion tunnel`)
- Aucune IP publique sur les VMs (zero-trust)
- SKU **Standard** requis pour les tunnels TCP natifs
- Déployé dans `AzureBastionSubnet` dans chaque environnement

Dans la Phase 8C, Bastion donne accès aux **deux VMs** :

```bash
# Tunnel Bastion vers VM monitoring (port 2222)
az network bastion tunnel \
  --name bastion-phase8c-dev \
  --resource-group rg-phase8c-dev \
  --target-resource-id <VM_MONITORING_ID> \
  --resource-port 22 --port 2222

# Tunnel Bastion vers VM app (port 2223)
az network bastion tunnel \
  --name bastion-phase8c-dev \
  --resource-group rg-phase8c-dev \
  --target-resource-id <VM_APP_ID> \
  --resource-port 22 --port 2223

# Accès Flask via port-forwarding SSH (dans un second terminal)
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \
  -L 5000:localhost:5000 -N
```

---

## Log Analytics Workspace

Le **Log Analytics Workspace** est l'outil de centralisation des
logs et métriques Azure natif.

- Déployé dans le **module monitoring** — partagé par tous les modules
- Chaque environnement a son propre workspace indépendant
- Reçoit les diagnostic settings de Service Bus, Event Hub et Key Vault

Logs collectés :

| Source      | Catégories                                 |
| ----------- | ------------------------------------------ |
| Service Bus | OperationalLogs, VNetAndIPFilteringLogs    |
| Event Hub   | OperationalLogs, ArchiveLogs               |
| Key Vault   | AuditEvent (lectures de secrets par la MI) |

Requêtes KQL utiles :

```kql
// Messages en dead-letter dans Service Bus
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where MetricName == "DeadletteredMessages"
| where Total > 0
| project TimeGenerated, Total

// Accès aux secrets Key Vault par la Managed Identity
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where OperationName == "SecretGet"
| project TimeGenerated, CallerIPAddress, id_s, ResultType
```

---

## Cloud-Init

**Cloud-init** est le mécanisme d'initialisation des VMs Linux au
premier démarrage.

Dans la Phase 8C, il y a **deux templates cloud-init** :

- `cloud-init-app.tftpl` : initialise la VM Flask
  - Installation Python, Flask, SDK azure-servicebus, azure-eventhub,
    azure-identity, azure-keyvault-secrets
  - Démarrage des services systemd `flask-app` et `eventhub-consumer`
  - Injection de `KEY_VAULT_URL` et `PUSHGATEWAY_URL`

- `cloud-init-monitoring.tftpl` : initialise la VM Monitoring
  - Installation de Docker et Docker Compose uniquement
  - Création des répertoires `/opt/monitoring/`
  - Ne lance **pas** Docker Compose — c'est le rôle de `setup-monitoring.sh`

Le mot de passe Grafana (`GF_ADMIN_PASSWORD`) n'est jamais dans
cloud-init ni dans TFC — il est saisi interactivement par
`setup-monitoring.sh` lors de la première configuration.

Ordre d'exécution cloud-init :

```
1. write_files  : écrire les fichiers dans /tmp/ (les répertoires cibles
                  n'existent pas encore à cette étape)
2. runcmd       : mkdir -p → copier depuis /tmp/ → installer dépendances
                  → activer systemd
```

---

## Architecture Logique Globale

```
TERRAFORM CLOUD
  workspace phase8c-dev
  workspace phase8c-staging
  workspace phase8c-prod
  (3 workspaces indépendants — pas de remote state partagé)

AZURE : rg-phase8c-dev
│
├── vnet-phase8c-dev (10.0.0.0/16)
│   │
│   ├── AzureBastionSubnet ──── Azure Bastion (Standard SKU)
│   │
│   ├── snet-app ──── NSG ──── VM Flask (Ubuntu 22.04)
│   │                          ├── Managed Identity (system-assigned)
│   │                          ├── Flask + azure-servicebus + azure-eventhub
│   │                          ├── azure-identity + azure-keyvault-secrets
│   │                          ├── systemd : flask-app
│   │                          └── systemd : eventhub-consumer (consumer group grafana)
│   │
│   ├── snet-monitoring ── NSG ── VM Monitoring (Ubuntu 22.04)
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
│       ├── Subscription : sub-logs    (Boolean True)
│       └── Subscription : sub-alerts  (SQL : level = 'critical')
│
├── Event Hub Namespace (Standard, 2TU dev/staging, 4TU prod)
│   └── Event Hub : app-metrics (2 partitions)
│       ├── Consumer Group : $Default
│       └── Consumer Group : grafana
│
├── Key Vault
│   ├── publicNetworkAccess : Enabled (TFC a besoin d'accès)
│   ├── Modèle RBAC (pas de policy legacy)
│   ├── secret : servicebus-connection-string
│   ├── secret : eventhub-connection-string
│   └── Diagnostic Settings → Log Analytics (AuditEvent)
│
├── Zone DNS privée : privatelink.servicebus.windows.net  (prod — SB + EH partagée)
│   └── Lien VNet → vnet-phase8c-prod
│
├── Zone DNS privée : privatelink.vaultcore.azure.net  (tous les env)
│   └── Lien VNet → vnet-phase8c-{env}
│
├── Log Analytics Workspace
│   ├── Logs Service Bus (OperationalLogs)
│   ├── Logs Event Hub (OperationalLogs)
│   └── Logs Key Vault (AuditEvent — lectures MI)
│
└── RBAC
    ├── Key Vault Secrets User → VM Flask MI → Key Vault
    └── Monitoring Metrics Publisher → VM Monitoring MI → Resource Group
```

---

## Flux de Connexion aux Services

```
DÉMARRAGE FLASK (une seule fois)
  VM Flask
    └── ManagedIdentityCredential()
          └── IMDS (169.254.169.254)
                └── Token AAD (scope : vault.azure.net)
                      └── Key Vault (via Private Endpoint)
                            ├── GET secret : servicebus-connection-string
                            └── GET secret : eventhub-connection-string

MESSAGING (POST /api/messages/send)
  VM Flask
    └── ServiceBusClient.from_connection_string(sb_conn_str)
          └── get_queue_sender("orders").send_messages(msg)
                └── Service Bus Namespace (PE snet-pe en prod / public en dev)

PUBLICATION (POST /api/events/publish)
  VM Flask
    └── ServiceBusClient.from_connection_string(sb_conn_str)
          └── get_topic_sender("events").send_messages(msg)
                application_properties={"level": "critical"}
                └── sub-logs  (reçoit le message)
                    sub-alerts (reçoit si level = 'critical')

PIPELINE MÉTRIQUES
  Flask POST /api/metrics/emit
    └── EventHubProducerClient → Event Hub app-metrics

  consumer.py (systemd — consumer group : grafana)
    └── EventHubConsumerClient ← Event Hub app-metrics
          └── parse JSON → HTTP POST Pushgateway :9091
                → Prometheus scrape :9090
                  → Grafana dashboard :3000
```

---

## Résumé

| Composant                 | Rôle                                                                         |
| ------------------------- | ---------------------------------------------------------------------------- |
| Resource Group            | Conteneur global par environnement                                           |
| VNet                      | Réseau privé isolé par environnement                                         |
| Subnets (x4)              | VM app / VM monitoring / services PaaS / Bastion                             |
| NSG                       | Pare-feu réseau, zero-trust                                                  |
| VM Flask                  | Flask + eventhub-consumer.service, deux services systemd                     |
| VM Monitoring             | Prometheus + Grafana + Pushgateway via Docker Compose                        |
| Managed Identity          | Authentification AAD pour Key Vault uniquement, sans secret                  |
| Service Bus               | Queue orders + Topic events avec filtres SQL                                 |
| Dead-Letter Queue         | Capture les messages en erreur, retraitement via /api/messages/dlq/reprocess |
| Event Hub                 | Streaming de métriques, consumer group grafana pour le pipeline              |
| eventhub-consumer.service | Systemd sur VM app — lit EH et pousse vers Pushgateway                       |
| Key Vault                 | Distribution sécurisée des connection strings SB et EH                       |
| Private Endpoints         | Accès privé Key Vault (tous env) + Service Bus (prod)                        |
| Zones DNS privées (x2)    | servicebus.windows.net (SB+EH partagée), vaultcore.azure.net                 |
| Azure Bastion             | Accès SSH sécurisé aux deux VMs sans IP publique                             |
| Log Analytics Workspace   | Centralisation des logs et métriques par environnement                       |
| Prometheus / Grafana      | Métriques applicatives Event Hub en temps réel                               |
| Pushgateway               | Pont entre consumer.py (push) et Prometheus (scrape)                         |
| Cloud-Init (x2)           | Initialisation VM app + VM monitoring, GF_ADMIN_PASSWORD jamais stocké       |
| RBAC                      | Key Vault Secrets User (Flask) + Monitoring Metrics Publisher (Monitoring)   |

Cette architecture illustre l'intégration de deux paradigmes de
messagerie complémentaires :

- **Service Bus** : messagerie fiable avec garanties de livraison,
  dead-letter queue, filtres SQL — adapté aux commandes et événements
  applicatifs nécessitant un traitement garanti
- **Event Hub** : streaming haute performance avec consumer groups
  indépendants — adapté aux métriques et données analytiques nécessitant
  plusieurs consommateurs parallèles sans interférence

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
