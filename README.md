# LocalMenu

Assistant documentaire macOS dans la barre de menus. SwiftUI, moteur local Ollama, aucun framework tiers ajouté au projet. macOS 14 minimum ; Xcode avec Swift 6.2 minimum pour compiler.

## Installer et lancer

Depuis le projet, sur un Mac Apple Silicon (M1 compris) avec macOS 14 minimum et une toolchain **Swift 6.2 minimum** :

```sh
bash scripts/install.sh
open ~/Applications/LocalMenu.command
```

Le script :

- vérifie macOS, la RAM, les outils Apple et Swift ; relance nativement arm64 s'il a été lancé sous Rosetta ;
- compile explicitement pour **arm64**, vérifie l'architecture et la signature ad hoc de l'app ;
- utilise Ollama existant, ou télécharge l'application officielle **0.40.5** dans `~/Applications/LocalMenuRuntime`, avec SHA-256 épinglé, signature, Gatekeeper et architecture vérifiés ;
- démarre un serveur local si nécessaire, télécharge le modèle adapté à la RAM et vérifie un vrai appel d'outil avant de déclarer l'installation prête ;
- installe l'app et son lanceur dans `~/Applications`, sans droits administrateur.

| Mémoire physique | Modèle choisi | Poids approximatif |
| --- | --- | --- |
| 8 à moins de 24 Go | `qwen3.5:4b` | 4 Go |
| 24 Go et plus | `qwen3.5:9b` | 7,6 Go |

Prévoir 12 Go libres pour un téléchargement de modèle. Sur 8 Go, le script avertit du risque de pression mémoire : fermer les applications lourdes. Les performances et la stabilité sur un **M1 physique**, notamment 8 Go, restent à mesurer. Les tests réels des deux modèles ont été exécutés sur le M4 Max de 36 Go disponible ici, pas sur un M1.

La compilation depuis Git nécessite des outils de développement récents. Si les outils Apple manquent, lancer `xcode-select --install`, puis sélectionner Xcode/Command Line Tools avec Swift 6.2 ou plus récent. Le script échoue clairement si cette version n'est pas disponible ; une mise à jour de macOS peut être nécessaire pour installer la toolchain appropriée. Il ne contourne pas ces prérequis et ne modifie pas automatiquement Xcode.

Le lanceur `~/Applications/LocalMenu.command`, par double-clic, redémarre le serveur au besoin avant d'ouvrir l'app. L'ouverture directe de `LocalMenu.app` suppose que le serveur tourne déjà. Aucun démarrage à la connexion n'est installé. Un serveur démarré par LocalMenu reste actif après fermeture de l'interface ; ses journaux sont dans `~/Library/Logs/LocalMenu/ollama.log`.

Un serveur Ollama existant n'est jamais arrêté ni reconfiguré automatiquement. Les nouveaux serveurs sont lancés avec `OLLAMA_NO_CLOUD=1` et `OLLAMA_HOST=127.0.0.1:11434`. Vérifier manuellement les paramètres d'un serveur existant. Une version Ollama trop ancienne peut nécessiter une mise à jour manuelle ; elle n'est pas remplacée de force.

Pour installer depuis un dépôt HTTPS publié et de confiance :

```sh
bash scripts/install.sh https://github.com/PROPRIETAIRE/LocalMenu.git
```

Cette URL est un exemple : aucun dépôt distant n'est configuré. Sur un autre Mac, cloner le dépôt puis exécuter son script. Compiler un dépôt exécute son code : vérifier sa provenance.

Pour mettre à jour, quitter l'app puis relancer le script. Pour désinstaller l'interface, supprimer `~/Applications/LocalMenu.app` et `~/Applications/LocalMenu.command`. Pour supprimer aussi les autorisations et les index extraits, utiliser **Tout effacer (sources et index)** avant de quitter, ou supprimer `~/Library/Application Support/LocalMenu/Sources`. Les fichiers originaux ne sont pas touchés. Ollama, son serveur et les modèles sont indépendants ; supprimer l'interface ne les arrête ni ne les efface. Le runtime éventuellement installé par le projet se trouve dans `~/Applications/LocalMenuRuntime`.

