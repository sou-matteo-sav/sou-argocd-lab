#!/usr/bin/env bash
# ==============================================================================
# lab-cluster_argocd - BOOTSTRAP PREREQUISITI (eseguire una tantum come cluster-admin)
# Crea i namespace gestiti da openshift-gitops, i permessi RBAC CRD, i Secret out-of-band
# (mai salvati su Git) e registra l'Application root su Argo CD.
# ==============================================================================
set -euo pipefail

# 00 - PRE-FLIGHT: verifica placeholder Git e prerequisiti cluster (nessun prerequisito S3 al Day-0)
echo "==> Verifica che non restino placeholder (<GIT_REPO_URL>, <GIT_REVISION>)"
if grep -rnE '<[A-Z0-9_]+>' bootstrap/root-app.yaml apps/ | grep -vE ':[0-9]+:[[:space:]]*#'; then
  echo "ERRORE: sostituire tutti i placeholder Git sopra prima di eseguire il bootstrap e fare git push." >&2
  exit 1
fi

echo "==> Verifica StorageClass, VolumeSnapshotClass LVMS e OpenShift User Workload Monitoring"
oc get sc lvms-vg1
oc get volumesnapshotclass lvms-vg1
oc get pods -n openshift-user-workload-monitoring

# 01 - NAMESPACE CON LABEL argocd.argoproj.io/managed-by: openshift-gitops
echo "==> Creazione namespace gestiti da openshift-gitops"
oc apply -f components/namespaces/namespaces.yaml

# 02 - RBAC AGGIUNTIVI PER CNPG, RHBK, MONITORING E VOLUMESNAPSHOT
echo "==> Applicazione RBAC CRD per openshift-gitops-argocd-application-controller"
oc apply -f bootstrap/00-gitops-rbac.yaml

# 03 - SECRET OUT-OF-BAND (creati solo se non esistono già, così lo script è rieseguibile)
create_secret_if_missing() {
  local ns="$1"
  local name="$2"
  shift 2
  if oc get secret "$name" -n "$ns" >/dev/null 2>&1; then
    echo "    Secret $ns/$name già presente (saltato)"
  else
    oc create secret generic "$name" -n "$ns" "$@"
  fi
}

echo "==> Creazione Secret applicativi (nessun Secret S3 richiesto con backup LVM CSI VolumeSnapshot)"
create_secret_if_missing gitea gitea-admin-secret \
  --from-literal=username=gitea_admin \
  --from-literal=password="$(openssl rand -hex 16)"

create_secret_if_missing keycloak keycloak-admin-secret \
  --from-literal=username=keycloak_admin \
  --from-literal=password="$(openssl rand -hex 16)"

create_secret_if_missing redis-lab redis-secret \
  --from-literal=database-password="$(openssl rand -hex 16)"

# Nota Day-2 (opzionale, per abilitare WAL/PITR verso S3 esterno):
# create_secret_if_missing gitea gitea-pg-backup-s3 --from-literal=ACCESS_KEY_ID="..." --from-literal=ACCESS_SECRET_KEY="..."
# create_secret_if_missing keycloak keycloak-pg-backup-s3 --from-literal=ACCESS_KEY_ID="..." --from-literal=ACCESS_SECRET_KEY="..."

# 04 - REGISTRAZIONE APPLICATION ROOT IN ARGO CD
echo "==> Applicazione bootstrap/root-app.yaml"
oc apply -f bootstrap/root-app.yaml

echo ""
echo "Bootstrap completato."
echo "Prossimi passi (vedere README.md):"
echo "  1. Sincronizzare app-cluster-root su Argo CD."
echo "  2. Sincronizzare app-cluster-namespaces (Wave 0) e app-cluster-operators (Wave 1)."
echo "  3. Approvare manualmente gli InstallPlan di CNPG e RHBK."
echo "  4. Sincronizzare gitea-db, keycloak-db e redis (Wave 2) e attendere che i DB siano healthy."
echo "  5. Sincronizzare gitea-app e keycloak-app (Wave 3), poi gitea-ops (Wave 4)."
