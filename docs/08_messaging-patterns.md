# Patterns de Messagerie

Guide sur les principaux patterns de messagerie implémentés
dans Phase 8C — competing consumers, publish-subscribe,
dead-letter handling et les garanties de livraison associées.

---

## Table des Matières

1. [Competing Consumers](#competing-consumers)
2. [Publish-Subscribe](#publish-subscribe)
3. [Dead-Letter Handling](#dead-letter-handling)
4. [Garanties de Livraison](#garanties-de-livraison)
5. [Idempotence des Consommateurs](#idempotence-des-consommateurs)
6. [Patterns de Retry](#patterns-de-retry)
7. [Dans notre Phase 8C](#dans-notre-phase-8c)

---

## Competing Consumers

Le pattern Competing Consumers distribue le traitement d'une queue
entre plusieurs consommateurs qui s'exécutent en parallèle.
Chaque message est traité par **un seul** consommateur.

```
Queue orders
  │
  ├── Consumer A  ←── message 1
  ├── Consumer B  ←── message 2
  └── Consumer C  ←── message 3

Chaque consumer traite son message indépendamment.
Service Bus garantit qu'un message n'est livré qu'à un seul consumer
à la fois (via le mécanisme de lock PEEK_LOCK).
```

### Quand Utiliser ce Pattern

```
Volume élevé de tâches    Distribuer la charge entre N workers
Traitement parallélisable Chaque tâche est indépendante des autres
Scalabilité horizontale   Ajouter des workers pour augmenter le débit
Résilience                Si un worker plante, les autres continuent
```

### Dans Phase 8C

Dans Phase 8C, un seul worker Flask traite la queue orders. Le pattern
competing consumers est illustré par l'architecture possible :

```
Scénario sans scale-out (Phase 8C actuel) :
  VM Flask (unique) → GET /receive → un message à la fois

Scénario avec scale-out (évolution possible) :
  VM Flask 1 → GET /receive ─┐
  VM Flask 2 → GET /receive ─┼── Queue orders  (Service Bus distribue)
  VM Flask 3 → GET /receive ─┘
```

### Avantage du Lock PEEK_LOCK

```
Consumer A reçoit message 1 → lock de 60s (lock_duration = PT1M)
Consumer B ne voit pas message 1 pendant le lock

Si Consumer A complete() → message supprimé de la queue
Si Consumer A crashe → lock expire → message remis dans la queue
                                  → Consumer B peut le recevoir
```

---

## Publish-Subscribe

Le pattern Publish-Subscribe découple les producteurs des consommateurs.
Un producteur publie un événement sur un topic sans connaître les
consommateurs. Les consommateurs s'abonnent aux événements qui
les intéressent.

```
Producteur Flask
  └── publish({"event": "payment-failed", "level": "critical"})
        └── [ Topic events ]
              │
              ├── sub-logs    (filtre : True)
              │     └── Consommateur A : enregistre TOUS les événements
              │
              └── sub-alerts  (filtre SQL : level = 'critical')
                    └── Consommateur B : traite uniquement les ALERTES
```

### Découplage Producteur / Consommateur

```
Sans pub/sub (couplage direct) :
  Flask → LogService (HTTP)
  Flask → AlertService (HTTP)
  Flask → AnalyticsService (HTTP)
  → Si un service est indisponible, Flask doit gérer l'erreur
  → Ajouter un service = modifier Flask

Avec pub/sub (couplage faible) :
  Flask → Topic events
  → Chaque service s'abonne indépendamment
  → Flask ne connaît pas les consommateurs
  → Ajouter un service = nouvelle subscription (Flask ne change pas)
  → Si un consommateur est indisponible, les messages s'accumulent
    dans sa subscription et sont traités à la reprise
```

### Filtrage par Propriété

Le filtrage sur `level = 'critical'` dans sub-alerts permet de
ne réveiller le consommateur d'alertes que sur les événements
importants, sans charger inutilement le système.

```
Exemple de flux dans Phase 8C :

Flask publie 100 événements :
  - 80 avec level = 'info'   → sub-logs reçoit 100 messages
                              → sub-alerts reçoit 0 messages
  - 20 avec level = 'critical' → sub-logs reçoit 100 messages
                                → sub-alerts reçoit 20 messages

Le consommateur de sub-alerts n'est sollicité que pour les critiques.
```

---

## Dead-Letter Handling

Le pattern Dead-Letter Handling consiste à capturer les messages
en erreur dans la DLQ pour analyse et retraitement, plutôt que
de les perdre silencieusement.

```
FLUX NORMAL :
  Producteur → Queue → Consumer → complete()
                                  (message supprimé)

FLUX D'ERREUR RÉPÉTÉ :
  Producteur → Queue → Consumer → échec (abandon ou crash)
                     ↑                             ↓
                     └── retry (jusqu'à max_delivery_count)
                                                   ↓ (après N échecs)
                               DLQ → analyse → retraitement ou suppression
```

### Les Trois Actions du Consommateur

```python
# 1. Succès — supprimer le message de la queue
receiver.complete_message(msg)

# 2. Echec temporaire — remettre dans la queue (sera relivré)
receiver.abandon_message(msg)
# → delivery_count++ → nouveau lock → rélivraison possible

# 3. Echec définitif — transférer en DLQ (ne sera pas relivré)
receiver.dead_letter_message(
    msg,
    reason="InvalidFormat",
    error_description="Champ order_id manquant"
)
```

### Décider entre Abandon et Dead-Letter

```
Abandon (retry) :
  - Erreur transitoire (service temporairement indisponible)
  - Base de données en cours de redémarrage
  - Timeout réseau

Dead-Letter (no retry) :
  - Message malformé (JSON invalide, champs manquants)
  - Données métier invalides (order_id inexistant en base)
  - Après N tentatives d'abandon → Service Bus passe en DLQ automatiquement
```

---

## Garanties de Livraison

### At-Least-Once Delivery

Service Bus garantit qu'un message sera livré **au moins une fois**.
Si le consommateur ne confirme pas (complete), le message sera
relivré après expiration du lock.

```
Implication : un consommateur peut recevoir le même message deux fois
              si le lock expire ou si le consommateur crashe après
              réception mais avant complete().

Solution    : rendre le consommateur idempotent — traiter deux fois
              le même message doit produire le même résultat qu'une
              seule fois.
```

### At-Most-Once Delivery

Disponible via le mode `RECEIVE_AND_DELETE` — le message est supprimé
dès réception. Pas de retry possible si le traitement échoue.

```
Implication : un message peut être perdu si le consommateur plante
              après réception et avant traitement.

Usage       : acceptable pour des métriques ou des logs où une perte
              occasionnelle est tolérable.
```

### Exactly-Once Delivery

Possible avec les sessions Service Bus et un stockage idempotent.
Non utilisé dans Phase 8C.

---

## Idempotence des Consommateurs

L'idempotence signifie qu'une opération produit le même résultat
qu'elle soit exécutée une ou plusieurs fois. Un consommateur idempotent
peut recevoir le même message deux fois sans effets de bord.

### Pourquoi l'Idempotence est Importante

Avec at-least-once delivery, un message peut être relivré dans ces
situations :

- Le lock expire avant que le consommateur appelle complete()
- Le consommateur plante après réception mais avant complete()
- Problème réseau lors de l'appel à complete()

### Techniques d'Idempotence

```
1. Opérations naturellement idempotentes
   Upsert (INSERT OR REPLACE) plutôt que INSERT
   SET plutôt qu'INCREMENT

2. Déduplication par message_id
   Stocker les message_id traités dans une cache ou base de données
   Vérifier avant traitement si le message_id a déjà été traité

3. Idempotent key dans le payload
   Utiliser un identifiant métier unique dans le corps du message
   (order_id, transaction_id) pour détecter les doublons
```

### Dans Phase 8C

Flask utilise un upsert plutôt qu'un insert pour les opérations
critiques, et les métriques Event Hub sont des gauges (valeurs
ponctuelles) — les écrire plusieurs fois produit le même résultat.

---

## Patterns de Retry

### Retry avec Backoff Exponentiel

Pour les erreurs transitoires côté consommateur, le retry avec
backoff exponentiel évite de surcharger un service déjà en difficulté.

```python
import time

def process_with_retry(msg, max_retries=3):
    for attempt in range(max_retries):
        try:
            process_message(msg)
            return True
        except TransientError as e:
            if attempt == max_retries - 1:
                return False  # abandon ou dead_letter après N tentatives
            wait_time = (2 ** attempt) + random.random()
            time.sleep(wait_time)   # 1s, 2s, 4s + jitter
    return False
```

### Retry Géré par Service Bus

Service Bus gère lui-même le retry via `max_delivery_count`.
Le consommateur n'a pas besoin d'implémenter sa propre logique de retry
au niveau du message — il lui suffit d'abandonner le message pour
déclencher une nouvelle tentative.

```
Stratégie recommandée pour Phase 8C :
  - Errors transitoires → abandon_message() → Service Bus relivre
  - Errors définitives  → dead_letter_message() → analyse manuelle
  - max_delivery_count  → 10 tentatives maximum avant DLQ automatique
```

---

## Dans notre Phase 8C

### Patterns Implémentés

```
Competing Consumers :
  Queue orders → Flask (un seul consumer dans Phase 8C)
  Évolutif vers N consumers si nécessaire

Publish-Subscribe :
  Topic events → sub-logs (tous) + sub-alerts (level = 'critical')
  Filtrage SQL sur application_properties["level"]

Dead-Letter Handling :
  Queue orders/$DeadLetterQueue → GET /dlq → POST /dlq/reprocess
  Inspection de dead_letter_reason et dead_letter_error_description

Streaming (Event Hub) :
  POST /metrics/emit → Event Hub app-metrics
  consumer.py (consumer group grafana) → Pushgateway → Prometheus → Grafana
```

### Décisions de Design

```
PEEK_LOCK partout         At-least-once delivery — pas de perte de message
max_delivery_count = 10   10 tentatives avant DLQ — tolérant aux erreurs transitoires
Filtres SQL sur           Les propriétés de routage dans application_properties,
application_properties    pas dans le body — règle fondamentale Service Bus
consumer group "grafana"  Isolation du pipeline monitoring — $Default disponible
                          pour d'autres usages futurs
```

### Points Clés à Retenir

- Le pattern **competing consumers** nécessite des consommateurs
  **idempotents** — at-least-once delivery implique des doublons possibles
- Les filtres SQL s'appliquent sur **application_properties**, jamais
  sur le body — erreur architecturale si les propriétés de routage
  sont dans le body JSON
- **PEEK_LOCK** est le mode par défaut et le plus sûr — toujours
  préférer à RECEIVE_AND_DELETE en production
- La **DLQ est un indicateur** de problème, pas une destination normale —
  la surveiller activement et la traiter rapidement
- Le pattern **pub/sub avec filtres** découple les producteurs des
  consommateurs — ajouter un nouveau consommateur = nouvelle subscription,
  sans modifier le producteur

---

Auteur : Palou
Date : Mars 2026
Phase : 8C - Messaging et Integration
