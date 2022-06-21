Create namespaces and inject istio-operator config for control plane

```
kubectl --context ${WEST_CONTEXT} create namespace istio-system 
kubectl --context ${WEST_CONTEXT} create namespace istio-ingress
kubectl --context ${WEST_CONTEXT} create namespace istio-eastwest
kubectl --context ${WEST_CONTEXT} create namespace istio-config

istioctl --context ${WEST_CONTEXT} operator init --watchedNamespaces=istio-system,istio-ingress,istio-eastwest

CLUSTER_NAME=$WEST_MESH_NAME

cat <<EOF | istioctl --context ${WEST_CONTEXT} install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  profile: minimal
  # This value is required for Gloo Mesh Istio
  hub: ${REPO}
  # This value can be any Gloo Mesh Istio tag
  tag: ${ISTIO_VERSION}
  revision: ${REVISION}

  # You may override parts of meshconfig by uncommenting the following lines.
  meshConfig:
    # enable access logging. Empty value disables access logging.
    accessLogFile: /dev/stdout
    # Encoding for the proxy access log.
    accessLogEncoding: JSON
    accessLogFormat: '{
      "start_time": "%START_TIME%",
      "authority": "%REQ(:AUTHORITY)%",
      "bytes_received": "%BYTES_RECEIVED%",
      "bytes_sent": "%BYTES_SENT%",
      "downstream_local_address": "%DOWNSTREAM_LOCAL_ADDRESS%",
      "downstream_remote_address": "%DOWNSTREAM_REMOTE_ADDRESS%",
      "duration": "%DURATION%",
      "method": "%REQ(:METHOD)%",
      "path": "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%",
      "protocol": "%PROTOCOL%",
      "requested_server_name": "%REQUESTED_SERVER_NAME%",
      "response_code": "%RESPONSE_CODE%",
      "response_code_details": "%RESPONSE_CODE_DETAILS%",
      "response_flags": "%RESPONSE_FLAGS%",
      "route_name": "%ROUTE_NAME%",
      "upstream_cluster": "%UPSTREAM_CLUSTER%",
      "upstream_host": "%UPSTREAM_HOST%",
      "upstream_local_address": "%UPSTREAM_LOCAL_ADDRESS%",
      "upstream_service_time": "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%",
      "upstream_transport_failure_reason": "%UPSTREAM_TRANSPORT_FAILURE_REASON%",
      "user_agent": "%REQ(USER-AGENT)%",
      "x_forwarded_for": "%REQ(X-FORWARDED-FOR)%"
    }'

    enableTracing: true

    enableAutoMtls: true

    extensionProviders:
      - name: "opencensus-tracing"
        opencensus:
          context: ["W3C_TRACE_CONTEXT"]
          service: "oc-opentelemetry-collector.telemetry.svc"
          port: 55678
    defaultProviders:
      tracing: ["opencensus-tracing"]

    defaultConfig:
      # wait for the istio-proxy to start before application pods
      holdApplicationUntilProxyStarts: true
      # location of istiod service
      # discoveryAddress: istiod-${REVISION}.istio-system.svc:15012
      # enable GlooMesh metrics service
      envoyMetricsService:
        address: gloo-mesh-agent.gloo-mesh:9977
      # enable GlooMesh accesslog service
      envoyAccessLogService:
        address: gloo-mesh-agent.gloo-mesh:9977
      # Tracing with opencensus. 
      # TODO: This is a temp solution until opentelemetry is introduced in Istio/Envoy
      # tracing:
        # sample 100% of traffic
        # sampling: 100.0
        # openCensusAgent:
        #  address: "dns:oc-opentelemetry-collector.telemetry.svc:55678"
        #  context: [W3C_TRACE_CONTEXT]
      proxyMetadata:
        # Enable Istio agent to handle DNS requests for known hosts
        # Unknown hosts will automatically be resolved using upstream dns servers in resolv.conf
        ISTIO_META_DNS_CAPTURE: "true"
        # Enable automatic address allocation, optional
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
        # Used for gloo mesh metrics aggregation
        # should match trustDomain
        GLOO_MESH_CLUSTER_NAME: ${CLUSTER_NAME}
    
    # Specify if http1.1 connections should be upgraded to http2 by default. 
    # Can be overridden using DestinationRule
    # h2UpgradePolicy: UPGRADE

    # Set the default behavior of the sidecar for handling outbound traffic from the application.
    outboundTrafficPolicy:
      mode: ALLOW_ANY
    # The trust domain corresponds to the trust root of a system. For Gloo Mesh this should be the name of the cluster that cooresponds with the CA certificate CommonName identity
    trustDomain: ${CLUSTER_NAME}.solo.io
    # The namespace to treat as the administrative root namespace for Istio configuration.
    rootNamespace: istio-config

  # Traffic management feature
  components:
    base:
      enabled: true
    pilot:
      enabled: true
      k8s:
        replicaCount: 1
        resources:
          requests:
            cpu: 200m
            memory: 200Mi
        env:
        # Allow multiple trust domains (Required for Gloo Mesh east/west routing)
        - name: PILOT_SKIP_VALIDATE_TRUST_DOMAIN
          value: "true"
        - name: PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES
          value: "false"

    # Disable Istio CNI feature
    cni:
      enabled: false

    # Istio Gateway featureß
    # Disable gateways deployments because they will be in separate IstioOperator configs
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
    - name: istio-eastwestgateway
      enabled: false
    egressGateways:
    - name: istio-egressgateway
      enabled: false

    # Helm values overrides
  values:
    global:
      # Needed for connecting VirtualMachines to the mesh
      network: ${CLUSTER_NAME}-network
      # Needed for annotating istio metrics with cluster
      multiCluster:
        clusterName: ${CLUSTER_NAME}
      # proxy:
      #  tracer: openCensusAgent 
EOF
```

