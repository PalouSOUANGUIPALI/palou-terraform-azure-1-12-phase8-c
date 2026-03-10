# Managed Identity

Guide sur l'utilisation de la Managed Identity dans Phase 8C —
comment la VM Flask s'authentifie à Key Vault sans secret,
le flux IMDS, les rôles RBAC attribués et la chaîne complète
d'accès aux ressources.

---

## Table des Matières

1. [Qu'est-ce qu'une Managed Identity](#quest-ce-quune-managed-identity)
2. [System-Assigned vs User-Assigned](#system-assigned-vs-user-assigned)
3. [Flux d'Authentification — IMDS](#flux-dauthentification--imds)
4. [RBAC — Rôles Attribués dans Phase 8C](#rbac--rôles-attribués-dans-phase-8c)
5. [Managed Identity et Key Vault](#managed-identity-et-key-vault)
6. [Managed Identity et Service Bus / Event Hub](#managed-identity-et-service-bus--event-hub)
7. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Qu'est-ce qu'une Managed Identity

Une Managed Identity est une identité Azure Active Directory associée
à une ressource Azure (VM, App Service, Function...). Elle permet
à cette ressource de s'authentifier à d'autres services Azure sans
stocker ni gérer de secrets (mots de passe, clés, certificats).

```
Sans Managed Identity :
  VM Flask
    └── connection string hardcodé dans le code (risque de fuite)
    ou
    └── clé stockée dans une variable d'environnement (moins sécurisé)

Avec Managed Identity :
  VM Flask
    └── ManagedIdentityCredential()  (aucun secret dans le code)
          └── IMDS (169.254.169.254)  (service Azure interne)
                └── Token AAD         (valide 1h, renouvelé automatiquement)
                      └── Key Vault   (lecture des connection strings)
```

L'avantage principal est **zéro secret à gérer** : pas de rotation,
pas de risque de fuite dans le code source, pas de variable
d'environnement sensible.

---

## System-Assigned vs User-Assigned

### System-Assigned (utilisée dans Phase 8C)

L'identité est créée automatiquement par Azure lors de la création
de la VM et supprimée automatiquement lors de la destruction.
Elle est liée au cycle de vie de la ressource.

```hcl
resource "azurerm_linux_virtual_machine" "app" {
  ...
  identity {
    type = "SystemAssigned"
  }
}

# Récupérer le principal_id pour les attributions RBAC
output "vm_identity_principal_id" {
  value = azurerm_linux_virtual_machine.app.identity[0].principal_id
}
```

```
Avantage    : création automatique, cycle de vie géré par Azure
Inconvénient : liée à une seule VM — ne peut pas être partagée
              entre plusieurs ressources
```

### User-Assigned

L'identité est créée indépendamment et peut être assignée à
plusieurs ressources. Son cycle de vie est géré séparément.

```
Avantage    : peut être partagée entre VM, App Service, Functions, etc.
              Persiste après suppression des ressources assignées
Inconvénient : ressource supplémentaire à créer et gérer
```

Pour Phase 8C, la System-Assigned est suffisante — chaque VM a
sa propre identité et ses propres accès.

---

## Flux d'Authentification — IMDS

L'Instance Metadata Service (IMDS) est un service HTTP disponible
à l'adresse `169.254.169.254` (link-local — uniquement depuis une VM Azure).
Il fournit des tokens d'accès AAD pour la Managed Identity.

```
VM Flask
  │
  └── ManagedIdentityCredential.get_token("https://vault.azure.net/.default")
        │
        └── HTTP GET http://169.254.169.254/metadata/identity/oauth2/token
              ?api-version=2018-02-01
              &resource=https://vault.azure.net
              Headers: Metadata: true
              │
              └── IMDS Azure (service interne — pas de NSG nécessaire)
                    │
                    └── Token JWT AAD
                          {
                            "oid": "<object_id_MI>",
                            "aud": "https://vault.azure.net",
                            "exp": 1740833800,
                            ...
                          }
                          │
                          └── Flask utilise le token pour appeler Key Vault
```

### Obtenir un Token Manuellement (diagnostic)

```bash
# Sur la VM Flask (via Bastion)
curl -s \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token\
?api-version=2018-02-01&resource=https://vault.azure.net" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('Token type :', d['token_type'])
print('Expires in :', d['expires_in'], 'secondes')
print('Token       :', d['access_token'][:60] + '...')
"
```

### L'IMDS ne Nécessite pas de Règle NSG

L'adresse `169.254.169.254` est une adresse link-local spéciale Azure.
Le trafic vers cette adresse ne passe pas par le NSG — aucune règle
n'est nécessaire pour autoriser les appels IMDS.

```
Règles NSG requises pour la MI :
  - Outbound HTTPS 443 → AzureActiveDirectory  (login.microsoftonline.com)
  - Outbound HTTPS 443 → snet-pe               (Private Endpoint Key Vault)

Règle NSG NON requise :
  - 169.254.169.254                            (IMDS — link-local Azure)
```

---

## RBAC — Rôles Attribués dans Phase 8C

### VM Flask — Rôles

```
Managed Identity (VM Flask)
  └── Key Vault Secrets User
        scope : /subscriptions/.../resourceGroups/rg-phase8c-{env}/
                  providers/Microsoft.KeyVault/vaults/phase8c-{env}-kv
```

La MI de la VM Flask a **uniquement** le rôle `Key Vault Secrets User`
sur le Key Vault de son environnement. Elle lit les deux secrets :

- `servicebus-connection-string`
- `eventhub-connection-string`

Elle n'a **pas** d'accès direct à Service Bus ni à Event Hub via RBAC.
L'accès aux services de messagerie passe par les connection strings
stockés dans Key Vault — une seule surface d'attaque à gérer.

### VM Monitoring — Rôles

```
Managed Identity (VM Monitoring)
  └── Monitoring Metrics Publisher
        scope : /subscriptions/.../resourceGroups/rg-phase8c-{env}
```

Le rôle `Monitoring Metrics Publisher` permet à la VM Monitoring
d'envoyer des métriques personnalisées vers Azure Monitor.
Cela n'est pas utilisé directement dans Phase 8C (les métriques
passent par Pushgateway), mais c'est une bonne pratique de l'attribuer.

### Terraform — Attribution RBAC

```hcl
resource "azurerm_role_assignment" "vm_app_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.vm_app_identity_principal_id
}

resource "azurerm_role_assignment" "vm_monitoring_metrics_publisher" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = var.vm_monitoring_identity_principal_id
}
```

---

## Managed Identity et Key Vault

Flask lit Key Vault **au démarrage** pour récupérer les connection strings.
Ce flux se produit une seule fois — les connection strings sont mis en
cache en mémoire pour la durée de vie du processus.

```
DÉMARRAGE FLASK
  │
  └── 1. Lire KEY_VAULT_URL depuis la variable d'environnement systemd
  │
  └── 2. ManagedIdentityCredential()
  │
  └── 3. IMDS → Token AAD (scope : vault.azure.net)
  │
  └── 4. SecretClient(vault_url=KEY_VAULT_URL, credential=credential)
  │
  └── 5. client.get_secret("servicebus-connection-string")
  │         → HTTP GET https://phase8c-dev-kv.vault.azure.net/secrets/...
  │         → Authorization: Bearer <token>
  │         → 200 OK { "value": "Endpoint=sb://..." }
  │
  └── 6. client.get_secret("eventhub-connection-string")
  │
  └── 7. ServiceBusClient.from_connection_string(sb_conn_str)
  │
  └── 8. EventHubProducerClient.from_connection_string(eh_conn_str)
  │
  └── 9. Flask démarre et accepte les requêtes
```

Si l'une de ces étapes échoue, Flask s'arrête immédiatement.
`journalctl -u flask-app` indique l'étape en erreur.

---

## Managed Identity et Service Bus / Event Hub

Dans Phase 8C, la MI n'a pas de rôle RBAC direct sur Service Bus
ni Event Hub. L'accès passe par les connection strings dans Key Vault.

### Pourquoi ne pas utiliser RBAC Direct sur Service Bus ?

Il serait possible d'attribuer le rôle `Azure Service Bus Data Owner`
à la MI et d'utiliser `DefaultAzureCredential` ou
`ManagedIdentityCredential` directement pour les connexions Service Bus.

Cependant, le pattern Key Vault → connection string est utilisé car :

```
1. Unified secret management  Un seul endroit (Key Vault) pour gérer
                              tous les accès — facile à auditer et à révoquer

2. Flexibilité                La connection string peut être remplacée
                              sans changer le RBAC ni le code Flask

3. Compatibilité              Les SDK Service Bus et Event Hub supportent
                              les connection strings de manière uniforme
                              quelle que soit la version
```

### Si l'on voulait utiliser RBAC Direct (non utilisé dans Phase 8C)

```python
# Connexion directe via Managed Identity (sans connection string)
from azure.identity import ManagedIdentityCredential
from azure.servicebus import ServiceBusClient

credential = ManagedIdentityCredential()
client = ServiceBusClient(
    fully_qualified_namespace="sbns-phase8c-dev.servicebus.windows.net",
    credential=credential
)

# Rôle requis : Azure Service Bus Data Owner (ou Data Sender/Receiver)
# sur le namespace ou la queue/topic spécifique
```

---

## Dans notre Phase 8C

### Ressources Terraform Déployées

```
azurerm_linux_virtual_machine.app
  └── identity.type = "SystemAssigned"
  └── identity[0].principal_id → référencé dans les attributions RBAC

azurerm_linux_virtual_machine.monitoring
  └── identity.type = "SystemAssigned"

azurerm_role_assignment.vm_app_kv_secrets_user
  role    = "Key Vault Secrets User"
  scope   = Key Vault de l'environnement
  principal = VM Flask MI

azurerm_role_assignment.vm_monitoring_metrics_publisher
  role    = "Monitoring Metrics Publisher"
  scope   = Resource Group de l'environnement
  principal = VM Monitoring MI
```

### Variable d'Environnement systemd

Flask reçoit l'URL du Key Vault via une variable d'environnement
injectée dans le service systemd par cloud-init :

```ini
# /etc/systemd/system/flask-app.service
[Service]
Environment="KEY_VAULT_URL=https://phase8c-dev-kv.vault.azure.net/"
ExecStart=/opt/flask-app/venv/bin/gunicorn ...
```

Cette URL est la seule information sensible injectée par Terraform.
Les connection strings elles-mêmes ne transitent jamais par le code
Terraform ni par les variables TFC.

### Points Clés à Retenir

- `ManagedIdentityCredential()` dans le code Python — **aucun secret**
  dans le code source, jamais de clé hardcodée
- L'IMDS (`169.254.169.254`) ne nécessite **aucune règle NSG** —
  c'est une adresse link-local Azure traitée en dehors du plan de données
- Flask lit Key Vault **au démarrage uniquement** — si KEY_VAULT_URL
  est absent ou le RBAC incorrect, Flask s'arrête avant de démarrer
- La MI a le **principe du moindre privilège** : uniquement
  `Key Vault Secrets User` sur le KV de son environnement
- Un changement de RBAC prend **quelques minutes** à se propager —
  redémarrer Flask après attribution d'un nouveau rôle si le rôle
  n'est pas encore visible
- `vm_identity_principal_id` dans les outputs TFC permet de vérifier
  que la VM a bien été recréée avec la nouvelle identité après
  un `taint` ou une modification de la VM

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
