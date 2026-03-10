# Observabilité

Guide sur la stratégie d'observabilité dans Phase 8C — Azure Monitor
natif pour Service Bus, Event Hub et Key Vault via Log Analytics,
et stack Prometheus/Grafana/Pushgateway pour les métriques Event Hub
en temps réel.

---

## Table des Matières

1. [Stratégie d'Observabilité dans Phase 8C](#stratégie-dobservabilité-dans-phase-8c)
2. [Diagnostic Settings](#diagnostic-settings)
3. [Métriques Service Bus](#métriques-service-bus)
4. [Métriques Event Hub](#métriques-event-hub)
5. [Métriques Key Vault](#métriques-key-vault)
6. [Requêtes KQL](#requêtes-kql)
7. [Stack Prometheus / Grafana](#stack-prometheus--grafana)
8. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Stratégie d'Observabilité dans Phase 8C

Phase 8C combine deux niveaux d'observabilité :

```
Niveau 1 — Azure Monitor natif (infrastructure)
  Service Bus → Diagnostic Settings → Log Analytics Workspace
  Event Hub   → Diagnostic Settings → Log Analytics Workspace
  Key Vault   → Diagnostic Settings → Log Analytics Workspace
  → Métriques et logs sur 30 à 90 jours
  → KQL pour analyse et alertes

Niveau 2 — Prometheus / Grafana (métriques applicatives temps réel)
  Flask → /metrics/emit → Event Hub → consumer.py → Pushgateway
  Prometheus scrape Pushgateway → Grafana dashboard
  → Métriques applicatives custom (orders_processed, queue_depth...)
  → Visualisation quasi temps réel (délai < 30 secondes)
```

### Ce qui est Observé

```
Service       Métriques clés                    Logs diagnostiques
------------  --------------------------------  ----------------------------
Service Bus   Messages entrants/sortants,        OperationalLogs,
              Dead-letter count, erreurs         VNetAndIPFilteringLogs
Event Hub     Événements entrants, sortants,     OperationalLogs,
              Consumer lag, erreurs              ArchiveLogs
Key Vault     Requêtes de secrets, latence,      AuditEvent,
              disponibilité                      AllMetrics
```

---

## Diagnostic Settings

Les Diagnostic Settings configurent la destination des métriques
et logs Azure Monitor pour chaque service.

### Pattern Terraform

```hcl
resource "azurerm_monitor_diagnostic_setting" "servicebus" {
  name                       = "diag-servicebus-phase8c-${var.environment}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "VNetAndIPFilteringLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
```

### Catégories Valides par Service

Les catégories valides diffèrent selon le type de ressource Azure.

```
Service Bus Namespace :
  Logs   : OperationalLogs, VNetAndIPFilteringLogs, RuntimeAuditLogs
  Metrics: AllMetrics

Event Hub Namespace :
  Logs   : OperationalLogs, ArchiveLogs, AutoScaleLogs
  Metrics: AllMetrics

Key Vault :
  Logs   : AuditEvent, AzurePolicyEvaluationDetails
  Metrics: AllMetrics
```

Vérifier les catégories disponibles avant d'écrire le Terraform :

```bash
# Lister les catégories disponibles pour le namespace Service Bus
az monitor diagnostic-settings categories list \
  --resource "/subscriptions/{sub}/resourceGroups/rg-phase8c-dev/\
providers/Microsoft.ServiceBus/namespaces/sbns-phase8c-dev"
```

---

## Métriques Service Bus

### Métriques Clés

**IncomingMessages** — nombre de messages reçus par le namespace.
Indicateur du volume de trafic entrant.

**OutgoingMessages** — nombre de messages envoyés depuis le namespace.
Doit être proche de IncomingMessages si les messages sont traités
rapidement.

**ActiveMessages** — nombre de messages en attente dans les queues
et subscriptions. Un pic indique que le traitement est lent ou
les consommateurs indisponibles.

**DeadletteredMessages** — nombre de messages transférés en DLQ.
Toute valeur non nulle mérite investigation.

**ServerErrors** et **UserErrors** — erreurs côté Service Bus
et erreurs d'utilisation. Les UserErrors incluent les erreurs
d'authentification et de format.

**ThrottledRequests** — requêtes limitées par Service Bus.
Indique que le namespace est sollicité au-delà de sa capacité.

### Logs OperationalLogs

```
Champs disponibles :
  ActivityId          Identifiant de l'opération (corrélation)
  EventName           Type d'opération (Send, Receive, Complete, DeadLetter...)
  ResourceName        Namespace ou entité concernée
  OperationName       Nom de l'opération Azure
  Status              Succeeded, Failed, Unauthorized
  CallerIPAddress     IP source de la requête
  ErrorDescription    Description de l'erreur si Status = Failed
```

---

## Métriques Event Hub

### Métriques Clés

**IncomingMessages** — événements ingérés par Event Hub.
Indicateur du volume de production.

**OutgoingMessages** — événements lus par les consommateurs.
Si IncomingMessages >> OutgoingMessages, les consommateurs
sont en retard (consumer lag).

**IncomingBytes** et **OutgoingBytes** — débit en entrée et sortie.
À comparer avec la capacité des Throughput Units (1 Mo/s par TU).

**ThrottledRequests** — requêtes limitées par les TU configurés.
Si non nul, augmenter les Throughput Units.

**CaptureBacklog** — arriéré de capture (si la fonctionnalité
Capture vers Blob Storage est activée — non utilisée dans Phase 8C).

### Logs OperationalLogs

```
Champs disponibles :
  ActivityId          Identifiant de l'opération
  EventName           ConsumerGroupCreated, EventHubCreated, Send...
  NamespaceName       Nom du namespace Event Hub
  EventHubName        Nom du hub
  ConsumerGroupName   Nom du consumer group
  Status              Succeeded, Failed
  ErrorDescription    Description de l'erreur si applicable
```

---

## Métriques Key Vault

### Métriques Clés

**ServiceApiHit** — nombre d'appels API Key Vault.
Permet de vérifier que Flask lit ses secrets au démarrage.

**ServiceApiLatency** — latence des appels API.
Un pic peut indiquer un problème réseau avec le Private Endpoint.

**Availability** — disponibilité du service.
Valeur attendue : 100 %.

### Logs AuditEvent

```
Champs disponibles :
  OperationName         SecretGet, SecretSet, SecretDelete, KeySign...
  ResultType            Success, Unauthorized, Forbidden, NotFound
  CallerIPAddress       IP source de la requête
  identity_claim_oid_g  Object ID du principal Azure AD (MI de la VM)
  id_s                  Identifiant du secret accédé
  TimeGenerated         Timestamp de l'accès
```

Les logs AuditEvent permettent d'auditer chaque accès aux secrets —
qui a accédé à quoi, depuis quelle IP, avec quel résultat.

---

## Requêtes KQL

### Service Bus — Messages en Dead-Letter

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where MetricName == "DeadletteredMessages"
| where Total > 0
| project TimeGenerated, ResourceId, DeadLettered = Total
| order by TimeGenerated desc
```

### Service Bus — Erreurs d'Authentification

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where Category == "OperationalLogs"
| where Status == "Unauthorized" or Status == "Failed"
| project TimeGenerated, EventName, Status, ErrorDescription,
  CallerIPAddress
| order by TimeGenerated desc
```

### Service Bus — Volume de Messages par Entité

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where MetricName in ("IncomingMessages", "OutgoingMessages")
| summarize total = sum(Total) by MetricName, bin(TimeGenerated, 5m)
| render timechart
```

### Event Hub — Débit en Entrée et Sortie

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.EVENTHUB"
| where MetricName in ("IncomingMessages", "OutgoingMessages",
  "IncomingBytes", "OutgoingBytes")
| summarize avg(Average) by MetricName, bin(TimeGenerated, 5m)
| render timechart
```

### Event Hub — Requêtes Limitées (Throttling)

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.EVENTHUB"
| where MetricName == "ThrottledRequests"
| where Total > 0
| project TimeGenerated, throttled = Total
| order by TimeGenerated desc
```

### Key Vault — Accès aux Secrets

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where OperationName == "SecretGet"
| summarize
    access_count = count(),
    last_access = max(TimeGenerated)
  by identity_claim_oid_g, id_s, ResultType
| order by access_count desc
```

### Key Vault — Accès Non Autorisés

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where ResultType in ("Unauthorized", "Forbidden")
| project TimeGenerated, OperationName, CallerIPAddress,
  identity_claim_oid_g, ResultType, id_s
| order by TimeGenerated desc
```

### Vue d'Ensemble de l'Infrastructure

```kql
search *
| where TimeGenerated > ago(1h)
| summarize count() by Type
| order by count_ desc
```

---

## Stack Prometheus / Grafana

La stack Prometheus/Grafana sur VM monitoring est déployée via
Docker Compose et lancée par `setup-monitoring.sh`.

### Docker Compose

```
Services :
  prometheus   :9090   scrape Pushgateway toutes les 15s
  grafana      :3000   dashboard Event Hub (datasource : Prometheus)
  pushgateway  :9091   reçoit les métriques de consumer.py
```

### Accès via Tunnel Bastion

```bash
# Terminal 1 — tunnel Bastion vers VM monitoring
az network bastion tunnel \
  --name bastion-phase8c-{env} \
  --resource-group rg-phase8c-{env} \
  --target-resource-id <vm-monitoring-id> \
  --resource-port 22 \
  --port 2222

# Terminal 2 — tunnels SSH avec port-forwarding
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9091:localhost:9091 \
  -N

# Accès depuis le navigateur
open http://localhost:3000   # Grafana
open http://localhost:9090   # Prometheus
open http://localhost:9091   # Pushgateway
```

### Vérifications

```bash
# Vérifier l'état des conteneurs Docker (sur VM monitoring via Bastion)
docker compose ps
docker compose logs --tail=20 pushgateway
docker compose logs --tail=20 prometheus

# Vérifier que Pushgateway a des métriques
curl http://localhost:9091/metrics | grep -v "^#"

# Vérifier que Prometheus scrape bien Pushgateway
curl -s http://localhost:9090/api/v1/targets \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(t['scrapeUrl'], ':', t['health'])
"
```

---

## Dans notre Phase 8C

### Ressources Terraform Déployées

```
azurerm_log_analytics_workspace.main         (phase8c-{env}-law)
azurerm_monitor_diagnostic_setting.servicebus
azurerm_monitor_diagnostic_setting.eventhub
azurerm_monitor_diagnostic_setting.kv
```

### Nommage

```
Log Analytics  : phase8c-{env}-law
Diag SB        : diag-servicebus-phase8c-{env}
Diag EH        : diag-eventhub-phase8c-{env}
Diag KV        : diag-kv-phase8c-{env}
```

### Accéder aux Logs depuis Azure CLI

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group rg-phase8c-dev \
  --workspace-name phase8c-dev-law \
  --query customerId -o tsv)

az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "
    AzureMetrics
    | where ResourceProvider == 'MICROSOFT.SERVICEBUS'
    | where MetricName == 'DeadletteredMessages'
    | where Total > 0
    | project TimeGenerated, Total
    | order by TimeGenerated desc
    | take 10
  " \
  --output table
```

### Points Clés à Retenir

- Les catégories valides de logs diffèrent selon le type de ressource —
  toujours vérifier avec `az monitor diagnostic-settings categories list`
  avant d'écrire le Terraform
- **DeadletteredMessages > 0** est l'alerte la plus importante à surveiller
  sur Service Bus — elle indique des messages non traités
- Les métriques Azure Monitor (AzureMetrics) et les logs diagnostics
  (AzureDiagnostics) sont dans des tables KQL différentes
- **ThrottledRequests > 0** sur Event Hub indique que les Throughput Units
  sont insuffisants — augmenter le TU count dans terraform.tfvars
- La stack Prometheus/Grafana est **complémentaire** d'Azure Monitor —
  Azure Monitor pour l'infrastructure, Prometheus/Grafana pour les
  métriques applicatives custom en temps réel

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
