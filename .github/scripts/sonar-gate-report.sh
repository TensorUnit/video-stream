#!/usr/bin/env bash
# Affiche la cause EXACTE d'un échec de l'étape Sonar, dans le log et dans le résumé du run.
#
# Lancé seulement quand l'étape Sonar échoue (if: failure()), AVANT l'arrêt du proxy
# Cloudflare Access (Sonar est joint via http://127.0.0.1:9000).
# Sans ce script, le run n'affiche que « QUALITY GATE STATUS: FAILED » et « exit code 3 »,
# avec un lien masqué (l'adresse de Sonar est un secret).
#
# Ce qu'il affiche selon le cas :
#   - Sonar injoignable, token refusé, analyse non envoyée ou non traitée : la cause, en clair ;
#   - Quality Gate en échec : chaque condition en échec (valeur mesurée / seuil), puis le
#     détail : problèmes avec fichier et ligne, hotspots à revoir, fichiers dupliqués,
#     couverture manquante.
# Les problèmes apparaissent aussi en annotations sur les fichiers (onglet « Files changed »
# des PR).
#
# Variables : SONAR_TOKEN (secret), SONAR_PROJECT_KEY.
# Droit nécessaire pour le token : « Browse » sur le projet (accordé à ci-github par le
# script 03 de sonar_config).
set -uo pipefail

SONAR=http://127.0.0.1:9000
KEY="${SONAR_PROJECT_KEY:?SONAR_PROJECT_KEY manquant}"
RESUME="${GITHUB_STEP_SUMMARY:-/dev/null}"
RAPPORT=.scannerwork/report-task.txt
MAX=15            # nombre maximum de lignes de détail par condition
ANNOT=0           # GitHub n'affiche que 10 annotations par type et par étape

# api chemin clé=valeur ... : GET sur l'API Sonar (le token n'est jamais affiché)
api() {
  local p=$1; shift
  local args=()
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl -sS -f -G --max-time 60 -H "Authorization: Bearer ${SONAR_TOKEN}" "${args[@]}" "$SONAR/api/$p"
}
erreur() { echo "::error title=Sonar::$1"; md "> **❌ $1**"; }
indispo() { local t="(détail indisponible : le token n'a pas le droit de lecture « Browse » sur le projet)"; echo "  $t"; md "$t"; md ""; }
declare -A VU     # annotations déjà émises (un même problème peut concerner plusieurs conditions)
md()     { echo "$1" >> "$RESUME"; }
fin()    { md ""; md "_Projet Sonar : \`$KEY\`_"; exit 0; }   # le job est déjà en échec

md "## Analyse Sonar en échec"
md ""

# ─── 1. Sonar joignable ? ───────────────────────────────────────────────────────
if ! api system/status 2>/dev/null | grep -q '"status":"UP"'; then
  erreur "Sonar est injoignable (proxy Cloudflare Access ou serveur Sonar arrêté). L'échec ne vient PAS de la Quality Gate : voir l'étape « Démarrer le proxy Cloudflare Access »."
  fin
fi

# ─── 2. Token accepté ? ─────────────────────────────────────────────────────────
if ! api authentication/validate 2>/dev/null | grep -q '"valid":true'; then
  erreur "SONAR_TOKEN refusé par Sonar (token expiré, révoqué ou mal copié). L'échec ne vient PAS de la Quality Gate : remplacer le secret SONAR_TOKEN du dépôt."
  fin
fi

# ─── 3. L'analyse a-t-elle été envoyée ? ────────────────────────────────────────
# Le scanner écrit report-task.txt dans .scannerwork/ une fois l'analyse envoyée.
[ -f "$RAPPORT" ] || RAPPORT=$(find . -maxdepth 4 -name report-task.txt -path '*scannerwork*' 2>/dev/null | head -n1)
if [ -z "$RAPPORT" ] || [ ! -f "$RAPPORT" ]; then
  erreur "L'analyse n'a pas été envoyée à Sonar : le scanner a échoué avant la fin. L'échec ne vient PAS de la Quality Gate : voir les lignes ERROR de l'étape Sonar (droits du token sur le projet, fichier de configuration, mémoire...)."
  fin
fi
TACHE=$(grep '^ceTaskId=' "$RAPPORT" | cut -d= -f2-)

# ─── 4. Sonar a-t-il traité l'analyse ? ─────────────────────────────────────────
t=$(api ce/task id="$TACHE" 2>/dev/null) || { erreur "Impossible de lire la tâche Sonar $TACHE (droit « Browse » manquant pour le token ?)."; fin; }
etat=$(jq -r '.task.status' <<<"$t")
case "$etat" in
  SUCCESS) ;;
  FAILED|CANCELED)
    erreur "Sonar n'a pas pu traiter l'analyse ($etat) : $(jq -r '.task.errorMessage // "pas de message"' <<<"$t")"
    fin ;;
  *)
    erreur "Sonar n'a pas fini de traiter l'analyse dans le délai de 10 minutes (état : $etat). Serveur surchargé : relancer le run."
    fin ;;
