#!/bin/bash

Generate() {
    echo "------------------------------------------------------------"
    echo "Bootstrapping the relay PKI"
    echo "------------------------------------------------------------"
    echo ""

    kubectl --context ${MGMT_CONTEXT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${MGMT_CONTEXT} apply -f -

    # Find the public IP for the vault service
    export VAULT_LB=$(kubectl --context ${MGMT_CONTEXT} get svc -n vault vault \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    export VAULT_ADDR="http://${VAULT_LB}:8200"
    export VAULT_TOKEN="root"
    COMMON_NAME="gloo-mesh-mgmt-server"

    sleep 60

    # Enable PKI
    vault secrets enable pki

    # Setup trust root
    vault write -format=json \
      pki/root/generate/internal \
      common_name="Solo.io Root CA" \
      organization="solo.io" \
      ttl=187600h

    # Generate an intermediate CA
    vault secrets enable -path pki_relay pki

    vault write -format=json \
      pki_relay/intermediate/generate/internal \
      common_name=${COMMON_NAME} \
      organization="mesh.solo.io" \
      ttl=43800h | jq -r '.data.csr' > signing_request.csr

    # Sign and generate the certificate with the above CSR
    vault write -format=json \
      pki/root/sign-intermediate \
      csr=@signing_request.csr \
      format=pem_bundle \
      ttl=43800h | jq -r ' .data.certificate' > intermediate.crt

    rm -f signing_request.csr

    # Set signed cert with the extracted blob
    vault write -format=json \
      pki_relay/intermediate/set-signed \
      certificate=@intermediate.crt

    rm -f intermediate.crt

    # Configure a role
    vault write \
      pki_relay/roles/gloo-mesh-mgmt-server \
      allow_any_name=true max_ttl="720h"

    echo ""
    echo "Configuring certificate manager to issue relay server certificate"
    kubectl --context ${MGMT_CONTEXT} create secret generic vault-token --from-literal=token=root -n gloo-mesh
        
    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: pki_relay/sign/gloo-mesh-mgmt-server
    server: http://vault-internal.vault.svc:8200
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 60

    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-server-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "${COMMON_NAME}"
    - "${COMMON_NAME}.gloo-mesh"
    - "${COMMON_NAME}.gloo-mesh.svc"
    - "*.gloo-mesh"
  secretName: relay-server-tls-secret
  duration: 72h
  renewBefore: 30m
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF

    sleep 60

    kubectl --context ${WEST_CONTEXT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${WEST_CONTEXT} apply -f -

    echo ""
    echo "Configuring certificate manager to issue the relay client certificate for West cluster"
    kubectl --context ${WEST_CONTEXT} create secret generic vault-token --from-literal=token=root -n gloo-mesh

    kubectl --context ${WEST_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: pki_relay/sign/gloo-mesh-mgmt-server
    server: $VAULT_ADDR
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 60

    kubectl apply --context ${WEST_CONTEXT} -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-client-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "$WEST_MESH_NAME"
  secretName: relay-client-tls-secret
  duration: 24h
  renewBefore: 30m
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF

    kubectl --context ${EAST_CONTEXT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${EAST_CONTEXT} apply -f -

    echo ""
    echo "Configuring certificate manager to issue the relay client certificate for East cluster"
    kubectl --context ${EAST_CONTEXT} create secret generic vault-token --from-literal=token=root -n gloo-mesh

    kubectl --context ${EAST_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: pki_relay/sign/gloo-mesh-mgmt-server
    server: $VAULT_ADDR
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 60

    kubectl --context ${EAST_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-client-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "$EAST_MESH_NAME"
  secretName: relay-client-tls-secret
  duration: 24h
  renewBefore: 30m
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF

}

Delete() {
    echo "Cleaning up ..."

    kubectl --context ${MGMT_CONTEXT} delete secret vault-token -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete secret relay-server-tls-secret -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete certificate relay-server-tls -n gloo-mesh

    kubectl --context ${EAST_CONTEXT} delete secret vault-token -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete secret relay-client-tls-secret -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete secret relay-identity-token-secret -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete secret relay-root-tls-secret -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete certificate relay-client-tls -n gloo-mesh

    kubectl --context ${WEST_CONTEXT} delete secret vault-token -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete secret relay-client-tls-secret -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete secret relay-identity-token-secret -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete secret relay-root-tls-secret -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete certificate relay-client-tls -n gloo-mesh
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