Deploy ingress gateway

```
cat <<EOF | istioctl --context ${WEST_CONTEXT} install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: ingress-gateway-${REVISION}
  namespace: istio-ingress
spec:
  profile: empty
  # This value is required for Gloo Mesh Istio
  hub: ${REPO}
  # This value can be any Gloo Mesh Istio tag
  tag: ${ISTIO_VERSION}
  revision: ${REVISION}
  components:
    ingressGateways:
      - name: istio-ingressgateway
        namespace: istio-ingress
        enabled: true
        label:
          istio: ingressgateway
          version: ${REVISION}
          app: istio-ingressgateway
          # matches spec.values.global.network in istiod deployment
          topology.istio.io/network: ${CLUSTER_NAME}-network
        k8s:
          resources:
            limits:
              cpu: 2000m
              memory: 1024Mi
            requests:
              cpu: 100m
              memory: 40Mi
          serviceAnnotations:
            service.beta.kubernetes.io/aws-load-balancer-type: "external"
            service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
            service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
            service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/healthz/ready"
            service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "15021"
            service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "http"
            external-dns.alpha.kubernetes.io/hostname: apps.${DOMAIN_NAME}
          service:
            type: LoadBalancer
            ports:
              - name: tcp-status-port
                port: 15021
                targetPort: 15021
              - name: http2
                port: 80
                targetPort: 8080
              - name: https
                port: 443
                targetPort: 8443
          overlays:
            - apiVersion: v1
              kind: Deployment
              name: istio-ingressgateway
              patches:
              # Sleep 25s on pod shutdown to allow connections to drain
              - path: spec.template.spec.containers.[name:istio-proxy].lifecycle
                value:
                  preStop:
                    exec:
                      command:
                      - sleep
                      - "25"
              # Schedule pods on separate nodes if possible
              - path: spec.template.spec.affinity
                value:
                  podAntiAffinity:
                    preferredDuringSchedulingIgnoredDuringExecution:
                    - podAffinityTerm:
                        labelSelector:
                          matchExpressions:
                          - key: app
                            operator: In
                            values:
                            - istio-ingressgateway
                        topologyKey: kubernetes.io/hostname
                      weight: 100

  # Helm values overrides
  values:
    gateways:
      istio-ingressgateway:
        # Enable gateway injection
        injectionTemplate: gateway
    global:
      # needed for connecting VirtualMachines to the mesh
      network: ${CLUSTER_NAME}-network
      # needed for annotating istio metrics with cluster
      multiCluster:
        clusterName: ${CLUSTER_NAME}
EOF
```

Deploy east-west gateway

```
cat <<EOF | istioctl --context ${WEST_CONTEXT} install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest-gateway-${REVISION}
  namespace: istio-eastwest
spec:
  # No control plane components are installed
  profile: empty
  # This value is required for Gloo Mesh Istio
  hub: ${REPO}
  # The Solo.io Gloo Mesh Istio version
  tag: ${ISTIO_VERSION}
  # Istio revision to create resources with
  revision: ${REVISION}
  
  components:
    ingressGateways:
      # Enable the default east-west gateway
      - name: istio-eastwestgateway
        namespace: istio-eastwest
        enabled: true
        label:
          istio: eastwestgateway
          version: ${REVISION}
          app: istio-eastwestgateway
          # Matches spec.values.global.network in the istiod deployment
          topology.istio.io/network: ${CLUSTER_NAME}-network
        k8s:
          resources:
            limits:
              cpu: 2000m
              memory: 1024Mi
            requests:
              cpu: 100m
              memory: 40Mi
          env:
            # Required by Gloo Mesh for east/west routing
            # sni-dnat adds the clusters required for AUTO_PASSTHROUGH mode
            - name: ISTIO_META_ROUTER_MODE
              value: "sni-dnat"
            # Traffic through this gateway should be routed inside the network
            #- name: ISTIO_META_REQUESTED_NETWORK_VIEW
            #  value: ${CLUSTER_NAME}-network
          service:
            type: LoadBalancer
            ports:
              # Health check port. For AWS ELBs, this port must be listed first.
              - name: tcp-status-port
                port: 15021
                targetPort: 15021
              # Port for multicluster mTLS passthrough
              # Dont change the name since Gloo Mesh looks for "tls"
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tcp-istiod
                port: 15012
                targetPort: 15012
          overlays:
            - apiVersion: apps/v1
              kind: Deployment
              name: istio-eastwestgateway
              patches:
                # Sleep 25s on pod shutdown to allow connections to drain
                - path: spec.template.spec.containers.[name:istio-proxy].lifecycle
                  value:
                    preStop:
                      exec:
                        command:
                        - sleep
                        - "25"
                # Schedule pods on separate nodes if possible
                - path: spec.template.spec.affinity
                  value:
                    podAntiAffinity:
                      preferredDuringSchedulingIgnoredDuringExecution:
                      - podAffinityTerm:
                          labelSelector:
                            matchExpressions:
                            - key: app
                              operator: In
                              values:
                              - istio-eastwestgateway
                          topologyKey: kubernetes.io/hostname
                        weight: 100

  # Helm values overrides
  values:
    gateways:
      istio-ingressgateway:
        # Enable gateway injection
        injectionTemplate: gateway
    global:
      # needed for connecting VirtualMachines to the mesh
      network: ${CLUSTER_NAME}-network
      # needed for annotating istio metrics with cluster
      multiCluster:
        clusterName: ${CLUSTER_NAME}
EOF
```