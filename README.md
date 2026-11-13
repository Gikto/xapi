# Xapi, miel de Dion-le-Mont

Site vitrine et de vente de Xapi (Xavier Van Cauter, apiculteur récoltant), une seule page `index.html`, sans outil de construction.

## Mettre en ligne avec GitHub Pages

1. Créer un dépôt `xapi` sur le compte GitHub voulu, puis y déposer tout le contenu du zip : `index.html`, `admin.html`, le dossier `images/`, `README.md`, `.nojekyll`.
2. Dans le dépôt : Settings > Pages > Source : « Deploy from a branch », branche `main`, dossier `/ (root)`.
3. Le site apparaît sur `https://<compte>.github.io/xapi/` après une minute ou deux.

## Brancher xapi.be

1. Chez le registraire du domaine, ajouter quatre enregistrements `A` pour `xapi.be` : `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`.
2. Ajouter un enregistrement `CNAME` pour `www` vers `<compte>.github.io`.
3. Dans Settings > Pages > Custom domain, saisir `xapi.be` puis cocher « Enforce HTTPS » quand la case devient disponible.

Vérifier ces adresses sur la documentation GitHub Pages avant de les saisir : elles peuvent changer.

## Ce qui se modifie dans `index.html`

Le bloc au début du `<script>` (« À MODIFIER ») contient :

- `CONTACT`, `PHONE`, `MESSENGER` : coordonnées et lien Messenger (à tester).
- `PRICES` : prix par texture et par format.
- `HONEYS` : fiches des miels (récolte, origine, stock facultatif).
- `SUPABASE_URL` et `SUPABASE_KEY` : à remplir (voir ci-dessous). Paiement par virement bancaire (IBAN et bénéficiaire déjà renseignés).

## Commandes et page admin

Le client commande avec son nom et son e-mail (obligatoire), reçoit un numéro, l'IBAN, le montant, une communication structurée et un QR de virement, plus un e-mail de confirmation. Il paie avant le retrait. Les commandes sont stockées dans Supabase.

`admin.html` (protégée par mot de passe, non référencée, déconnexion après 2 heures d'inactivité) a un menu à gauche : Tableau de bord (« à faire » et alertes), Commandes, Préparation, Stock, Miels (catalogue, variantes et prix, textes, photos), Statistiques, Réglages (pause, bandeau d'annonce, compte bancaire, sauvegarde, lieux de retrait, e-mail d'alerte, mot de passe), Aide (mode d'emploi en français simple). Le menu affiche une pastille pour les nouvelles commandes, et le titre de l'onglet aussi.

1. Créer un projet Supabase (compte distinct de Kaos2flow si voulu).
2. Ouvrir `schema.sql` (fourni à part, ne pas le mettre dans le dépôt), remplacer `REMPLACER_PAR_VOTRE_MOT_DE_PASSE` par une longue phrase de passe, puis l'exécuter dans SQL Editor.
3. Copier l'URL du projet et la clé publiable (Project Settings > API) dans `SUPABASE_URL` / `SUPABASE_KEY`, en haut du script de `index.html` et de `admin.html`. Ces deux valeurs sont publiques par conception ; le mot de passe, lui, ne doit jamais être dans le dépôt.
4. Alerte e-mail automatique : dans `schema.sql`, remplacer `REMPLACER_PAR_CLE_API_BREVO` (clé API Brevo) et `REMPLACER_PAR_EXPEDITEUR_VERIFIE` (adresse expéditrice vérifiée dans Brevo > Senders). Destinataire de test : efats@pm.me, modifiable dans la page admin > Réglages. Ne pas mettre la clé dans le dépôt.
5. Tester : passer une commande, ouvrir `/admin.html`, entrer la phrase de passe.

## Ce que fait le système (après `schema.sql`)

