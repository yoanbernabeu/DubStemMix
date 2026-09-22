# DubStemMix — ce qui reste à faire

> État au 22 septembre 2026. Jalons M0 à M3 validés, M4 livré (en attente d'essai), dette PRD (§ 2) résorbée sauf tests de charge, robustesse (§ 3) validée, M6 validé, M7 validé. La référence produit reste `PRD.md`.
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
- [x] Stems de **fréquences d'échantillonnage différentes** — testé le 22/09 (44,1 + 48 kHz alignés au sample près, à l'étalement du convertisseur près) ; un retard de 22 ms du départ hors ligne corrigé au passage.

## 4. M5 — Publication

- [ ] Vraie **app `.app`** avec icône, lançable sans terminal (aujourd'hui : `swift run`). **[toi]** pour l'icône.
- [ ] **README** (installation, prise en main, contournement de Gatekeeper puisque l'app n'est pas notarisée, plugin à régler 100 % wet, limites connues) et **LICENSE** MIT.
- [ ] **Accueil au premier lancement** : console non détectée, rappel du SEND ALL, mapping d'usine requis. **[toi]** pour le contenu.
- [ ] **Release GitHub** (archive de l'app) et, si tu veux, formule Homebrew.
- [ ] Nettoyage avant passage en public : noms de stems neutres dans les tests (ils citent « Akae Beka - Don't Feel No Way »), suppression de la cible `M0Spike`.
- [ ] Évaluer le support de **macOS 15 / 14** (seulement si presque aucune adaptation).
- [ ] Passer le repo en **public**. **[toi]**

## 5. Effets et gestes dub — tranché le 22/09, voir PRD § 11

Interview faite : tout est retenu **sauf la sirène**. Les décisions (pages MASTER et INSERTS, chaîne master, inserts de tranche, compléments delay/reverb, gestes, stockage) sont dans le PRD § 11 ; les jalons M6, M7, M8 dans le PRD § 9.

- [x] **M6 — Master** — livré et validé le 22/09 : page MASTER (BANK RIGHT deux fois, BANK LEFT = retour MIX), big knob à crans, kills BASS/MID/TOP, dubplate + craquements, pull-up (R), DROP (D maintenu) avec marques KEEP enregistrées dans le projet.
- [x] **M7 — Delay et reverb** — livré et validé le 22/09 : HOLD (H maintenu), têtes Space Echo et ping-pong (tranche 4 de la page MASTER), cible du throw (menu du slot delay), reverb à ressort (menu du slot reverb) + CRASH (C).
- [ ] **M8 — Inserts** : slot d'insert par tranche (intégrés + AU), sub, auto-wah, page INSERTS, flanger à bande sur le bus 3.
- [ ] **[toi]** Valider la disposition de la page MASTER (PRD § 11.2) et les touches des gestes (§ 11.6) à l'usage.

## 6. Idées pour plus tard (hors v1, notées dans le PRD)

- [ ] Sortie **cue / casque** pour pré-écouter une tranche.
- [ ] **Second contrôleur** dédié aux effets ; autres contrôleurs que la MIDImix (le mapping est déjà isolé).
- [ ] Enregistrement de la **performance** (gestes) pour rejouer, corriger ou ré-exporter un mix ; **export hors ligne** (le moteur sait déjà rendre hors ligne, c'est ce qu'utilisent les tests).
- [ ] Enregistrement des **retours d'effets séparés** pour retravailler dans un DAW.
- [ ] **Marqueurs / sections** et boucles de passages.
- [ ] **Séparation de stems intégrée** à partir d'un morceau complet.
- [ ] Interface localisée (français), time-stretch / pitch, version iPad.
