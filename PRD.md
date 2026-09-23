# DubStemMix — PRD

> Version 1.2 · 22 septembre 2026 · issu de l'interview de cadrage du 21 septembre 2026 et de l'interview « effets dub » du 22 septembre 2026
> Statut : validé — jalons M0 à M4 livrés, § 3 du TODO livré ; v2 (§ 11, jalons M6 à M8) livrée et validée ; séparation de stems (§ 12, jalon M9) cadrée le 22 septembre 2026. Ce document reste la référence produit et se tient à jour à chaque jalon

## 1. Vision

DubStemMix est une app macOS qui transforme une **Akai MIDImix** en **console de mix dub** : on charge les stems d'un morceau, et on le remixe en direct comme un ingénieur dub — faders, mutes, envois vers un delay, une reverb et un troisième effet, « dub throws » — sans DAW, sans configuration.

**Promesse** : brancher la console, glisser un dossier de stems, jouer. L'expérience doit être immédiate, stable en live, et le son des effets intégrés doit être bon dès l'installation.

### Pourquoi pas un DAW ?

Ableton Live + MIDImix fait techniquement la même chose, mais demande un DAW payant, un projet à préparer par morceau, et un mapping générique. DubStemMix est un **instrument dédié** : une seule chose, bien faite, avec les gestes dub (throw, envois, queue d'écho qui survit au mute) pensés pour la console.

## 2. Public et distribution

| | |
|---|---|
| Public | Musiciens, selectors, ingénieurs dub/reggae sur Mac possédant une MIDImix. D'abord l'auteur, puis public. |
| Modèle | **Open source public**, licence **MIT** |
| Plateforme | macOS uniquement. Développé et testé sur **macOS 26** (machine de l'auteur). Évalué en M5 le 22/09/2026 : compile et passe les tests en ciblant **macOS 15** sans aucune adaptation → cible minimale 15 (non testée sur machine) ; macOS 14 exclu (module Synchronization : `Atomic`, `Mutex`) |
| Langue de l'interface | Anglais uniquement |
| Usage | **Live** (performance en direct) **+ enregistrement** du mix |

## 3. Décisions de cadrage

| Sujet | Décision |
|---|---|
| Techno | **Swift + SwiftUI + AVAudioEngine + CoreMIDI** |
| Plugins | **Audio Units (AU)** ; pas de VST3 (la quasi-totalité des plugins utiles au dub existent en AU sur Mac) |
| Effets v1 | Effets **intégrés** par défaut **+ slot AU** par bus pour les remplacer |
| 3 potards par tranche | 3 **envois** : Delay, Reverb, 3e bus libre |
| 3e bus par défaut | **Phaser type Bi-Phase** |
| Envois pré/post | **Post-fader par défaut**, réglable **par bus** |
| Réglages des effets | **Page FX** via BANK RIGHT (retour mix : BANK LEFT), avec rattrapage des potards |
| REC ARM | **Dub throw** vers le delay (momentané) |
| Transport | **Clavier + écran** (la MIDImix n'a pas de bouton play) |
| Morceaux | **Projets sauvegardés + setlist** |
| Enregistrement | **Master stéréo WAV** |
| Tempo | **Détection auto + tap tempo** + correction manuelle |
| Sortie audio | **Stéréo simple** (pas de cue casque en v1) |
| Contrôleurs | **MIDImix uniquement en v1**, mapping isolé dans un profil pour en ajouter d'autres |
| Effets dub v2 (22/09/2026) | **Chaîne master + inserts par tranche**, tout sauf la sirène (§ 11). Réglages sur une **troisième page** de la console (BANK RIGHT), gestes momentanés au **clavier et à l'écran**. Ordre : master (M6) → delay/reverb (M7) → inserts (M8) |

## 4. Matériel : Akai MIDImix

Console USB class-compliant (aucun driver). Mapping **d'usine vérifié sur la console** le 21/09/2026 avec `tools/midi-monitor.swift` (canal MIDI 1) :

| Contrôle | Message |
|---|---|
| Potards tranche 1 → 8 (haut, milieu, bas) | CC 16-17-18 · 20-21-22 · 24-25-26 · 28-29-30 · 46-47-48 · 50-51-52 · 54-55-56 · 58-59-60 |
| Faders tranche 1 → 8 | CC 19, 23, 27, 31, 49, 53, 57, 61 |
| Fader master | CC 62 |
| MUTE tranche *i* (1 → 8) | Note 1 + 3(*i*−1) → 1, 4, 7, 10, 13, 16, 19, 22 |
| REC ARM tranche *i* | Note 3 + 3(*i*−1) → 3, 6, 9, 12, 15, 18, 21, 24 |
| BANK LEFT / BANK RIGHT | Notes 25 / 26 |
| SOLO | Note 27 |
| SEND ALL | Renvoie la position de tous les potards et faders (vérifié) |

Les boutons envoient Note On à l'appui et Note Off au relâchement (→ gestes momentanés possibles).

**LEDs** : pilotées par Note On sur la même note que le bouton (vélocité 127 = allumée, 0 = éteinte) — allumage **confirmé visuellement**. Convention retenue : **LED MUTE allumée = tranche coupée**.

**À confirmer sur la console (en M0)** : SOLO maintenu + MUTE — notes attendues 2, 5, 8… (2 + 3(*i*−1)), non capturées.

Si l'utilisateur a reconfiguré sa console avec l'éditeur Akai, le mapping diffère : prévoir un message clair et un lien vers la remise à zéro d'usine (pas de MIDI learn en v1).

## 5. Fonctionnalités v1

### 5.1 Stems et tranches

- Import par glisser-déposer (fichiers ou dossier) ou sélecteur : WAV, AIFF, FLAC, MP3, M4A.
- Cas nominal : **6 à 8 stems WAV** par morceau. Cible technique : jusqu'à 16 stems sans décrochage.
- **L'utilisateur gère lui-même l'affectation des stems aux tranches** : l'app n'affecte rien automatiquement et n'écarte aucun fichier de sa propre initiative. Les fichiers importés arrivent dans une **réserve** (« Stems to place ») ; on les glisse sur la tranche voulue (ou clic droit → « Place on strip »). Un fichier déposé directement sur une tranche y est affecté. Un stem peut être déplacé vers une autre tranche, renvoyé dans la réserve ou retiré. Exemple : un dossier qui contient aussi le mix complet — l'utilisateur ne le place simplement sur aucune tranche.
- Les noms de tranche sont déduits des noms de fichiers (préfixe et suffixe communs retirés : « Artiste - Titre (Basse)_1 » → « BASSE »). Les fichiers non audio (ex. `.asd` d'Ableton) sont ignorés.
- **Plusieurs stems par tranche** possibles (ex. « kick » + « snare » sur la tranche 1) : ils sont sommés avant le fader.
- Lecture **en streaming depuis le disque**, démarrage de tous les stems **calé à l'échantillon**.
- Stems de longueurs différentes acceptés (le plus long fixe la durée du morceau) ; fréquences d'échantillonnage différentes converties automatiquement.

### 5.2 Page MIX (BANK LEFT)

Par tranche :

| Contrôle | Fonction |
|---|---|
| Potard haut | Envoi **Delay** |
| Potard milieu | Envoi **Reverb** |
| Potard bas | Envoi **Bus 3** (phaser par défaut) |
| Fader | Volume de la tranche (repère de gain unité) |
| MUTE | Mute on/off, LED = état |
| SOLO maintenu + MUTE | Solo on/off (solo in place ; les retours d'effets restent audibles) |
| REC ARM (maintenu) | **Dub throw** : la tranche part à fond dans le delay, **prise avant mute et fader** (on peut « lancer » une piste coupée) ; LED allumée pendant le geste |

Fader master : volume général, suivi d'un limiteur de sécurité.

**Comportement dub essentiel** : les effets sont sur des bus partagés, donc couper ou baisser une tranche n'interrompt jamais la queue d'écho ou de reverb déjà lancée.

### 5.3 Page FX (BANK RIGHT)

Les potards des tranches pilotent les paramètres d'effets ; **les faders restent des volumes de tranche** sur les deux pages. Les LEDs BANK indiquent la page active.

Proposition de disposition (à valider à l'usage) :

| Tranche | Haut | Milieu | Bas |
|---|---|---|---|
| 1 — Delay | Time | Feedback | Wow/flutter |
| 2 — Delay | Low cut | High cut | Delay → Reverb |
| 3 — Reverb | Decay | Damping | Predelay |
| 4 — Reverb | Low cut | Tone | — |
| 5 — Phaser | Rate | Depth | Feedback |
| 6 — Phaser | Center | Stereo | — |
| 7 — Retours | Retour Delay | Retour Reverb | Retour Bus 3 |
| 8 — Renvois | Reverb → (au choix) | Bus 3 → (au choix) | — |

**Renvois de bus à bus** (issue #1, en essai) : le retour de chaque bus peut partir, en plus du master, dans **un autre bus choisi par l'utilisateur**, comme sur une console dub. Menu « Send to » sur la carte de chaque bus : None, Delay, Reverb ou Bus 3. Un potard par bus dose le renvoi : celui du delay reste en tranche 2 (DLY→REV, reverb par défaut, 20 %), ceux de la reverb et du bus 3 sont en tranche 8 (aucune destination et 0 par défaut). Le libellé du potard affiche la destination (« REV→DLY », « B3→— »). **Jamais de boucle** : un choix qui en fermerait une est grisé dans le menu, et un projet qui en contiendrait une revient au routage par défaut. Changer de destination arrête le moteur un instant (queues d'effets coupées), comme changer d'effet : c'est un réglage de préparation, les potards restent jouables en direct. Renvoi et retour d'un bus sont indépendants : retour à zéro, le renvoi passe quand même. Les potards de renvoi restent du routage quand un bus héberge un plugin : les 6 macros de la reverb et du bus 3 ne bougent pas. Pas de renvoi depuis les inserts de tranche. Écarté pour l'instant : empiler plusieurs effets dans un même bus (voir l'issue).

**Lisibilité à l'écran** : chaque tranche a deux zones. En haut, les potards : sur la page FX leur en-tête annonce l'effet piloté (DELAY, REVERB, PHASER, RETURNS) et la zone prend la teinte du bus. En bas, ce qui appartient au stem sur les deux pages : son nom, MUTE, THROW et le fader — le nom ne bouge donc pas quand on change de page.

**Rattrapage (soft takeover)** : les potards ne sont pas motorisés. Après un changement de page, un potard n'agit que lorsqu'il a rejoint ou croisé la valeur courante ; l'écran affiche sa position physique en « fantôme ». Au démarrage, **SEND ALL** cale l'app sur la console.

Quand un bus héberge un plugin AU, ses 6 emplacements de la page FX deviennent des **macros** que l'utilisateur affecte aux paramètres du plugin.

### 5.4 Effets intégrés

Objectif : un son crédible pour le dub sans aucun plugin tiers.

- **Dub Delay (tape echo)** : temps libre (ms) ou calé au tempo (1/16 → 1/2, dont 1/8 pointé et 1/4 pointé), changement de temps avec glissement de hauteur façon bande, feedback jusqu'à l'auto-oscillation contrôlée par saturation, filtres passe-haut/passe-bas dans la boucle, wow/flutter, envoi du delay vers la reverb.
- **Reverb** : plate de Dattorro (entrée mono, sortie stéréo) — decay, damping, predelay, coupe-bas, tone. Un second modèle **ressort** arrive en M7 (§ 11.4).
- **Phaser type Bi-Phase** — le « gros » phaser du reggae 70/80 : deux phaseurs 6 étages en série, résonance poussée (tenue par une saturation), balayage jusqu'à ± 2,5 octaves, LFO déphasé entre gauche et droite. Réglages : rate, depth, resonance, fréquence centrale, largeur stéréo. **Sa sortie est 100 % déphasée** : l'effet vit sur un bus d'envoi, et c'est sa somme avec le signal direct de la tranche qui creuse les encoches (complètes avec l'envoi à fond et le retour à 0 dB, valeur par défaut).
- **Master** : limiteur de sécurité transparent.

### 5.5 Slots Audio Unit

- Chaque bus (Delay, Reverb, Bus 3) a un **slot** : l'effet intégré (défaut) ou **n'importe quel plugin AU d'effet installé**. Le nom de l'effet, sur sa carte, est un menu : effet intégré, ou plugins rangés par éditeur ; « Open plugin window » ouvre l'interface du plugin.
- Chargement **dans un processus séparé** quand c'est possible (sinon dans l'app, signalé « in-process ») : un plugin qui plante ne tue pas l'app en live. Vérifié avec AudioThing Dub Filter, iZotope Vinyl et TAL Reverb 4.
- **Potards macros** : sur la page FX, les 6 potards du bus (5 pour le delay, dont le 6e reste DLY→REV, qui est du routage) deviennent des macros. Vides la première fois ; l'utilisateur affecte à chacun un paramètre du plugin (menu sous le potard). **Les affectations sont mémorisées par plugin** et reproposées dans tous les morceaux. Un réglage fait dans la fenêtre du plugin se reflète sur le potard (avec rattrapage du potard physique).
- Le projet enregistre, par bus : le plugin, **son état complet** (réglages, preset) et ses macros.
- Plugin absent à l'ouverture d'un projet → l'effet intégré reste en place, un avertissement s'affiche, et le plugin **reste inscrit dans le projet** (il reviendra sur un Mac où il est installé) tant que l'utilisateur ne choisit pas autre chose pour ce bus.
- Un plugin sur un bus d'envoi doit être réglé **100 % wet** (son « mix » à fond) : le signal direct passe déjà par la tranche.
- Changer d'effet arrête le moteur une fraction de seconde (les queues d'effets sont coupées) puis la lecture reprend au même endroit : AVAudioEngine ne supporte pas ce recâblage moteur en marche.

### 5.6 Transport

- Espace : lecture/pause · retour au début · boucle du morceau on/off (calée à l'échantillon).
- Forme d'onde globale avec tête de lecture ; clic pour se déplacer.
- Affichage position / durée.

### 5.7 Tempo

- BPM **détecté quand on pose des stems sur les tranches** (jamais si un tempo est déjà connu ; bouton **AUTO** pour relancer), corrigeable : glisser sur la valeur (Maj = pas de 0,1), **tap tempo** (touche T), boutons **÷2 / ×2**. Moitié et double tempo expliquent aussi bien le signal : le détecteur répond toujours dans la plage **58–125 BPM**, ×2 donne l'autre lecture.
- **SYNC** cale le delay sur le tempo : le potard TIME choisit alors une division (1/16, 1/8, 1/8 pointé, 1/4, 1/4 pointé, 1/2) au lieu de millisecondes ; changer le tempo déplace le delay. Tempo et SYNC sont enregistrés dans le projet.
- Sert à caler le temps du delay ; le mode libre en ms reste disponible.

### 5.8 Projets et setlist

- **Projet** = un morceau, fichier `.dubstem` (JSON) : références des stems, affectation aux tranches, fichiers en réserve, BPM, réglages et slots d'effets, boucle. **Enregistrer / Ouvrir classiques** : rien n'est écrit tant que l'utilisateur n'a pas fait « Save » et choisi l'emplacement (⌘S, ⇧⌘S pour « Save As ») ; ensuite les changements sont sauvegardés automatiquement dans ce fichier. Une session jamais enregistrée demande confirmation avant d'être remplacée. Chaque fichier est référencé par chemin absolu **et** relatif au projet : le projet survit au déplacement du dossier entier.
- Les positions de faders/potards ne sont **pas** restaurées comme vérité : la console physique fait foi (rattrapage).
- **Setlist** : fichier `.dubset`, liste ordonnée de projets, affichée dans la barre latérale (clic = charger, clic droit = monter / descendre / retirer, « + Add this song »). Morceau suivant / précédent : touches **N / P**. Le morceau est **chargé à l'arrêt, au début** — l'utilisateur lance quand il veut — et les queues d'effets du précédent continuent pendant la transition. Les stems étant lus en streaming, le chargement est quasi instantané : pas de préchargement pour l'instant (à mesurer sur de gros projets).
- Stems introuvables (fichier déplacé) → signalés, bouton « Locate missing stems… » (recherche par nom de fichier dans un dossier choisi) ; tant qu'ils ne sont pas retrouvés, ils restent inscrits dans le projet.

### 5.9 Enregistrement

- Bouton REC : enregistre le **master stéréo** (après limiteur) en **WAV** (24 bits, fréquence du moteur), écriture hors thread audio. Raccourci ⌘R.
- Nommage automatique (morceau + date et heure), dans `~/Music/DubStemMix` (dossier réglable : à venir avec les réglages), chrono à l'écran, lien « show in Finder » une fois l'enregistrement terminé.
- L'enregistrement ne doit jamais provoquer de décrochage audio.

### 5.10 Interface

- Fenêtre unique, thème sombre lisible sur scène, **miroir de la console** : 8 tranches (3 potards colorés par bus, fader, vu-mètre, états mute/solo/throw, noms des stems) + master.
- Panneau FX (disposé comme la page FX de la console), indicateur de page MIX/FX.
- Barre latérale setlist · transport + forme d'onde · tempo · REC.
- Indicateurs d'état : MIDImix connectée/déconnectée, carte son, charge CPU / décrochages.
- Tout est pilotable à la souris : l'app reste utilisable sans console (avec rattrapage au retour de la console).

### 5.11 Identité visuelle

**Direction : « scène sombre épurée »** — flat, fond presque noir, gros contrôles contrastés, lisible d'un coup d'œil dans le noir à un mètre de l'écran. Aucune ombre ni dégradé décoratif, pas de skeuomorphisme.

**Disposition : miroir fidèle de la MIDImix** — 8 colonnes, 3 potards, boutons, fader, master à droite : ce qu'on touche est là où on le voit.

**Palette « reggae désaturé / terreux »** (une couleur par bus, code couleur fonctionnel) :

| Rôle | Hex |
|---|---|
| Fond · surface · bordure | `#14110F` · `#1E1A17` · `#2E2823` |
| Texte · texte secondaire | `#EDE3CF` (crème) · `#9A8F7E` |
| Delay | `#D9A441` (ocre doré) |
| Reverb | `#7E9B5A` (olive-sauge) |
| Bus 3 / phaser | `#C2553A` (brique) |
| REC (réservé à l'enregistrement) | `#E5412D` |

**Typographie** : grotesque à caractère, grasse et légèrement large pour les libellés (**Archivo**, OFL) + monospace pour les valeurs — BPM, temps, ms (**JetBrains Mono**, OFL). Polices embarquées dans l'app.

**Principes** : potard = arc plein de la couleur du bus · MUTE = bloc crème inversé (même signal que la LED) · throw = flash ocre tant que le bouton est tenu · vu-mètres sauge → ocre → rouge · potard « fantôme » = repère crème tant que le physique n'a pas rattrapé la valeur · libellés en capitales.

### 5.12 Réglages

Carte son et taille de buffer · dossier d'enregistrement · mode pré/post par bus · gestion des plugins AU.

## 6. Exigences non fonctionnelles

| | Cible |
|---|---|
| Latence | Buffer 128–256 échantillons ; geste → son perçu comme immédiat (< 15 ms hors carte son) |
| Stabilité | Zéro décrochage avec 16 stems + 3 effets sur un Mac Apple Silicon d'entrée de gamme ; 2 h de lecture continue sans dérive ni fuite mémoire |
| Changements de paramètres | Sans « zipper noise » (lissage de tous les gains et paramètres) |
| Robustesse live | Débranchement/rebranchement de la MIDImix et de la carte son sans redémarrer ; plantage d'un AU isolé ; sauvegarde automatique |
| Démarrage | App prête en < 3 s ; projet de 8 stems chargé en < 2 s (streaming) |
| Distribution | **Pas de compte Apple Developer** : app non notarisée, publiée sur GitHub Releases (signature ad hoc) + compilation depuis les sources. Le README documente l'ouverture malgré Gatekeeper (Réglages → Confidentialité et sécurité → « Ouvrir quand même ») |

## 7. Architecture technique (esquisse)

- **UI** : SwiftUI, état observable ; aucun travail UI sur le thread audio.
- **Audio** : `AVAudioEngine`. Par stem : `AVAudioPlayerNode` (streaming fichier, départ synchronisé sur un même `AVAudioTime`). Par tranche : un mixeur. Envois : fan-out de la tranche vers le master et les 3 bus (`AVAudioConnectionPoint` + volume par destination via `AVAudioMixingDestination`). Bus : effet (intégré ou AU) → retour → master → limiteur → sortie.
- **Effets intégrés** : `AUAudioUnit` internes à l'app (`BuiltInEffect`), insérées dans le moteur comme le seront les plugins tiers. Les noyaux DSP temps réel sont écrits en **C** (cible `DubDSP` : petits, isolés, sans allocation ni verrou, testés directement), tout le reste en Swift. C'est la pratique recommandée par Apple : Swift pur n'offre pas de garanties temps réel sur le thread audio.
- **Hébergement AU** : `AVAudioUnitComponentManager` + instanciation hors processus si possible ; `fullState` pour la sauvegarde.
- **MIDI** : CoreMIDI, entrée + sortie (LEDs), reconnexion à chaud. Le mapping vit dans un **profil de contrôleur** (données, pas de code) → autres contrôleurs plus tard. Fait le 22/09/2026 : `ControllerProfile` (tables CC/notes, nom du périphérique, LEDs), le MIDImix est le premier profil ; une console de même géométrie s'ajoute par un profil, une géométrie différente demanderait de toucher à l'interface et à la logique (FAQ du README).
- **Contrôleur logique** : couche indépendante de l'UI et du MIDI qui gère pages, rattrapage, throw, mute/solo — testable unitairement.
- **Enregistrement** : tap sur la sortie master → `AVAudioFile`.
- **Projet** : paquet `.dubstem` (JSON + références de fichiers) ; setlist `.dubset`.
- **Tests** : unitaires sur le contrôleur logique, le mapping et le DSP (rendu hors ligne) ; `tools/midi-monitor.swift` pour diagnostiquer la console.

### Risques techniques (à lever en premier)

1. **Envois et lissage dans AVAudioEngine** — ✅ **levé au M0**. Les envois passent par les volumes par destination d'un fan-out (`AVAudioMixingDestination`) ; le mixeur d'Apple lisse lui-même chaque changement de volume (~25 ms, mesuré hors ligne, aucun saut). Limites constatées : volumes plafonnés à 1,0 (→ tranches et master travaillent 6 dB sous l'unité, rattrapés par un étage de gain final) ; une tranche sans stem n'a pas de destination d'envoi (→ niveaux mémorisés et réappliqués) ; `nextAvailableInputBus` ignore les fan-out (→ bus attribués explicitement).
2. **Synchronisation de 8–16 lecteurs** en streaming, boucle et seek calés à l'échantillon — ✅ **levé au M0/M1** (tests hors ligne au sample près : départ, boucle avec stems de longueurs différentes, seek).
3. **Recâblage à chaud** — tranché au M4 : changer de **morceau** ne coupe pas les queues d'effets (seuls les lecteurs changent) ; changer d'**effet** sur un bus impose d'arrêter le moteur un instant (AVAudioEngine lève une exception interne au 3e recâblage d'un même bus moteur en marche) — acceptable : on ne change pas de plugin au milieu d'un morceau.
4. **Latence des plugins AU** non compensée par AVAudioEngine : acceptable sur des bus d'effets (100 % wet), à documenter.
5. **Détection de BPM** fiable sur du reggae (ambiguïté demi/double tempo) → d'où tap et ×2/÷2.

Si les risques 1 à 3 s'avèrent bloquants, plan B déjà identifié : garder l'UI SwiftUI et remplacer le cœur audio par un moteur C++ dédié.

## 8. Hors périmètre v1

VST3 · sortie cue/casque · autres contrôleurs et MIDI learn · enregistrement des gestes (automation) et des retours séparés · marqueurs/sections et boucles de passages · time-stretch / pitch · sirène dub / générateur de sons · interface localisée · iPad.

Pistes notées pour la suite : cue casque, second contrôleur dédié aux effets, enregistrement de la performance, séparation de stems intégrée, sirène dub (écartée de la v2 le 22/09/2026 : c'est un instrument, pas un effet).

## 9. Jalons

| Jalon | Contenu | Validation |
|---|---|---|
| **M0 — Spike** | Graphe AVAudioEngine : 8 stems synchronisés, envois vers un bus, lissage, MIDImix entrée + LEDs | Les risques 1 et 2 sont levés (ou le plan B est déclenché) ; LEDs et SOLO+MUTE confirmés |
| **M1 — Mix** | Import de stems, tranches, faders/mutes/solo, transport, vu-mètres, UI miroir | On mixe un morceau à la console, le ressenti est bon |
| **M2 — Effets** | Delay, reverb, phaser intégrés ; page FX ; rattrapage ; dub throw | Un vrai dub mix jouable, son convaincant |
| **M3 — Morceaux** | Projets, setlist, BPM auto + tap, enregistrement WAV | Un set de plusieurs morceaux enchaînés et enregistré |
| **M4 — Audio Units** | Slots AU, fenêtre plugin, macros, état sauvegardé | TAL Reverb 4 / Dub Filter utilisables sur un bus |
| **M5 — Publication** | README (dont contournement Gatekeeper), onboarding, release GitHub, évaluation du support de macOS 15/14 | Un inconnu installe et joue en moins de 5 minutes |
| **M6 — Master** | Page MASTER (3e page), chaîne master : big knob, kills, dubplate, pull-up ; geste DROP | Un mix « sound system » jouable : on retire les basses sur le temps, on rembobine, on drop |
| **M7 — Delay et reverb** | HOLD, têtes Space Echo et ping-pong, throw configurable ; reverb à ressort + CRASH | Le delay se tient en boucle, le ressort claque |
| **M8 — Inserts** | Slot d'insert par tranche (intégrés + AU), renfort de sub, auto-wah ; flanger à bande sur le bus 3 ; page INSERTS | Sub sur la basse, wah sur le skank, sans plugin tiers |
| **M9 — Séparation** | Un morceau complet déposé → 4 stems (htdemucs_ft via ONNX Runtime) sur les tranches 1 à 4 ; modèles téléchargés au premier usage, jamais embarqués | Un MP3 glissé donne un dub mixable en quelques minutes, sans rien installer |

## 10. Points ouverts

1. **SOLO + MUTE** : confirmer les notes émises par la console (non testé pendant le M0 — à faire au M1).
2. **Disposition de la page FX** : à ajuster après les premiers essais en M2.
Points tranchés depuis la v0.1 : identité visuelle **validée sur maquette SwiftUI** (`swift run`, § 5.11) · LEDs confirmées (MUTE allumée = coupée) · cible macOS 26 · pas de compte Apple Developer · nom « DubStemMix » définitif.

## 11. v2 — Effets et gestes dub (jalons M6 à M8)

Décidé en interview le 22 septembre 2026, à partir des propositions du TODO § 5. Tout est retenu **sauf la sirène** (un instrument, pas un effet). Les effets vivent à deux endroits nouveaux : une **chaîne d'inserts sur le master** et un **slot d'insert par tranche** ; les bus d'envoi existants reçoivent leurs compléments (delay, reverb, bus 3).

### 11.1 Pages de la console

La MIDImix n'a plus de potard libre (page MIX = envois, page FX = 21 paramètres). Deux pages s'ajoutent :

| Page | Accès | LEDs BANK | Potards |
|---|---|---|---|
| MIX | BANK LEFT | gauche | envois |
| FX | BANK RIGHT | droite | effets des bus (inchangé) |
| **MASTER** (M6) | BANK RIGHT depuis FX | les deux | chaîne master et compléments delay (§ 11.2) |
| **INSERTS** (M8) | BANK RIGHT depuis MASTER | les deux | l'insert de chaque tranche (§ 11.5) |

**BANK LEFT ramène toujours à MIX** en un appui (en live, le retour au mix ne se cherche pas). BANK RIGHT avance d'une page : FX → MASTER → INSERTS, puis reste sur INSERTS. L'écran affiche la page en gros ; les faders restent des volumes de tranche sur toutes les pages ; le rattrapage des potards s'applique comme sur la page FX.

### 11.2 Page MASTER — disposition (à valider à l'usage, comme la page FX)

| Tranche | Haut | Milieu | Bas |
|---|---|---|---|
| 1 — Big knob | **Big knob** (passe-haut à crans) | — | — |
| 2 — Kills | **BASS** | **MID** | **TOP** |
| 3 — Dubplate | **Intensité** | Craquements | — |
| 4 — Delay+ | **Têtes** (motif) | **Ping-pong** (largeur) | — |
| 5 à 8 | libres | | |

Les cases vides restent vides : on ne remplit pas pour remplir.

### 11.3 Chaîne master (M6)

Dans l'ordre du signal : somme des tranches et des retours → **big knob** → **kills** → **dubplate** → **pull-up** → rattrapage de gain → limiteur → sortie. Chaque étage est neutre par défaut (aucun changement de son tant qu'on n'y touche pas) et se contourne (bypass) individuellement à l'écran.

- **Big knob** (King Tubby, console MCI) : passe-haut **à crans** — 20 Hz (off), 70, 100, 150, 200, 300, 500, 800 Hz, 1, 2, 5, 10 kHz —, pente 12 dB/oct, **sans résonance**, passage d'un cran à l'autre lissé (pas de clic) mais audible comme un palier. Un seul potard.
- **Kills** (préampli de sound system) : isolateur 3 bandes **BASS / MID / TOP**, coupures 200 Hz et 2,5 kHz (filtres Linkwitz-Riley 24 dB/oct : la somme des trois bandes à fond est transparente). Chaque potard va du kill complet (−∞) à 0 dB, à fond par défaut ; pas de boost.
- **Dubplate** : le son d'un acétate joué cent fois — saturation de bande douce, bande passante réduite (bas et haut), léger pleurage. **Un potard d'intensité** (0 = contourné) ; un second potard, à part, pour les **craquements** (0 par défaut).
- **Pull-up / rewind** (geste, § 11.6) : ralentissement de la lecture jusqu'à l'arrêt (bande qui freine, hauteur qui tombe, en ~1 s), **retour au début et relance immédiate**. S'applique au master (varispeed) : les queues d'effets freinent avec le morceau, c'est le son recherché.

### 11.4 Compléments delay et reverb (M7)

- **HOLD / freeze** (geste) : tant qu'on tient, le delay ferme son entrée et réinjecte à 100 % (tenu par la saturation de la boucle) : la boucle tourne pendant qu'on coupe tout le reste. Au relâchement, retour au feedback réglé.
- **Têtes multiples** (Space Echo) : le potard TÊTES choisit un **motif** de répétitions parmi les combinaisons du RE-201 (tête 1, 2, 3, 1+2, 2+3, 1+3, 1+2+3 ; espacement 1 : 2 : 3 du temps de delay) ; le motif « tête 1 » est le delay actuel. **Ping-pong** : les répétitions alternent gauche / droite, le potard règle la largeur (0 = mono centré, comme aujourd'hui).
- **Throw configurable** : le dub throw part vers le **delay** (défaut), la **reverb**, ou **les deux**. Menu sur la carte du delay, enregistré dans le projet.
- **Reverb à ressort** : second modèle dans le menu du slot REVERB (Plate / **Spring**), même potards (decay, damping, predelay, coupe-bas, tone) réinterprétés pour le ressort (dispersion, « boing »). Modèle enregistré dans le projet.
- **CRASH** (geste) : on frappe le ressort — une impulsion forte dans la ligne du ressort, le coup de tonnerre de Tubby et de Perry. Disponible quand le modèle Spring est sélectionné ; sur Plate, le geste ne fait rien (signalé à l'écran).

### 11.5 Inserts de tranche (M8)

- Chaque tranche a un **slot d'insert** entre sa somme de stems et son fader : vide (défaut), un effet intégré, ou **n'importe quel plugin AU** (compresseur sur la basse…). Même mécanique que les slots de bus : chargement hors processus, état complet et macros enregistrés dans le projet, plugin absent signalé et conservé.
- Effets intégrés d'insert : **Renfort de sub** (générateur d'octave grave façon dbx « boom box » : quantité, fréquence de coupure) et **Auto-wah** façon Mu-Tron III (filtre à suivi d'enveloppe : sensibilité, plage, résonance, sens haut/bas).
- **Page INSERTS** : les 3 potards de chaque tranche pilotent son insert (paramètres de l'effet intégré, ou 3 macros pour un plugin). Tranche sans insert : potards inertes.
- Un plugin d'insert est réglé **au mix voulu** (pas 100 % wet, contrairement aux bus) : il est dans le chemin direct.
- **Flanger à bande** : alternative au Bi-Phaser dans le menu du slot du bus 3, mêmes potards (rate, depth, feedback, centre, stéréo).

### 11.6 Gestes momentanés

Au **clavier et à l'écran** (bouton maintenu) ; la console garde son mapping d'usine et ses boutons.

| Geste | Touche | Effet tant qu'on tient |
|---|---|---|
| **DROP** | D | coupe toutes les tranches sauf celles marquées **KEEP** (case à l'écran, enregistrée dans le projet : basse + batterie, le « riddim ») ; relâcher rend tout |
| **HOLD** | H | le delay boucle sur lui-même (§ 11.4) |
| **CRASH** | C | frappe le ressort (§ 11.4) — appui, pas maintien |
| **Pull-up** | R | rembobine (§ 11.3) — appui, pas maintien |

Les gestes ne touchent pas aux états de MUTE / SOLO : au relâchement de DROP, le mix revient exactement à ce qu'il était.

### 11.7 Ce qui s'enregistre dans le projet

Réglages de la chaîne master et des compléments (nouveaux cas de `FXParameter`, même mécanique que la page FX), modèle de reverb, cible du throw, marques KEEP, et par tranche l'insert (effet intégré + réglages, ou plugin + état + macros).

### 11.8 Architecture

- **Master** : les étages s'insèrent entre le mixeur principal et le rattrapage de gain, chacun entre deux nœuds neutres fixes (même recette que les bus : un changement à chaud ne touche jamais aux mixeurs). Pull-up : `AVAudioUnitVarispeed` sur le master.
- **Inserts** (construit en M8) : `somme des stems → entrée neutre → effet → sortie neutre → mixeur « pré » (prises pré-fader et throw) → mixeur fader (master + envois post)`. Les nœuds neutres existent dès le départ pour toutes les tranches ; un insert vide est un simple passage. Conséquence : les envois pré-fader et le dub throw sont pris **après** l'insert (un sub ajouté sur la basse part aussi dans le delay).
- **Noyaux DSP en C** (`DubDSP`), sans allocation ni verrou : passe-haut à crans, isolateur, dubplate, ressort (+ crash), têtes et ping-pong dans `dub_delay.c`, HOLD dans la boucle du delay, sub, auto-wah, flanger. Chacun testé en rendu hors ligne.
- **Contrôleur logique** : pages MASTER et INSERTS, disposition en données comme `FXParameter.layout`, rattrapage inchangé.

## 12. Séparation de stems (jalon M9)

Cadré le 22 septembre 2026 à partir de la spec « Séparation de stems avec htdemucs_ft » (POC validé sur un morceau réel). Cette spec fait foi pour le moteur (modèle, format, runtime, pipeline, mémoire, licences) ; ce chapitre fixe ce qui est propre à DubStemMix.

### 12.1 Geste

- Une **zone de dépôt dédiée** dans la barre latérale (« SPLIT A SONG ») et un menu Fichier « Split a Song… ». Un fichier audio déposé ailleurs reste un stem ordinaire qui va dans la réserve : l'app ne devine rien.
- Résultat : **nouvelle session** (confirmation si la session courante n'est pas enregistrée), les 4 stems posés **dans l'ordre batterie, basse, instruments, voix sur les tranches 1 à 4**, l'original dans la réserve pour l'écoute A/B, tempo détecté, titre = nom du morceau.
- Lecture en cours au moment du dépôt : un dialogue prévient (« plusieurs minutes de calcul intensif, risque de décrochage ») et laisse choisir. À l'arrêt, aucun dialogue.

### 12.2 Modèles

- `htdemucs_ft` en ONNX (dépôt `StemSplitio/htdemucs-ft-onnx`, révision épinglée), 4 réseaux fp16, ~663 Mo, exécutés sur CPU par ONNX Runtime (paquet SwiftPM Microsoft).
- **Jamais dans le dépôt, la release ni le bundle.** Au premier usage, un écran explicite propose le téléchargement, indique la taille et le statut de licence des poids ; rien n'est téléchargé sans accord. Reprise après coupure, vérification taille + SHA-256, fichier invalide retéléchargé.
- Emplacement : `~/Library/Application Support/DubStemMix/Models/htdemucs_ft/<révision>/`. Les Réglages montrent l'état des modèles (absents, partiels, prêts), permettent de les télécharger ou de les supprimer.
- Un fichier `NOTICE` dans le dépôt liste le modèle, sa provenance et le statut de licence des poids (non explicite chez Meta, MUSDB18-HQ « educational purposes only »), sans prétendre les relicencier ; l'écran de téléchargement et les Réglages l'affichent.

### 12.3 Stems produits

- Écrits dans **`~/Music/DubStemMix/Stems/<titre> [empreinte]/`** (dossier durable, réglable), en WAV Float32 44,1 kHz : `drums.wav`, `bass.wav`, `instruments.wav`, `vocals.wav`, plus un manifeste (empreinte du fichier source, identifiant du modèle). Un morceau déjà séparé avec le même modèle se rouvre **sans recalcul**.
- Pas de cache purgeable : un projet `.dubstem` référence ces fichiers.

### 12.4 Pendant le calcul

- Job en tâche de fond (priorité utilitaire, jamais sur le thread principal), **un seul à la fois**, annulable en moins de 3 s.
- Progression dans la barre latérale : stem en cours (« vocals… »), pourcentage, estimation du temps restant ; notification système à la fin si l'app n'est pas au premier plan. L'interface reste réactive.
- Ordre d'exécution imposé par la mémoire : un réseau à la fois sur tout le morceau (pic ~8 Go), stem écrit sur disque dès que son réseau a fini.

### 12.5 Vérification

- Unitaire, sans modèle : fenêtre et poids de l'overlap-add, nombre de blocs, décodage (mono 22,05 kHz, stéréo 48 kHz), affectation des lignes du bag avec un faux séparateur, annulation.
- Avec les vrais modèles (hors CI) : `--split <fichier>` en ligne de commande rapporte Σ stems vs mix (≥ 25 dB attendu) et l'énergie par stem ; mix synthétique voix + basse + batterie → `instruments` < −40 dB. Le POC n'étant pas disponible, pas de test de parité à −60 dB.
