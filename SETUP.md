# Guide d'Installation - Phase 8C

## Table des matières

1. [Prérequis](#étape-1--prérequis)
2. [Connexions](#étape-2--connexions)
3. [Clé SSH](#étape-3--clé-ssh)
4. [Organisation Terraform Cloud](#étape-4--organisation-terraform-cloud)
5. [Service Principal Azure](#étape-5--service-principal-azure)
6. [Configuration automatisée](#étape-6--configuration-automatisée)
7. [Connexion VCS et déploiement](#étape-7--connexion-vcs-et-déploiement)
8. [Configuration du monitoring](#étape-8--configuration-du-monitoring)
9. [Validation de l'infrastructure](#étape-9--validation-de-linfrastructure)
10. [Accès à l'application Flask](#étape-10--accès-à-lapplication-flask)
11. [Tests](#étape-11--tests)
12. [Génération de trafic](#étape-12--génération-de-trafic)
13. [Exploration Log Analytics](#étape-13--exploration-log-analytics)
14. [Destruction](#étape-14--destruction)
15. [Dépannage](#étape-15--dépannage)

---

## Étape 1 : Prérequis

> Toutes les commandes de cette section s'exécutent sur ordinateur.

### Terraform CLI (>= 1.6)

```bash
# macOS
brew install terraform

# Vérification
terraform version
```

### Azure CLI

```bash
# macOS
brew install azure-cli

# Vérification
az version
```

### Extensions Azure CLI requises

```bash
az extension add --name ssh
az extension add --name bastion
```

Ces extensions sont indispensables pour les connexions SSH et
les tunnels via Azure Bastion.

### Git

```bash
# Vérification
git --version
git config --list
```

### Outils supplémentaires

```bash
# curl et python3 sont généralement préinstallés
curl --version
python3 --version
```

---

## Étape 2 : Connexions

> Toutes les commandes de cette section s'exécutent sur ordinateur.

### Terraform Cloud

```bash
terraform login
```

Cela ouvre un navigateur. Connectez-vous à votre compte TFC et
autorisez l'accès. Le token est sauvegardé dans
`$HOME/.terraform.d/credentials.tfrc.json`.

### Azure

```bash
az login
```

Vérifiez que vous êtes sur le bon abonnement :

```bash
az account show
az account list -o table

# Changer d'abonnement si nécessaire
az account set --subscription "VOTRE_SUBSCRIPTION_ID"
```

---

## Étape 3 : Clé SSH

> Sur ordinateur.

Les VMs Azure sont accessibles via SSH à travers Azure Bastion.
La clé publique est envoyée à TFC comme variable sensitive et
configurée automatiquement sur les deux VMs par Terraform.

TFC tourne dans le cloud et ne peut pas appeler `file()` sur
le filesystem local. C'est pourquoi le **contenu** de la clé
publique est injecté comme variable sensitive, pas un chemin.

```bash
# Vérifier si la clé existe déjà
ls ~/.ssh/id_rsa_azure.pub

# Si elle n'existe pas, la générer
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure -C "azure-phase8c"
```

Le script `setup-azure.sh` lit automatiquement la clé depuis
`~/.ssh/id_rsa_azure.pub`. Vous n'avez pas besoin de la copier
manuellement.

Pour vous connecter aux VMs via Bastion, vous utiliserez :

- Nom d'utilisateur : `azureuser`
- Clé privée : `~/.ssh/id_rsa_azure`

---

## Étape 4 : Organisation Terraform Cloud

> Sur ordinateur — dans un navigateur.

Créez une organisation sur https://app.terraform.io si ce n'est
pas déjà fait.

L'organisation utilisée dans ce projet est :
`palou-terraform-azure-1-12-phase8-c`

Si votre organisation a un nom différent, modifiez la variable
`TFC_ORG` dans `scripts/setup-azure.sh`.

---

## Étape 5 : Service Principal Azure

> Sur ordinateur.

Terraform Cloud s'authentifie auprès d'Azure via un Service
Principal. Les credentials sont stockés comme variables Terraform
sensitives dans TFC.

Il doit avoir les rôles suivants au niveau de l'abonnement :

| Rôle                                  | Pourquoi                                                                |
| ------------------------------------- | ----------------------------------------------------------------------- |
| Contributeur                          | Création de toutes les ressources Azure                                 |
| Administrateur de l'accès utilisateur | Attribution RBAC aux Managed Identities des VMs (Key Vault, Monitoring) |

### Créer un Service Principal (si nécessaire)

```bash
# Récupérer votre Subscription ID
az account show --query "id" -o tsv

# Créer le Service Principal
az ad sp create-for-rbac \
  --name "terraform-cloud-sp" \
  --role "Contributor" \
  --scopes "/subscriptions/VOTRE_SUBSCRIPTION_ID"
```

Notez les valeurs retournées :

- `appId` → client_id
- `password` → client_secret
- `tenant` → tenant_id

### Ajouter le rôle User Access Administrator

```bash
az role assignment create \
  --assignee "APP_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/VOTRE_SUBSCRIPTION_ID"
```

Ce rôle est indispensable pour que Terraform puisse attribuer :

- le rôle **Key Vault Secrets User** à la Managed Identity de la VM Flask
  (lecture des connection strings Service Bus et Event Hub)
- le rôle **Monitoring Metrics Publisher** à la Managed Identity de la
  VM Monitoring

### Où trouver les valeurs dans le portail Azure

| Variable        | Où la trouver                                                              |
| --------------- | -------------------------------------------------------------------------- |
| subscription_id | Abonnements > votre abonnement > ID d'abonnement                           |
| tenant_id       | Microsoft Entra ID > Vue d'ensemble > ID du locataire                      |
| client_id       | Entra ID > Inscriptions d'applications > votre SP > ID d'application       |
| client_secret   | Entra ID > Inscriptions d'applications > votre SP > Certificats et secrets |

---

## Étape 6 : Configuration automatisée

> Sur ordinateur.

Le script `setup-azure.sh` automatise la création des workspaces
TFC et la configuration de toutes les variables sensitives.

```bash
chmod +x scripts/*.sh tests/*.sh
./scripts/setup-azure.sh
```

Ce script va :

1. Vérifier tous les prérequis (Terraform, Azure CLI, Git,
   clé SSH, token TFC)
2. Créer les 3 workspaces dans Terraform Cloud :
   - phase8c-dev
   - phase8c-staging
   - phase8c-prod
3. Configurer les 7 variables sensitives de manière interactive :
   - `subscription_id`, `tenant_id`, `client_id`, `client_secret`
   - `vm_ssh_public_key` (lue automatiquement depuis
     `~/.ssh/id_rsa_azure.pub`)
   - `servicebus_connection_string`
   - `eventhub_connection_string`
4. Valider le formatage de tous les fichiers Terraform

### Variables configurées par workspace

| Variable                     | dev | staging | prod |
| ---------------------------- | :-: | :-----: | :--: |
| subscription_id              | oui |   oui   | oui  |
| tenant_id                    | oui |   oui   | oui  |
| client_id                    | oui |   oui   | oui  |
| client_secret                | oui |   oui   | oui  |
| vm_ssh_public_key            | oui |   oui   | oui  |
| servicebus_connection_string | oui |   oui   | oui  |
| eventhub_connection_string   | oui |   oui   | oui  |

Les connection strings Service Bus et Event Hub sont stockés
dans Key Vault par Terraform. Flask les lit au démarrage via
Managed Identity — ils ne transitent jamais en clair dans le code.

Note : `GF_ADMIN_PASSWORD` (mot de passe Grafana) n'est **pas**
dans TFC. Il est saisi interactivement lors de `setup-monitoring.sh`
après chaque déploiement.

---

## Étape 7 : Connexion VCS et déploiement

> Sur ordinateur — dans un navigateur et un terminal.

### Connexion VCS (obligatoire avant tout déploiement)

Après avoir exécuté `setup-azure.sh`, les workspaces TFC existent
et les variables sont configurées. Mais les workspaces n'ont pas
encore accès au code Terraform.

Terraform Cloud a besoin d'accéder à votre dépôt Git pour lire
les fichiers Terraform et détecter les changements.

#### Procédure

Répétez ces étapes pour chaque workspace :

1. Allez sur https://app.terraform.io
2. Sélectionnez le workspace (ex: phase8c-dev)
3. **Settings** > **Version Control**
4. Cliquez **Connect to version control**
5. Choisissez **GitHub** (ou votre fournisseur Git)
6. Autorisez TFC à accéder à votre dépôt si demandé
7. Sélectionnez votre dépôt
8. Dans **Working Directory**, entrez le chemin correspondant
9. Cliquez **Update VCS settings** pour enregistrer

#### Paramètres par workspace

| Workspace       | Working Directory    |
| --------------- | -------------------- |
| phase8c-dev     | environments/dev     |
| phase8c-staging | environments/staging |
| phase8c-prod    | environments/prod    |

### Déploiement

```bash
# Déclenche le plan dans TFC pour les 3 environnements
git add .
git commit -m "Phase 8C : déploiement initial"
git push
```

TFC déclenche automatiquement un plan pour chaque workspace
connecté au VCS. Approuvez chaque plan dans l'interface TFC.

IMPORTANT : attendez que chaque apply soit terminé avant
d'approuver le suivant. Service Bus et Event Hub se provisionnent
en 3 à 5 minutes. Les deux VMs démarrent ensuite leur cloud-init
en parallèle.

### Vérifier que cloud-init est terminé

> Sur les VMs — après connexion SSH via Bastion.

Les deux VMs sont initialisées via cloud-init au premier démarrage.
Ce processus prend environ 5 à 10 minutes sur chaque VM.

**VM app** :

```bash
sudo tail -30 /var/log/cloud-init-output.log
systemctl status flask-app
systemctl status eventhub-consumer
journalctl -u flask-app -n 50
journalctl -u eventhub-consumer -n 30
```

La dernière ligne du log cloud-init doit contenir :

```
Phase 8C - VM app initialisee avec succes en XXX secondes
```

**VM monitoring** :

```bash
sudo tail -30 /var/log/cloud-init-output.log
docker --version
ls /opt/monitoring/
```

La VM monitoring est prête quand Docker est installé et les
répertoires `/opt/monitoring/` existent. La stack Docker Compose
n'est pas encore lancée — c'est l'Étape 8.

### Séquence de démarrage Flask

Au démarrage, Flask effectue les opérations suivantes dans l'ordre :

```
1. Lire KEY_VAULT_URL depuis la variable d'environnement systemd
2. Instancier ManagedIdentityCredential()
3. Appeler IMDS (169.254.169.254) pour obtenir un token AAD
   scope : https://vault.azure.net/.default
4. Interroger Key Vault via Private Endpoint :
   GET servicebus-connection-string
   GET eventhub-connection-string
5. Initialiser ServiceBusClient.from_connection_string()
6. Initialiser EventHubProducerClient.from_connection_string()
7. Démarrer gunicorn
```

Si l'une de ces étapes échoue, Flask s'arrête immédiatement et
`journalctl -u flask-app` indique l'étape en erreur.

Note importante sur l'ordre cloud-init : `write_files` s'exécute
avant `runcmd`. Les fichiers applicatifs sont d'abord écrits dans
`/tmp/` puis copiés vers leur destination finale dans `runcmd`
après création des répertoires avec `mkdir -p`.

---

## Étape 8 : Configuration du monitoring

> Sur ordinateur. À exécuter après chaque déploiement réussi.

La stack Prometheus / Grafana / Pushgateway ne se lance pas
automatiquement via Terraform. Elle est déployée par
`setup-monitoring.sh` qui copie les fichiers de configuration
sur la VM Monitoring et démarre Docker Compose.

Cette séparation garantit que le mot de passe Grafana n'est
jamais stocké dans le code source ni dans TFC.

```bash
./scripts/setup-monitoring.sh dev
```

Le script va :

1. Ouvrir un tunnel Bastion vers la VM Monitoring
2. Copier les fichiers du dossier `monitoring/` sur la VM
   (`docker-compose.yml`, `prometheus.yml`, dashboards Grafana)
3. Demander le mot de passe Grafana interactivement :

```
   Mot de passe Grafana admin (GF_ADMIN_PASSWORD) :
```

4. Lancer `docker compose up -d` avec le mot de passe injecté
5. Vérifier que les trois conteneurs sont `Up`

```bash
# Répéter pour staging et prod
./scripts/setup-monitoring.sh staging
./scripts/setup-monitoring.sh prod
```

Note : si vous modifiez les fichiers dans `monitoring/` (dashboards,
configuration Prometheus), relancez `setup-monitoring.sh` pour
propager les changements sur la VM. Les conteneurs Docker seront
redémarrés automatiquement.

---

## Étape 9 : Validation de l'infrastructure

> Sur ordinateur.

```bash
./scripts/validate.sh dev
```

Ce script vérifie via Azure CLI que toutes les ressources sont
correctement déployées :

- Resource Group et VNet
- Subnets (snet-app, snet-monitoring, snet-pe, AzureBastionSubnet)
- Azure Bastion (état, SKU Standard)
- VM app et VM monitoring (état, IP privée, Managed Identity)
- Service Bus (namespace, queue orders, topic events, sub-logs,
  sub-alerts avec filtre SQL)
- Event Hub (namespace, hub app-metrics, consumer groups $Default
  et grafana)
- Key Vault (secrets servicebus et eventhub, RBAC MI)
- Private Endpoints (Key Vault, + Service Bus en prod) et zones DNS privées
- Log Analytics Workspace

Le script affiche également les commandes de tunnel et les
requêtes KQL prêtes à l'emploi.

---

## Étape 10 : Accès à l'application Flask

> Important : toutes les ressources sont dans un réseau privé.
> Aucune IP publique sur les VMs ni les services PaaS.
> L'accès depuis ordinateur se fait exclusivement via SSH
> à travers Azure Bastion avec port forwarding local.
>
> L'accès à Flask nécessite **deux tunnels ouverts en parallèle**
> dans deux terminaux séparés.

### Terminal 1 — Tunnel Bastion vers VM app

```bash
RG=rg-phase8c-dev

VM_APP_ID=$(az vm show \
  --resource-group $RG \
  --name "vm-phase8c-dev-app" \
  --query id -o tsv)

az network bastion tunnel \
  --name bastion-phase8c-dev \
  --resource-group $RG \
  --target-resource-id $VM_APP_ID \
  --resource-port 22 \
  --port 2223
```

Ce terminal reste bloqué tant que le tunnel est ouvert.
Laissez-le tourner et ouvrez un second terminal.

### Terminal 2 — Tunnel SSH avec port-forwarding Flask

```bash
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \
  -L 5000:localhost:5000 -N
```

Ce terminal reste bloqué. Laissez-le tourner et ouvrez un
troisième terminal.

### Terminal 3 — Appels Flask

```bash
# Health check
curl http://localhost:5000/health

# Envoyer un message dans la queue orders
curl -X POST http://localhost:5000/send \
  -H "Content-Type: application/json" \
  -d '{"order_id": "001", "product": "laptop", "quantity": 1}'

# Recevoir un message (PEEK_LOCK)
curl http://localhost:5000/receive

# Publier sur le topic events (reçu par sub-logs uniquement)
curl -X POST http://localhost:5000/publish \
  -H "Content-Type: application/json" \
  -d '{"event": "order-processed", "level": "info", "order_id": "001"}'

# Publier sur le topic events (reçu par sub-logs ET sub-alerts)
curl -X POST http://localhost:5000/publish \
  -H "Content-Type: application/json" \
  -d '{"event": "payment-failed", "level": "critical", "order_id": "001"}'

# Lire depuis les subscriptions
curl http://localhost:5000/subscribe/sub-logs
curl http://localhost:5000/subscribe/sub-alerts

# Lire la Dead-Letter Queue
curl http://localhost:5000/dlq

# Retraiter un message en DLQ
curl -X POST http://localhost:5000/dlq/reprocess

# Émettre des métriques vers Event Hub
curl -X POST http://localhost:5000/metrics/emit \
  -H "Content-Type: application/json" \
  -d '{"metric_name": "orders_processed", "value": 42, "tags": {"env": "dev"}}'
```

### Vérification de l'application depuis la VM app

> Sur la VM app — après connexion SSH via Bastion.

```bash
# Health check direct (pas besoin de tunnel)
curl http://localhost:5000/health

# Statut des deux services systemd
systemctl status flask-app
systemctl status eventhub-consumer
journalctl -u eventhub-consumer -n 30 --no-pager
```

### Résolution du known_hosts après recréation d'une VM

> Sur ordinateur.

Après la destruction et recréation d'une VM, SSH refuse la
connexion car l'empreinte a changé :

```bash
ssh-keygen -R "[127.0.0.1]:2222"   # VM monitoring
ssh-keygen -R "[127.0.0.1]:2223"   # VM app
```

---

## Étape 11 : Tests

> Sur ordinateur. Les tests infrastructure (1 et 2) fonctionnent
> sans tunnel. Les tests applicatifs (3 et 4) nécessitent les deux
> tunnels ouverts (voir Étape 10, Terminaux 1 et 2).

### Tests complets

```bash
./tests/test-all.sh dev
```

### Tests individuels

```bash
# Private Endpoints Key Vault (+ Service Bus en prod) et zones DNS privées
./tests/test-private-endpoint.sh dev

# Managed Identity → Key Vault → connection strings
./tests/test-mi-auth.sh dev

# Service Bus : queue orders, topic events, sub-logs, sub-alerts, DLQ
./tests/test-servicebus.sh dev

# Event Hub : namespace, hub app-metrics, consumer group grafana,
# pipeline consumer.py → Pushgateway
./tests/test-eventhub.sh dev
```

---

## Étape 12 : Génération de trafic

> Sur ordinateur. Aucun tunnel préalable n'est nécessaire —
> le script ouvre lui-même les tunnels en arrière-plan.

```bash
./scripts/generate-traffic.sh dev 15
```

Ce script génère du trafic pendant 15 minutes sur tous les
endpoints Flask pour alimenter :

- Log Analytics avec des métriques Service Bus et Event Hub
- Le pipeline Event Hub → consumer.py → Pushgateway → Prometheus
  → Grafana pour alimenter les dashboards

Le trafic couvre l'ensemble des patterns :

- Messages dans la queue orders (send + receive)
- Publication sur le topic events (info et critical)
- Lecture depuis sub-logs et sub-alerts
- Émission de métriques vers Event Hub

Prérequis : Azure CLI connecté (`az login`) et clé SSH
disponible (`~/.ssh/id_rsa_azure`).

---

## Étape 13 : Exploration Log Analytics

> Dans le portail Azure — portail.azure.com.

Chemin d'accès :

```
Portail Azure
  → Resource Groups
  → rg-phase8c-dev
  → phase8c-dev-law
  → Logs (menu gauche)
```

### Tables disponibles

```kql
search *
| where TimeGenerated > ago(1h)
| summarize count() by Type
| order by count_ desc
```

### Messages en Dead-Letter Queue

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where MetricName == "DeadletteredMessages"
| where Total > 0
| project TimeGenerated, Total
| order by TimeGenerated desc
```

### Volume de messages Service Bus

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where MetricName in ("IncomingMessages", "OutgoingMessages", "ActiveMessages")
| summarize total = sum(Total) by MetricName, bin(TimeGenerated, 5m)
| render timechart
```

### Erreurs d'authentification Service Bus

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| where Category == "OperationalLogs"
| where Status == "Unauthorized" or Status == "Failed"
| project TimeGenerated, EventName, Status, ErrorDescription
| order by TimeGenerated desc
```

### Débit Event Hub (messages entrants et sortants)

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.EVENTHUB"
| where MetricName in ("IncomingMessages", "OutgoingMessages",
  "IncomingBytes", "OutgoingBytes")
| summarize avg(Average) by MetricName, bin(TimeGenerated, 5m)
| render timechart
```

### Audit Key Vault (lectures de secrets par la MI)

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where OperationName == "SecretGet"
| where TimeGenerated > ago(1h)
| project TimeGenerated, CallerIPAddress, id_s, ResultType
| order by TimeGenerated desc
```

---

## Étape 14 : Destruction

> Sur ordinateur.

### Ordre recommandé

```
1. prod      (détruire EN PREMIER)
2. staging
3. dev       (détruire EN DERNIER)
```

### Destruction complète

```bash
./scripts/destroy-all.sh
```

### Destruction individuelle

```bash
./scripts/destroy-env.sh prod
./scripts/destroy-env.sh staging
./scripts/destroy-env.sh dev
```

Vérifiez que tous les Resource Groups ont été supprimés :

```bash
az group list --query "[?contains(name, 'phase8c')]" -o table
```

Note : Key Vault est en soft-delete par défaut. Si vous
redéployez immédiatement après destruction, le nom peut être
en conflit avec le vault supprimé. Purgez-le si nécessaire :

```bash
az keyvault purge --name phase8c-dev-kv --location francecentral
```

---

## Étape 15 : Dépannage

### Token TFC introuvable

> Sur ordinateur.

```bash
terraform login
```

### Non connecté à Azure

> Sur ordinateur.

```bash
az login
```

### Clé SSH introuvable

> Sur ordinateur.

```bash
# Vérifier
ls ~/.ssh/id_rsa_azure.pub

# Générer si absente
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure -C "azure-phase8c"
```

### Workspace introuvable

> Sur ordinateur.

```bash
./scripts/setup-azure.sh
```

### Permission denied sur les scripts

> Sur ordinateur.

```bash
chmod +x scripts/*.sh tests/*.sh
```

### Flask ne répond pas sur le tunnel

> Sur la VM app — après connexion SSH via Bastion.

Cloud-init est peut-être encore en cours. Attendez 5 à 10
minutes après la création de la VM, puis vérifiez :

```bash
systemctl status flask-app
journalctl -u flask-app -n 100
sudo tail -50 /var/log/cloud-init-output.log
```

### eventhub-consumer.service ne démarre pas

> Sur la VM app.

```bash
systemctl status eventhub-consumer
journalctl -u eventhub-consumer -n 50 --no-pager

# Vérifier les variables d'environnement du service
systemctl cat eventhub-consumer | grep -E "KEY_VAULT|EVENTHUB|PUSHGATEWAY"

# Vérifier la résolution DNS Event Hub depuis la VM
dig evhns-phase8c-dev.servicebus.windows.net +short

# Vérifier la connectivité vers Pushgateway
curl -v http://<IP_VM_MONITORING>:9091/metrics 2>&1 | head -10
```

### Key Vault inaccessible au démarrage Flask

Flask lit `KEY_VAULT_URL` au démarrage et contacte Key Vault
via Private Endpoint pour récupérer les connection strings.
Si ce contact échoue, Flask s'arrête immédiatement.

> Sur la VM app.

```bash
# Vérifier que KEY_VAULT_URL est injecté dans l'environnement systemd
systemctl cat flask-app | grep KEY_VAULT_URL

# Vérifier la résolution DNS du Key Vault
# Doit retourner une IP privée 10.x.3.x — pas une IP publique
dig phase8c-dev-kv.vault.azure.net +short

# Vérifier les logs Flask au démarrage
journalctl -u flask-app -n 50
```

> Sur ordinateur.

```bash
# Vérifier les secrets dans Key Vault
az keyvault secret list \
  --vault-name phase8c-dev-kv \
  --query "[].{name: name, enabled: attributes.enabled}" \
  --output table

# Vérifier le RBAC MI sur Key Vault
MI_ID=$(az vm show \
  --resource-group rg-phase8c-dev \
  --name vm-phase8c-dev-app \
  --query "identity.principalId" -o tsv)

KV_ID=$(az keyvault show \
  --name phase8c-dev-kv \
  --query "id" -o tsv)

az role assignment list \
  --assignee "$MI_ID" \
  --scope "$KV_ID" \
  --query "[].roleDefinitionName" -o tsv
```

Résultat attendu : `Key Vault Secrets User`

### Service Bus inaccessible depuis Flask

> Sur ordinateur.

```bash
# Vérifier le namespace
az servicebus namespace show \
  --resource-group rg-phase8c-dev \
  --name sbns-phase8c-dev \
  --query "{sku: sku.name, state: provisioningState}" \
  --output json

# Vérifier la queue orders
az servicebus queue show \
  --resource-group rg-phase8c-dev \
  --namespace-name sbns-phase8c-dev \
  --name orders \
  --query "status" -o tsv
```

En dev/staging (SKU Standard), Service Bus n'a pas de Private
Endpoint. La connexion passe par les IPs publiques Azure avec
authentification AAD via la connection string dans Key Vault.
Vérifiez que `local_auth_enabled = false` et que le NSG autorise
HTTPS 443 vers Internet depuis snet-app.

### Event Hub inaccessible depuis consumer.py

> Sur ordinateur.

```bash
# Vérifier le namespace Event Hub
az eventhubs namespace show \
  --resource-group rg-phase8c-dev \
  --name evhns-phase8c-dev \
  --query "{sku: sku.name, state: provisioningState}" \
  --output json

# Vérifier le consumer group grafana
az eventhubs eventhub consumer-group show \
  --resource-group rg-phase8c-dev \
  --namespace-name evhns-phase8c-dev \
  --eventhub-name app-metrics \
  --name grafana \
  --query "name" -o tsv
```

### Grafana n'affiche pas les métriques

> Sur la VM monitoring (via Bastion SSH sur port 2222).

```bash
# Vérifier l'état des conteneurs Docker Compose
docker compose -f /opt/monitoring/docker-compose.yml ps

# Vérifier les logs de chaque conteneur
docker compose -f /opt/monitoring/docker-compose.yml logs --tail=30 grafana
docker compose -f /opt/monitoring/docker-compose.yml logs --tail=30 prometheus
docker compose -f /opt/monitoring/docker-compose.yml logs --tail=30 pushgateway

# Vérifier que Pushgateway a des métriques
curl http://localhost:9091/metrics | grep -v "^#" | head -20

# Forcer le re-provisionnement des dashboards Grafana
docker compose -f /opt/monitoring/docker-compose.yml restart grafana
```

Si Grafana tourne mais que les dashboards sont vides, vérifiez
que consumer.py envoie bien des métriques vers Pushgateway en
consultant `journalctl -u eventhub-consumer` sur la VM app.

### NSG bloque internet outbound sur les VMs

> Sur ordinateur.

Si cloud-init échoue avec des erreurs de téléchargement apt
ou pip (ou Docker sur VM monitoring), vérifiez que les règles
NSG outbound vers Internet sont présentes :

```bash
# NSG de snet-app
NSG_APP=$(az network nsg list \
  -g rg-phase8c-dev \
  --query "[?contains(name,'app')].name" -o tsv)

az network nsg rule list \
  --resource-group rg-phase8c-dev \
  --nsg-name $NSG_APP \
  --query "[?direction=='Outbound'].{Name:name, Priority:priority, Access:access, Port:destinationPortRange}" \
  -o table

# NSG de snet-monitoring
NSG_MON=$(az network nsg list \
  -g rg-phase8c-dev \
  --query "[?contains(name,'monitoring')].name" -o tsv)

az network nsg rule list \
  --resource-group rg-phase8c-dev \
  --nsg-name $NSG_MON \
  --query "[?direction=='Outbound'].{Name:name, Priority:priority, Access:access, Port:destinationPortRange}" \
  -o table
```

Les règles `Allow-...-HTTP-Internet-Outbound` (port 80) et
`Allow-...-HTTPS-Internet-Outbound` (port 443) doivent être
présentes sur les deux NSGs.

### cloud-init : fichiers écrits dans un répertoire inexistant

Le mécanisme cloud-init exécute `write_files` **avant** `runcmd`.
À ce stade, les répertoires de destination n'existent pas encore.
Les fichiers doivent être écrits dans `/tmp/` par `write_files`,
puis copiés vers leur destination dans `runcmd` après `mkdir -p`.

```bash
# Sur la VM app
ls /opt/flask-app/
ls /opt/flask-app/venv/
cat /opt/flask-app/app/main.py
```

### Key Vault soft-delete : conflit de nom lors d'un redéploiement

Lors de la destruction, Key Vault passe en soft-delete (état
supprimé mais récupérable). Si vous redéployez immédiatement
avec le même nom, Terraform échoue avec un conflit de ressource.

> Sur ordinateur.

```bash
# Lister les Key Vaults en soft-delete
az keyvault list-deleted \
  --query "[?name=='phase8c-dev-kv']" -o table

# Purger définitivement le Key Vault supprimé
az keyvault purge --name phase8c-dev-kv --location francecentral
```

Les environnements dev et staging ont `purge_protection=false`
pour faciliter les itérations. L'environnement prod a
`purge_protection=true` — une purge manuelle n'est pas possible,
il faut attendre la fin de la période de rétention (7 jours).

### Bastion : tunnel SSH impossible

> Sur ordinateur.

Vérifiez que le SKU Bastion est bien Standard :

```bash
az network bastion list \
  --resource-group rg-phase8c-dev \
  --query "[0].{sku:sku.name, state:provisioningState}" \
  -o table
```

Vérifiez que les extensions Azure CLI sont installées :

```bash
az extension add --name ssh
az extension add --name bastion
```

### Host key changed après recréation d'une VM

> Sur ordinateur.

```bash
ssh-keygen -R "[127.0.0.1]:2222"   # VM monitoring
ssh-keygen -R "[127.0.0.1]:2223"   # VM app
```

---

## Résumé de l'Ordre Complet

```
CONFIGURATION (sur ordinateur)
-------------------------------
1. chmod +x scripts/*.sh tests/*.sh
2. az extension add --name ssh && az extension add --name bastion
3. ls ~/.ssh/id_rsa_azure.pub  (ou générer avec ssh-keygen)
4. ./scripts/setup-azure.sh
5. Connecter les 3 workspaces au VCS dans TFC

DEPLOIEMENT INFRASTRUCTURE (sur ordinateur)
--------------------------------------------
6. git add . && git commit -m "Phase 8C initial" && git push
7. Approuver dev dans TFC -> attendre l'apply (3-5 min SB/EH, 5-10 min VMs)
8. Approuver staging dans TFC -> attendre l'apply
9. Approuver prod dans TFC -> attendre l'apply (saisir "oui" pour confirmer)

CONFIGURATION MONITORING (sur ordinateur)
------------------------------------------
10. ./scripts/setup-monitoring.sh dev
    -> saisir le mot de passe Grafana interactivement
11. ./scripts/setup-monitoring.sh staging
12. ./scripts/setup-monitoring.sh prod

VERIFICATION CLOUD-INIT (sur les VMs via Bastion SSH)
------------------------------------------------------
13. Attendre 5 a 10 minutes apres creation des VMs
14. Se connecter a la VM app via Bastion (port 2223) :
      az network bastion ssh \
        --name bastion-phase8c-dev \
        --resource-group rg-phase8c-dev \
        --target-resource-id $(az vm show -g rg-phase8c-dev \
          -n vm-phase8c-dev-app --query id -o tsv) \
        --auth-type ssh-key \
        --username azureuser \
        --ssh-key ~/.ssh/id_rsa_azure
15. Sur la VM app, verifier :
      systemctl status flask-app
      systemctl status eventhub-consumer
      sudo tail -30 /var/log/cloud-init-output.log
      curl http://localhost:5000/health

VALIDATION (sur ordinateur)
-----------------------------
16. ./scripts/validate.sh dev

TESTS (sur ordinateur)
------------------------
17. ./tests/test-all.sh dev

ACCES FLASK DEPUIS ORDINATEUR
-------------------------------
Terminal 1 (sur ordinateur) — tunnel Bastion vers VM app :
      az network bastion tunnel \
        --name bastion-phase8c-dev \
        --resource-group rg-phase8c-dev \
        --target-resource-id $(az vm show -g rg-phase8c-dev \
          -n vm-phase8c-dev-app --query id -o tsv) \
        --resource-port 22 --port 2223

Terminal 2 (sur ordinateur) — port-forwarding Flask :
      ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \
        -L 5000:localhost:5000 -N

Terminal 3 (sur ordinateur) — appels Flask :
      curl http://localhost:5000/health
      curl -X POST http://localhost:5000/send \
        -H "Content-Type: application/json" \
        -d '{"order_id": "001", "product": "laptop", "quantity": 1}'
      curl http://localhost:5000/receive
      curl -X POST http://localhost:5000/publish \
        -H "Content-Type: application/json" \
        -d '{"event": "payment-failed", "level": "critical", "order_id": "001"}'
      curl http://localhost:5000/subscribe/sub-alerts

ACCES MONITORING DEPUIS ORDINATEUR
-------------------------------------
Terminal 1 (sur ordinateur) — tunnel Bastion vers VM monitoring :
      az network bastion tunnel \
        --name bastion-phase8c-dev \
        --resource-group rg-phase8c-dev \
        --target-resource-id $(az vm show -g rg-phase8c-dev \
          -n vm-phase8c-dev-monitoring --query id -o tsv) \
        --resource-port 22 --port 2222

Terminal 2 (sur ordinateur) — port-forwarding Grafana + Prometheus :
      ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
        -L 3000:localhost:3000 \
        -L 9090:localhost:9090 \
        -L 9091:localhost:9091 -N

Navigateur :
      http://localhost:3000   Grafana (admin / mot de passe setup-monitoring.sh)
      http://localhost:9090   Prometheus
      http://localhost:9091   Pushgateway

GENERATION DE TRAFIC (sur ordinateur — tunnels non requis)
-----------------------------------------------------------
18. ./scripts/generate-traffic.sh dev 15

EXPLORATION LOG ANALYTICS
--------------------------
19. Portail Azure -> rg-phase8c-dev -> phase8c-dev-law -> Logs
    Requetes KQL : voir Etape 13

DESTRUCTION (sur ordinateur)
------------------------------
20. ./scripts/destroy-all.sh
21. az group list --query "[?contains(name, 'phase8c')]" -o table
    # Si Key Vault en soft-delete conflict :
    az keyvault purge --name phase8c-dev-kv --location francecentral
```

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
