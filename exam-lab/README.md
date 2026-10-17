# Laboratoire d'examen blanc

Ce laboratoire utilise **le vrai Safe Exam Browser signé**, pas une fenêtre plein écran imitant un mode examen. Le sujet est fictif : aucun LMS, examen institutionnel, capture de webcam ni service de surveillance commerciale n'est reproduit.

**LocalMenu doit être bloqué dans les profils stricts.** Une indisponibilité de l'assistant est le résultat attendu du contrôle, pas une incompatibilité à contourner. Rien ici ne garantit son fonctionnement pendant un examen réel.

## Préparer sans verrouiller

1. Sauvegarder le travail. Utiliser de préférence un Mac de test et un compte macOS dédié. Ne pas activer SEB sur une session de travail non sauvegardée : il peut demander la fermeture d'applications, voire terminer certains processus selon ses règles internes.
2. Installer [Safe Exam Browser pour macOS](https://safeexambrowser.org/download_en.html). Version préparée sur ce Mac : **3.7.1.1**, signature vérifiée. Ne pas encore le lancer.
3. Depuis LocalMenu, servir uniquement le sujet public :
   ```sh
   python3 -m http.server 8765 --bind 127.0.0.1 --directory exam-lab/web
   ```
   Python 3 est nécessaire pour ce laboratoire, pas pour l'installateur de LocalMenu. Dans un autre terminal :
   ```sh
   python3 scripts/prepare-exam.py
   ```
4. Ouvrir `http://127.0.0.1:8765/` dans Safari pour le contrôle sans verrouillage. Joindre `exam-lab/materials/notes.txt` à LocalMenu, poser les trois questions et vérifier les références.

**Pour le vrai test AAC, servir le sujet depuis un second ordinateur est préférable** : le mode examen peut interdire le Terminal et le réseau des processus non autorisés, donc un serveur sur le Mac testé risque de devenir inaccessible. Sur le Mac serveur, un sujet fictif peut être exposé au réseau local, jamais aux documents privés :

```sh
python3 -m http.server 8765 --bind 0.0.0.0 --directory exam-lab/web
```

Sur le Mac testé, remplacer l'adresse par celle du serveur accessible :

```sh
python3 scripts/prepare-exam.py --url http://ADRESSE_DU_SERVEUR:8765/
```

Le sujet ne doit pas être exposé à Internet. Les configurations `.seb` et les notes restent hors du répertoire servi. Vérifier l'URL dans Safari sur le Mac testé avant de lancer SEB. Si le serveur est sur le même Mac, le lancer explicitement avec `nohup` en arrière-plan ne garantit pas son accès réseau sous AAC ; un échec de chargement rend l'essai inconclusif.

## Activer manuellement un seul profil

Avant de continuer, noter sur papier le mot de passe ASCII de laboratoire : **LocalMenuLab2026**. Il sert à la sortie, au déverrouillage et aux préférences. **Cmd-Q** puis ce mot de passe permet la sortie normale. Le lien **Quitter l'examen blanc** constitue une seconde sortie prévue par la configuration. Pour éditer sans verrouiller, maintenir Option en lançant SEB, selon son manuel.

Les profils sont générés dans `dist/exam-lab/` et restent des fichiers XML modifiables, réservés au laboratoire. Ils lancent une session d'examen (`sebConfigPurpose=0`), sans demander la reconfiguration persistante du client. Ils ne désactivent pas SIP, Gatekeeper, la détection des VM ou les protections de capture.

- **`aac-strict.seb`** : demande explicitement le mode d'évaluation Apple AAC (`lockdownModePolicy=2`). Barre de menus/changement d'application indisponibles selon les protections système. LocalMenu et Ollama figurent aussi parmi les processus interdits.
- **`classic-prohibited.seb`** : mode kiosque classique SEB (`lockdownModePolicy=1`) avec LocalMenu et Ollama explicitement interdits. Ce profil teste le contrôle des processus, pas AAC.

Lancer le profil choisi uniquement après confirmation humaine :

```sh
open -a "$HOME/Applications/Safe Exam Browser.app" dist/exam-lab/aac-strict.seb
```

Adapter le chemin si SEB est installé dans `/Applications`. Ne pas ouvrir les deux profils simultanément. Ne pas modifier les protections pour faire passer un test. Une VM refusée par SEB n'est pas un test valide du comportement sur Mac natif.

## Grille à remplir après observation réelle

| Contrôle | Résultat attendu | Résultat observé |
| --- | --- | --- |
| Safari sans verrouillage + LocalMenu | Questions, extraits et références fonctionnent | Non exécuté sur M1 |
| AAC strict : mode réellement actif (journal SEB) | AAC confirmé, pas de simple retour au kiosque classique | Non exécuté |
| AAC strict : ouverture de LocalMenu | Accès bloqué ou fermeture demandée | Non exécuté |
| Kiosque classique : processus interdits | LocalMenu/Ollama signalés ou fermeture demandée | Non exécuté |
| Cmd-Q + mot de passe | Sortie et retour au bureau possibles | Non exécuté |
| Relancer LocalMenu après sortie | Assistant documentaire à nouveau utilisable | Non exécuté |

Noter modèle du Mac, RAM, version de macOS, version SEB, profil, permissions demandées et messages exacts. Consulter les journaux de SEB pour confirmer le mode actif. Les événements de focus de la page ne suffisent pas à prouver AAC ni la détection d'une application.

Le laboratoire a été **préparé**, pas exécuté en verrouillage sur le Mac de travail. Un autre logiciel (Respondus, surveillance distante, MDM) nécessite son propre environnement autorisé et ses propres essais.

Sources : [manuel SEB](https://safeexambrowser.org/macosx/mac_usermanual_en.html), [réglages officiels SEB](https://github.com/SafeExamBrowser/seb-mac/blob/main/docs/settings/new-and-updated-settings.md), [mode d'évaluation Apple](https://support.apple.com/en-us/101976).