esac
ANALYSE=$(jq -r '.task.analysisId' <<<"$t")

# ─── 5. Résultat de la Quality Gate ─────────────────────────────────────────────
qg=$(api qualitygates/project_status analysisId="$ANALYSE" 2>/dev/null) || { erreur "Impossible de lire le résultat de la Quality Gate."; fin; }
if [ "$(jq -r '.projectStatus.status' <<<"$qg")" = "OK" ]; then
  erreur "La Quality Gate est OK : l'échec vient d'une autre cause, voir les lignes ERROR de l'étape Sonar."
  fin
fi

libelle() {
  local m=$1 base portee
  if [[ $m == new_* ]]; then base=${m#new_}; portee="nouveau code"; else base=$m; portee="code global"; fi
  case "$base" in
    violations)                                          echo "Problèmes (issues) — $portee" ;;
    security_rating|software_quality_security_rating)    echo "Sécurité — $portee" ;;
    reliability_rating|software_quality_reliability_rating) echo "Fiabilité (bugs) — $portee" ;;
    maintainability_rating|sqale_rating|software_quality_maintainability_rating) echo "Maintenabilité — $portee" ;;
    security_hotspots_reviewed)                          echo "Security Hotspots revus — $portee" ;;
    coverage)                                            echo "Couverture par les tests — $portee" ;;
    line_coverage)                                       echo "Couverture des lignes — $portee" ;;
    duplicated_lines_density)                            echo "Duplication — $portee" ;;
    *)                                                   echo "$m" ;;
  esac
}
valeur() {   # valeur lisible : note A-E, pourcentage, nombre
  local m=$1 v=$2
  case "$m" in
    *rating*) case "${v%%.*}" in 1) echo A;; 2) echo B;; 3) echo C;; 4) echo D;; 5) echo E;; *) echo "$v";; esac ;;
    *coverage*|*density*|*reviewed*) LC_ALL=C printf '%.1f %%\n' "$v" 2>/dev/null | sed 's/\.0 %/ %/' || echo "$v %" ;;
    *) echo "$v" ;;
  esac
}
seuil() {
  local m=$1 op=$2 s
  s=$(valeur "$m" "$3")
  case "$m:$op" in
    *rating*:GT) echo "note $s ou mieux" ;;
    *:GT)        echo "maximum $s" ;;
    *:LT)        echo "minimum $s" ;;
    *)           echo "$op $s" ;;
  esac
}
chemin() { sed "s|^${KEY}:||"; }
gravite() { case "$1" in BLOCKER) echo bloquante;; HIGH|CRITICAL) echo haute;; MEDIUM|MAJOR) echo moyenne;; LOW|MINOR) echo basse;; INFO) echo info;; *) echo "$1";; esac; }   # « cle-projet:src/a.py » -> « src/a.py »

conds=$(jq -c '.projectStatus.conditions[] | select(.status=="ERROR")' <<<"$qg")
n=$(grep -c . <<<"$conds")
echo "=================== QUALITY GATE EN ÉCHEC : $n condition(s) ==================="
md "### ❌ Quality Gate en échec : $n condition(s)"
md ""
md "| Condition | Valeur mesurée | Attendu |"
md "|---|---|---|"
while read -r c; do
  m=$(jq -r .metricKey <<<"$c"); op=$(jq -r .comparator <<<"$c")
  s=$(jq -r .errorThreshold <<<"$c"); v=$(jq -r '.actualValue // "?"' <<<"$c")
  l=$(libelle "$m"); vv=$(valeur "$m" "$v"); ss=$(seuil "$m" "$op" "$s")
  echo "::error title=Quality Gate Sonar::$l : $vv (attendu : $ss)"
  md "| $l | **$vv** | $ss |"
done <<<"$conds"
md ""

