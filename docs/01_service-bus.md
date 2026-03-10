# Azure Service Bus

Introduction à Azure Service Bus — son modèle de messagerie,
les namespaces, queues, topics et subscriptions, les SKUs disponibles,
la structure des messages et son intégration dans une architecture
zero-trust avec Private Endpoint et Managed Identity.

---

## Table des Matières

1. [Qu'est-ce qu'Azure Service Bus](#quest-ce-quazure-service-bus)
2. [Namespace et Hiérarchie des Ressources](#namespace-et-hiérarchie-des-ressources)
3. [SKUs — Basic, Standard, Premium](#skus--basic-standard-premium)
4. [Queues](#queues)
5. [Topics et Subscriptions](#topics-et-subscriptions)
6. [Structure d'un Message](#structure-dun-message)
7. [Modes de Réception](#modes-de-réception)
8. [Dead-Letter Queue](#dead-letter-queue)
9. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Qu'est-ce qu'Azure Service Bus

Azure Service Bus est un service de messagerie cloud entièrement managé
qui permet à des applications de communiquer de manière asynchrone et
découplée. Les producteurs envoient des messages sans attendre que les
consommateurs soient disponibles. Les consommateurs lisent les messages
quand ils sont prêts.

Ce modèle résout plusieurs problèmes d'architecture :

```
Sans Service Bus (couplage direct) :
  Producteur ──► Consommateur   Si le consommateur est indisponible,
                                le message est perdu et le producteur
                                doit gérer l'erreur.

Avec Service Bus (découplage) :
  Producteur ──► [ Service Bus ] ──► Consommateur
                  (persistance)      Peut traiter quand disponible.
                                     Pas de perte de message.
```

Azure Service Bus garantit la livraison des messages et supporte
des patterns avancés : publication/abonnement, filtrage par SQL,
sessions pour l'ordre garanti, et dead-letter pour les messages
en erreur.

---

## Namespace et Hiérarchie des Ressources

Le namespace est le conteneur de plus haut niveau. Il définit
le point de terminaison réseau, le SKU et les paramètres globaux.

```
Namespace Service Bus (sbns-phase8c-{env})
  ├── Queue : orders
  │   └── Dead-Letter : orders/$DeadLetterQueue  (auto-créée par Azure)
  └── Topic : events
      ├── Subscription : sub-logs    (tous les messages)
      └── Subscription : sub-alerts  (filtre SQL : level = 'critical')
```

**Namespace** — ressource Azure facturée. Contient toutes les entités
de messagerie. Le FQDN du namespace est :
`{namespace}.servicebus.windows.net`

**Queue** — canal point-à-point. Un message envoyé est reçu par
un seul consommateur. Adapté aux tâches à traiter une seule fois
(commandes, jobs).

**Topic** — canal publication/abonnement. Un message publié est reçu
par tous les abonnements actifs. Adapté aux événements broadcast
(logs, notifications, audits).

**Subscription** — vue filtrée d'un topic. Chaque subscription
maintient sa propre file d'attente de messages. Un filtre SQL
peut limiter les messages reçus selon leurs propriétés.

---

## SKUs — Basic, Standard, Premium

```
SKU       Queues  Topics  Subscriptions  PE  local_auth
--------  ------  ------  -------------  --  ----------
Basic     oui     non     non            non  oui
Standard  oui     oui     oui            non  oui
Premium   oui     oui     oui            oui  configurable
```

**Basic** — uniquement des queues. Pas de topics ni de subscriptions.
Adapté aux cas d'usage simples sans publication/abonnement.

**Standard** — queues et topics. Pas de Private Endpoints.
Le trafic réseau passe par les endpoints publics de Service Bus
(protégés par authentification AAD ou SAS).

**Premium** — même fonctionnalités que Standard avec en plus :
Private Endpoints pour l'isolation réseau complète, débit dédié
(Messaging Units), taille de message jusqu'à 100 Mo.

Dans Phase 8C, dev et staging utilisent **Standard** — les topics
et subscriptions sont nécessaires pour le pattern pub/sub.
Prod utilise **Premium** pour les Private Endpoints zero-trust.

Note importante : en Standard, l'isolation réseau se fait via
`public_network_access_enabled = false` avec authentification
AAD obligatoire (`local_auth_enabled = false`). Sans Private Endpoint,
les connexions passent par les IPs publiques de Service Bus mais
sont protégées par le token Managed Identity.

---

## Queues

Une queue est une file d'attente FIFO (First In, First Out) avec
des garanties de livraison au moins une fois (at-least-once delivery).

### Cycle de Vie d'un Message

```
Producteur
  └── send()
        └── [ Queue ]
              ├── État : Active      Le message attend d'être consommé
              │
              ├── receive_mode=PEEK_LOCK
              │     └── Message verrouillé pour le consommateur
              │           ├── complete()    → message supprimé de la queue
              │           ├── abandon()     → message remis dans la queue
              │           └── dead_letter() → message déplacé dans la DLQ
              │
              └── Expiration (max_delivery_count dépassé)
                    └── [ Dead-Letter Queue ]
```

### Paramètres Importants

```
max_delivery_count    Nombre max de tentatives de livraison avant
                      que le message parte en Dead-Letter Queue.
                      Valeur dans Phase 8C : 10

lock_duration         Durée pendant laquelle un message est verrouillé
                      pour un consommateur (mode PEEK_LOCK).
                      Valeur dans Phase 8C : PT1M (1 minute)

message_ttl           Durée de vie maximale d'un message dans la queue
                      avant suppression automatique.
                      Valeur dans Phase 8C : P14D (14 jours)

dead_lettering_on_message_expiration
                      Si true, les messages expirés vont en DLQ
                      plutôt qu'être silencieusement supprimés.
```

### Exemple Python (SDK azure-servicebus)

```python
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.identity import ManagedIdentityCredential

# Connexion via connection string (lue depuis Key Vault)
client = ServiceBusClient.from_connection_string(connection_str)

# Envoyer un message
with client.get_queue_sender("orders") as sender:
    msg = ServiceBusMessage(
        body=json.dumps({"order_id": "123", "product": "laptop"}),
        content_type="application/json"
    )
    sender.send_messages(msg)

# Recevoir un message (PEEK_LOCK — mode par défaut)
with client.get_queue_receiver("orders", max_wait_time=5) as receiver:
    for msg in receiver:
        try:
            data = json.loads(str(msg))
            # traitement...
            receiver.complete_message(msg)   # acquittement
        except Exception:
            receiver.dead_letter_message(msg, reason="ProcessingError")
```

---

## Topics et Subscriptions

Un topic permet la diffusion d'un message vers plusieurs abonnements
simultanément. Chaque abonnement maintient sa propre copie des messages.

### Flux de Publication

```
Producteur
  └── publish() vers topic "events"
        └── [ Topic : events ]
              ├── [ sub-logs ]    (filtre : aucun — tous les messages)
              │     └── copie du message
              └── [ sub-alerts ]  (filtre SQL : level = 'critical')
                    └── copie du message (seulement si level = 'critical')
```

Un message publié avec `level = 'info'` est reçu uniquement par
`sub-logs`. Un message avec `level = 'critical'` est reçu par
`sub-logs` ET `sub-alerts`.

### Filtres SQL

Les filtres SQL s'appliquent sur les `application_properties`
du message — les métadonnées, pas le corps.

```python
# Publier avec des application_properties
msg = ServiceBusMessage(
    body=json.dumps({"event": "payment-failed", "order_id": "456"}),
    application_properties={"level": "critical", "source": "payment-service"}
)
topic_sender.send_messages(msg)
```

```
Filtre sub-alerts : level = 'critical'

Ce filtre correspond si application_properties['level'] == 'critical'
Il ne lit pas le corps du message (body) — uniquement les propriétés.
```

### Types de Filtres Disponibles

```
SQL Filter    Filtre sur les propriétés du message avec syntaxe SQL simplifiée
              Exemples :
                level = 'critical'
                priority > 5
                level IN ('critical', 'error')

Boolean Rule  True  → tous les messages (comportement de sub-logs)
              False → aucun message

Correlation   Filtre sur ContentType, Label, MessageId, ReplyTo,
              ReplyToSessionId, SessionId, To, ou propriétés custom.
              Plus performant que SQL pour les filtrages simples.
```

### Exemple Python — Lire depuis une Subscription

```python
# Lire depuis sub-logs (tous les messages)
with client.get_subscription_receiver(
    topic_name="events",
    subscription_name="sub-logs",
    max_wait_time=5
) as receiver:
    for msg in receiver:
        data = json.loads(str(msg))
        props = msg.application_properties or {}
        print(f"Event: {data}, Level: {props.get('level')}")
        receiver.complete_message(msg)
```

---

## Structure d'un Message

Un message Service Bus est composé de deux parties :

```
Message
  ├── body                  Corps du message (bytes ou string)
  │                         Dans Phase 8C : JSON sérialisé en UTF-8
  │
  └── system_properties     Métadonnées gérées par Service Bus
        ├── message_id       Identifiant unique (auto-généré si absent)
        ├── sequence_number  Numéro de séquence immuable (attribué par SB)
        ├── enqueued_time    Heure d'entrée dans la queue
        ├── locked_until     Heure d'expiration du verrou (PEEK_LOCK)
        ├── delivery_count   Nombre de tentatives de livraison
        └── dead_letter_reason  Raison du transfert en DLQ (si applicable)

  └── application_properties  Propriétés custom (dict clé/valeur)
        Exemples :
          {"level": "critical", "source": "payment-service"}
        Utilisées par les filtres SQL des subscriptions.
```

---

## Modes de Réception

### PEEK_LOCK (recommandé — par défaut)

Le message est verrouillé pendant la durée `lock_duration`.
Le consommateur doit acquitter explicitement. Si l'acquittement
n'arrive pas avant l'expiration du verrou, le message est remis
dans la queue et relivré.

```
Avantage    : garantie at-least-once — si le traitement échoue,
              le message est relivré automatiquement
Inconvénient : nécessite un acquittement explicite (complete/abandon/dead_letter)
```

### RECEIVE_AND_DELETE

Le message est supprimé dès réception, sans acquittement.

```
Avantage    : plus simple, moins de code
Inconvénient : si le consommateur plante après réception et avant
               traitement, le message est perdu (at-most-once)
```

Dans Phase 8C, le mode **PEEK_LOCK** est utilisé partout — la
fiabilité prime sur la simplicité.

---

## Dead-Letter Queue

La Dead-Letter Queue (DLQ) est une queue secondaire associée
automatiquement à chaque queue et subscription par Azure Service Bus.
Elle stocke les messages qui n'ont pas pu être traités.

### Raisons de Transfert vers la DLQ

```
max_delivery_count dépassé      Le message a échoué N fois (N = 10 dans Phase 8C)
dead_letter_message() explicite Le consommateur a décidé que le message est invalide
Message expiré (si configuré)   TTL du message dépassé dans la queue
Filtre subscription invalide    Impossible d'évaluer le filtre SQL
```

### Chemin d'Accès à la DLQ

```
Queue orders :
  orders/$DeadLetterQueue

Subscription sub-logs :
  events/subscriptions/sub-logs/$DeadLetterQueue
```

### Retraitement des Messages en DLQ

Le pattern standard est :

1. Lire le message depuis la DLQ
2. Analyser la raison de l'échec (`dead_letter_reason`)
3. Corriger si possible
4. Renvoyer dans la queue principale

```python
# Lire depuis la DLQ de la queue orders
with client.get_queue_receiver(
    "orders",
    sub_queue=ServiceBusSubQueue.DEAD_LETTER,
    max_wait_time=5
) as dlq_receiver:
    for msg in dlq_receiver:
        reason = msg.dead_letter_reason
        print(f"DLQ message — raison : {reason}")
        dlq_receiver.complete_message(msg)   # supprimer de la DLQ
        # optionnel : renvoyer dans la queue principale
```

---

## Dans notre Phase 8C

### Ressources Terraform Déployées

```
azurerm_servicebus_namespace.main          (sbns-phase8c-{env})
  ├── azurerm_servicebus_queue.orders      (orders)
  ├── azurerm_servicebus_topic.events      (events)
  │     ├── azurerm_servicebus_subscription.sub_logs    (sub-logs)
  │     └── azurerm_servicebus_subscription.sub_alerts  (sub-alerts)
  │           └── azurerm_servicebus_subscription_rule.alert_filter
  │
  ├── azurerm_private_endpoint.servicebus          (dev/staging : absent, prod : PE)
  ├── azurerm_private_dns_zone_virtual_network_link  (prod uniquement)
  └── azurerm_monitor_diagnostic_setting.servicebus
```

Note : en dev et staging (SKU Standard), les Private Endpoints ne sont
pas disponibles. L'isolation réseau repose sur `local_auth_enabled = false`
(authentification AAD uniquement) et `public_network_access_enabled = false`.
TFC et Flask accèdent au namespace via le réseau public avec un token
Managed Identity — pas de SAS keys.

En prod (SKU Premium), le Private Endpoint est créé dans `snet-pe` et
la zone DNS privée `privatelink.servicebus.windows.net` est utilisée.

### Nommage des Ressources

```
Namespace      : sbns-phase8c-{env}
Queue          : orders
Topic          : events
Subscription 1 : sub-logs
Subscription 2 : sub-alerts
PE (prod)      : pe-servicebus-phase8c-prod
Zone DNS       : privatelink.servicebus.windows.net
```

### Accès Zero-Trust

```
1. local_auth_enabled = false      SAS keys désactivées — AAD uniquement
2. public_network_access disabled  Pas d'accès depuis Internet non authentifié
3. Managed Identity → Key Vault    Flask lit la connection string depuis KV
4. connection string dans KV        Secrets jamais dans le code ni dans TFC
5. prod : Private Endpoint          Trafic uniquement via snet-pe (IP privée)
```

### Flux dans Phase 8C

```
Flask app (snet-app)
  ├── POST /send       → ServiceBusClient → Queue orders
  ├── GET  /receive    → ServiceBusClient ← Queue orders (PEEK_LOCK)
  ├── GET  /dlq        → ServiceBusClient ← orders/$DeadLetterQueue
  ├── POST /publish    → ServiceBusClient → Topic events
  │                          └── sub-logs (tous)
  │                          └── sub-alerts (level = 'critical' uniquement)
  └── GET  /subscribe/{sub} → ServiceBusClient ← sub-logs ou sub-alerts
```

### Points Clés à Retenir

- Le SKU Basic ne supporte pas les topics — **Standard minimum obligatoire**
  si l'architecture nécessite du pub/sub
- Les filtres SQL s'appliquent sur les `application_properties`,
  pas sur le corps du message — la propriété `level` doit être passée
  dans `application_properties`, pas dans le JSON du body
- Le mode **PEEK_LOCK** garantit at-least-once delivery — préférer ce mode
  en production pour éviter la perte de messages
- `max_delivery_count = 10` avant transfert en DLQ — surveiller la DLQ
  pour détecter les messages en erreur récurrente
- En SKU Standard, `public_network_access_enabled = false` avec
  `local_auth_enabled = false` assure que seuls les tokens AAD valides
  peuvent accéder au namespace — sans Private Endpoint mais avec une
  sécurité d'authentification forte
- La zone DNS `privatelink.servicebus.windows.net` est **partagée**
  entre Service Bus et Event Hub — un seul enregistrement DNS suffit
  pour les deux namespaces

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
