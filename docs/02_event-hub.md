# Azure Event Hub

Introduction à Azure Event Hub — son modèle de streaming d'événements,
les namespaces, les hubs, les partitions, les consumer groups et son
intégration dans une architecture zero-trust avec Private Endpoint
et Managed Identity.

---

## Table des Matières

- [Azure Event Hub](#azure-event-hub)
  - [Table des Matières](#table-des-matières)
  - [Qu'est-ce qu'Azure Event Hub](#quest-ce-quazure-event-hub)
  - [Service Bus vs Event Hub — Quand Choisir](#service-bus-vs-event-hub--quand-choisir)
  - [Namespace et Hiérarchie des Ressources](#namespace-et-hiérarchie-des-ressources)
  - [Partitions](#partitions)
    - [Propriétés des Partitions](#propriétés-des-partitions)
    - [Choisir le Nombre de Partitions](#choisir-le-nombre-de-partitions)
  - [Consumer Groups](#consumer-groups)
    - [Isolation entre Consumer Groups](#isolation-entre-consumer-groups)
  - [SKUs et Throughput Units](#skus-et-throughput-units)
  - [Structure d'un Événement](#structure-dun-événement)
    - [Exemple de Corps de Message (Phase 8C)](#exemple-de-corps-de-message-phase-8c)
  - [Producteurs et Consommateurs](#producteurs-et-consommateurs)
    - [Producteur — Flask app (main.py)](#producteur--flask-app-mainpy)
    - [Consommateur — consumer.py (systemd eventhub-consumer.service)](#consommateur--consumerpy-systemd-eventhub-consumerservice)
    - [Checkpointing — Suivi de la Position](#checkpointing--suivi-de-la-position)
  - [Dans notre Phase 8C](#dans-notre-phase-8c)
    - [Ressources Terraform Déployées](#ressources-terraform-déployées)
    - [Nommage des Ressources](#nommage-des-ressources)
    - [Flux dans Phase 8C](#flux-dans-phase-8c)
    - [Points Clés à Retenir](#points-clés-à-retenir)

---

## Qu'est-ce qu'Azure Event Hub

Azure Event Hub est un service de streaming d'événements à haute
capacité. Il est conçu pour ingérer des millions d'événements par
seconde depuis de nombreux producteurs, et les mettre à disposition
de consommateurs qui lisent à leur propre rythme.

```
Modèle Service Bus (messagerie) :
  Producteur → [ Queue ] → Consommateur
  Le message est consommé une fois et supprimé.

Modèle Event Hub (streaming) :
  Producteurs → [ Event Hub ] → Consommateur A (consumer group A)
                              → Consommateur B (consumer group B)
  L'événement est conservé N jours (retention).
  Chaque consumer group lit indépendamment.
```

Event Hub est orienté données — il ne gère pas les acquittements,
les dead-letter queues ni les filtres SQL. Son point fort est le
débit : ingestion massive d'événements avec un coût faible par
événement.

---

## Service Bus vs Event Hub — Quand Choisir

```
Critère               Service Bus               Event Hub
--------------------  ------------------------  --------------------------
Usage principal       Messagerie applicative    Streaming de données
Débit                 Milliers/sec              Millions/sec
Ordre                 FIFO garanti par session  Ordre par partition
Acquittement          Oui (PEEK_LOCK)           Non (offset géré par client)
Dead-Letter Queue     Oui                       Non
Filtres               SQL, Correlation          Non
Rétention             Jusqu'à 14 jours          1 à 90 jours
Consommateurs         Un seul par message       Plusieurs consumer groups
Cas d'usage           Commandes, jobs, RPC      Métriques, logs, IoT, CDC
```

Dans Phase 8C, les deux services coexistent avec des rôles distincts :

- **Service Bus** : commandes (queue orders) et événements applicatifs
  (topic events avec filtrage par niveau)
- **Event Hub** : métriques techniques (hub app-metrics) lues par le
  consumer Grafana

---

## Namespace et Hiérarchie des Ressources

```
Namespace Event Hub (evhns-phase8c-{env})
  └── Event Hub : app-metrics
        ├── Consumer Group : $Default    (auto-créé par Azure)
        └── Consumer Group : grafana     (consumer.py → Pushgateway)
```

**Namespace** — conteneur de haut niveau. Définit le SKU, les
Throughput Units et le point de terminaison réseau. FQDN :
`{namespace}.servicebus.windows.net`

Note : Event Hub et Service Bus partagent le même suffixe DNS
`servicebus.windows.net`, et donc la même zone DNS privée
`privatelink.servicebus.windows.net`. Un seul enregistrement DNS
est nécessaire pour les deux.

**Event Hub** — canal de streaming. Comparable à un topic Kafka.
Les événements sont distribués sur N partitions pour le parallélisme.

**Consumer Group** — vue indépendante du hub. Chaque consumer group
maintient son propre offset de lecture — sa position dans le flux
d'événements. Deux consumer groups lisent les mêmes événements
de manière complètement indépendante.

---

## Partitions

Les partitions sont l'unité de parallélisme d'Event Hub. Le hub
`app-metrics` dans Phase 8C a 2 partitions.

```
Event Hub app-metrics (2 partitions)
  ├── Partition 0  [evt1, evt3, evt5, ...]
  └── Partition 1  [evt2, evt4, evt6, ...]

Producteur
  └── send()  → partition déterminée par :
        ├── partition_key  (hash déterministe → même partition pour même clé)
        └── round-robin    (si pas de partition_key → équilibrage automatique)
```

### Propriétés des Partitions

```
Ordre           Les événements d'une partition sont ordonnés (FIFO).
                L'ordre entre partitions n'est pas garanti.

Parallélisme    Un consommateur par partition maximum dans un consumer group.
                2 partitions → 2 consommateurs parallèles maximum.

Immutabilité    Les événements ne peuvent pas être modifiés après envoi.

Rétention       Les événements sont conservés N jours quelle que soit
                la vitesse de consommation (message_retention = 1 dans Phase 8C).
```

### Choisir le Nombre de Partitions

Le nombre de partitions se définit à la création et ne peut pas
être diminué. Il peut être augmenté sur les namespaces Premium.

```
2 partitions   → adapté à 2 consommateurs parallèles maximum (Phase 8C dev/staging)
4 partitions   → adapté à 4 consommateurs parallèles
32 partitions  → limite Standard/Premium pour le débit maximal
```

---

## Consumer Groups

Un consumer group est un groupe logique de consommateurs qui lisent
le même Event Hub. Chaque consumer group maintient son propre offset
(position de lecture) par partition.

```
Event Hub app-metrics
  │
  ├── Consumer Group : $Default
  │     Partition 0 → offset: 150  (position du dernier message lu)
  │     Partition 1 → offset: 143
  │
  └── Consumer Group : grafana
        Partition 0 → offset: 89   (en retard — lit à son propre rythme)
        Partition 1 → offset: 91
```

### Isolation entre Consumer Groups

Deux consumer groups lisent indépendamment — ni leurs offsets ni
leurs vitesses de lecture ne s'influencent mutuellement.

```python
# consumer.py — lit depuis le consumer group "grafana"
async with EventHubConsumerClient(
    fully_qualified_namespace=f"{namespace}.servicebus.windows.net",
    eventhub_name="app-metrics",
    consumer_group="grafana",
    credential=credential
) as consumer:
    await consumer.receive(on_event=process_event, starting_position="-1")
```

`starting_position="-1"` signifie "commencer par les événements les
plus récents". La position `"@latest"` a le même effet. La position
`"@earliest"` permet de relire depuis le début de la rétention.

---

## SKUs et Throughput Units

```
SKU       TU  MB/s entrant  MB/s sortant  Consumer Groups  PE   Rétention max
--------  --  -------------  ------------  ---------------  ---  -------------
Basic     1   1 Mo/s/TU      2 Mo/s/TU     1 ($Default)     non  1 jour
Standard  N   1 Mo/s/TU      2 Mo/s/TU     20               non  7 jours
Premium   N   1 Mo/s/PU      2 Mo/s/PU     illimité         oui  90 jours
```

**Throughput Unit (TU)** — unité de débit dans le SKU Standard.
Chaque TU apporte 1 Mo/s en entrée et 2 Mo/s en sortie.

**Processing Unit (PU)** — équivalent des TU pour le SKU Premium.

Dans Phase 8C :

- dev/staging : **Standard 2 TU** — supporte les consumer groups
  custom (grafana) avec un débit suffisant pour les tests
- prod : **Standard 4 TU** — débit doublé pour la charge production

Note : Le SKU **Basic** ne supporte qu'un seul consumer group (`$Default`).
Il est incompatible avec le consumer group `grafana` requis pour le
pipeline Event Hub → consumer.py → Pushgateway.

---

## Structure d'un Événement

Un événement Event Hub est une paire corps/propriétés.

```
EventData
  ├── body                   Contenu de l'événement (bytes)
  │                          Dans Phase 8C : JSON sérialisé en UTF-8
  │
  ├── properties             Propriétés custom (dict clé/valeur)
  │                          Exemples : {"env": "dev", "source": "flask"}
  │
  └── system_properties      Métadonnées gérées par Event Hub
        ├── sequence_number  Numéro de séquence unique par partition
        ├── offset           Position dans la partition (string)
        ├── enqueued_time    Heure d'ingestion par Event Hub
        └── partition_key    Clé de partition (si fournie par le producteur)
```

### Exemple de Corps de Message (Phase 8C)

```json
{
  "metric_name": "orders_processed",
  "value": 42,
  "timestamp": "2026-03-09T18:00:00Z",
  "tags": {
    "env": "dev",
    "source": "flask-app"
  }
}
```

---

## Producteurs et Consommateurs

### Producteur — Flask app (main.py)

```python
from azure.eventhub import EventHubProducerClient, EventData

# Connexion via connection string (lue depuis Key Vault)
producer = EventHubProducerClient.from_connection_string(
    conn_str=connection_str,
    eventhub_name="app-metrics"
)

# Envoyer un événement
event_data_batch = producer.create_batch()
event_data_batch.add(EventData(json.dumps({
    "metric_name": "orders_processed",
    "value": 42,
    "tags": {"env": "dev"}
})))
producer.send_batch(event_data_batch)
```

### Consommateur — consumer.py (systemd eventhub-consumer.service)

```python
from azure.eventhub.aio import EventHubConsumerClient

async def on_event(partition_context, event):
    # Parser le corps de l'événement
    data = json.loads(event.body_as_str())

    # Pousser la métrique vers Pushgateway
    metric_name = data.get("metric_name", "unknown")
    value = data.get("value", 0)
    push_to_pushgateway(metric_name, value)

    # Mettre à jour l'offset (checkpoint)
    await partition_context.update_checkpoint(event)

async def main():
    client = EventHubConsumerClient.from_connection_string(
        conn_str=connection_str,
        consumer_group="grafana",
        eventhub_name="app-metrics"
    )
    async with client:
        await client.receive(on_event=on_event, starting_position="-1")
```

### Checkpointing — Suivi de la Position

Le consumer doit enregistrer sa position (offset) après chaque
événement traité pour ne pas relire les mêmes événements au
redémarrage. Sans checkpoint, le consumer relit depuis
`starting_position` à chaque redémarrage.

```
Avec checkpoint :
  consumer.py redémarre → reprend depuis le dernier offset enregistré
  → aucun événement rejoué

Sans checkpoint :
  consumer.py redémarre → starting_position="-1" → événements récents seulement
  → ou starting_position="@earliest" → rejoue tout depuis le début
```

Dans Phase 8C, `update_checkpoint(event)` est appelé après chaque
push réussi vers le Pushgateway. Si le push échoue, le checkpoint
n'est pas mis à jour — l'événement sera retraité au prochain cycle.

---

## Dans notre Phase 8C

### Ressources Terraform Déployées

```
azurerm_eventhub_namespace.main        (evhns-phase8c-{env})
  └── azurerm_eventhub.app_metrics     (app-metrics)
        ├── azurerm_eventhub_consumer_group.default  ($Default — auto)
        └── azurerm_eventhub_consumer_group.grafana  (grafana)

azurerm_private_endpoint.eventhub          (même zone DNS que Service Bus)
azurerm_monitor_diagnostic_setting.eventhub
```

### Nommage des Ressources

```
Namespace      : evhns-phase8c-{env}
Event Hub      : app-metrics
Consumer Group : grafana
PE (prod)      : pe-eventhub-phase8c-prod
Zone DNS       : privatelink.servicebus.windows.net  (partagée avec Service Bus)
```

### Flux dans Phase 8C

```
Flask app (snet-app)
  └── POST /metrics/emit
        └── EventHubProducerClient → app-metrics (PE snet-pe en prod)

VM app (snet-app) — consumer.py (systemd : eventhub-consumer.service)
  └── EventHubConsumerClient (consumer group : grafana)
        └── app-metrics
              └── parse métrique
                    └── HTTP POST → Pushgateway (snet-monitoring:9091)

VM monitoring (snet-monitoring) — Docker Compose
  ├── Pushgateway :9091   reçoit les métriques du consumer
  ├── Prometheus  :9090   scrape Pushgateway toutes les 15s
  └── Grafana     :3000   dashboard métriques Event Hub
```

### Points Clés à Retenir

- Event Hub n'est pas une queue — pas de dead-letter, pas de filtres,
  pas d'acquittement. C'est un journal append-only distribué sur partitions
- Le **SKU Basic** ne supporte qu'un seul consumer group (`$Default`) —
  le consumer group `grafana` nécessite **Standard minimum**
- La zone DNS `privatelink.servicebus.windows.net` est **partagée** entre
  Service Bus et Event Hub — un seul enregistrement DNS gère les deux
- Le **checkpointing** est essentiel pour éviter de rejouer les événements
  au redémarrage du consumer — `update_checkpoint(event)` après chaque
  traitement réussi
- `starting_position="-1"` démarre depuis les événements les plus récents —
  adapté au monitoring temps réel où les anciennes métriques n'ont pas
  d'intérêt après un redémarrage du consumer
- La rétention à 1 jour (`message_retention = 1`) est suffisante pour
  Phase 8C — en production réelle, augmenter selon le besoin de replay

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
