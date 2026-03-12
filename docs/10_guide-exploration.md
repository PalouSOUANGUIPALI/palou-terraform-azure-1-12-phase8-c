# Guide d'Exploration

Guide pratique pour explorer et valider l'infrastructure Phase 8C
déployée — vérification des ressources Azure, tests Service Bus,
Event Hub, monitoring et accès aux dashboards Grafana via tunnels
Bastion.

---

## Table des Matières

1. [Prérequis](#prérequis)
2. [Vérifier les Ressources Azure](#vérifier-les-ressources-azure)
3. [Tester Service Bus](#tester-service-bus)
4. [Tester Event Hub et le Pipeline Monitoring](#tester-event-hub-et-le-pipeline-monitoring)
5. [Accéder au Monitoring](#accéder-au-monitoring)
6. [Requêtes KQL Log Analytics](#requêtes-kql-log-analytics)
7. [Diagnostic et Dépannage](#diagnostic-et-dépannage)

---

## Prérequis

### Extensions Azure CLI

> Sur ordinateur.

```bash
az extension add --name ssh
az extension add --name bastion
```

### Variables d'Environnement

> Sur ordinateur — adapter selon l'environnement exploré.

```bash
export ENV=dev
export RG=rg-phase8c-${ENV}
export BASTION=bastion-phase8c-${ENV}
```

### Récupérer les IDs des VMs

> Sur ordinateur.

```bash
VM_APP_ID=$(az vm show \
  --resource-group "$RG" \
  --name "vm-phase8c-${ENV}-app" \
  --query id -o tsv)

VM_MONITORING_ID=$(az vm show \
  --resource-group "$RG" \
  --name "vm-phase8c-${ENV}-monitoring" \
  --query id -o tsv)
```

### Ouvrir les Tunnels

Deux séries de tunnels sont nécessaires selon ce qu'on veut tester.

#### Accès Flask (VM app)

> Sur ordinateur — deux terminaux requis.

```bash
# Terminal 1 — tunnel Bastion vers VM app (laisser ouvert)
az network bastion tunnel \
  --name "$BASTION" \
  --resource-group "$RG" \
  --target-resource-id "$VM_APP_ID" \
  --resource-port 22 \
  --port 2223

# Terminal 2 — port-forwarding SSH Flask (laisser ouvert)
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \
  -L 5000:localhost:5000 -N
```

#### Accès Monitoring (VM monitoring)

> Sur ordinateur — deux terminaux requis.

```bash
# Terminal 3 — tunnel Bastion vers VM monitoring (laisser ouvert)
az network bastion tunnel \
  --name "$BASTION" \
  --resource-group "$RG" \
  --target-resource-id "$VM_MONITORING_ID" \
  --resource-port 22 \
  --port 2222

# Terminal 4 — port-forwarding SSH Grafana + Prometheus (laisser ouvert)
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9091:localhost:9091 \
  -N
```

---

## Vérifier les Ressources Azure

### Vue d'Ensemble du Resource Group

> Sur ordinateur.

```bash
az resource list \
  --resource-group "$RG" \
  --output table
```

Ressources attendues :

```
Nom                           Type
----------------------------  ----------------------------------------
sbns-phase8c-{env}            Microsoft.ServiceBus/namespaces
evhns-phase8c-{env}           Microsoft.EventHub/namespaces
phase8c-{env}-kv              Microsoft.KeyVault/vaults
vm-phase8c-{env}-app          Microsoft.Compute/virtualMachines
vm-phase8c-{env}-monitoring   Microsoft.Compute/virtualMachines
bastion-phase8c-{env}         Microsoft.Network/bastionHosts
vnet-phase8c-{env}            Microsoft.Network/virtualNetworks
pe-kv-phase8c-{env}           Microsoft.Network/privateEndpoints
law2-phase8c-{env}            Microsoft.OperationalInsights/workspaces
```

Note : le Private Endpoint Service Bus (`pe-sb-phase8c-{env}`) n'existe
qu'en prod (SKU Premium). En dev et staging (SKU Standard), le namespace
Service Bus et Event Hub sont accessibles via leurs IPs publiques Azure —
seul Key Vault dispose d'un Private Endpoint dans tous les environnements.

### Vérifier le Namespace Service Bus

> Sur ordinateur.

```bash
az servicebus namespace show \
  --resource-group "$RG" \
  --name "sbns-phase8c-${ENV}" \
  --query "{
    name: name,
    sku: sku.name,
    provisioningState: provisioningState,
    localAuth: disableLocalAuth
  }" \
  --output json
```

Résultat attendu pour dev et staging (Standard SKU) :

```json
{
  "name": "sbns-phase8c-dev",
  "sku": "Standard",
  "provisioningState": "Succeeded",
  "localAuth": false
}
```

`localAuth: false` signifie que `disableLocalAuth = false`, c'est-à-dire
que l'authentification locale (SAS keys) est **activée** — ce qui est
requis pour le SKU Standard car Managed Identity seule ne fonctionne pas
sans Premium. En prod (Premium), la valeur attendue est `true` (SAS désactivé,
Managed Identity uniquement).

### Vérifier la Queue et le Topic

> Sur ordinateur.

```bash
# Queue orders
az servicebus queue show \
  --resource-group "$RG" \
  --namespace-name "sbns-phase8c-${ENV}" \
  --name "orders" \
  --query "{status: status, maxDelivery: maxDeliveryCount}" \
  --output json

# Topic events
az servicebus topic show \
  --resource-group "$RG" \
  --namespace-name "sbns-phase8c-${ENV}" \
  --name "events" \
  --query "status" \
  --output tsv

# Subscriptions
for SUB in sub-logs sub-alerts; do
  echo "=== $SUB ==="
  az servicebus topic subscription show \
    --resource-group "$RG" \
    --namespace-name "sbns-phase8c-${ENV}" \
    --topic-name "events" \
    --name "$SUB" \
    --query "{status: status, messageCount: messageCount}" \
    --output json
done
```

### Vérifier le Namespace Event Hub

> Sur ordinateur.

```bash
az eventhubs namespace show \
  --resource-group "$RG" \
  --name "evhns-phase8c-${ENV}" \
  --query "{
    name: name,
    sku: sku.name,
    sku_capacity: sku.capacity,
    provisioningState: provisioningState
  }" \
  --output json

# Event Hub app-metrics et consumer groups
az eventhubs eventhub show \
  --resource-group "$RG" \
  --namespace-name "evhns-phase8c-${ENV}" \
  --name "app-metrics" \
  --query "{status: status, partitions: partitionCount}" \
  --output json

az eventhubs eventhub consumer-group show \
  --resource-group "$RG" \
  --namespace-name "evhns-phase8c-${ENV}" \
  --eventhub-name "app-metrics" \
  --name "grafana" \
  --query "name" \
  --output tsv
```

---

## Tester Service Bus

### Health Check Flask

> Sur ordinateur — tunnels Flask actifs requis (Terminaux 1 et 2).

```bash
curl -s http://localhost:5000/health | python3 -m json.tool
```

Résultat attendu :

```json
{
  "status": "healthy",
  "servicebus": "connected",
  "eventhub": "connected",
  "environment": "dev"
}
```

### Envoyer et Recevoir un Message (Queue)

> Sur ordinateur — tunnels Flask actifs requis.

```bash
# Envoyer un message dans la queue orders
curl -s -X POST http://localhost:5000/api/messages/send \
  -H "Content-Type: application/json" \
  -d '{"order_id": "test-001", "product": "laptop", "quantity": 1}' \
  | python3 -m json.tool

# Recevoir le message
curl -s http://localhost:5000/api/messages/receive | python3 -m json.tool
```

### Publier sur le Topic Events

> Sur ordinateur — tunnels Flask actifs requis.

```bash
# Publier un événement info (reçu par sub-logs uniquement)
curl -s -X POST http://localhost:5000/api/events/publish \
  -H "Content-Type: application/json" \
  -d '{"event": "order-processed", "level": "info", "order_id": "test-001"}' \
  | python3 -m json.tool

# Publier un événement critical (reçu par sub-logs ET sub-alerts)
curl -s -X POST http://localhost:5000/api/events/publish \
  -H "Content-Type: application/json" \
  -d '{"event": "payment-failed", "level": "critical", "order_id": "test-001"}' \
  | python3 -m json.tool

# Lire depuis sub-logs (doit contenir les deux messages)
curl -s http://localhost:5000/api/events/subscribe/sub-logs | python3 -m json.tool

# Lire depuis sub-alerts (doit contenir uniquement le message critical)
curl -s http://localhost:5000/api/events/subscribe/sub-alerts | python3 -m json.tool
```

### Tester la Dead-Letter Queue

> Sur ordinateur — tunnels Flask actifs requis.

```bash
# Envoyer un message invalide (sans product requis)
curl -s -X POST http://localhost:5000/api/messages/send \
  -H "Content-Type: application/json" \
  -d '{"order_id": "bad-001"}' \
  | python3 -m json.tool

# Inspecter la DLQ (après que max_delivery_count soit dépassé
# ou si le consumer appelle dead_letter_message() explicitement)
curl -s http://localhost:5000/api/messages/dlq | python3 -m json.tool

# Retraiter le premier message en DLQ
curl -s -X POST http://localhost:5000/api/messages/dlq/reprocess | python3 -m json.tool

# Vérifier le count de messages en DLQ via Azure CLI
az servicebus queue show \
  --resource-group "$RG" \
  --namespace-name "sbns-phase8c-${ENV}" \
  --name "orders" \
  --query "deadLetterMessageCount" \
  --output tsv
```

---

## Tester Event Hub et le Pipeline Monitoring

### Émettre des Métriques

> Sur ordinateur — tunnels Flask actifs requis.

```bash
# Émettre plusieurs métriques vers Event Hub
for METRIC in "orders_processed:42" "queue_depth:10" "consumer_lag:3"; do
  NAME="${METRIC%%:*}"
  VALUE="${METRIC##*:}"
  curl -s -X POST http://localhost:5000/api/metrics/emit \
    -H "Content-Type: application/json" \
    -d "{
      \"metric_name\": \"$NAME\",
      \"value\": $VALUE,
      \"tags\": {\"env\": \"$ENV\", \"source\": \"flask-app\"}
    }" -o /dev/null
  echo "Emis : $NAME = $VALUE"
done
```

### Vérifier consumer.py sur la VM App

> Sur la VM app — connexion SSH via Terminal 1 (bastion tunnel ouvert sur 2223).

```bash
# Se connecter à la VM app
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

# Statut du service consumer
systemctl status eventhub-consumer

# Logs récents
journalctl -u eventhub-consumer -n 30 --no-pager

# Quitter la VM
exit
```

### Vérifier Pushgateway

> Sur ordinateur — tunnels monitoring actifs requis (Terminaux 3 et 4).

```bash
curl -s http://localhost:9091/metrics | grep -v "^#" | grep -E "orders|queue|consumer"
```

Résultat attendu :

```
orders_processed{env="dev",instance="",job="eventhub_consumer",source="flask-app"} 42
queue_depth{env="dev",instance="",job="eventhub_consumer",source="flask-app"} 10
consumer_lag{env="dev",instance="",job="eventhub_consumer",source="flask-app"} 3
```

### Vérifier Prometheus

> Sur ordinateur — tunnels monitoring actifs requis.

```bash
# Vérifier que Pushgateway est scrappé
curl -s http://localhost:9090/api/v1/targets \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(t['scrapePool'], ':', t['health'], '-', t['scrapeUrl'])
"

# Chercher les métriques Event Hub
curl -s "http://localhost:9090/api/v1/query?query=orders_processed" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d['data']['result']:
    print(r['metric'], ':', r['value'][1])
"
```

---

## Accéder au Monitoring

### Grafana

> Sur ordinateur — tunnels monitoring actifs requis (Terminaux 3 et 4).

```
URL      : http://localhost:3000
Login    : admin
Password : le mot de passe saisi lors de ./scripts/setup-monitoring.sh
```

Dashboard disponible : **Event Hub Metrics** (provisionné automatiquement).

Panels :

- orders_processed — nombre de commandes traitées
- queue_depth — profondeur de la queue orders
- consumer_lag — retard du consumer Event Hub
- processing_time — temps de traitement des messages

Si les panels sont vides, vérifier que la datasource Prometheus a bien
l'UID `prometheus` dans `monitoring/grafana/provisioning/datasources/datasource.yml`.
En cas de doute, forcer le re-provisionnement :

```bash
# Sur la VM monitoring (via Bastion SSH sur 2222)
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1

sudo docker compose -f /opt/monitoring/docker-compose.yml restart grafana
```

### Prometheus

> Sur ordinateur — tunnels monitoring actifs requis.

```
URL : http://localhost:9090
```

Requêtes PromQL utiles :

```
# Métriques émises via Event Hub
orders_processed
queue_depth
consumer_lag

# Targets actifs
up{job="pushgateway"}

# Taux de variation des commandes
rate(orders_processed[5m])
```

### Pushgateway

> Sur ordinateur — tunnels monitoring actifs requis.

```
URL : http://localhost:9091
```

L'interface web du Pushgateway affiche toutes les métriques stockées
en mémoire, regroupées par job.

---

## Requêtes KQL Log Analytics

### Récupérer l'ID du Workspace

> Sur ordinateur.

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" \
  --workspace-name "law2-phase8c-${ENV}" \
  --query customerId -o tsv)
```

Note : le workspace est nommé `law2-phase8c-{env}` (préfixe `law2` et non `law`)
pour contourner le soft-delete de 14 jours d'Azure lors des déploiements
successifs.

### Messages en Dead-Letter

```bash
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

### Volume de Messages Service Bus

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "
    AzureMetrics
    | where ResourceProvider == 'MICROSOFT.SERVICEBUS'
    | where MetricName in ('IncomingMessages', 'OutgoingMessages')
    | summarize total = sum(Total) by MetricName
  " \
  --output table
```

### Débit Event Hub

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "
    AzureMetrics
    | where ResourceProvider == 'MICROSOFT.EVENTHUB'
    | where MetricName in ('IncomingMessages', 'OutgoingMessages')
    | summarize total = sum(Total) by MetricName, bin(TimeGenerated, 5m)
    | order by TimeGenerated desc
  " \
  --output table
```

### Accès aux Secrets Key Vault

```bash
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "
    AzureDiagnostics
    | where ResourceProvider == 'MICROSOFT.KEYVAULT'
    | where Category == 'AuditEvent'
    | where OperationName == 'SecretGet'
    | project TimeGenerated, ResultType, id_s
    | order by TimeGenerated desc
    | take 20
  " \
  --output table
```

---

## Diagnostic et Dépannage

### Flask ne démarre pas

> Sur la VM app — via Bastion SSH sur 2223.

```bash
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

systemctl status flask-app
journalctl -u flask-app -n 100 --no-pager
sudo tail -30 /var/log/cloud-init-output.log
```

Note : cloud-init peut prendre jusqu'à 10 minutes après la création
de la VM. Si le service n'est pas encore démarré, attendre et relancer
la vérification.

### consumer.py ne reçoit pas de métriques

> Sur la VM app — via Bastion SSH sur 2223.

```bash
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

systemctl status eventhub-consumer
journalctl -u eventhub-consumer -n 50 --no-pager

# Vérifier la résolution DNS Event Hub depuis la VM app
dig evhns-phase8c-${ENV}.servicebus.windows.net +short

# Vérifier la variable PUSHGATEWAY_URL
systemctl cat eventhub-consumer | grep PUSHGATEWAY_URL
```

### Pushgateway ne reçoit pas de métriques

> Sur la VM app — via Bastion SSH sur 2223.

```bash
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

# Récupérer l'IP privée de la VM monitoring
IP_MONITORING=$(az vm show \
  --resource-group "$RG" \
  --name "vm-phase8c-${ENV}-monitoring" \
  --show-details \
  --query privateIps -o tsv)

# Tester la connectivité depuis VM app vers VM monitoring
curl -v "http://${IP_MONITORING}:9091/metrics" 2>&1 | head -20
```

### Grafana n'affiche pas les métriques

> Sur la VM monitoring — via Bastion SSH sur 2222.

```bash
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1

# Vérifier Docker Compose
sudo docker compose -f /opt/monitoring/docker-compose.yml ps
sudo docker compose -f /opt/monitoring/docker-compose.yml logs --tail=30 grafana

# Forcer le re-provisionnement des dashboards
# (nécessaire si le fichier datasource.yml a été modifié après le premier démarrage)
sudo docker compose -f /opt/monitoring/docker-compose.yml down
sudo docker volume rm monitoring_grafana_data
sudo docker compose -f /opt/monitoring/docker-compose.yml up -d

# Vérifier que Pushgateway a des métriques
curl http://localhost:9091/metrics | grep -v "^#" | head -20
```

Note : si les panels Grafana affichent "No data" malgré des métriques
dans Pushgateway, vérifier que `uid: prometheus` est bien présent dans
`monitoring/grafana/provisioning/datasources/datasource.yml`. Sans cet UID
explicite, Grafana génère un UID aléatoire au démarrage et les dashboards
ne trouvent pas leur datasource.

### Résolution DNS depuis les VMs

> Sur la VM app — via Bastion SSH sur 2223.

```bash
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

# Service Bus Standard — IP publique Azure attendue (normal en dev/staging)
dig sbns-phase8c-${ENV}.servicebus.windows.net +short

# Event Hub Standard — IP publique Azure attendue (normal en dev/staging)
dig evhns-phase8c-${ENV}.servicebus.windows.net +short

# Key Vault — IP privée attendue (10.x.3.x) — Private Endpoint présent dans tous les envs
dig phase8c-${ENV}-kv.vault.azure.net +short
```

Service Bus et Event Hub utilisent leurs IPs publiques en dev/staging
(SKU Standard, pas de Private Endpoint disponible). C'est le comportement
attendu. Seul Key Vault dispose d'un Private Endpoint dans tous les
environnements.

### Réinitialiser les Tunnels après Recréation d'une VM

> Sur ordinateur.

```bash
# Si SSH refuse la connexion après recréation d'une VM (clé SSH changed warning)
ssh-keygen -R "[127.0.0.1]:2222"   # VM monitoring
ssh-keygen -R "[127.0.0.1]:2223"   # VM app
```

### Vérifier les Règles NSG (Service Bus AMQP)

> Sur ordinateur.

```bash
# Vérifier que le NSG autorise AMQP sortant (requis pour Service Bus Standard)
az network nsg rule list \
  --resource-group "$RG" \
  --nsg-name "nsg-app-phase8c-${ENV}" \
  --query "[?contains(name, 'amqp') || contains(name, 'AMQP')].{
    name: name,
    priority: priority,
    direction: direction,
    access: access,
    destinationPortRange: destinationPortRange
  }" \
  --output table
```

Les ports 5671 et 5672 (AMQP et AMQP+TLS) doivent être autorisés en
sortie vers Internet pour que Flask puisse se connecter au Service Bus
Standard depuis `snet-app`.

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
