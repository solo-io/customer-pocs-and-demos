#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

Provision() {
  echo "------------------------------------------------------------"
  echo "Injecting assets for publishing APIs and portal"
  echo "------------------------------------------------------------"
  echo ""

  kubectl apply -f $DIR/api-publish/petstore-schema.yaml
  kubectl apply -f $DIR/api-publish/petstore-product.yaml
  envsubst < <(cat $DIR/api-publish/petstore-env.yaml) | kubectl apply -f -
  envsubst < <(cat $DIR/api-publish/petstore-portal.yaml) | kubectl apply -f -

  echo ""
  echo "---- Generating a user/group for testing ... ----"
  pass=$(htpasswd -bnBC 10 "" Passwd00 | tr -d ':\n')
  # Store the hash as a Kubernetes Secret
  kubectl create secret generic dev1-password -n apps-configuration \
    --type=opaque \
    --from-literal=password=$pass 
  kubectl apply -f $DIR/api-publish/basic-auth/dev-group.yaml
  kubectl apply -f $DIR/api-publish/basic-auth/dev-user.yaml 

  export CLIENT_SECRET_BASE64_ENCODED=$(echo -n $CLIENT_SECRET | base64)
  envsubst < <(cat $DIR/api-publish/oidc-auth/secret.yaml) | kubectl apply -f -
  kubectl apply -f $DIR/api-publish/oidc-auth/dev-group.yaml
}

Delete() {
  echo "Cleaning up ..."

  kubectl delete -f $DIR/api-publish/petstore-schema.yaml
  kubectl delete -f $DIR/api-publish/petstore-product.yaml
  envsubst < <(cat $DIR/api-publish/petstore-env.yaml) | kubectl delete -f -
  envsubst < <(cat $DIR/api-publish/petstore-portal.yaml) | kubectl delete -f -

  kubectl delete secret dev1-password -n apps-configuration
  kubectl delete -f $DIR/api-publish/basic-auth/dev-group.yaml
  kubectl delete -f $DIR/api-publish/basic-auth/dev-user.yaml

  envsubst < <(cat $DIR/api-publish/oidc-auth/secret.yaml) | kubectl delete -f -
  kubectl delete -f $DIR/api-publish/oidc-auth/dev-group.yaml
}

shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    prov )
        Provision
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