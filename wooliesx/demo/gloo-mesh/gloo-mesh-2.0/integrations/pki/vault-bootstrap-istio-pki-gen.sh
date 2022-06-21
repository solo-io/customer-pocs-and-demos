#!/bin/bash

# TODO: WIP script to manage Istio PKI integration with Vault

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

Generate() {
    echo "------------------------------------------------------------"
    echo "Bootstrapping the istio PKI"
    echo "------------------------------------------------------------"
    echo ""

    # Find the public IP for the vault service
    export VAULT_LB=$(kubectl --context ${MGMT_CONTEXT} get svc -n vault vault \
       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    export VAULT_ADDR="http://${VAULT_LB}:8200"
    export VAULT_TOKEN="root"

    if [[ -z "${VAULT_LB}" ]]; then
      echo "Unable to obtain the address for the Vault service"
      exit 1
    fi

    COMMON_NAME="istio.solo.io"
    CERT_GEN_DIR=$DIR/../../_output/certs/istio
    mkdir -p $CERT_GEN_DIR
    mkdir -p $CERT_GEN_DIR/cacerts

    # Generate offline root CA
    cfssl genkey \
      -initca $DIR/istio/root-template.json | cfssljson -bare $CERT_GEN_DIR/root-cert

    # Enable PKI
    vault secrets enable -path=istio-pki pki

    # Tune with 10 years TTL
    vault secrets tune -max-lease-ttl="87600h" istio-pki

    # Generate a CSR
    vault write -field=csr \
      istio-pki/intermediate/generate/internal \
      common_name="$COMMON_NAME" \
      key_type=rsa \
      key_bits=4096 \
      ttl="26280h" > $CERT_GEN_DIR/signing-request.csr

    # Configure certificate issuing and CRL
    vault write \
      istio-pki/config/urls \
      issuing_certificates="$VAULT_ADDR/v1/istio-pki/ca"
      crl_distribution_points="$VAULT_ADDR/v1/istio-pki/crl"
    
    # Sign the CSR using the offline root
    cfssl sign \
      -ca $CERT_GEN_DIR/root-cert.pem \
      -ca-key $CERT_GEN_DIR/root-cert-key.pem \
      -config $DIR/istio/signing-config.json \
      $CERT_GEN_DIR/signing-request.csr | cfssljson -bare $CERT_GEN_DIR/signing-ca

    # Set back the signed CA so that Vault can start issuing certs
    vault write \
      istio-pki/intermediate/set-signed \
      certificate=@$CERT_GEN_DIR/signing-ca.pem

    # Role for cert-manager
    vault write \
      istio-pki/roles/cert-manager \
      allowed_domains="solo.io" \
      allow_subdomains=true \
      max_ttl="720h" \
      require_cn=false \
      allowed_uri_sans="spiffe://cluster.local/*"

    # Use AppRole to authenticate
    vault auth enable approle

    # Define a policy for cert-manager
    vault policy write cert-manager-policy -<<EOF 
path "istio-pki/sign/cert-manager" { capabilities = ["update"] } 
EOF

    # Attach the policy to the AppRole
    vault write \
      auth/approle/role/cert-manager \
      token_policies="cert-manager-policy" \
      token_ttl=1h \
      token_max_ttl=4h
    
    # Get the role-id and secret-id
    CERT_MANAGER_ROLE_ID=$(vault read -format=json auth/approle/role/cert-manager/role-id | jq -r .data.role_id)
    CERT_MANAGER_SECRET_ID=$(vault write -force -format=json auth/approle/role/cert-manager/secret-id | jq -r .data.secret_id | base64)

    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cert-manager-vault-approle
  namespace: gloo-mesh
data:
  secretId: $CERT_MANAGER_SECRET_ID
type: Opaque
EOF

    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: istio-pki/sign/cert-manager
    server: http://vault-internal.vault.svc:8200
    auth:
      appRole:
        path: approle
        roleId: $CERT_MANAGER_ROLE_ID
        secretRef:
          name: cert-manager-vault-approle
          key: secretId
EOF

    # Wait for the issuer to be ready
    kubectl --context ${MGMT_CONTEXT} wait --for=condition=ready issuer vault-issuer -n gloo-mesh

    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-cacerts
  namespace: gloo-mesh
spec:
  secretName: istio-cacerts
  commonName: istio.solo.io
  subject:
    organizations:
      - Istio
  duration: 720h
  renewBefore: 360h
  isCA: true
  usages:
    - digital signature
    - cert sign
    - key encipherment
  dnsNames:
    - istio.solo.io
  issuerRef:
    kind: Issuer
    name: vault-issuer
EOF

    # Wait for certs to become ready
    kubectl --context ${MGMT_CONTEXT} wait --for=condition=ready certs istio-cacerts -n gloo-mesh

    # TODO: Workaround to convert kubernetes TLS format to cacerts format for Istio
    kubectl --context ${MGMT_CONTEXT} get secret istio-cacerts -n gloo-mesh \
      -o json | jq '.data."tls.crt"' -r | base64 --decode > $CERT_GEN_DIR/cacerts/ca-cert.pem
    kubectl --context ${MGMT_CONTEXT} get secret istio-cacerts -n gloo-mesh \
      -o json | jq '.data."tls.key"' -r | base64 --decode > $CERT_GEN_DIR/cacerts/ca-key.pem
    kubectl --context ${MGMT_CONTEXT} get secret istio-cacerts -n gloo-mesh \
      -o json | jq '.data."ca.crt"'  -r | base64 --decode > $CERT_GEN_DIR/cacerts/root-cert.pem
    kubectl --context ${MGMT_CONTEXT} get secret istio-cacerts -n gloo-mesh \
      -o json | jq '.data."tls.crt"' -r | base64 --decode > $CERT_GEN_DIR/cacerts/cert-chain.pem
    kubectl --context ${MGMT_CONTEXT} get secret istio-cacerts -n gloo-mesh \
      -o json | jq '.data."ca.crt"'  -r | base64 --decode >> $CERT_GEN_DIR/cacerts/cert-chain.pem

    # kubectl --context ${MGMT_CONTEXT} create secret generic root-trust-ca -n gloo-mesh \
    #   --from-file=$CERT_GEN_DIR/cacerts/ca-cert.pem \
    #   --from-file=$CERT_GEN_DIR/cacerts/ca-key.pem \
    #   --from-file=$CERT_GEN_DIR/cacerts/root-cert.pem \
    #   --from-file=$CERT_GEN_DIR/cacerts/cert-chain.pem

    kubectl --context ${MGMT_CONTEXT} create secret generic root-trust-ca -n gloo-mesh \
      --from-file=root-cert.pem=$CERT_GEN_DIR/cacerts/root-cert.pem \
      --from-file=cert-chain.pem=$CERT_GEN_DIR/cacerts/cert-chain.pem \
      --from-file=ca-cert.pem=$CERT_GEN_DIR/cacerts/ca-cert.pem \
      --from-file=ca-key.pem=$CERT_GEN_DIR/cacerts/ca-key.pem
}

Delete() {
    echo "Cleaning up ..."

    kubectl --context ${MGMT_CONTEXT} delete secret cert-manager-vault-approle -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete certs istio-cacerts -n gloo-mesh

    kubectl --context ${MGMT_CONTEXT} delete secret istio-cacerts -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete secret root-trust-ca -n gloo-mesh

    rm -rf $CERT_GEN_DIR
}

shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    gen )
        Generate
    ;;
    del )
        Delete
    ;;
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        exit 1
    ;;
esac