- E-mail de confirmation au client (s'il a donné son adresse) avec IBAN, montant et communication, et alerte à Xavier à chaque commande.
- Rappel automatique au client 3 jours après une commande impayée (une seule fois, et seulement si Xavier s'est connecté à la page admin dans les 48 dernières heures), et un mail de relance à Xavier (une fois par commande) quand un paiement n'est pas arrivé après 48 h. Il tourne chaque jour vers 8 h grâce à l'extension `pg_cron` ; si le script indique qu'elle n'est pas activée, l'activer dans Supabase > Database > Extensions puis relancer le dernier bloc du script.
- Stock (page admin > Stock) : pour chaque miel, « Disponible » (réglage normal, le site ne dit rien), « Épuisé », ou « Nombre exact » si Xavier veut compter ses pots (« Plus que N pots » sous 5, « Épuisé » à zéro). Le serveur refuse les commandes en trop. Annuler une commande remet les pots en stock.
- Page « Préparation » (avec bouton d'impression) : elle inclut aussi les commandes pas encore payées, signalées en rouge (on prépare, mais on ne remet qu'après paiement) ; liste des commandes payées à remettre, par lieu de retrait, avec le total de pots à sortir.

## Partage et référencement

- Aperçu de partage (Facebook, Messenger, WhatsApp) : balises dans `index.html` et image `images/og.jpg` (1200 × 630). Après la mise en ligne sur xapi.be, tester le lien avec l'outil « Débogueur de partage » de Facebook (developers.facebook.com/tools/debug) et cliquer « Récupérer de nouvelles informations » si l'ancienne carte reste affichée.
- Google : titre, description, icône (`favicon.svg`, `images/apple-touch-icon.png`), données « commerce local » dans la page, `sitemap.xml` et `robots.txt`. Proposer ensuite le plan du site dans Google Search Console. Le gain principal pour la recherche locale reste la fiche Google Business.

## Textes légaux

Les « Conditions de vente » et la « Vie privée » (liens en pied de page, case à cocher à la commande) sont dans `index.html`. Textes de départ à faire relire par Xavier et son comptable : durée de conservation (7 ans), TVA/prix TTC, annulation des commandes impayées, droit de rétractation (non mentionné).

## Images

- `images/site/` : les images du site (déjà fournies, chargées à la demande pour alléger la page).
- `images/pots/` : les photos des pots, à ajouter (voir ci-dessous).

- Catalogue (page admin > Miels) : Xavier ajoute, renomme, masque ou réordonne les miels, modifie le texte et les caractéristiques, et envoie les photos des pots depuis son téléphone. Une nouvelle récolte ne demande plus de développeur. Les photos vont dans Supabase Storage (bucket public `photos`, créé par `schema.sql` ; s'il n'a pas pu l'être, le créer à la main dans Storage, public, puis relancer le dernier bloc « Stockage » du script). À défaut de photo envoyée, le site utilise `images/pots/` puis l'image par défaut.
- Prix et variantes : chaque miel a ses propres variantes (classique ou crémeux, 250 g ou 500 g) et ses prix, à régler dans Miels. Les deux miels actuels sont créés avec leurs 4 variantes ; on peut ajouter d'autres tailles (1 kg, 125 g…) miel par miel. La page admin se rafraîchit toute seule toutes les minutes tant que quelqu'un est connecté et signale chaque nouvelle commande. Pause des commandes et bandeau d'annonce sont deux réglages séparés (Réglages). Les commandes sont numérotées à partir de 0001.
- Mot de passe oublié : sur la page de connexion, un code à 6 chiffres est envoyé à l'e-mail d'alerte (valable 30 min, 3 demandes par heure).
- Suivi des e-mails : si l'envoi échoue (clé Brevo expirée, par exemple) ou n'est pas configuré, le tableau de bord de l'admin affiche un avertissement rouge (contrôle toutes les heures par `pg_cron`).
- Base de données jamais en pause : le plan gratuit de Supabase met un projet en pause après environ une semaine sans activité. Le workflow `.github/workflows/keepalive.yml` appelle la base tous les 3 jours (il lit `SUPABASE_URL` et `SUPABASE_KEY` dans `index.html`, aucun secret à créer) et fait un petit commit le 1er du mois pour que GitHub ne désactive pas le workflow après 60 jours sans activité. Activer l'onglet Actions du dépôt au premier push ; l'onglet Actions affiche une croix rouge si la base ne répond pas. Les visites du site comptent aussi comme activité. Seconde ligne de défense possible : un appel planifié gratuit (cron-job.org) vers la même adresse.
- Sauvegardes : le plan gratuit de Supabase n'en fait pas. Le 1er de chaque mois à 7 h, la base envoie par e-mail (Brevo, pièce jointe .csv ouvrable dans Excel) toutes les commandes à l'adresse d'alerte ; un bouton « Envoyer une sauvegarde maintenant » existe dans Réglages. Les sauvegardes ne sont volontairement pas stockées dans GitHub : le dépôt est public et les commandes contiennent des noms et e-mails de clients.

## Photos des pots (méthode alternative)

La méthode simple est la page admin > Miels. Sinon, :

Déposer les photos dans le dossier `images/pots/` du dépôt (à côté de `index.html`), au format JPG, avec exactement ces noms :

- `printemps-classique-250.jpg`, `printemps-classique-500.jpg`
- `printemps-cremeux-250.jpg`, `printemps-cremeux-500.jpg`
- `ete-classique-250.jpg`, `ete-classique-500.jpg`
- `ete-cremeux-250.jpg`, `ete-cremeux-500.jpg`

Conseil : format paysage 16:10 (par exemple 1600 × 1000 px), moins de 300 Ko chacune. Tant qu'une photo manque, le site garde l'image actuelle. Les commandes se font uniquement par e-mail : le téléphone n'est plus demandé.

## À faire

Voir le document « Site Xapi : ce qu'il reste à faire » (photos des pots, notes de dégustation, mentions légales, fiche Google Maps, carnet relié à Facebook).
