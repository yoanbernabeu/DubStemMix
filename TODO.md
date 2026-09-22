# DubStemMix — ce qui reste à faire

> État au 22 septembre 2026. Jalons M0 à M3 validés, M4 livré (en attente d'essai), dette PRD (§ 2) résorbée sauf tests de charge et reverb à ressort. La référence produit reste `PRD.md`.
> Légende : **[toi]** = demande un essai ou une décision de ta part.

## 1. À essayer ou à confirmer

- [ ] **[toi]** Valider le **M4** à l'oreille : charger TAL Reverb 4 / Dub Filter sur un bus, fenêtre du plugin, affectation des macros, réouverture d'un projet avec plugin.
- [ ] **[toi]** Confirmer le geste **SOLO maintenu + MUTE** sur la console (l'app attend les notes 2, 5, 8…, jamais capturées). S'il ne marche pas : relever les vraies notes avec `tools/midi-monitor.swift`.
- [ ] **[toi]** Juger sur un vrai set si le **chargement du morceau suivant** est assez rapide sans préchargement.
- [ ] **[toi]** Juger si la **coupure des MUTE** (rampe d'environ 25 ms imposée par le mixeur d'Apple) est assez franche pour des cuts dub secs.
- [x] **[toi]** Fenêtre Réglages (carte son, buffer, dossier, envois PRE) — validée le 22/09.
- [x] **[toi]** Ligne DSP de la barre d'état — validée le 22/09 (le test de charge à 16 stems reste à faire, § 2).
- [ ] **[toi]** Provoquer l'avertissement **« console not on factory mapping »** (par exemple en envoyant un CC depuis un autre contrôleur nommé « MIDI Mix », ou en reconfigurant un potard avec l'éditeur Akai) pour valider le message.

## 2. Promis dans le PRD, pas encore fait

- [x] **Envois pré/post réglables par bus** (PRD § 3) — fait le 22/09 : réglage dans la fenêtre Réglages, étiquette PRE/POST vivante sur le rack.
- [x] **Écran de réglages** (PRD § 5.12) — fait le 22/09 : ⌘, → carte son, taille de buffer, dossier d'enregistrement, pré/post par bus, rescan des plugins AU. Préférences propres au Mac (pas au projet).
- [x] **Indicateur de charge DSP et de décrochages** (PRD § 5.10) et nom de la carte son — fait le 22/09 (ligne DSP et ligne AUDIO de la barre d'état ; `--check-audio` pour vérifier sans interface).
- [x] **Console reconfigurée** (PRD § 4) — fait le 22/09 : encart dans la barre latérale avec le message reçu et la remise à zéro via l'éditeur Akai.
- [ ] **Tests de charge** (PRD § 6) : 16 stems + 3 effets sans décrochage ; 2 h de lecture continue sans dérive ni fuite mémoire ; temps de démarrage et de chargement. La ligne DSP donne maintenant la mesure.
- [ ] **Couleur « ressort » pour la reverb** (PRD § 5.4) — voir § 5 ci-dessous.
- [x] Mettre à jour l'en-tête du PRD — fait le 22/09 (version 1.0, statut validé).

## 3. Robustesse et dette technique

- [x] **Plugin qui plante** — fait le 22/09 : sondage une fois par seconde (la notification système ne vient pas pour les AU v2 hors processus), retour à l'effet intégré, avertissement, slot conservé dans le projet. Vérifié par `--check-plugin-crash`.
- [x] **Plugin sans fenêtre propre** — fait le 22/09 : vue générique Apple dans une fenêtre à défilement (cas jamais rencontré sur macOS 26, tous les plugins répondent).
- [ ] **Événements MIDI sur le thread principal** : surveiller la latence quand l'écran est très sollicité ; si besoin, appliquer les niveaux hors du thread principal.
- [ ] **Vu-mètres** : AVAudioEngine livre les mesures par paquets (~100 ms) ; à fluidifier si c'est gênant.
- [ ] **Micro-coupure** quand on pose ou retire un stem pendant la lecture, et **arrêt bref du moteur** quand on change d'effet sur un bus (limite d'AVAudioEngine, voir PRD § 7).
- [ ] **Latence des plugins non compensée** (acceptable sur des bus 100 % wet) : à documenter dans le README (→ M5).
- [x] **Renommer une tranche** — fait le 22/09 : double-clic ou clic droit sur la plaque de nom, enregistré dans le projet.
- [x] **Setlist** — fait le 22/09 : glisser-déposer d'une ligne sur une autre, double-clic sur le titre pour renommer.
- [x] Changement de carte son **avec des plugins chargés** — vérifié le 22/09 par `--check-audio` (Dub Filter hors processus conservé et vivant après deux bascules).
- [x] Stems de **fréquences d'échantillonnage différentes** — testé le 22/09 (44,1 + 48 kHz alignés au sample près, à l'étalement du convertisseur près) ; un retard de 22 ms du départ hors ligne corrigé au passage. **[toi]** à confirmer à l'oreille sur de vrais fichiers mélangés.

## 4. M5 — Publication

