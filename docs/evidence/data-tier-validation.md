# Evidence — Data tier validation on OrbStack Kubernetes

Chart deployed with the application tier disabled (`magento.replicaCount=0`,
install/cron/cloudflared/ingress off) to validate the stateful services,
storage and network posture independently of the Magento image.

Cluster: OrbStack, Kubernetes v1.34.8+orb1, StorageClass `local-path` (default).

## Release

```
$ helm upgrade --install magento charts/magento -n magento --create-namespace \
    -f charts/magento/values.yaml -f charts/magento/values-orbstack.yaml ...
STATUS: deployed   REVISION: 1
```

## Pods

```
$ kubectl -n magento get pods
NAME                     READY   STATUS    RESTARTS   AGE
mariadb-0                1/1     Running   0          8m
opensearch-0             1/1     Running   0          8m
redis-764fcff4b4-md9gc   1/1     Running   0          8m
```

## Persistent volumes

```
$ kubectl -n magento get pvc
NAME                STATUS    CAPACITY   ACCESS MODES   STORAGECLASS
data-mariadb-0      Bound     8Gi        RWO            local-path
data-opensearch-0   Bound     5Gi        RWO            local-path
magento-media       Pending   -          RWO            local-path
```

`magento-media` stays Pending by design: `local-path` uses
`WaitForFirstConsumer`, and the app tier that mounts it is scaled to 0 in this
test. It binds as soon as a Magento pod is scheduled.

## Service reachability

MariaDB — the dedicated **non-root** application user authenticates and the
schema exists:

```
$ kubectl -n magento exec mariadb-0 -- mysql -umagento -p*** -e "SELECT CURRENT_USER(); SHOW DATABASES;"
CURRENT_USER()
magento@%
Database
information_schema
magento
```

Redis:

```
$ kubectl -n magento exec deploy/redis -- redis-cli PING
PONG
$ ... redis-cli INFO replication | grep role
role:master
```

OpenSearch — cluster health **green**:

```
$ kubectl -n magento exec opensearch-0 -- curl -s localhost:9200/_cluster/health
{"cluster_name":"docker-cluster","status":"green","number_of_nodes":1,
 "active_shards":3,"unassigned_shards":0,"active_shards_percent_as_number":100.0}
```

## Network posture

Every data-tier Service is `ClusterIP` (headless for the StatefulSets) — none is
reachable from outside the cluster. Only `magento-web` is fronted by the
Ingress, and public traffic arrives exclusively through the Cloudflare Tunnel.

```
$ kubectl -n magento get svc -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,CLUSTERIP:.spec.clusterIP
NAME          TYPE        CLUSTERIP
magento-web   ClusterIP   192.168.194.201
mariadb       ClusterIP   None
opensearch    ClusterIP   None
redis         ClusterIP   None
```

## Prerequisites in place

```
$ kubectl -n ingress-nginx get pods
ingress-nginx-controller-6fd7d65fb-9vxh5   1/1   Running

$ kubectl -n kube-system get deploy metrics-server
metrics-server   1/1   1   1
```
