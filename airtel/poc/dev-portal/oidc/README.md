# Dev Portal OIDC Poc for Airtel

PoC for Airtel to verify OIDC authentication with Keycloak.

## Prerequisites

1. Create required env vars

    ```
    export CLUSTER_OWNER="kasunt"
    export CLUSTER_REGION=ap-southeast-1
    export PROJECT="airtel"

    export CLUSTER_NAME=${CLUSTER_OWNER}-${PROJECT}
    export PARENT_DOMAIN_NAME=${CLUSTER_OWNER}.fe.gl00.net
    export DOMAIN_NAME=${PROJECT}.${CLUSTER_OWNER}.fe.gl00.net

    export GLOO_EDGE_HELM_VERSION=1.11.16
    export GLOO_EDGE_VERSION=v${GLOO_EDGE_HELM_VERSION}

    export GLOO_PORTAL_HELM_VERSION=1.2.5
    ```

2. Create output directory structure

    ```
    mkdir -p _output/{gloo,alb-controller,external-dns,cert-manager}
    ```

3. Provisioned cluster

    ```
    ./cluster-provision/scripts/provision-eks-cluster.sh create -n ${PROJECT} -o ${CLUSTER_OWNER} -a 3 -v 1.22 -r ${CLUSTER_REGION}
    ```

## Integrations

Refer to [guide](integrations/INTEGRATIONS.md) for instructions.

### Setup Postgres for Dev Portal

```
kubectl create ns gloo-system
kubectl create ns gloo-portal

cat <<EOF | kubectl apply -n gloo-system -f -
apiVersion: v1
kind: Secret
metadata:
  name: monetization-secret
type: kubernetes.io/basic-auth
stringData:
  username: postgres-user
  password: postgres-password
EOF

cat <<EOF | kubectl apply -n gloo-system -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: monetization-config
data:
  storage-type: "postgres"
  config.yaml: | # Edge and Portal will mount this volume and read this field as a YAML file
    secretpath: /etc/monetization/secret
    host: postgres-postgresql.gloo-system.svc.cluster.local
    db: postgres-db
    port: 5432
EOF

cat <<EOF | kubectl apply -n gloo-portal -f -
apiVersion: v1
kind: Secret
metadata:
  name: monetization-secret
type: kubernetes.io/basic-auth
stringData:
  username: postgres-user
  password: postgres-password
EOF

cat <<EOF | kubectl apply -n gloo-portal -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: monetization-config
data:
  storage-type: "postgres"
  config.yaml: | # Edge and Portal will mount this volume and read this field as a YAML file
    secretpath: /etc/monetization/secret
    host: postgres-postgresql.gloo-system.svc.cluster.local
    db: postgres-db
    port: 5432
EOF

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-schema
  namespace: gloo-system
data:
  init-schema.sql: |
    CREATE TABLE public.requests
    (
        id          bigint                   NOT NULL,
        user_id     text                     NOT NULL,
        route       text                     NOT NULL,
        api_product text                     NOT NULL,
        environment text                     NOT NULL,
        status      integer                  NOT NULL,
        request_ts  timestamp with time zone NOT NULL,
        method      text                     NOT NULL,
        request_id  text                     NOT NULL
    );

    ALTER TABLE public.requests
        OWNER TO "postgres-user";

    CREATE SEQUENCE public.requests_id_seq
        AS bigint
        START WITH 1
        INCREMENT BY 1
        NO MINVALUE
        NO MAXVALUE
        CACHE 1;

    ALTER TABLE public.requests_id_seq
        OWNER TO "postgres-user";

    ALTER SEQUENCE public.requests_id_seq OWNED BY public.requests.id;

    ALTER TABLE ONLY public.requests
        ALTER COLUMN id SET DEFAULT nextval('public.requests_id_seq'::regclass);

    ALTER TABLE ONLY public.requests
        ADD CONSTRAINT requests_pkey PRIMARY KEY (id);
EOF

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install postgres bitnami/postgresql -n gloo-system \
  --version 10.16.2 \
  --set image.debug=true \
  --set global.postgresql.postgresqlDatabase=postgres-db \
  --set global.postgresql.postgresqlUsername=postgres-user \
  --set global.postgresql.postgresqlPassword=postgres-password \
  --set service.ports.postgresql=5432 \
  --set primary.initdb.scriptsConfigMap=postgres-schema
```

## Setup Gloo Edge & Dev Portal

```
helm repo add gloo-portal https://storage.googleapis.com/dev-portal-helm
helm repo update

envsubst < gloo-edge-helm-values.yaml > _output/gloo/gloo-edge-helm-values.yaml
helm install glooe glooe/gloo-ee -n gloo-system \
  --version ${GLOO_EDGE_HELM_VERSION} \
  --create-namespace \
  --set-string license_key=${GLOO_EDGE_LICENSE_KEY} \
  -f _output/gloo/gloo-edge-helm-values.yaml

helm install gloo-portal gloo-portal/gloo-portal -n gloo-portal \
  --version ${GLOO_PORTAL_HELM_VERSION} \
  --create-namespace -f gloo-dev-portal-helm-values.yaml
```

## Setup Application and Configuration

```
kubectl create ns petstore
kubectl create ns apps-configuration

kubectl apply -f apps/
```