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

```bash
# Sur l'ordinateur
az extension add --name ssh
az extension add --name bastion
```

### Variables d'Environnement

```bash
# Sur l'ordinateur — adapter selon l'environnement exploré
export ENV=dev
export RG=rg-phase8c-${ENV}
export BASTION=bastion-phase8c-${ENV}
```

### Récupérer les IDs des VMs

```bash
# Sur l'ordinateur
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

```bash
# Terminal 1 — tunnel Bastion vers VM app
az network bastion tunnel \
  --name "$BASTION" \
  --resource-group "$RG" \
  --target-resource-id "$VM_APP_ID" \
  --resource-port 22 \
  --port 2223

# Terminal 2 — tunnel SSH avec port-forwarding Flask
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \
  -L 5000:localhost:5000 -N
```

#### Accès Monitoring (VM monitoring)

```bash
# Terminal 3 — tunnel Bastion vers VM monitoring
az network bastion tunnel \
  --name "$BASTION" \
  --resource-group "$RG" \
  --target-resource-id "$VM_MONITORING_ID" \
  --resource-port 22 \
  --port 2222

# Terminal 4 — tunnel SSH avec port-forwarding Grafana + Prometheus
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9091:localhost:9091 \
  -N
```

---

## Vérifier les Ressources Azure

### Vue d'Ensemble du Resource Group

```bash
# Sur l'ordinateur
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
phase8c-{env}-law             Microsoft.OperationalInsights/workspaces
```

### Vérifier le Namespace Service Bus

```bash
# Sur l'ordinateur
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

Résultat attendu :

```json
{
  "name": "sbns-phase8c-dev",
  "sku": "Standard",
  "provisioningState": "Succeeded",
  "localAuth": true
}
```

### Vérifier la Queue et le Topic

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

```bash
# Sur l'ordinateur
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

```bash
# Sur l'ordinateur — tunnel Flask actif requis
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

```bash
# Envoyer un message dans la queue orders
curl -s -X POST http://localhost:5000/send \
  -H "Content-Type: application/json" \
  -d '{"order_id": "test-001", "product": "laptop", "quantity": 1}' \
  | python3 -m json.tool

# Recevoir le message
curl -s http://localhost:5000/receive | python3 -m json.tool
```

### Publier sur le Topic Events

```bash
# Publier un événement info (reçu par sub-logs uniquement)
curl -s -X POST http://localhost:5000/publish \
  -H "Content-Type: application/json" \
  -d '{"event": "order-processed", "level": "info", "order_id": "test-001"}' \
  | python3 -m json.tool

# Publier un événement critical (reçu par sub-logs ET sub-alerts)
curl -s -X POST http://localhost:5000/publish \
  -H "Content-Type: application/json" \
  -d '{"event": "payment-failed", "level": "critical", "order_id": "test-001"}' \
  | python3 -m json.tool

# Lire depuis sub-logs (doit contenir les deux messages)
curl -s http://localhost:5000/subscribe/sub-logs | python3 -m json.tool

# Lire depuis sub-alerts (doit contenir uniquement le message critical)
curl -s http://localhost:5000/subscribe/sub-alerts | python3 -m json.tool
```

### Tester la Dead-Letter Queue

```bash
# Envoyer un message invalide (sans order_id)
curl -s -X POST http://localhost:5000/send \
  -H "Content-Type: application/json" \
  -d '{"product": "laptop"}' \
  | python3 -m json.tool

# Lire la DLQ (après que max_delivery_count soit dépassé
# ou si le consumer appelle dead_letter_message() explicitement)
curl -s http://localhost:5000/dlq | python3 -m json.tool

# Retraiter le premier message en DLQ
curl -s -X POST http://localhost:5000/dlq/reprocess | python3 -m json.tool

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

```bash
# Sur l'ordinateur — tunnel Flask actif requis

# Émettre plusieurs métriques
for METRIC in "orders_processed:42" "queue_depth:10" "consumer_lag:3"; do
  NAME="${METRIC%%:*}"
  VALUE="${METRIC##*:}"
  curl -s -X POST http://localhost:5000/metrics/emit \
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