# ─── 6. Détail de chaque condition en échec ─────────────────────────────────────
problemes() {   # $1 = qualité (SECURITY, RELIABILITY, MAINTAINABILITY ou vide), $2 = nouveau code (true/false)
  local filtre=() r total
  [ -n "$1" ] && filtre+=(impactSoftwareQualities="$1")
  [ "$2" = true ] && filtre+=(inNewCodePeriod=true)
  r=$(api issues/search components="$KEY" issueStatuses=OPEN,CONFIRMED ps="$MAX" s=SEVERITY asc=false "${filtre[@]}" 2>/dev/null) || { indispo; return; }
  total=$(jq -r .total <<<"$r")
  echo "  $total problème(s)$( [ "$total" -gt "$MAX" ] && echo ", les $MAX plus graves :")"
  md "$total problème(s)$( [ "$total" -gt "$MAX" ] && echo ", les $MAX plus graves") :"
  md ""
  while IFS=$'\t' read -r comp ligne grav msg regle; do
    [ -z "$comp" ] && continue
    f=$(chemin <<<"$comp"); grav=$(gravite "$grav")
    echo "  - $f:${ligne} [$grav] $msg ($regle)"
    md "- \`$f:${ligne}\` **$grav** — $msg _(règle $regle)_"
    if [ "$ANNOT" -lt 10 ] && [ -n "$ligne" ] && [ -z "${VU[$f:$ligne:$regle]:-}" ]; then
      echo "::warning file=$f,line=$ligne,title=Sonar ($grav)::$msg ($regle)"; ANNOT=$((ANNOT+1)); VU[$f:$ligne:$regle]=1
    fi
  done < <(jq -r '.issues[] | [.component, (.line // "" | tostring),
            ((((.impacts // []) | map(.severity) | first) // .severity) // "?"), .message, .rule] | @tsv' <<<"$r")
  md ""
}

while read -r c; do
  m=$(jq -r .metricKey <<<"$c"); v=$(jq -r '.actualValue // "0"' <<<"$c")
  nouveau=false; [[ $m == new_* ]] && nouveau=true
  l=$(libelle "$m")
  echo "::group::Détail — $l"
  md "#### $l"
  case "${m#new_}" in
    security_rating|software_quality_security_rating)          problemes SECURITY "$nouveau" ;;
    reliability_rating|software_quality_reliability_rating)    problemes RELIABILITY "$nouveau" ;;
    maintainability_rating|sqale_rating|software_quality_maintainability_rating) problemes MAINTAINABILITY "$nouveau" ;;
    violations|blocker_violations|critical_violations)         problemes "" "$nouveau" ;;
    security_hotspots_reviewed)
      filtre=(); [ "$nouveau" = true ] && filtre+=(inNewCodePeriod=true)
      if r=$(api hotspots/search project="$KEY" status=TO_REVIEW ps="$MAX" "${filtre[@]}" 2>/dev/null); then
        total=$(jq -r '.paging.total' <<<"$r")
        echo "  $total hotspot(s) à revoir dans Sonar (Security Hotspots) : les marquer « Safe » ou les corriger"
        md "$total hotspot(s) à revoir dans Sonar (onglet Security Hotspots) : les marquer « Safe » ou les corriger."
        md ""
        while IFS=$'\t' read -r comp ligne proba msg; do
          [ -z "$comp" ] && continue
          f=$(chemin <<<"$comp")
          case "$proba" in HIGH) proba=élevé;; MEDIUM) proba=moyen;; LOW) proba=faible;; esac
          echo "  - $f:${ligne} [risque $proba] $msg"
          md "- \`$f:${ligne}\` risque **$proba** — $msg"
        done < <(jq -r '.hotspots[] | [.component, (.line // "" | tostring), .vulnerabilityProbability, .message] | @tsv' <<<"$r")
        md ""
      else indispo; fi ;;
    coverage|line_coverage)
      if [ "${v%%.*}" = 0 ]; then
        txt="Couverture à 0 % : Sonar n'a reçu aucun rapport de couverture. Les tests ne sont pas lancés dans la pipeline, ou le rapport (coverage.xml / coverage/lcov.info) n'est pas au chemin indiqué dans sonar-project.properties."
      else
        txt="Seulement $v % des lignes concernées sont exécutées par les tests : ajouter des tests sur le code modifié."
      fi
      echo "  $txt"; md "$txt"; md "" ;;
    duplicated_lines_density)
      mm=duplicated_lines; [ "$nouveau" = true ] && mm=new_duplicated_lines
      if r=$(api measures/component_tree component="$KEY" metricKeys="$mm" strategy=leaves qualifiers=FIL ps=500 2>/dev/null); then
        echo "  Fichiers avec le plus de lignes dupliquées :"; md "Fichiers avec le plus de lignes dupliquées :"; md ""
        jq -r '.components[] | [.path, ((.measures[0] // {}) | (.period.value // .value // "0"))] | @tsv' <<<"$r" \
          | awk -F'\t' '$2+0>0' | sort -t$'\t' -k2,2nr | head -n "$MAX" \
          | while IFS=$'\t' read -r f nb; do echo "  - $f : $nb ligne(s)"; md "- \`$f\` : $nb ligne(s) dupliquée(s)"; done
        md ""
      else indispo; fi ;;
    *) echo "  Voir la condition dans Sonar."; md "Voir la condition dans Sonar."; md "" ;;
  esac
  echo "::endgroup::"
done <<<"$conds"

echo "Détail complet dans Sonar : projet $KEY (onglet Overview, puis la Quality Gate)."
fin
