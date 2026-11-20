# DubStemMix — fonctionnalités par plateforme

> État au 20 novembre 2026 (app 0.15.1 ; app Linux : PR #19, pas encore publiée). La référence produit reste `PRD.md` : ce tableau dit seulement **où chaque fonctionnalité existe**.
> À tenir à jour dans la même PR que toute évolution.

## Légende

| Signe | Sens |
|---|---|
| ✅ | Fait, comme décrit dans le PRD |
| 🟡 | Fait, mais différent : la différence est écrite dans la case |
| ⏳ | À faire (décidé, pas encore codé) |
| ❌ | Non prévu : écart voulu, la raison est écrite dans la case |
| ❔ | À trancher : écart constaté, jamais décidé |
| · | Pas encore cadré |

**Colonne Linux / Windows** : c'est l'app de `desktop/` (PRD § 17), sous Linux. Elle est vérifiée par ses tests automatiques et par des essais sur le Mac de Yoan ; **rien n'a encore été essayé sur un vrai PC Linux** (son, MIDImix, LEDs). Windows n'est pas encore compilé.

Un écart voulu (❌, 🟡) n'est pas un oubli. Un ❔ en est peut-être un : ils sont repris en fin de fichier.

## 1. Stems et tranches

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Import WAV, AIFF, FLAC, MP3, M4A | § 5.1 | ✅ | ❌ WAV 44,1 kHz seulement, préparés par l'export du Mac | 🟡 OGG en plus ; M4A sur macOS seulement |
| Réserve « Stems to place », affectation à la main | § 5.1 | ✅ | ❌ L'affectation se fait sur le Mac, avant l'export | ✅ |
| Plusieurs stems par tranche | § 5.1 | ✅ | 🟡 Mixés en un seul fichier par tranche à l'export | ✅ |
| 6 tranches de stems, 7-8 tranches d'effets | § 14 | ✅ | ✅ | ✅ |
| Noms de tranche | § 5.1 | ✅ | ✅ Repris du projet à l'export | ✅ |
| Fréquences et longueurs de stems différentes | § 5.1 | ✅ | ❌ Tout est converti à l'export | ✅ |

## 2. Page MIX

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Envois Delay / Reverb / Bus 3 par tranche | § 5.2 | ✅ | ✅ | ✅ |
| Envois pré ou post-fader, par bus | § 5.12 | ✅ | 🟡 Toujours post-fader | ✅ |
| Fader, MUTE | § 5.2 | ✅ | ✅ | ✅ |
| SOLO (SOLO tenu + MUTE) | § 5.2 | ✅ | ✅ | 🟡 À l'écran : bouton SOLO, puis MUTE |
| Dub throw (REC ARM tenu) | § 5.2 | ✅ | ✅ | ✅ |
| Cible du throw : delay, reverb ou les deux | § 11.4 | ✅ | ✅ Onglet SETUP | ✅ |
| Tout à fond ne sature pas (−6 dB) | § 5.2 | ✅ | ✅ | ✅ |
| Rattrapage des potards (soft takeover) | § 5.3 | ✅ | ✅ | ✅ |
| SEND ALL au démarrage | § 5.3 | ✅ | ❌ Le plugin ne peut pas parler à la console | ❔ Pas fait |
| LEDs de la MIDImix | § 4 | ✅ | ❌ Un plugin MPC n'émet pas de MIDI : l'écran les montre | ✅ Pas encore essayé sur un PC Linux |
| PANIC (BANK LEFT + RIGHT) | § 14 | ✅ Aussi Esc | ✅ | ✅ Aussi Esc |

## 3. Tranches d'effets 7-8, sirène et Syndrum

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Tranche 7 : vitesse, feedback, longueur reverb, retour delay | § 14 | ✅ | ✅ | ✅ |
| Tranche 8 : vitesse phaser, renvois DLY→ / REV→, retour reverb | § 14 | ✅ | ✅ | ✅ |
| HOLD, ×2, FX ONLY, TAPE STOP à la console | § 14 | ✅ | ✅ | ✅ |
| Sirène sur la tranche 5 vide | § 15 | ✅ | ✅ | ✅ |
| Syndrum sur la tranche 6 vide | § 15 | ✅ | ✅ | ✅ |
| Sirène carrée / triangle, valeur du roulement | § 15 | ✅ À la souris | 🟡 Fixe : sirène carrée, roulement en doubles croches (pas de réglage à l'écran) | ✅ À la souris |
| Envois reverb et bus 3 des instruments | § 15 | ✅ À la souris | ❌ Delay seulement (pas de réglage à l'écran) | ❔ Delay seulement, comme la MPC |

## 4. Page FX et effets intégrés

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Page FX : 21 réglages delay / reverb / bus 3 | § 5.3 | ✅ | ✅ | ✅ |
| Dub Delay (bande, filtres, wow) | § 5.4 | ✅ | ✅ Même code | ✅ Même code |
| Delay calé sur le tempo (SYNC) | § 5.7 | ✅ | ✅ BPM du morceau, sinon tempo de la MPC | ✅ |
| Reverb plate | § 5.4 | ✅ | ✅ Même code | ✅ Même code |
| Reverb à ressort + CRASH | § 11.4 | ✅ Touche C | ✅ Pad 10 | ✅ Touche C |
| Bi-Phaser | § 5.4 | ✅ | ✅ Même code | ✅ Même code |
| Flanger à bande sur le bus 3 | § 11.5 | ✅ | ✅ | ✅ |
| Renvois de bus à bus, destination au choix | § 5.3 | ✅ | ✅ Onglet SETUP | ✅ |
| Renvois par défaut | § 5.3 | ✅ Aucun | 🟡 DLY→REV et REV→PHS par défaut, modifiable dans SETUP | ✅ Aucun |
| Câbles dessinés entre les bus | § 5.3 | ✅ | ❌ Pas la place à l'écran | ✅ |
| Plugins tiers sur les bus, macros | § 5.5 | ✅ Audio Unit | ❌ Pas de plugin dans un plugin MPC | 🟡 VST3 et LV2 (Audio Unit sur macOS) ; 5 macros par bus ; le plugin tourne dans l'app ; non partagé avec les projets du Mac |

## 5. Page MASTER

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Big knob (passe-haut à crans) | § 11.3 | ✅ | ✅ | ✅ |
| Kills BASS / MID / TOP | § 11.3 | ✅ | ✅ | ✅ |
| Dubplate + craquements | § 11.3 | ✅ | ✅ | ✅ |
| Têtes Space Echo, ping-pong | § 11.4 | ✅ | ✅ | ✅ |
| Contournement (bypass) de chaque étage à l'écran | § 11.3 | ✅ | ❌ Chaque étage est neutre à zéro | ❔ Absent, comme la MPC |
| Limiteur de sécurité | § 5.4 | ✅ | ✅ Même code | ✅ Même code |
| Limiteur ON / OFF | § 5.4 | ✅ | ❌ Toujours actif | ✅ |
| Indicateur GR / CLIP | § 5.4 | ✅ | ❌ Absent | ✅ |

## 6. Page INSERTS

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Insert par tranche : renfort de sub | § 11.5 | ✅ | ✅ | ✅ |
| Insert par tranche : auto-wah | § 11.5 | ✅ | 🟡 Sens toujours vers le haut | 🟡 Sens toujours vers le haut, comme la MPC |
| Choix de l'insert | § 11.5 | ✅ Menu | 🟡 Trois boutons tactiles (§ 16.2 ter) | ✅ Menu |
| Plugin tiers en insert | § 11.5 | ✅ Audio Unit | ❌ Comme les bus | 🟡 VST3 et LV2 ; 3 macros |

## 7. Gestes

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| DROP + tranches KEEP | § 11.6 | ✅ Touche D | ✅ Pad 9, KEEP tactile | ✅ Touche D |
| HOLD | § 11.6 | ✅ Touche H + console | ✅ Console | ✅ Touche H + console |
| Pull-up / rewind | § 11.3 | ✅ Touche R | 🟡 Pad 11, très court silence à la relance | ✅ Touche R (moteur repris de la MPC, non comparé au Mac à l'oreille) |
| Relancer le morceau du début | § 16.2 ter | ✅ Transport | 🟡 Pad 16, très court silence | ✅ Transport |

## 8. Transport et tempo

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Lecture / pause | § 5.6 | ✅ Espace | ✅ PLAY / STOP de la MPC | ✅ Espace |
| Forme d'onde, clic pour se déplacer | § 5.6 | ✅ | ❌ Barre d'avancement seulement (§ 16.3) | ✅ |
| Boucle du morceau | § 5.6 | ✅ | ❌ Enchaînement automatique à la place | ✅ |
| Temps restant | § 5.6 | ✅ + orange aux 30 dernières secondes | 🟡 Temps restant seul | ✅ + ocre aux 30 dernières secondes |
| BPM détecté, tap, ÷2 / ×2 | § 5.7 | ✅ | ❌ Le BPM vient de l'export | ✅ |

## 9. Morceaux et setlist

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Projet `.dubstem`, enregistrer / ouvrir | § 5.8 | ✅ | ❌ Réglages enregistrés dans le projet MPC | ✅ Mêmes fichiers que le Mac |
| Réglages propres à chaque morceau | § 5.8 | ✅ | ❌ Mix continu : les réglages restent (§ 16.2) | ✅ |
| Setlist de jeu, morceau suivant / précédent | § 5.8 | ✅ N / P | ✅ Onglet SONG, pads 13 / 14 | ✅ N / P |
| Morceau suivant lancé par l'utilisateur | § 5.8 | ✅ Chargé à l'arrêt | 🟡 PLAY START ou pad 15 (GO), en pleine lecture | ✅ Chargé à l'arrêt |
| Enchaînement automatique sans blanc | § 16.2 | ❌ Jamais demandé sur le Mac | ✅ | ❌ Comme le Mac |
| Queues d'effets gardées au changement | § 5.8 | ✅ | ✅ | ✅ |
| Déjà joué ✓ après 30 s | § 13 | ✅ | ✅ | ✅ |
| Ajouter / réordonner en live | § 13 | ✅ | 🟡 Choisir le suivant seulement | 🟡 « + » sans recherche |
| Atelier de setlist, bibliothèque, pré-écoute | § 13 | ✅ | ❌ Se prépare sur le Mac | 🟡 Bouton EDIT, pas de menu « Setlists… » |
| Couleur et tag par ligne | § 13 | ✅ | ❌ Non exportés | ✅ |
| Export de la setlist en dossier | § 5.8 | ✅ | ❌ Sans objet | ❔ Pas fait |
| Export to MPC | § 16.2 quater | ✅ | ❌ Sans objet | ❔ Pas fait |
| Fichiers récents | § 5.8 | ✅ | ❌ Sans objet | ✅ |

## 10. Séparation, enregistrement

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Séparation d'un morceau en 4 stems | § 12 | ✅ | ❌ Reste sur le Mac (§ 16.3) | ✅ Mêmes modèles, dossiers et résultats que le Mac (vérifié sous Ubuntu, en conteneur) |
| Mode préparation (file de morceaux) | § 12.6 | ✅ | ❌ Idem | 🟡 Modèles et dossier des stems réglés sur cet écran ; ordre au clic droit ; pas de notification à la fin |
| Enregistrement du master, sessions, fiche | § 5.9 | ✅ | ❌ La MPC a son propre enregistreur | ✅ Mêmes fichiers que le Mac |
| Export MP3 d'une session | § 5.9 | ✅ | ❌ Idem | ✅ |

## 11. Écran, réglages, distribution

| Fonctionnalité | PRD | Mac | MPC | Linux / Windows |
|---|---|---|---|---|
| Miroir de la console, identité visuelle | § 5.10, § 5.11 | ✅ | ✅ Onglet CONSOLE | ✅ |
| Vu-mètres par tranche | § 5.10 | ✅ | ✅ | ✅ |
| Barre PRE (signal avant fader) | § 5.10 | ✅ | ❌ Absente | ✅ |
| Tout jouable sans console (souris) | § 5.10 | ✅ | ❌ La console est obligatoire | ✅ |
| Carte son, taille de buffer | § 5.12 | ✅ | ❌ Géré par la MPC | ✅ |
| État MIDI, charge, décrochages | § 5.10 | ✅ Barre d'état | ✅ Onglet TEST | ✅ Barre latérale |
| Autres contrôleurs (profil) | § 7 | ✅ Par profil de même géométrie | ❌ MIDImix seulement | ❔ MIDImix seulement |
| Mise à jour en un clic | § 5.12 | ✅ | 🟡 Par un nouvel export depuis le Mac | ❔ Pas faite : on retélécharge l'archive |
| Installation | § 6 | ✅ Zip, `install.sh`, Homebrew | ✅ Zip, ou export depuis le Mac | 🟡 Linux : archive `.tar.gz` + `install.sh` ; Windows : pas encore compilé |

## Écarts à trancher (❔)

Sept, tous dans la colonne Linux / Windows : ce que l'app Mac fait et que l'app Linux ne fait pas, sans que ce soit décidé.

- SEND ALL au démarrage (la console n'envoie pas ses positions à l'ouverture).
- Envois reverb et bus 3 de la sirène et du Syndrum (delay seulement).
- Contournement de chaque étage de la page MASTER à l'écran.
- Export de la setlist en dossier.
- Export to MPC.
- Autres contrôleurs que la MIDImix.
- Mise à jour en un clic.

**Écarts Mac / MPC assumés** (décidé le 16 novembre 2026) : les écarts relevés à la création de ce tableau restent tels quels pour l'instant. Ce n'est pas un gel de la MPC : elle reçoit les évolutions à venir comme les autres apps, et un de ces écarts pourra être repris sur demande. Ils sont marqués 🟡 ou ❌ dans les tableaux ci-dessus : envois toujours post-fader, renvois DLY→REV et REV→PHS par défaut, auto-wah vers le haut, limiteur toujours actif sans indicateur, pas de contournement par étage du master, pas de barre PRE, sirène carrée et roulement en doubles croches sans réglage, instruments envoyés dans le delay seulement, couleurs et tags de setlist non exportés, MIDImix seulement.