```bash
# Sur la VM app (connexion SSH via terminal Bastion ouvert sur 2223)
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

# Statut du service consumer
systemctl status eventhub-consumer

# Logs récents
journalctl -u eventhub-consumer -n 30 --no-pager

# Quitter la VM
exit
```

### Vérifier Pushgateway

```bash
# Sur l'ordinateur — tunnel monitoring actif requis
curl -s http://localhost:9091/metrics | grep -v "^#" | grep -E "orders|queue|consumer"
```

Résultat attendu :

```
orders_processed{env="dev",instance="",job="eventhub_consumer",source="flask-app"} 42
queue_depth{env="dev",instance="",job="eventhub_consumer",source="flask-app"} 10
consumer_lag{env="dev",instance="",job="eventhub_consumer",source="flask-app"} 3
```

### Vérifier Prometheus

```bash
# Sur l'ordinateur — tunnel monitoring actif requis

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

Avec le tunnel SSH actif sur le port 3000 (voir Prérequis) :

```
URL      : http://localhost:3000
Login    : admin
Password : le mot de passe saisi lors de ./scripts/setup-monitoring.sh
```

Dashboard disponible : **Event Hub Metrics** (provisionné automatiquement)

Panels :

- orders_processed — nombre de commandes traitées
- queue_depth — profondeur de la queue orders
- consumer_lag — retard du consumer Event Hub
- processing_time — temps de traitement des messages

### Prometheus

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

```
URL : http://localhost:9091
```

L'interface web du Pushgateway affiche toutes les métriques
stockées en mémoire, regroupées par job.

---

## Requêtes KQL Log Analytics

### Accéder au Workspace

```bash
# Sur l'ordinateur
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" \
  --workspace-name "phase8c-${ENV}-law" \
  --query customerId -o tsv)
```

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

```bash
# Sur la VM app (via Bastion SSH sur 2223)
systemctl status flask-app
journalctl -u flask-app -n 100 --no-pager
sudo tail -30 /var/log/cloud-init-output.log
```

### consumer.py ne reçoit pas de métriques

```bash
# Sur la VM app (via Bastion SSH sur 2223)
systemctl status eventhub-consumer
journalctl -u eventhub-consumer -n 50 --no-pager

# Vérifier la résolution DNS Event Hub depuis la VM app
dig evhns-phase8c-${ENV}.servicebus.windows.net +short

# Vérifier la variable PUSHGATEWAY_URL
systemctl cat eventhub-consumer | grep PUSHGATEWAY_URL
```

### Pushgateway ne reçoit pas de métriques

```bash
# Vérifier la connectivité depuis VM app vers VM monitoring
# (sur VM app via Bastion)
IP_MONITORING=$(az vm show \
  --resource-group "$RG" \
  --name "vm-phase8c-${ENV}-monitoring" \
  --show-details \
  --query privateIps -o tsv)

curl -v "http://${IP_MONITORING}:9091/metrics" 2>&1 | head -20
```

### Grafana n'affiche pas les métriques

```bash
# Sur VM monitoring (via Bastion SSH sur 2222)

# Vérifier Docker Compose
docker compose ps
docker compose logs --tail=30 grafana

# Forcer le re-provisionnement des dashboards
docker compose restart grafana

# Vérifier que Pushgateway a des métriques
curl http://localhost:9091/metrics | grep -v "^#" | head -20
```

### Résolution DNS depuis les VMs

```bash
# Sur VM app (via Bastion SSH sur 2223)

# Service Bus — Standard : IP publique attendue
dig sbns-phase8c-${ENV}.servicebus.windows.net +short

# Event Hub — Standard : IP publique attendue
dig evhns-phase8c-${ENV}.servicebus.windows.net +short

# Key Vault — IP privée attendue (10.x.3.x)
dig phase8c-${ENV}-kv.vault.azure.net +short
```

### Réinitialiser les Tunnels après Recréation d'une VM

```bash
# Sur l'ordinateur — si SSH refuse après recréation d'une VM
ssh-keygen -R "[127.0.0.1]:2222"   # VM monitoring
ssh-keygen -R "[127.0.0.1]:2223"   # VM app
```

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
