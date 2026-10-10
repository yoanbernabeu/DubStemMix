# DubStemMix — ce qui reste à faire

> État au 4 octobre 2026. Ancien TODO soldé. La référence produit reste `PRD.md`.
> Légende : **[toi]** = demande un essai ou une décision de ta part.

## 1. Confort d'un set préparé (cadré le 26/09)

- [x] **Fin de morceau visible** (PRD § 5.6) : temps restant « −1:23 » à côté du chrono, forme d'onde orange dans les 30 dernières secondes.
- [x] **Même plugin d'insert, pas de coupure** (PRD § 5.8) : même plugin sur la même tranche dans les deux morceaux → il reste branché, seuls ses réglages changent ; l'avertissement à l'armement ne parle plus de ce cas.
- [x] **Signal avant fader** (PRD § 5.10) : barre fine PRE à côté du vu-mètre de chaque tranche, avant fader et MUTE.
- [x] **Limiteur master désactivable** (PRD § 5.4) : clic sur « LIMITER ON / OFF » sous le fader master, mémorisé pour ce Mac.
- [x] **[toi]** Barre PRE, fin de morceau et même plugin d'insert : validés le 26/09.
- [x] **[toi]** Essayer le limiteur OFF en vrai (sur la sono, en surveillant le haut du vu-mètre master).
- [x] **[toi]** Essayer en vrai : laisser tourner un morceau jusqu'aux 30 dernières secondes ; deux morceaux de la setlist avec le même plugin sur la même tranche, armer puis Espace (les queues doivent passer).

## 2. Mode préparation : plusieurs morceaux en file (cadré le 03/10, PRD § 12.6)

- [x] Zone « Prepare songs » dans la barre latérale + menu Fichier « Prepare Songs… » ; écran à part à la place de la console, lecture coupée.
- [x] File : ajouter en cours de route, retirer / réordonner les morceaux en attente, tout annuler (les finis restent), estimation du temps total.
- [x] Un projet `.dubstem` prêt par morceau, à côté de ses stems ; notification à la fin ; avertissement en quittant.
- [x] Split a Song : la session prend le nom du morceau, plus celui de son dossier.
- [x] **[toi]** Essayer en vrai : glisser 3 ou 4 morceaux (ou un dossier), réordonner, en retirer un, laisser finir ; ouvrir un des projets créés.
- [x] **[toi]** Vérifier que la notification de fin s'affiche (macOS demande l'autorisation la première fois).

## 2 bis. Doc du mode préparation (à faire avant le § 4)

- [x] README « Splitting a tune into stems » : paragraphe « A whole set at once » (PREPARE SONGS, File ▸ Prepare Songs…, un `.dubstem` prêt par morceau à côté de ses stems, ajouter / retirer / réordonner / tout annuler, temps restant, notification).
- [x] README section développeurs : `--check-prepare`, `--split … --project`, `--snapshot … --prepare`.
- [x] Site : même paragraphe dans `Split.astro`, une phrase dans l'aide-mémoire « Play » (`Install.astro`).
- [x] **[toi]** Capture de l'écran de préparation (`--snapshot … --prepare`, données de démo) pour le site et le README : oui (04/10, `docs/screenshots/prepare.png`). Chiffre « ~1,2× la durée » gardé tel quel.

## 3. Atelier de setlist (cadré le 04/10, PRD § 13)

- [x] **[toi]** Relire le PRD § 13 et valider avant qu'on code (validé le 04/10, avec deux ajouts : la bibliothèque cherche aussi dans le dossier des stems des réglages, et se souvient des `.dubstem` glissés depuis le Finder).
- [x] Écran à part : mes setlists, bibliothèque auto avec recherche, setlist avec couleur / tag par ligne, glisser pour ajouter et réordonner, durée totale.
- [x] Pré-écoute du mix brut, forme d'onde cliquable.
- [x] Pas de doublon ; morceau introuvable en rouge ⚠ avec « Locate… ».
- [x] Barre latérale : réordonner, « + » pour ajouter un morceau après celui en cours (sans couper), couleurs et tags visibles, « déjà joué » grisé ✓ (≥ 30 s, effacé à la fermeture).
- [x] **[toi]** Essayer en vrai : la pré-écoute (▶, clic dans la forme d'onde), « Locate… », le « + » de la barre latérale pendant la lecture, les morceaux grisés ✓ après 30 s.
- [x] Doc de l'atelier : README (« Building a set », Playing live), site (section 07 « Build a set », lien Setlists, FAQ, llms.txt), capture `docs/screenshots/setlists.png`.

## 4. Fichiers récents (décidé le 04/10, PRD § 5.8)

- [x] Fichier › Open Recent : 10 derniers `.dubstem` et `.dubset`, fichiers disparus masqués, Clear Menu, même liste dans le Dock. Un morceau ouvert depuis la setlist ouverte n'y entre pas.
- [x] **[toi]** Essayer Open Recent en vrai (menu Fichier et clic droit sur l'icône du Dock).


## 5. Skill de release (demandé le 04/10)

- [x] Créer une skill Claude Code de release qui pense à monter le numéro de version partout, site de doc compris. Endroits repérés : `web/src/site.ts` (`version`, encore à 0.6.0 alors que le dernier tag est v0.9.0), l'exemple `tools/make-app.sh 0.6.0 dist` du README, le tag git, la release GitHub.
- [x] **[toi]** Cadrer la skill (04/10) : elle prépare tout, montre numéro + fichiers + notes, et publie seulement après ton OK ; numéro proposé (mineur), notes rédigées par elle. Rangée dans `.claude/skills/release/`.
- [x] **[toi]** Premier essai avec `/release` : 0.10.0 publiée le 04/10 (site remis à jour).

## 6. Tranches d'effets 7 et 8 (cadré le 10/10, PRD § 14)

- [x] Points ouverts tranchés le 10/10 : console seulement pour les nouveaux gestes ; colonnes teintées écartées des stems.
- [x] **[toi]** Relire le PRD § 14 et valider avant qu'on code (validé le 10/10).
- [x] Moteur : ×2 et tape stop dans le delay, FX ONLY (son sec coupé, envois ouverts).
- [x] Console : tranches 1-6 pour les stems, potards / faders / boutons des tranches 7-8 ; anciens stems sur 7-8 → réserve.
- [x] Écran : tranches 7-8 teintées, écartées des stems.
- [x] **[toi]** Essayé et validé à la MIDImix le 10/10 : vitesse du delay en tournant le potard 7 du haut, HOLD puis ×2, tape stop sur un écho, FX ONLY sur la voix envoyée dans le delay, faders 7-8 en changeant de page.
- [x] Doc : README (« The effect strips »), site (The board, Gestures, accroche, llms.txt), captures MIX / FX / MASTER / INSERTS refaites.
