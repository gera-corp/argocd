Prerequisite
    You have a working vault cluster
    You have sufficient access to the cluster
    You have a working S3 storage instance


Create a minimal policy for our snapshot agent to perform the backup job.
```bash
echo '
path "sys/storage/raft/snapshot" {
   capabilities = ["read"]
}' | vault policy write snapshot -
```

AppRole auth method is perfectly suited for the snapshot agent to authenticate with our vault cluster. Notes role-id and secret-id, you will need them later.
```bash
vault auth enable approle
vault write auth/approle/role/snapshot-agent token_ttl=1m token_policies=snapshot
vault read auth/approle/role/snapshot-agent/role-id -format=json | jq -r .data.role_id
vault write -f auth/approle/role/snapshot-agent/secret-id -format=json | jq -r .data.secret_id
```

Put roleid and secretid in vault secrets. Then create cronjob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-snapshot-cronjob
  namespace: vault-backup
spec:
  schedule: "@every 12h"
  jobTemplate:
    spec:
      template:
        spec:
          volumes:
          - name: share
            emptyDir: {}
          containers:
          - name: snapshot
            image: hashicorp/vault:1.20.1
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            args:
            - -ec
            # The offical vault docker image actually doesn't come with `jq`. You can
            # - install it during runtime (not a good idea and your security team may not like it)
            # - ship `jq` static binary in a standalone image and mount it using a shared volume from `initContainers`
            # - build your custom `vault` image
            - |
              apk add --no-cache curl jq;
              export VAULT_ADDR="https://vault-cluster.local.geracorp.work";
              export VAULT_ADDR=$(vault read sys/leader --format=json | jq -r .data.leader_address);
              export VAULT_TOKEN=$(vault write auth/approle/login role_id=$VAULT_APPROLE_ROLE_ID secret_id=$VAULT_APPROLE_SECRET_ID -format=json | jq -r .auth.client_token);
              vault operator raft snapshot save /share/vault-raft.snap;
            env:
            - name: VAULT_APPROLE_ROLE_ID
              value: vault:secret/data/vault_backup/agent-token#VAULT_APPROLE_ROLE_ID
            - name: VAULT_APPROLE_SECRET_ID
              value: vault:secret/data/vault_backup/agent-token#VAULT_APPROLE_SECRET_ID
            volumeMounts:
            - mountPath: /share
              name: share
          - name: upload
            image: amazon/aws-cli:2.27.62
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            args:
            - -ec
            # the script wait untill the snapshot file is available
            # then upload to s3
            # for folks using non-aws S3 like IBM Cloud Object Storage service, add a `--endpoint-url` option
            # run `aws --endpoint-url <https://your_s3_endpoint> s3 cp ...`
            # change the s3://<path> to your desired location
            - |
              until [ -f /share/vault-raft.snap ]; do sleep 5; done;
              aws --endpoint-url https://api-minio.local.geracorp.work s3 cp /share/vault-raft.snap s3://vault-backup/vault_raft_$(date +"%Y%m%d_%H%M%S").snap;
            env:
            - name: AWS_ACCESS_KEY_ID
              value: vault:secret/data/vault_backup/snapshot-s3#AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              value: vault:secret/data/vault_backup/snapshot-s3#AWS_SECRET_ACCESS_KEY
            volumeMounts:
            - mountPath: /share
              name: share
          restartPolicy: OnFailure
```