- [ ] Vraie **app `.app`** avec icône, lançable sans terminal (aujourd'hui : `swift run`). **[toi]** pour l'icône.
- [ ] **README** (installation, prise en main, contournement de Gatekeeper puisque l'app n'est pas notarisée, plugin à régler 100 % wet, limites connues) et **LICENSE** MIT.
- [ ] **Accueil au premier lancement** : console non détectée, rappel du SEND ALL, mapping d'usine requis. **[toi]** pour le contenu.
- [ ] **Release GitHub** (archive de l'app) et, si tu veux, formule Homebrew.
- [ ] Nettoyage avant passage en public : noms de stems neutres dans les tests (ils citent « Akae Beka - Don't Feel No Way »), suppression de la cible `M0Spike`.
- [ ] Évaluer le support de **macOS 15 / 14** (seulement si presque aucune adaptation).
- [ ] Passer le repo en **public**. **[toi]**

## 5. Effets intégrés très typés dub — propositions

Rien n'est décidé ici : ce sont des propositions à trier ensemble. Pour chacune : ce que c'est, la référence, et comment elle tiendrait sur la MIDImix.

### Les plus « signature »

- [ ] **Reverb à ressort + « crash »** — le ressort qu'on frappe pour déclencher un coup de tonnerre (Fisher Space Expander de King Tubby, Lee Perry au Black Ark). Un second modèle de reverb sur le bus REVERB (choix Plate / Spring dans le menu du slot), et un geste **CRASH** momentané. *Console : un bouton à trouver — par exemple REC ARM de la tranche 8 quand elle est vide.*
- [ ] **Le « big knob » de King Tubby** — le passe-haut à crans de sa console MCI (70 Hz → 10 kHz par paliers), balayé sur tout le mix ou sur un groupe : LE geste Tubby. Filtre passif, sans résonance, à paliers audibles. *Console : page FX, potard du haut de la tranche 8 (aujourd'hui libre), appliqué au master.*
- [ ] **Kills de sound system** — coupe-bandes BASS / MID / TOP façon préampli de sound system : on retire les basses, on les relâche sur le temps. Isolateur 3 bandes sur le master. *Console : page FX, les 3 potards de la tranche 8 — en concurrence avec le big knob : à arbitrer, ou l'un sur les potards et l'autre ailleurs.*
- [ ] **Sirène dub** — l'oscillateur à LFO des sound systems (type NJD), envoyé dans le delay. C'est un instrument plus qu'un effet : hauteur, vitesse, forme du LFO, et un déclenchement momentané. *Console : à définir (un bouton + 2 réglages) ; pourrait vivre dans une troisième page.*

### Autour du delay

- [ ] **Hold / freeze** — l'écho se referme sur lui-même (entrée coupée, réinjection à 100 %) tant qu'on tient le bouton : la boucle tourne pendant qu'on coupe tout le reste.
- [ ] **Têtes multiples façon Space Echo** — combinaisons de têtes du RE-201 (rythmes d'échos syncopés) au lieu d'une seule répétition, et mode **ping-pong** stéréo.
- [ ] **Throw configurable** — choisir vers quel bus part le dub throw (delay, reverb, les deux). Déjà évoqué pendant le cadrage.

### Sur le master, pour le caractère

- [ ] **Pull-up / rewind** — l'arrêt de bande et le retour arrière du selector qui « rewind » le morceau : ralentissement de la lecture, retour au début, relance. *Console : un bouton ; touche clavier en attendant.*
- [ ] **Couleur « dubplate »** — saturation de bande, bande passante réduite, léger pleurage, craquements optionnels : le son d'un acétate joué cent fois. Un seul réglage d'intensité.
- [ ] **Renfort de sub** — générateur d'octave grave façon dbx « boom box », pour le poids sound system. Plutôt sur une tranche (la basse) que sur le master : demande un insert par tranche, ce que l'architecture n'a pas encore.

### Alternatives pour le bus 3

- [ ] **Flanger à bande** — le flanging des années 70, en alternative au Bi-Phaser dans le menu du slot.
- [ ] **Auto-wah façon Mu-Tron III** — le filtre à suivi d'enveloppe du skank et du clavinet reggae. Attention : c'est un effet d'insert, il sonne mal en envoi parallèle — même contrainte que le renfort de sub.

### Gestes de mix (pas des effets, mais dans le même esprit)

- [ ] **DROP** — un geste qui coupe tout sauf les tranches choisies (basse + batterie : le « riddim »), puis relâche. Aujourd'hui faisable à la main avec les MUTE ; un bouton dédié le rendrait instantané.

### Question d'architecture que ces propositions soulèvent

- [ ] Plusieurs idées (big knob, kills, dubplate, pull-up) vivent sur le **master**, d'autres (sub, auto-wah) demandent un **insert par tranche**. Aujourd'hui l'app n'a que 3 bus d'envoi. À décider avant d'en construire une : une petite **chaîne master** d'abord (le plus simple et le plus rentable), les inserts par tranche ensuite.
- [ ] La MIDImix n'a presque plus de contrôles libres : tranche 8 de la page FX (3 potards), et c'est tout. Une **troisième page** (BANK RIGHT une seconde fois ?) ou un second contrôleur devient nécessaire au-delà de deux ou trois ajouts.

## 6. Idées pour plus tard (hors v1, notées dans le PRD)

- [ ] Sortie **cue / casque** pour pré-écouter une tranche.
- [ ] **Second contrôleur** dédié aux effets ; autres contrôleurs que la MIDImix (le mapping est déjà isolé).
- [ ] Enregistrement de la **performance** (gestes) pour rejouer, corriger ou ré-exporter un mix ; **export hors ligne** (le moteur sait déjà rendre hors ligne, c'est ce qu'utilisent les tests).
- [ ] Enregistrement des **retours d'effets séparés** pour retravailler dans un DAW.
- [ ] **Marqueurs / sections** et boucles de passages.
- [ ] **Séparation de stems intégrée** à partir d'un morceau complet.
- [ ] Interface localisée (français), time-stretch / pitch, version iPad.
