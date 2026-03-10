# Queues, Topics et Subscriptions

Guide comparatif des trois entités de messagerie Azure Service Bus —
patterns d'usage, différences architecturales, et mise en œuvre
dans Phase 8C avec la queue orders, le topic events et les
subscriptions sub-logs et sub-alerts.

---

## Table des Matières

1. [Les Trois Entités](#les-trois-entités)
2. [Queue — Point à Point](#queue--point-à-point)
3. [Topic — Publication / Abonnement](#topic--publication--abonnement)
4. [Subscription — Vue Filtrée d'un Topic](#subscription--vue-filtrée-dun-topic)
5. [Comparaison des Patterns](#comparaison-des-patterns)
6. [Filtres de Subscription](#filtres-de-subscription)
7. [Ordering et Sessions](#ordering-et-sessions)
8. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Les Trois Entités

Azure Service Bus organise la messagerie autour de trois entités
complémentaires. Choisir la bonne entité pour chaque usage est
la décision architecturale la plus importante.

```
Queue
  Un producteur → [ File d'attente ] → Un consommateur
  Usage : traitement de tâches, commandes, jobs

Topic
  Un producteur → [ Sujet ] → Subscription A → Consommateur A
                             → Subscription B → Consommateur B
  Usage : diffusion d'événements vers plusieurs consommateurs

Subscription
  Vue filtrée d'un topic, se comporte comme une queue pour le consommateur
  Chaque subscription maintient sa propre file de messages filtrés
```

Les queues et les subscriptions se comportent de manière identique
du point de vue du consommateur — la différence est dans la source
des messages (envoi direct vs publication sur topic).

---

## Queue — Point à Point

Une queue implémente le pattern **competing consumers** : plusieurs
consommateurs peuvent écouter la même queue, mais chaque message est
livré à **un seul** consommateur. Les consommateurs se partagent la charge.

```
Producteur
  └── send("order-123")
        └── [ Queue : orders ]
              ├── Consommateur A reçoit "order-123" → traite → complete()
              │   (le message est supprimé)
              └── Consommateur B n'a pas reçu "order-123"
                  (il reçoit le prochain message disponible)
```

### Cas d'Usage Typiques

```
Traitement de commandes    Chaque commande traitée une seule fois
Jobs asynchrones           Envoyer une tâche sans attendre le résultat
File de travaux            Distribuer la charge entre plusieurs workers
Communication RPC async    Envoyer une requête et attendre la réponse
                           dans une reply queue dédiée
```

### Garanties

```
At-least-once delivery    Un message est livré au moins une fois.
                          Si le traitement échoue (pas de complete()),
                          le message est relivré après lock_duration.

Exactly-once delivery     Possible avec les sessions Service Bus.
                          Non utilisé dans Phase 8C.

FIFO                      L'ordre est respecté dans la queue.
                          Non garanti si plusieurs consommateurs parallèles
                          consomment simultanément (race condition).
```

---

## Topic — Publication / Abonnement

Un topic implémente le pattern **publish-subscribe** : un message
publié sur le topic est copié dans **toutes les subscriptions actives**
qui passent les filtres. Chaque subscription reçoit sa propre copie.

```
Producteur
  └── publish({"event": "payment-failed", "level": "critical"})
        └── [ Topic : events ]
              ├── [ sub-logs ]    filtre : aucun → copie reçue
              │     └── Consommateur Log : enregistre l'événement
              └── [ sub-alerts ]  filtre : level = 'critical' → copie reçue
                    └── Consommateur Alert : envoie une notification
```

### Cas d'Usage Typiques

```
Notifications broadcast    Informer tous les services abonnés d'un événement
Audit logging              Enregistrer tous les événements dans une log store
Alertes conditionnelles    Déclencher des alertes uniquement sur certains niveaux
Fan-out                    Distribuer un événement vers N systèmes simultanément
CQRS                       Séparer les commandes des événements de lecture
```

### Indépendance des Subscriptions

Chaque subscription est totalement indépendante :

- Son propre compteur de messages
- Sa propre dead-letter queue
- Ses propres paramètres (max_delivery_count, lock_duration)
- Son propre ensemble de consommateurs

La vitesse ou les échecs dans une subscription n'affectent pas
les autres subscriptions du même topic.

---

## Subscription — Vue Filtrée d'un Topic

Une subscription est associée à un topic et se comporte exactement
comme une queue pour le consommateur. Elle maintient sa propre file
de messages qui ont passé le filtre.

```
Topic events
  └── Subscription sub-logs
        ├── Filtre : True (tous les messages)
        ├── max_delivery_count : 10
        ├── lock_duration : PT1M
        └── File interne : [evt1, evt2, evt3, ...]  (copie des messages du topic)
```

### Création en Terraform

```hcl
resource "azurerm_servicebus_subscription" "sub_logs" {
  name                                 = "sub-logs"
  topic_id                             = azurerm_servicebus_topic.events.id
  max_delivery_count                   = 10
  dead_lettering_on_message_expiration = true
  lock_duration                        = "PT1M"
}

resource "azurerm_servicebus_subscription" "sub_alerts" {
  name                                 = "sub-alerts"
  topic_id                             = azurerm_servicebus_topic.events.id
  max_delivery_count                   = 10
  dead_lettering_on_message_expiration = true
  lock_duration                        = "PT1M"
}
```

---

## Comparaison des Patterns

```
Critère                     Queue                Topic + Subscription
--------------------------  -------------------  ---------------------
Destinataires               Un seul              Tous les abonnements
Isolation entre lecteurs    Non (compétition)    Oui (copies séparées)
Filtrage                    Non                  Oui (SQL, Correlation)
Dead-Letter Queue           Oui                  Oui (par subscription)
Couplage producteur         Faible               Très faible
Ajout de consommateurs      Worker supplémentaire Nouvelle subscription
Exemple Phase 8C            Queue orders         Topic events + sub-logs
                                                 + sub-alerts
```

### Quand Utiliser une Queue

Le producteur connaît le type de traitement requis et les
consommateurs sont interchangeables (même logique de traitement).

```
Exemple :
  Service commandes → queue orders → worker de traitement
  N'importe quel worker peut traiter n'importe quelle commande.
  La queue distribue la charge automatiquement.
```

### Quand Utiliser un Topic

Un événement doit déclencher des traitements différents dans
des systèmes différents, sans couplage entre eux.

```
Exemple :
  Service paiement → topic events → sub-logs → LogStore
                                 → sub-alerts → AlertingService
                                 → sub-analytics → DataWarehouse
  Ajouter un nouveau consommateur = créer une nouvelle subscription.
  Le service paiement ne change pas.
```

---

## Filtres de Subscription

Un filtre de subscription détermine quels messages publiés sur le
topic sont copiés dans cette subscription. Le filtre s'applique sur
les `application_properties` du message.

### SQL Filter

Syntaxe SQL simplifiée. Supporte les opérateurs de comparaison,
les opérateurs logiques AND/OR/NOT, IN, LIKE, IS NULL.

```sql
-- sub-alerts : uniquement les messages critiques
level = 'critical'

-- Autres exemples de filtres SQL valides
level IN ('critical', 'error')
priority > 5
level = 'critical' AND source = 'payment-service'
NOT level = 'info'
```

### Boolean Filter

```
True  → tous les messages (comportement de sub-logs)
False → aucun message
```

Un filtre booléen `True` est équivalent à "pas de filtre" — tous
les messages publiés sur le topic sont copiés dans la subscription.

### Règle par Défaut

Toute subscription est créée avec une règle par défaut (`$Default`)
de type Boolean True — elle reçoit tous les messages.

Pour ajouter un filtre SQL (comme pour sub-alerts), il faut :

1. Supprimer la règle par défaut `$Default`
2. Créer une nouvelle règle avec le filtre SQL

```hcl
# Supprimer la règle par défaut (qui accepte tout)
resource "azurerm_servicebus_subscription_rule" "sub_alerts_default_delete" {
  # Note : en pratique on crée directement la règle SQL
  # sans passer par la suppression de $Default en Terraform
}

# Créer la règle SQL pour sub-alerts
resource "azurerm_servicebus_subscription_rule" "alert_filter" {
  name            = "CriticalOnly"
  subscription_id = azurerm_servicebus_subscription.sub_alerts.id
  filter_type     = "SqlFilter"
  sql_filter      = "level = 'critical'"
}
```

### Application des Filtres côté Producteur

Le producteur doit placer les propriétés filtrables dans
`application_properties`, pas dans le corps du message.

```python
# Correct — propriété dans application_properties
msg = ServiceBusMessage(
    body=json.dumps({"event": "payment-failed", "order_id": "456"}),
    application_properties={"level": "critical"}
)

# Incorrect — le filtre SQL ne peut pas lire le corps du message
msg = ServiceBusMessage(
    body=json.dumps({"event": "payment-failed", "level": "critical"})
)
# → sub-alerts ne recevra pas ce message malgré level = 'critical' dans le body
```

---

## Ordering et Sessions

Par défaut, Service Bus ne garantit pas l'ordre entre plusieurs
consommateurs d'une même queue. Pour garantir l'ordre FIFO strict,
il faut utiliser les **sessions**.

### Sessions Service Bus

Une session est un groupe logique de messages identifiés par un
même `session_id`. Tous les messages d'une session sont traités
par un seul consommateur à la fois, dans l'ordre d'arrivée.

```
Sans session :
  Consumer A reçoit message 1
  Consumer B reçoit message 2   → l'ordre de traitement n'est pas garanti
  Consumer A reçoit message 3

Avec session (session_id = "order-123") :
  Consumer A verrouille la session "order-123"
  Consumer A traite message 1, 2, 3 dans l'ordre
  Consumer B ne peut pas accéder à la session "order-123"
  → garantie FIFO pour cette session
```

Dans Phase 8C, les sessions ne sont pas utilisées — l'ordre strict
n'est pas nécessaire pour la queue orders ni pour le topic events.

---

## Dans notre Phase 8C

### Architecture de Messagerie

```
Flask app (snet-app)
  │
  ├── Queue orders
  │     ├── POST /send           → envoie une commande dans la queue
  │     ├── GET  /receive        → reçoit et traite une commande
  │     └── GET  /dlq            → lit les commandes en erreur
  │
  └── Topic events
        ├── POST /publish        → publie un événement (level dans application_properties)
        │
        ├── sub-logs (filtre : True — tous les messages)
        │     └── GET /subscribe/sub-logs → lit les événements de log
        │
        └── sub-alerts (filtre SQL : level = 'critical')
              └── GET /subscribe/sub-alerts → lit uniquement les alertes critiques
```

### Paramètres Terraform des Entités

```
Queue orders :
  max_delivery_count                   = 10
  dead_lettering_on_message_expiration = true
  lock_duration                        = PT1M
  default_message_ttl                  = P14D
  enable_partitioning                  = false

Topic events :
  max_size_in_megabytes                = 1024
  default_message_ttl                  = P14D

Subscription sub-logs :
  max_delivery_count                   = 10
  lock_duration                        = PT1M
  filtre                               = Boolean True (tous les messages)

Subscription sub-alerts :
  max_delivery_count                   = 10
  lock_duration                        = PT1M
  filtre SQL                           = level = 'critical'
```

### Points Clés à Retenir

- Une queue livre chaque message à **un seul** consommateur —
  adapté aux jobs et commandes à traitement unique
- Un topic livre chaque message à **toutes les subscriptions** actives —
  adapté aux événements broadcast et au pattern pub/sub
- Les filtres SQL s'appliquent sur `application_properties`, jamais
  sur le corps (body) du message — erreur fréquente en début de projet
- Chaque subscription a sa propre dead-letter queue —
  surveiller `sub-logs/$DeadLetterQueue` et `sub-alerts/$DeadLetterQueue`
  en plus de `orders/$DeadLetterQueue`
- La règle par défaut `$Default` d'une subscription est Boolean True —
  pour ajouter un filtre SQL il faut créer une règle explicite en Terraform
- Sans sessions, l'ordre des messages entre consommateurs parallèles
  n'est pas garanti — acceptable pour Phase 8C où l'ordre strict n'est
  pas requis

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
