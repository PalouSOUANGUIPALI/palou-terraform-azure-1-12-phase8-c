# Scripts Phase 8C - Messaging et Integration

Guide complet d'utilisation des scripts d'automatisation.

## Première chose à faire

Rendez tous les scripts exécutables :

```bash
chmod +x scripts/*.sh
```

Vérifiez que vous êtes à la racine du projet :

```bash
ls -la scripts/
# Doit afficher les 10 fichiers .sh et ce README.md
```

## Prérequis

### Outils à installer

| Outil                  | Installation               | Vérification        |
| ---------------------- | -------------------------- | ------------------- |
| Terraform CLI (>= 1.5) | `brew install terraform`   | `terraform version` |
| Azure CLI              | `brew install azure-cli`   | `az version`        |
| Git                    | `brew install git`         | `git version`       |
| curl                   | Préinstallé sur ordinateur | `curl --version`    |
| python3                | Préinstallé sur ordinateur | `python3 --version` |

### Connexions requises

```bash
# 1. Se connecter à Terraform Cloud
terraform login

# 2. Se connecter à Azure
az login

# 3. Vérifier la connexion Azure
az account show
```

### Service Principal Azure pour Terraform Cloud

Terraform Cloud s'authentifie auprès d'Azure via un Service Principal.
Les credentials sont stockés comme variables Terraform sensitives dans TFC
(pas comme variables d'environnement ARM\_\*).

Vous devez avoir un Service Principal avec les rôles suivants :

| Rôle                                  | Pourquoi                                |
| ------------------------------------- | --------------------------------------- |
| Contributeur                          | Création de toutes les ressources Azure |
| Administrateur de l'accès utilisateur | Attribution RBAC aux Managed Identities |

Si vous n'avez pas encore de Service Principal :

```bash
# Créer le Service Principal
az ad sp create-for-rbac \
  --name "terraform-cloud-sp" \
  --role "Contributor" \
  --scopes "/subscriptions/VOTRE_SUBSCRIPTION_ID"

# Notez les valeurs retournées :
# - appId    -> client_id
# - password -> client_secret
# - tenant   -> tenant_id

# Ajouter le rôle User Access Administrator
az role assignment create \
  --assignee "APP_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/VOTRE_SUBSCRIPTION_ID"
```

Le script setup-azure.sh vous demandera ces 4 valeurs et les configurera
automatiquement dans chaque workspace TFC :

| Variable        | Où la trouver                                                              |
| --------------- | -------------------------------------------------------------------------- |
| subscription_id | Portail Azure > Abonnements > ID d'abonnement                              |
| tenant_id       | Microsoft Entra ID > Vue d'ensemble > ID du locataire                      |
| client_id       | Entra ID > Inscriptions d'applications > votre SP > ID d'application       |
| client_secret   | Entra ID > Inscriptions d'applications > votre SP > Certificats et secrets |

### Clé SSH pour les VMs

Le script setup-azure.sh lit automatiquement la clé publique depuis
`$HOME/.ssh/id_rsa_azure.pub` et la stocke dans TFC.

Si la clé n'existe pas encore :

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure
```

Pour vous connecter aux VMs via Bastion, vous utiliserez :

- Nom d'utilisateur : `azureuser`
- Clé privée : `~/.ssh/id_rsa_azure`

### Chaînes de connexion Service Bus et Event Hub

Les chaînes de connexion Service Bus et Event Hub sont stockées dans TFC
comme variables sensitives et injectées dans Key Vault par Terraform.

setup-azure.sh vous propose de les saisir immédiatement ou de les ajouter
plus tard une fois les namespaces déployés.

Pour les récupérer après déploiement :

```bash
# Service Bus
az servicebus namespace authorization-rule keys list \
  --resource-group rg-phase8c-dev \
  --namespace-name <sb-namespace-name> \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv

# Event Hub
az eventhubs namespace authorization-rule keys list \
  --resource-group rg-phase8c-dev \
  --namespace-name <eh-namespace-name> \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv
```

### Organisation Terraform Cloud

L'organisation doit exister avant d'exécuter les scripts.
Créez-la sur https://app.terraform.io si ce n'est pas le cas.

L'organisation utilisée dans ce projet est :
`palou-terraform-azure-1-12-phase8-c`

## Ordre d'exécution complet

### Vue d'ensemble

```
setup-azure.sh                  Configuration initiale (TFC + variables)
    |
    v
deploy-dev.sh                   Infrastructure dev
deploy-staging.sh               Infrastructure staging
deploy-prod.sh                  Infrastructure prod (Service Bus Premium)
(ou deploy-all.sh fait tout d'un coup)
    |
    v
setup-monitoring.sh <env>       Déployer la stack monitoring (Grafana, Prometheus)
    |
    v
validate.sh <env>               Vérifier que l'infrastructure est correctement déployée
    |
    v
generate-traffic.sh <env>       Générer du trafic Service Bus et Event Hub
```

### Etape 1 : Configuration initiale

```bash
./scripts/setup-azure.sh
```

Le script setup-azure.sh :

- Vérifie tous les prérequis (Terraform, Azure CLI, Git, clé SSH, token TFC)
- Crée les 3 workspaces dans Terraform Cloud :
  - `phase8c-dev`
  - `phase8c-staging`
  - `phase8c-prod`
- Configure les variables sensitives de manière interactive :
  - subscription_id, tenant_id, client_id, client_secret
  - vm_ssh_public_key (lue automatiquement depuis ~/.ssh/id_rsa_azure.pub)
  - servicebus_connection_string, eventhub_connection_string (optionnel à cette étape)
- Valide le formatage de tous les fichiers Terraform

### Etape 2 : Premier push

```bash
git add .
git commit -m "Phase 8C initial"
git push
```

### Etape 3 : Déploiement

Option A - Tout déployer d'un coup (guidé étape par étape) :

```bash
./scripts/deploy-all.sh
```

Option B - Déployer un par un :

```bash
./scripts/deploy-dev.sh
./scripts/deploy-staging.sh
./scripts/deploy-prod.sh
```

IMPORTANT : Chaque déploiement déclenche un plan dans TFC que vous
devez approuver manuellement via l'interface web de Terraform Cloud.

La VM Flask et la VM Monitoring sont configurées via cloud-init au
moment du terraform apply. Cloud-init installe les dépendances et
crée les répertoires — les fichiers de configuration monitoring sont
copiés par setup-monitoring.sh.

### Etape 4 : Déploiement de la stack monitoring

A exécuter après chaque déploiement Terraform, et après toute
modification des fichiers dans monitoring/ :

```bash
./scripts/setup-monitoring.sh dev
./scripts/setup-monitoring.sh staging
./scripts/setup-monitoring.sh prod
```

Ce script :

- Ouvre un tunnel Bastion vers la VM Monitoring
- Copie les fichiers monitoring/ vers /opt/monitoring/ sur la VM
- Demande le mot de passe Grafana et démarre docker compose

### Etape 5 : Validation de l'infrastructure

```bash
./scripts/validate.sh dev
./scripts/validate.sh staging
./scripts/validate.sh prod
```

Ce script vérifie via Azure CLI :

- Resource Group et VNet (4 subnets)
- Azure Bastion
- VM Flask et VM Monitoring (état, IP privée, Managed Identity)
- Service Bus Namespace (SKU, queue orders, topic events, abonnements)
- Event Hub Namespace (SKU, hub app-metrics, consumer group grafana)
- Key Vault (RBAC, secrets servicebus et eventhub)
- Private Endpoints et zones DNS privées
- Log Analytics Workspace

### Etape 6 : Génération de trafic

```bash
./scripts/generate-traffic.sh dev 10
./scripts/generate-traffic.sh staging 5
```

Ce script ouvre un tunnel Bastion vers la VM Flask et envoie des
requêtes sur tous les endpoints de l'application. Le trafic génère
des métriques visibles dans Grafana via Prometheus Pushgateway.

### Destruction

```bash
# Détruire un seul environnement
./scripts/destroy-env.sh dev

# Détruire tout (guidé, dans le bon ordre)
./scripts/destroy-all.sh
```

Ordre de destruction : prod → staging → dev

## Variables sensitives

Ces variables sont configurées par setup-azure.sh et stockées dans TFC
de manière chiffrée. Elles ne sont jamais dans le code source.

| Variable                     | dev | staging | prod |
| ---------------------------- | :-: | :-----: | :--: |
| subscription_id              | oui |   oui   | oui  |
| tenant_id                    | oui |   oui   | oui  |
| client_id                    | oui |   oui   | oui  |
| client_secret                | oui |   oui   | oui  |
| vm_ssh_public_key            | oui |   oui   | oui  |
| servicebus_connection_string | oui |   oui   | oui  |
| eventhub_connection_string   | oui |   oui   | oui  |

## Différences avec la phase précédente

| Aspect                | Phase 8A                          | Phase 8C                               |
| --------------------- | --------------------------------- | -------------------------------------- |
| Services messaging    | Aucun                             | Service Bus + Event Hub                |
| VMs par environnement | 1 (Flask)                         | 2 (Flask + Monitoring)                 |
| Authentification      | Managed Identity → PostgreSQL/SQL | Managed Identity → Key Vault → secrets |
| Monitoring            | Log Analytics seul                | Prometheus + Grafana + Pushgateway     |
| Stack monitoring      | Intégrée au cloud-init            | Copiée par setup-monitoring.sh         |
| Mot de passe Grafana  | N/A                               | Saisi interactivement, jamais stocké   |
| Consumer Event Hub    | N/A                               | Service eventhub-consumer sur VM Flask |
| Remote state partagé  | Non                               | Non                                    |

## Liste des scripts

| Script              | Description                                                     |
| ------------------- | --------------------------------------------------------------- |
| setup-azure.sh      | Configuration initiale complète (TFC + variables + validation)  |
| setup-monitoring.sh | Déploie la stack monitoring sur la VM Monitoring via Bastion    |
| deploy-dev.sh       | Déploie l'environnement dev via TFC                             |
| deploy-staging.sh   | Déploie l'environnement staging via TFC                         |
| deploy-prod.sh      | Déploie l'environnement prod via TFC (confirmation obligatoire) |
| deploy-all.sh       | Déploie les 3 environnements dans l'ordre (guidé)               |
| validate.sh         | Vérifie l'infrastructure d'un environnement via Azure CLI       |
| generate-traffic.sh | Génère du trafic Service Bus et Event Hub via tunnel Bastion    |
| destroy-env.sh      | Détruit un environnement via TFC                                |
| destroy-all.sh      | Détruit tous les environnements dans l'ordre inverse            |

## Connexion aux VMs via Bastion

### VM Flask (snet-app) — port 2223

```bash
# Tunnel Bastion
az network bastion tunnel \
  --name bastion-phase8c-dev \
  --resource-group rg-phase8c-dev \
  --target-resource-id $(az vm show -g rg-phase8c-dev -n vm-phase8c-dev-app --query id -o tsv) \
  --resource-port 22 \
  --port 2223

# Dans un autre terminal — connexion SSH
ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1

# Depuis la VM — tester l'application
curl http://localhost:5000/health
curl -X POST http://localhost:5000/send \
  -H 'Content-Type: application/json' \
  -d '{"order_id": "test-1", "product": "item", "quantity": 1}'
curl http://localhost:5000/receive
```

### VM Monitoring (snet-monitoring) — port 2222

```bash
# Tunnel Bastion
az network bastion tunnel \
  --name bastion-phase8c-dev \
  --resource-group rg-phase8c-dev \
  --target-resource-id $(az vm show -g rg-phase8c-dev -n vm-phase8c-dev-monitoring --query id -o tsv) \
  --resource-port 22 \
  --port 2222

# Dans un autre terminal — tunnels SSH vers les services
ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9091:localhost:9091

# Interfaces accessibles depuis ordinateur
# Grafana     : http://localhost:3000
# Prometheus  : http://localhost:9090
# Pushgateway : http://localhost:9091
```

## Dépannage

### "Token TFC introuvable"

```bash
terraform login
```

### "Non connecté à Azure"

```bash
az login
```

### "Clé SSH introuvable"

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure
```

### "Workspace introuvable"

```bash
./scripts/setup-azure.sh
```

### "Permission denied" sur les scripts

```bash
chmod +x scripts/*.sh
```

### "Flask ne répond pas" dans generate-traffic.sh

Cloud-init peut prendre jusqu'à 10 minutes après le terraform apply.
Vérifiez l'état depuis la VM Flask :

```bash
cloud-init status
journalctl -u cloud-init -n 100
journalctl -u flask-app -n 50
journalctl -u eventhub-consumer -n 50
```

### "Secret introuvable dans Key Vault"

Les chaînes de connexion Service Bus et Event Hub doivent être
configurées dans TFC avant le terraform apply :

```bash
./scripts/setup-azure.sh
# Saisir les chaînes de connexion quand demandé
```

### "docker compose ps" ne montre pas les conteneurs

La stack monitoring est démarrée par setup-monitoring.sh, pas par
cloud-init. Relancez le script :

```bash
./scripts/setup-monitoring.sh dev
```

### "Grafana inaccessible" après setup-monitoring.sh

Vérifiez que les tunnels SSH sont ouverts dans le bon ordre :
d'abord le tunnel Bastion (port 2222), puis le tunnel SSH avec
port-forwarding (-L 3000:localhost:3000).

### "Consumer group grafana introuvable" dans validate.sh

Le consumer group est créé par Terraform. Vérifiez que le
terraform apply s'est terminé correctement dans TFC.

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
