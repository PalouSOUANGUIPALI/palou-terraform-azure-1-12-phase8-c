# Dead-Letter Queue

Guide sur la Dead-Letter Queue (DLQ) dans Azure Service Bus —
pourquoi elle existe, dans quelles conditions les messages y
sont transférés, comment les lire et les retraiter depuis
l'application Flask de Phase 8C.

---

## Table des Matières

1. [Qu'est-ce que la Dead-Letter Queue](#quest-ce-que-la-dead-letter-queue)
2. [Conditions de Transfert en DLQ](#conditions-de-transfert-en-dlq)
3. [Structure d'un Message en DLQ](#structure-dun-message-en-dlq)
4. [Chemins d'Accès à la DLQ](#chemins-daccès-à-la-dlq)
5. [Lire et Retraiter les Messages](#lire-et-retraiter-les-messages)
6. [Stratégies de Gestion de la DLQ](#stratégies-de-gestion-de-la-dlq)
7. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Qu'est-ce que la Dead-Letter Queue

La Dead-Letter Queue est une sous-queue secondaire associée
automatiquement à chaque queue et subscription par Azure Service Bus.
Elle stocke les messages qui n'ont pas pu être livrés ou traités
avec succès.

```
Queue orders
  └── orders/$DeadLetterQueue    (sous-queue — créée automatiquement par Azure)

Topic events
  └── sub-logs
        └── events/subscriptions/sub-logs/$DeadLetterQueue
  └── sub-alerts
        └── events/subscriptions/sub-alerts/$DeadLetterQueue
```

La DLQ est conçue pour éviter la perte silencieuse de messages.
Sans elle, un message qui échoue à répétition serait simplement
supprimé après `max_delivery_count` tentatives. Avec la DLQ, le
message est conservé pour analyse et retraitement.

### La DLQ n'est pas une Queue Normale

```
Queue normale                 Dead-Letter Queue
-----------------------------  ------------------------------
Messages envoyés par des apps  Messages transférés automatiquement
                               ou explicitement par le consommateur
Délivrance automatique         Pas de délivrance automatique
Retry automatique              Pas de retry — attente d'action manuelle
Supprimés après traitement     Conservés jusqu'à lecture explicite
                               et acquittement
```

---

## Conditions de Transfert en DLQ

### 1. max_delivery_count Dépassé

Condition la plus fréquente. Quand un message a été livré et
non acquitté (abandon, crash du consommateur, expiration du verrou)
plus de `max_delivery_count` fois, il est automatiquement transféré
en DLQ.

```
max_delivery_count = 10  (valeur Phase 8C)

Tentative 1  → consommateur plante → verrou expire → message remis
Tentative 2  → idem
...
Tentative 10 → idem → Service Bus transfère en DLQ
               dead_letter_reason = "MaxDeliveryCountExceeded"
```

### 2. dead_letter_message() Explicite

Le consommateur décide lui-même qu'un message est invalide
et ne peut pas être traité.

```python
with client.get_queue_receiver("orders") as receiver:
    for msg in receiver:
        try:
            data = json.loads(str(msg))
            if "order_id" not in data:
                # Message mal formé — pas la peine de retenter
                receiver.dead_letter_message(
                    msg,
                    reason="InvalidFormat",
                    error_description="Champ order_id manquant"
                )
                continue
            # traitement normal...
            receiver.complete_message(msg)
        except Exception as e:
            receiver.dead_letter_message(msg, reason="ProcessingError",
                                         error_description=str(e))
```

### 3. Expiration du Message (si configuré)

Si `dead_lettering_on_message_expiration = true` sur la queue
ou la subscription, les messages dont le TTL (`default_message_ttl`)
expire avant d'être consommés sont transférés en DLQ plutôt que
silencieusement supprimés.

```hcl
resource "azurerm_servicebus_queue" "orders" {
  dead_lettering_on_message_expiration = true  # Phase 8C : activé
  default_message_ttl                  = "P14D"
}
```

### 4. Erreur d'Évaluation du Filtre SQL

Si le filtre SQL d'une subscription contient une erreur ou ne peut
pas être évalué pour un message donné, ce message peut être transféré
en DLQ selon la configuration.

---

## Structure d'un Message en DLQ

Un message en DLQ conserve toutes ses propriétés originales plus
des métadonnées supplémentaires ajoutées par Service Bus.

```
Message en DLQ
  ├── body                        Corps original du message (inchangé)
  ├── application_properties      Propriétés originales (inchangées)
  │
  └── system_properties
        ├── message_id             Id original
        ├── sequence_number        Numéro de séquence dans la DLQ
        ├── enqueued_time          Heure d'entrée dans la DLQ
        ├── delivery_count         Nombre de tentatives avant DLQ
        ├── dead_letter_reason     Raison du transfert (string)
        │                          Exemples :
        │                            "MaxDeliveryCountExceeded"
        │                            "InvalidFormat"
        │                            "ProcessingError"
        │                            "TTLExpiredException"
        └── dead_letter_error_description
                                   Description détaillée (string)
                                   Fournie lors d'un dead_letter() explicite
```

---

## Chemins d'Accès à la DLQ

### Depuis l'Application Python

```python
from azure.servicebus import ServiceBusClient, ServiceBusSubQueue

# DLQ de la queue orders
with client.get_queue_receiver(
    queue_name="orders",
    sub_queue=ServiceBusSubQueue.DEAD_LETTER,
    max_wait_time=5
) as receiver:
    for msg in receiver:
        print(f"Raison : {msg.dead_letter_reason}")
        print(f"Corps  : {str(msg)}")

# DLQ de la subscription sub-logs
with client.get_subscription_receiver(
    topic_name="events",
    subscription_name="sub-logs",
    sub_queue=ServiceBusSubQueue.DEAD_LETTER,
    max_wait_time=5
) as receiver:
    for msg in receiver:
        print(f"Raison : {msg.dead_letter_reason}")
```

### Depuis Azure CLI

```bash
# Compter les messages en DLQ de la queue orders
az servicebus queue show \
  --resource-group rg-phase8c-dev \
  --namespace-name $(az servicebus namespace list \
    --resource-group rg-phase8c-dev --query "[0].name" -o tsv) \
  --name orders \
  --query "deadLetterMessageCount" \
  --output tsv

# Compter les messages en DLQ de sub-logs
az servicebus topic subscription show \
  --resource-group rg-phase8c-dev \
  --namespace-name $(az servicebus namespace list \
    --resource-group rg-phase8c-dev --query "[0].name" -o tsv) \
  --topic-name events \
  --name sub-logs \
  --query "deadLetterMessageCount" \
  --output tsv
```

### Depuis le Portail Azure

```
Portail Azure
  → Namespaces Service Bus
  → sbns-phase8c-{env}
  → Queues → orders → Dead-letter
  ou
  → Topics → events → Subscriptions → sub-logs → Dead-letter
```

---

## Lire et Retraiter les Messages

### Pattern de Retraitement

Le pattern standard pour gérer la DLQ est en trois étapes :

```
1. Lire le message de la DLQ
   └── Examiner dead_letter_reason et dead_letter_error_description

2. Décider de l'action
   ├── Corriger et renvoyer dans la queue principale
   ├── Transmettre à un système d'alerte
   └── Supprimer (message définitivement invalide)

3. Acquitter le message dans la DLQ (complete)
   └── Le message est supprimé de la DLQ
```

### Endpoint /dlq dans Phase 8C (Flask)

```python
# GET /dlq — lit les messages en DLQ de la queue orders
@app.route("/dlq", methods=["GET"])
def read_dlq():
    messages = []
    with sb_client.get_queue_receiver(
        queue_name="orders",
        sub_queue=ServiceBusSubQueue.DEAD_LETTER,
        max_wait_time=5
    ) as receiver:
        for msg in receiver:
            messages.append({
                "body": json.loads(str(msg)),
                "reason": msg.dead_letter_reason,
                "description": msg.dead_letter_error_description,
                "delivery_count": msg.delivery_count
            })
            receiver.complete_message(msg)   # supprime de la DLQ
    return jsonify({"count": len(messages), "messages": messages})
```

### Endpoint /dlq/reprocess dans Phase 8C (Flask)

```python
# POST /dlq/reprocess — renvoie le premier message DLQ dans orders
@app.route("/dlq/reprocess", methods=["POST"])
def reprocess_dlq():
    reprocessed = 0
    with sb_client.get_queue_receiver(
        queue_name="orders",
        sub_queue=ServiceBusSubQueue.DEAD_LETTER,
        max_wait_time=5,
        max_message_count=1
    ) as dlq_receiver:
        for msg in dlq_receiver:
            # Renvoyer dans la queue principale
            with sb_client.get_queue_sender("orders") as sender:
                new_msg = ServiceBusMessage(body=str(msg))
                sender.send_messages(new_msg)
            dlq_receiver.complete_message(msg)
            reprocessed += 1
    return jsonify({"reprocessed": reprocessed})
```

---

## Stratégies de Gestion de la DLQ

### Surveillance Continue

La DLQ doit être surveillée en production. Un pic de messages
en DLQ indique un problème de traitement récurrent.

```bash
# Alerte Azure Monitor — messages en DLQ de orders
az monitor metrics alert create \
  --name "alert-dlq-orders-phase8c-dev" \
  --resource-group rg-phase8c-dev \
  --scopes /subscriptions/.../resourceGroups/rg-phase8c-dev/providers/\
    Microsoft.ServiceBus/namespaces/sbns-phase8c-dev \
  --condition "count DeadletteredMessages > 0" \
  --description "Messages en dead-letter dans queue orders"
```

### Décision par Raison

```
dead_letter_reason = "MaxDeliveryCountExceeded"
  → Le consommateur échoue à répétition
  → Analyser les logs du service pour trouver la cause
  → Corriger le consommateur, puis retraiter

dead_letter_reason = "InvalidFormat"
  → Le producteur a envoyé un message mal formé
  → Corriger le producteur, supprimer le message DLQ

dead_letter_reason = "TTLExpiredException"
  → La queue est saturée ou le consommateur trop lent
  → Augmenter max_delivery_count ou accélérer le traitement

dead_letter_reason = "ProcessingError"  (explicite)
  → Erreur applicative identifiée par le consommateur
  → Analyser dead_letter_error_description
```

### Ne Pas Laisser la DLQ Grossir

Une DLQ pleine indique que des messages ne sont pas traités.
En production, mettre en place :

- Une alerte sur le count de messages en DLQ
- Un processus de revue périodique des messages en DLQ
- Un endpoint de retraitement ou de suppression explicite

---

## Dans notre Phase 8C

### DLQs Présentes

```
Queue orders :
  orders/$DeadLetterQueue

Topic events :
  events/subscriptions/sub-logs/$DeadLetterQueue
  events/subscriptions/sub-alerts/$DeadLetterQueue
```

### Endpoints Flask

```
GET  /dlq               Lit et acquitte les messages DLQ de orders
POST /dlq/reprocess     Renvoie le premier message DLQ dans orders
```

### Tester la DLQ dans Phase 8C

```bash
# Envoyer un message qui échouera à être traité
# (format invalide — champ order_id manquant)
curl -X POST http://localhost:5000/send \
  -H "Content-Type: application/json" \
  -d '{"product": "laptop", "quantity": 1}'

# Attendre que max_delivery_count soit dépassé
# ou appeler dead_letter_message() explicitement dans le consumer

# Lire la DLQ
curl http://localhost:5000/dlq

# Retraiter
curl -X POST http://localhost:5000/dlq/reprocess
```

### Points Clés à Retenir

- La DLQ est créée **automatiquement** par Azure Service Bus —
  aucune configuration Terraform nécessaire
- Chaque subscription a sa **propre** DLQ, indépendante des autres
- `dead_lettering_on_message_expiration = true` empêche la perte
  silencieuse de messages expirés — toujours activer en production
- La DLQ n'a pas de retry automatique — les messages restent dans
  la DLQ jusqu'à une action explicite (lecture + complete ou reprocess)
- Surveiller le count de messages en DLQ — c'est le premier indicateur
  d'un problème de traitement dans un système de messagerie
- Un message en DLQ conserve son corps et ses `application_properties`
  d'origine — toute l'information nécessaire au diagnostic est disponible

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
