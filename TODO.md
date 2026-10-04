# DubStemMix — ce qui reste à faire

> État au 26 septembre 2026. Ancien TODO soldé. La référence produit reste `PRD.md`.
> Légende : **[toi]** = demande un essai ou une décision de ta part.

## 1. Confort d'un set préparé (cadré le 26/09)

- [x] **Fin de morceau visible** (PRD § 5.6) : temps restant « −1:23 » à côté du chrono, forme d'onde orange dans les 30 dernières secondes.
- [x] **Même plugin d'insert, pas de coupure** (PRD § 5.8) : même plugin sur la même tranche dans les deux morceaux → il reste branché, seuls ses réglages changent ; l'avertissement à l'armement ne parle plus de ce cas.
- [x] **Signal avant fader** (PRD § 5.10) : barre fine PRE à côté du vu-mètre de chaque tranche, avant fader et MUTE.
- [x] **Limiteur master désactivable** (PRD § 5.4) : clic sur « LIMITER ON / OFF » sous le fader master, mémorisé pour ce Mac.
- [x] **[toi]** Barre PRE, fin de morceau et même plugin d'insert : validés le 26/09.
- [ ] **[toi]** Essayer le limiteur OFF en vrai (sur la sono, en surveillant le haut du vu-mètre master).
- [x] **[toi]** Essayer en vrai : laisser tourner un morceau jusqu'aux 30 dernières secondes ; deux morceaux de la setlist avec le même plugin sur la même tranche, armer puis Espace (les queues doivent passer).

## 2. Mode préparation : plusieurs morceaux en file (cadré le 03/10, PRD § 12.6)

- [x] Zone « Prepare songs » dans la barre latérale + menu Fichier « Prepare Songs… » ; écran à part à la place de la console, lecture coupée.
- [x] File : ajouter en cours de route, retirer / réordonner les morceaux en attente, tout annuler (les finis restent), estimation du temps total.
- [x] Un projet `.dubstem` prêt par morceau, à côté de ses stems ; notification à la fin ; avertissement en quittant.
- [x] Split a Song : la session prend le nom du morceau, plus celui de son dossier.
- [ ] **[toi]** Essayer en vrai : glisser 3 ou 4 morceaux (ou un dossier), réordonner, en retirer un, laisser finir ; ouvrir un des projets créés.
- [ ] **[toi]** Vérifier que la notification de fin s'affiche (macOS demande l'autorisation la première fois).

## 2 bis. Doc du mode préparation (à faire avant le § 4)

- [ ] README « Splitting a tune into stems » : paragraphe « A whole set at once » (PREPARE SONGS, File ▸ Prepare Songs…, un `.dubstem` prêt par morceau à côté de ses stems, ajouter / retirer / réordonner / tout annuler, temps restant, notification).
- [ ] README section développeurs : `--check-prepare`, `--split … --project`, `--snapshot … --prepare`.
- [ ] Site : même paragraphe dans `Split.astro`, une phrase dans l'aide-mémoire « Play » (`Install.astro`).
- [ ] **[toi]** Capture de l'écran de préparation (`--snapshot … --prepare`, données de démo) pour le site et le README : oui ou non ? Chiffre « ~1,2× la durée » gardé tel quel ?

## 3. Atelier de setlist (cadré le 04/10, PRD § 13)

- [ ] **[toi]** Relire le PRD § 13 et valider avant qu'on code.
- [ ] Écran à part : mes setlists, bibliothèque auto avec recherche, setlist avec couleur / tag par ligne, glisser pour ajouter et réordonner, durée totale.
- [ ] Pré-écoute du mix brut, forme d'onde cliquable.
- [ ] Pas de doublon ; morceau introuvable en rouge ⚠ avec « Locate… ».
- [ ] Barre latérale : réordonner, « + » pour ajouter un morceau après celui en cours (sans couper), couleurs et tags visibles, « déjà joué » grisé ✓ (≥ 30 s, effacé à la fermeture).

## 4. Fichiers récents (décidé le 04/10, PRD § 5.8)

- [ ] Fichier › Open Recent : 10 derniers `.dubstem` et `.dubset`, fichiers disparus masqués, Clear Menu, même liste dans le Dock.