## Utiliser

- Cliquer sur le petit cercle dans la barre de menus.
- Saisir une question et appuyer sur **Entrée**. Le champ se vide après une réponse réussie.
- Les réponses sont **les plus courtes possible** : le modèle, local ou Claude Code, ne donne que l'information demandée, sans introduction ni conclusion.
- Pour une question documentaire, cliquer sur le **trombone** et sélectionner **un fichier ou un dossier**. Le panneau prévient que les extraits seront conservés localement. Après une indexation réussie, l'autorisation est mémorisée : l'app restaure ces sources au prochain lancement, sans choisir chaque document à nouveau. Puis poser la question dans le même champ.
- Le modèle peut trouver un fichier par un fragment de son nom/chemin relatif, lister les fichiers autorisés, rechercher des passages (dans tout le dossier ou dans un seul fichier) et lire un extrait ou ses voisins. Seuls les extraits utiles lui sont transmis, pas l'intégralité du dossier.
- Si le modèle local déclare la vision dans Ollama (c'est le cas de `qwen3.5`), il peut aussi **regarder la page** d'un extrait PDF ou d'une image avec l'outil `view_page` : graphiques, schémas et tableaux sont lus sur l'image de la page, 3 pages au plus par question. Quand un extrait trouvé vient de l'OCR d'une image, souvent inexact sur les valeurs d'un graphique, l'outil invite le modèle à regarder la page avant de citer une valeur.
- **Moteur** (menu **Actions** `…`) choisit qui répond : **Local (Ollama)** par défaut, ou **Claude Code (cloud)**. Le choix est mémorisé ; un petit nuage dans le champ signale le moteur Claude Code. Il utilise la CLI `claude` déjà installée et connectée, lancée sans interaction avec uniquement les outils Read, Grep et Glob, confinée au dossier choisi (un fichier seul est copié dans un dossier temporaire privé, sans ses voisins). Claude lit directement les PDF, graphiques compris ; l'index local lui fournit en plus des pistes de pages. Pour les documents Word, Excel et Pages, que Claude ne sait pas ouvrir, l'app lui donne leur texte extrait dans un dossier temporaire privé, supprimé après la réponse. Les réglages utilisateur, hooks et serveurs MCP de Claude Code ne sont pas chargés.
- Les références `[S1]`, `[S2]` affichent le fichier et la page, la feuille ou les lignes correspondantes. L'app refuse les références à des extraits non consultés. Une référence valide ne prouve cependant pas que le modèle a correctement interprété le passage.
- Quand **Rechercher dans les sources** est activé dans **Actions** (`…`), le champ indique **Question sur les sources…** et les réponses nécessitent des références vérifiables. Désactiver cette option pour résumer du texte collé sans effacer l'index : le badge indique **En pause** et le champ redevient **Une question…**. L'option est réactivée au chargement d'une source ou au prochain lancement.
- La croix ou **Tout effacer (sources et index)** oublie la sélection mémorisée et efface tous les index locaux, y compris ceux des dossiers précédemment choisis. Pour simplement suspendre leur utilisation, préférer la mise en pause.
- **Actualiser les sources** réindexe les fichiers modifiés et retire les fichiers supprimés. L'index est aussi actualisé au lancement et lors d'une nouvelle sélection. Il n'y a pas de surveillance permanente des modifications sur disque.
- Le trombone reste disponible pendant l'indexation : choisir un nouveau dossier annule proprement le travail précédent, attend sa fermeture et conserve uniquement la dernière demande. Annuler le sélecteur ne change pas la sélection en cours. Le sélecteur AppKit est indépendant du panneau de barre de menus et une ouverture déjà en cours est ramenée au premier plan.
- **Annuler** interrompt une génération ou une indexation ; une opération OCR en cours doit finir avant l'arrêt effectif. L'activité est affichée pendant le travail. Les sources ne sont mémorisées qu'après une indexation terminée avec succès.
- **Copier automatiquement la réponse** (menu **Actions** `…`) place chaque réponse complète dans le presse-papiers, prête à coller, au lieu de l'afficher dans le panneau : texte brut sans Markdown, suivi des références. Avec cette option, une fine barre au bas du champ défile pendant la génération et se remplit quand toute la réponse est copiée. Un bouton de copie apparaît dans le champ et affiche une coche après chaque copie. L'option est mémorisée et désactivée par défaut. Une erreur ou une annulation ne touche pas au presse-papiers.
- Le panneau se ferme en cliquant ailleurs, sans quitter l'app ni effacer son contenu.

Le modèle reste invisible dans l'interface. L'installateur réserve l'alias **`localmenu-assistant:latest`** au profil choisi, sans supprimer les autres modèles. L'app privilégie cet alias. Sans alias, elle accepte encore un unique modèle installé ; plusieurs modèles sans alias déclenchent une erreur explicite. L'alias peut être remplacé lors d'une nouvelle installation pour adapter le modèle à la RAM.

## Documents et index

| Format | Traitement et références |
| --- | --- |
| Texte, code, Markdown, CSV/TSV | UTF-8 ou UTF-16 avec BOM, références par lignes |
| PDF textuel | Extraction par page |
| PDF scanné | OCR Apple Vision sur les pages sans texte exploitable |
| PDF avec images ou graphiques | Texte de la page, plus OCR des images de taille notable (graphiques collés, figures), sans répéter le texte déjà présent |
| PNG, JPEG, TIFF, HEIC, WebP, BMP | OCR Apple Vision, images multiples prises en compte |
| DOCX | Texte du corps du document, paragraphes et lignes |
| XLSX | Feuilles, références des cellules et valeurs enregistrées, sans recalcul des formules |
| Pages (`.pages`, fichier ou paquet) | Texte du corps, tableaux (références des cellules, nombres, dates, résultats de formules enregistrés), données des graphiques, zones de texte, en-têtes et pieds de page, plus OCR des images insérées. Lu directement dans le fichier, sans ouvrir Pages ; les références nomment la partie du document (texte, tableau, graphique…) et non la page |

Le chargement crée un **index SQLite FTS5 sur disque**, avec classement BM25 et recherche insensible aux accents et à la casse. SQLite est fourni par macOS, sans dépendance supplémentaire. Le modèle ne reçoit que quelques extraits pertinents. Aucun service d'embeddings n'est requis. Une recherche sans résultat ne garantit pas une absence : reformuler ou nommer le fichier.

Le texte est lu par blocs de 64 Ko ; les PDF sont traités page par page, avec OCR si nécessaire. Les extraits de 1 800 caractères sont insérés progressivement dans SQLite, sans garder le corpus entier en mémoire. Le cache de pages SQLite est borné à 8 Mo par connexion ; PDFKit et Vision ont leur propre consommation mémoire.

Un index distinct est conservé pour chaque source sélectionnée dans `~/Library/Application Support/LocalMenu/Sources`. À l'actualisation, les fichiers dont la taille et les dates sont inchangées sont réutilisés ; les autres sont réindexés. Les opérations sont transactionnelles : une annulation n'expose pas un index partiellement reconstruit. Les sources restent un instantané entre deux actualisations, pas une recherche en direct dans tout le Mac.

### Garde-fous de ressources

Les limites évitent le blocage du Mac et une consommation de mémoire incontrôlée :

- Texte/PDF/images : 512 Mo et 10 000 pages/images maximum par document. Plus de plafond global de 2 millions de caractères pour les textes et PDF ; une page PDF reste bornée à 2 millions de caractères.
- Office : 32 Mo, 2 millions de caractères extraits et 200 feuilles XLSX maximum.
- 10 000 fichiers pris en charge, 50 000 entrées parcourues, 500 000 extraits et 2 Go d'index par source. Les index des autres dossiers restent conservés jusqu'à **Tout effacer** ; surveiller l'espace disque si de nombreuses sources sont utilisées.
- XML Office limité à 8 Mo par membre d'archive ; aucune extraction d'archive sur disque.
- Pages : 64 Mo par membre de l'archive, 256 Mo de données décompressées et 2 millions de caractères par tableau.
- Questions documentaires de 8 000 caractères maximum, 12 appels d'outils, 7 tours de dialogue, volume de résultats borné et contexte Ollama de 16 384 tokens.
- En cas de document non lisible dans un dossier, un avertissement est affiché. Survoler cet avertissement pour obtenir les détails. Un document sélectionné seul provoque une erreur explicite.

Les fichiers cachés, paquets et liens symboliques ne sont pas explorés ; un document Pages enregistré en paquet est lu comme un seul document. Les documents Pages protégés par un mot de passe et ceux de Pages '09 sont signalés : retirer le mot de passe, ou ouvrir et réenregistrer le document dans Pages. Les commentaires Pages ne sont pas lus, et les dates de tableaux Pages sont données telles que Pages les affiche, sans leur format. Les PDF protégés, la mise en page complexe, les graphiques vectoriels au-delà de leurs libellés, les annotations, les en-têtes/pieds de page DOCX et le sens des styles de cellules XLSX ne sont pas interprétés. Les nombres de dates XLSX peuvent rester des valeurs numériques. L'OCR peut se tromper, notamment sur l'écriture manuscrite et les scans dégradés. L'OCR ne lit que le texte des images : la hauteur des barres ou la forme d'une courbe nécessitent `view_page` (modèle avec vision) ou le moteur Claude Code. Les index créés par une version antérieure sont reconstruits une fois pour en profiter.

## Confidentialité et sécurité

- Outils en **lecture seule**, sans terminal, modification de fichiers, contrôle d'applications ni accès global au disque. Les outils lisent uniquement l'instantané des sources choisies et n'acceptent jamais un chemin arbitraire fourni par le modèle.
- **Moteur Claude Code : la question, les noms de fichiers et les extraits lus quittent le Mac** vers les serveurs d'Anthropic, selon le compte connecté dans Claude Code. Garder le moteur local pour les documents sensibles.
- Moteur local : requêtes uniquement vers `http://127.0.0.1:11434`. Les redirections HTTP sont refusées. Avant toute question, l'app refuse les modèles déclarés distants par Ollama, y compris sous un alias local. Elle vérifie aussi les capacités d'outils avant une recherche documentaire.
- Les extraits et noms relatifs peuvent être transmis au modèle ; pas les chemins absolus. Utiliser un serveur Ollama de confiance, avec le cloud désactivé.
- Les conversations ne sont pas enregistrées par l'app. **Les textes extraits et les autorisations sont désormais conservés sur disque**, dans `~/Library/Application Support/LocalMenu/Sources`, avec répertoire privé (0700) et fichiers d'index/bookmark privés (0600). Ce n'est pas un chiffrement : activer FileVault si les documents sont sensibles et tenir compte des sauvegardes du Mac.
- La croix et **Tout effacer (sources et index)** suppriment les caches et l'autorisation enregistrée, pas les originaux. Cela ne garantit pas un effacement sécurisé du SSD, des sauvegardes ou de la mémoire. Ollama gère ses propres journaux, caches et stockage.
- Le téléchargement initial nécessite Internet ; l'inférence, la recherche et l'OCR fonctionnent ensuite localement.
- Aucune tentative de contournement du mode examen ou des logiciels de surveillance. Une app de barre de menus n'est pas indétectable.

## Vérifier

```sh
python3 -m unittest discover -s scripts/tests -v
swift test
LOCALMENU_LIVE_TESTS=1 swift test --filter LiveDocumentTests
LOCALMENU_LARGE_TESTS=1 swift test --filter LargeDocumentTests
bash scripts/build-app.sh
```

Les tests Python vérifient l'installateur dans un environnement simulant un M1 (macOS, RAM, compilateur et outils substitués), la préservation d'une installation en cas d'échec et les profils SEB. Cette simulation n'est pas un essai matériel sur M1. Le chemin de téléchargement officiel d'Ollama a aussi été essayé avec un HOME isolé ; signature, SHA-256, architecture et appel d'outil ont passé les contrôles.

Les tests ordinaires couvrent la recherche, les formats, l'OCR, les liens hors périmètre, XML Office, les outils et citations, les bookmarks et permissions privées, les caches séparés, les suppressions/modifications, le rollback d'une indexation annulée et les limites de blocs UTF-8/UTF-16/CRLF. Les tests du modèle d'interface enchaînent 30 changements de dossier, remplacent une indexation active et vérifient la reprise après une source invalide et après redémarrage. Ils n'exigent pas Ollama.

Vérifications manuelles sur le Mac de développement : 30 sélections/annulations dans le sélecteur natif, changement pendant une indexation d'environ 75 Mo, restauration après relancement, pause/reprise des sources et réponse avec référence depuis l'index restauré. Le blocage initial signalé n'a pas été reproduit à l'identique ; ces essais valident le nouveau cycle de sélection, pas tous les scénarios système possibles.

Les tests volumineux optionnels retrouvent une réponse à la fin d'un fichier texte de 36 864 071 octets et à la page 1 101 d'un PDF. Sur le M4 Max disponible, l'indexation du texte prend environ 5,4 secondes et les pages textuelles du PDF environ 0,1 seconde, hors génération des fixtures. Ce ne sont pas des mesures sur M1 ni des estimations de vitesse pour 1 101 pages OCR.

Les tests réels sont optionnels et utilisent uniquement des documents synthétiques :

1. Enchaînement `list_documents` → `read_passage` → `search_documents`, réponse avec référence et document distracteur.
2. Réponse croisée depuis un PDF scanné et un XLSX, avec les deux références.
3. Rejet d'une instruction malveillante présente dans le document, traitée comme une donnée.
4. Reconnaissance d'une information absente, sans inventer de coordonnées bancaires.
5. Résumé d'un texte collé de plus de 8 000 caractères sans pièce jointe ni exigence de références documentaires.
6. Recherche d'un fichier parmi plus de 30 documents, puis réponse citée sur son contenu.
7. Lecture d'une valeur présente uniquement dans un graphique en image (PDF de 2 pages), avec référence à la page 2.
8. Réponses courtes limitées à l'information demandée, sans document puis avec un rapport.
9. Lecture d'un document Pages : une cellule de tableau et une valeur de graphique, avec leurs références.

`LOCALMENU_CLAUDE_LIVE_TESTS=1 swift test --filter liveClaudeCode` vérifie de même le moteur Claude Code : lecture du graphique et refus de lire un fichier hors du dossier choisi.

Résultat sur ce Mac : `qwen3:4b` a échoué à l'enchaînement complet ; `qwen3.5:2b` n'a pas satisfait tous les contrôles et n'est pas retenu. `qwen3.5:4b` et `qwen3.5:9b` ont réussi les quatre cas avec le harnais actuel. Une réponse documentaire sans référence valide bénéficie d'une seule demande de correction, puis est refusée si elle reste invalide. La suite Swift comprend 67 tests ; la suite Python en comprend 10. Cela vérifie ces scénarios, pas toutes les questions possibles ni une résistance universelle aux injections de prompt.

## Examen blanc avec un vrai navigateur verrouillé

Le [laboratoire SEB](exam-lab/README.md) fournit un sujet fictif, des notes de contrôle et deux profils : AAC Apple strict et kiosque classique avec processus interdits. Préparation sans verrouiller :

```sh
python3 scripts/prepare-exam.py
```

Safe Exam Browser 3.7.1.1 signé a été installé et son entitlement AAC vérifié sur ce Mac. **Aucune session verrouillée n'a été lancée automatiquement.** L'essai réel doit être confirmé et observé sur une session de test sauvegardée. Les profils doivent bloquer LocalMenu ; ils ne constituent pas un moyen de le rendre autorisé ou invisible. Aucun logiciel de surveillance commerciale n'est émulé.

Signature ad hoc pour usage local, sans notarisation ni distribution App Store.
