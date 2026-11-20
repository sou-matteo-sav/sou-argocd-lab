# `lab-cluster_argocd` — Stack Middleware GitOps (OpenShift GitOps / Argo CD)

Repository di test 1:1 per il deploy GitOps su **OpenShift Single-Node (SNO) 4.22 con LVM Storage (`lvms-vg1`)** tramite **OpenShift GitOps (`openshift-gitops`)**.

## Struttura della cartella

```text
lab-cluster_argocd/
├── bootstrap/
│   ├── 00-bootstrap-secrets.sh   # Pre-flight, creazione namespace managed-by, RBAC CRD, Secret out-of-band e root-app
│   ├── 00-gitops-rbac.yaml       # Permessi CRD (CNPG, RHBK, Monitoring, VolumeSnapshot) per il controller Argo CD
│   └── root-app.yaml             # App-of-Apps (app-cluster-root) nel progetto "default"
├── apps/                         # Argo CD Applications ordinate per sync-wave (0 -> 4)
│   ├── 00-namespaces.yaml        # Wave 0: namespace gitea, keycloak, redis-lab (Prune=false)
│   ├── 01-operators.yaml         # Wave 1: CNPG Operator + RHBK Operator (Manual approval)
│   ├── 02-gitea-db.yaml          # Wave 2: gitea-pg + ScheduledBackup (LVM CSI VolumeSnapshot) + Monitoring + NetPol
│   ├── 03-gitea-app.yaml         # Wave 3: Helm multi-source gitea-charts/gitea 12.7.0 + values-gitea.yaml
│   ├── 04-gitea-ops.yaml         # Wave 4: CronJob LVM CSI VolumeSnapshot (/data + retention gitea-pg) + NetPol gitea-ingress
│   ├── 05-keycloak-db.yaml       # Wave 2: keycloak-pg + ScheduledBackup (LVM CSI VolumeSnapshot) + pruning + Monitoring + NetPol + keycloak-service-trusted
│   ├── 06-keycloak-app.yaml      # Wave 3: Keycloak CR (2 pod) + PDB + Route reencrypt
│   └── 07-redis.yaml             # Wave 2: Redis 7 RHEL 9 StatefulSet (namespace redis-lab) + Service + NetworkPolicy
└── components/                   # Manifest Kustomize / Helm values
```

## Adattamenti specifici per il cluster lab (SNO + LVMS)

1. **Single-Node OpenShift (SNO):** anti-affinity impostata su `preferred` (invece di `required`) su `gitea-pg`, `keycloak-pg` e `keycloak`, così le 2 istanze di ciascun servizio possono girare sullo stesso nodo testando comunque replica PostgreSQL, cold snapshot su standby e clustering Infinispan.
2. **Storage LVM (`lvms-vg1`):** tutti i PVC usano `StorageClass: lvms-vg1` in modalità **`ReadWriteOnce`** (LVMS non supporta `ReadWriteMany`) e `VolumeSnapshotClass: lvms-vg1`.
3. **Risorse ridotte per lab:**
   * **Storage totale:** `19Gi` (`gitea-pg`: `2 × (2Gi + 2Gi)`, `gitea`: `2Gi`, `keycloak-pg`: `2 × (2Gi + 2Gi)`, `redis`: `1Gi`), retention snapshot a `3` copie.
   * **CPU / RAM richieste:** `~1,05 vCPU` e `~4,4 Gi` RAM totali (`gitea-pg` / `keycloak-pg`: `100m`/`512Mi`, `keycloak`: `250m`/`1Gi`, `gitea`: `100m`/`256Mi`, `redis`: `50m`/`128Mi`).
4. **Namespace Redis dedicato (`redis-lab`):** evita conflitti con eventuali workload già presenti nel namespace `redis` del cluster lab.
5. **Argo CD `AppProject` `default` + RBAC minimo:** usa il progetto `default` di `openshift-gitops`, label `argocd.argoproj.io/managed-by: openshift-gitops` sui namespace e `bootstrap/00-gitops-rbac.yaml` sui soli namespace `gitea` e `keycloak`.
6. **Nessun Secret su Git:** tutte le credenziali vengono generate casualmente in locale da `bootstrap/00-bootstrap-secrets.sh`.

---

## Procedura di Bootstrap (Day-0)

### 1. Compilare i placeholder Git e fare push su GitHub
Sostituire in `bootstrap/root-app.yaml` e `apps/*.yaml`:
* `https://github.com/sou-matteo-sav/openshift-argocd-lab.git` (es. `https://github.com/<utente>/<repo>.git`)
* `main` (es. `main`)

Eseguire il `git push` sul repository GitHub.

### 2. Eseguire lo script di bootstrap (come `cluster-admin`)
```bash
chmod +x bootstrap/00-bootstrap-secrets.sh
./bootstrap/00-bootstrap-secrets.sh
```

### 3. Sincronizzare in ordine su Argo CD (UI o CLI)
1. **Sync `app-cluster-root`** → crea le 8 Application figlie in `openshift-gitops`.
2. **Sync `app-cluster-namespaces` (Wave 0) e `app-cluster-operators` (Wave 1)**.
3. **Approvare manualmente i due `InstallPlan` OLM** e attendere `Succeeded`:
   ```bash
   oc get installplan -n openshift-operators
   oc patch installplan <install-cnpg> -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
   oc get csv -n openshift-operators -w

   oc get installplan -n keycloak
   oc patch installplan <install-rhbk> -n keycloak --type merge -p '{"spec":{"approved":true}}'
   oc get csv -n keycloak -w
   ```
4. **Sync `gitea-db`, `keycloak-db` e `redis` (Wave 2)** e attendere lo stato healthy dei due DB:
   ```bash
   oc get cluster gitea-pg -n gitea -w
   oc get cluster keycloak-pg -n keycloak -w
   oc get secret keycloak-pg-app keycloak-tls -n keycloak
   oc get backup,volumesnapshot -n gitea
   oc get backup,volumesnapshot -n keycloak
   ```
5. **Sync `gitea-app` e `keycloak-app` (Wave 3)** → attende creazione PVC `gitea-shared-storage` e pod Ready.
6. **Sync `gitea-ops` (Wave 4)** → attiva il `CronJob` LVM CSI `VolumeSnapshot` (con retention a 3 snapshot per `/data` e `gitea-pg`) e `NetworkPolicy/gitea-ingress`.

### 4. Recupero password iniziali
```bash
# Gitea admin
oc get secret gitea-admin-secret -n gitea -o jsonpath='{.data.password}' | base64 -d && echo
# Keycloak admin
oc get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.password}' | base64 -d && echo
# Redis
oc get secret redis-secret -n redis-lab -o jsonpath='{.data.database-password}' | base64 -d && echo
```
