# Xapi, miel de Dion-le-Mont

Site vitrine et de vente de Xapi (Xavier Van Cauter, apiculteur récoltant), une seule page `index.html`, sans outil de construction.

## Mettre en ligne avec GitHub Pages

1. Créer un dépôt `xapi` sur le compte GitHub voulu, puis y déposer ces fichiers (`index.html`, `README.md`, `.nojekyll`).
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
- `STRIPE` : liens de paiement Stripe, un par miel, texture et format. Vide tant qu'il n'y a pas de compte Stripe.

## À faire

Voir le document « Site Xapi : ce qu'il reste à faire » (photos des pots, notes de dégustation, mentions légales, fiche Google Maps, carnet relié à Facebook).
