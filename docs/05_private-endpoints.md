# Private Endpoints

Guide sur les Private Endpoints dans Phase 8C — comment ils isolent
Service Bus, Event Hub et Key Vault dans le réseau privé Azure,
le rôle des zones DNS privées, et les différences de comportement
entre les SKUs Standard et Premium de Service Bus et Event Hub.

---

## Table des Matières

1. [Qu'est-ce qu'un Private Endpoint](#quest-ce-quun-private-endpoint)
2. [Zones DNS Privées](#zones-dns-privées)
3. [Service Bus et Event Hub — Particularité de la Zone DNS](#service-bus-et-event-hub--particularité-de-la-zone-dns)
4. [Private Endpoints et SKUs](#private-endpoints-et-skus)
5. [Flux Réseau dans Phase 8C](#flux-réseau-dans-phase-8c)
6. [Vérification de l'Isolation Réseau](#vérification-de-lisolation-réseau)
7. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Qu'est-ce qu'un Private Endpoint

Un Private Endpoint est une interface réseau dans un subnet VNet
qui expose un service Azure PaaS (Service Bus, Event Hub, Key Vault...)
sur une adresse IP privée. Le trafic vers ce service ne quitte jamais
le réseau Azure privé.

```
Sans Private Endpoint :
  VM Flask (10.0.1.4)
    └── → résolution DNS → sbns-phase8c-prod.servicebus.windows.net
              → IP publique Azure (52.x.x.x)
              → Internet (trafic sort du VNet)
              → Service Bus

Avec Private Endpoint :
  VM Flask (10.0.1.4)
    └── → résolution DNS → sbns-phase8c-prod.servicebus.windows.net
              → IP privée (10.0.3.4) dans snet-pe
              → Private Endpoint → Service Bus
              (trafic reste dans le VNet — jamais sur Internet)
```

### Bénéfices

```
Isolation réseau      Le service PaaS n'est accessible que depuis le VNet
                      (et les VNets peering si configurés)

Pas d'IP publique     Même avec public_network_access = Disabled,
sur le service        le Private Endpoint fonctionne via IP privée

NSG sur snet-pe       Les règles NSG contrôlent qui peut accéder
                      au Private Endpoint depuis quels subnets

Audit réseau          Le trafic est visible dans les logs Azure Monitor
                      avec les IPs privées source et destination
```

---

## Zones DNS Privées

Un Private Endpoint seul ne suffit pas. Sans zone DNS privée,
la résolution du FQDN du service retourne toujours l'IP publique
Azure — même si le service est accessible en privé.

```
Sans zone DNS privée (configuration incomplète) :
  nslookup sbns-phase8c-prod.servicebus.windows.net
  → 52.x.x.x  (IP publique — connexion rejetée car public_network_access = Disabled)

Avec zone DNS privée et VNet link :
  nslookup sbns-phase8c-prod.servicebus.windows.net
  → sbns-phase8c-prod.privatelink.servicebus.windows.net → 10.0.3.4
  (IP privée du Private Endpoint — connexion acceptée)
```

### Mécanisme de Résolution

```
1. VM Flask demande la résolution de sbns-phase8c-prod.servicebus.windows.net
2. Azure DNS resolver (168.63.129.16) consulte les zones DNS privées
   liées au VNet
3. Zone privée privatelink.servicebus.windows.net trouvée
4. Enregistrement A : sbns-phase8c-prod → 10.0.3.4
5. VM Flask se connecte à 10.0.3.4 (Private Endpoint dans snet-pe)
6. Private Endpoint route le trafic vers Service Bus
```

### Terraform — Zone DNS et Lien VNet

```hcl
resource "azurerm_private_dns_zone" "servicebus" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "servicebus" {
  name                  = "link-servicebus-${var.environment}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.servicebus.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}
```

---

## Service Bus et Event Hub — Particularité de la Zone DNS

Service Bus et Event Hub utilisent **la même zone DNS privée** :
`privatelink.servicebus.windows.net`

C'est une particularité importante qui évite de créer deux zones DNS
distinctes pour deux services différents.

```
Zone DNS privée unique :
  privatelink.servicebus.windows.net
    ├── sbns-phase8c-prod.servicebus.windows.net → 10.0.3.4  (Service Bus)
    └── evhns-phase8c-prod.servicebus.windows.net → 10.0.3.5 (Event Hub)
```

Cette zone est créée une seule fois et associée au VNet. Les enregistrements
DNS sont créés automatiquement lors de la création des Private Endpoints.

```hcl
# Un seul Private Endpoint resource pour Service Bus
resource "azurerm_private_endpoint" "servicebus" {
  name                = "pe-servicebus-phase8c-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.subnet_pe_id

  private_service_connection {
    name                           = "psc-servicebus"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-servicebus"
    private_dns_zone_ids = [azurerm_private_dns_zone.servicebus.id]
  }
}

# Même zone DNS pour Event Hub — juste un deuxième PE
resource "azurerm_private_endpoint" "eventhub" {
  name                = "pe-eventhub-phase8c-${var.environment}"
  ...
  private_dns_zone_group {
    name                 = "dns-eventhub"
    private_dns_zone_ids = [azurerm_private_dns_zone.servicebus.id]  # même zone
  }
}
```

---

## Private Endpoints et SKUs

### Service Bus

```
SKU Standard  → Private Endpoint non disponible
               Isolation via public_network_access_enabled = false
               + local_auth_enabled = false (AAD uniquement)

SKU Premium   → Private Endpoint disponible
               Isolation complète dans snet-pe
               Trafic uniquement via IP privée
```

### Event Hub

```
SKU Basic     → Private Endpoint non disponible
SKU Standard  → Private Endpoint non disponible
               Isolation via public_network_access_enabled = false
SKU Premium   → Private Endpoint disponible
```

### Stratégie dans Phase 8C

```
Environnement  Service Bus  Event Hub  Private Endpoints
-------------  -----------  ---------  -----------------
dev            Standard     Standard   Non (pas disponible)
staging        Standard     Standard   Non (pas disponible)
prod           Premium      Standard   Oui (Service Bus), Non (Event Hub)
```

En dev et staging, l'isolation repose sur :

- `public_network_access_enabled = false`
- `local_auth_enabled = false` (Service Bus Standard uniquement)
- Authentification AAD via Managed Identity

Le trafic passe par les IPs publiques Azure Service Bus mais
avec un token AAD valide — la sécurité d'authentification est forte
même sans isolation réseau complète.

---

## Flux Réseau dans Phase 8C

### Environnement dev/staging (sans PE)

```
VM Flask (snet-app : 10.0.1.4)
  │
  ├── DNS : sbns-phase8c-dev.servicebus.windows.net
  │           → IP publique Azure (52.x.x.x)
  │           → NSG outbound HTTPS 443 → Internet (autorisé)
  │           → Service Bus (authentification AAD — token MI valide)
  │
  ├── DNS : evhns-phase8c-dev.servicebus.windows.net
  │           → IP publique Azure
  │           → Event Hub (authentification AAD — token MI valide)
  │
  └── DNS : phase8c-dev-kv.vault.azure.net
              → IP privée (10.0.3.6 — PE Key Vault dans snet-pe)
              → Key Vault (RBAC — Key Vault Secrets User)
```

Note : Key Vault a `public_network_access_enabled = true` pour
permettre à TFC de provisionner les secrets. L'accès est protégé
par RBAC — seule la Managed Identity a le rôle `Key Vault Secrets User`.

### Environnement prod (avec PE Service Bus)

```
VM Flask (snet-app : 10.2.1.4)
  │
  ├── DNS : sbns-phase8c-prod.servicebus.windows.net
  │           → IP privée (10.2.3.4 — PE Service Bus dans snet-pe)
  │           → NSG snet-pe inbound HTTPS 443 depuis snet-app (autorisé)
  │           → Service Bus (token MI valide)
  │
  ├── DNS : evhns-phase8c-prod.servicebus.windows.net
  │           → IP publique Azure (PE non disponible en Standard)
  │           → Event Hub (token MI valide)
  │
  └── DNS : phase8c-prod-kv.vault.azure.net
              → IP privée (10.2.3.6 — PE Key Vault dans snet-pe)
              → Key Vault (RBAC — Key Vault Secrets User)
```

---

## Vérification de l'Isolation Réseau

### Vérifier la Résolution DNS depuis la VM

```bash
# Sur la VM Flask (via Bastion)

# Service Bus — dev/staging : IP publique attendue
#             — prod : IP privée (10.x.3.x) attendue
dig sbns-phase8c-dev.servicebus.windows.net +short

# Event Hub — IP publique attendue (Standard en dev/staging/prod)
dig evhns-phase8c-dev.servicebus.windows.net +short

# Key Vault — IP privée (10.x.3.x) attendue dans tous les environnements
dig phase8c-dev-kv.vault.azure.net +short
```

### Vérifier les Private Endpoints via Azure CLI

```bash
# Lister les Private Endpoints dans le resource group
az network private-endpoint list \
  --resource-group rg-phase8c-prod \
  --query "[].{Nom:name, Etat:provisioningState, Subnet:subnet.id}" \
  --output table

# Vérifier la connexion d'un PE
az network private-endpoint show \
  --resource-group rg-phase8c-prod \
  --name pe-servicebus-phase8c-prod \
  --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState" \
  --output json
```

Résultat attendu :

```json
{
  "actionsRequired": "None",
  "description": "Auto-approved",
  "status": "Approved"
}
```

### Vérifier les Zones DNS Privées

```bash
# Lister les zones DNS privées
az network private-dns zone list \
  --resource-group rg-phase8c-prod \
  --query "[].name" \
  --output table

# Lister les enregistrements de la zone servicebus
az network private-dns record-set a list \
  --resource-group rg-phase8c-prod \
  --zone-name "privatelink.servicebus.windows.net" \
  --output table
```

---

## Dans notre Phase 8C

### Private Endpoints Déployés

```
dev/staging :
  pe-kv-phase8c-{env}           privatelink.vaultcore.azure.net

prod :
  pe-servicebus-phase8c-prod    privatelink.servicebus.windows.net
  pe-kv-phase8c-prod            privatelink.vaultcore.azure.net
```

### Zones DNS Privées

```
privatelink.servicebus.windows.net    Service Bus + Event Hub (partagée)
privatelink.vaultcore.azure.net       Key Vault
```

### NSG snet-pe (prod)

```
Règle inbound 100  : Allow snet-app  → snet-pe TCP 443    (Service Bus + KV)
Règle inbound 4096 : Deny All Inbound
```

### Points Clés à Retenir

- Service Bus **Standard** et Event Hub **Standard** ne supportent pas
  les Private Endpoints — l'isolation en dev/staging repose sur AAD
  uniquement
- Service Bus et Event Hub **partagent** la même zone DNS privée
  `privatelink.servicebus.windows.net` — créer la zone une seule fois
- Sans le **VNet link** sur la zone DNS, la résolution retourne l'IP
  publique même si le Private Endpoint est créé — les deux ressources
  sont indispensables
- `private_endpoint_network_policies = "Enabled"` sur `snet-pe` est
  nécessaire pour que les règles NSG s'appliquent aux Private Endpoints
  dans ce subnet
- Key Vault a `public_network_access_enabled = true` dans tous les
  environnements pour permettre à TFC de provisionner les secrets —
  l'accès est protégé par RBAC, pas par isolation réseau

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
