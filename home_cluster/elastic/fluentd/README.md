### To set up authentication credentials for Fluentd:

#### 1. Use the the Management > Roles UI in Kibana or the role API to create a fluentd_writer role. For cluster privileges, add manage_index_templates and monitor. For indices privileges, add write, create, and create_index.
#### Add manage_ilm for cluster and manage and manage_ilm for indices if you plan to use [index lifecycle management](https://www.elastic.co/guide/en/elasticsearch/reference/8.12/getting-started-index-lifecycle-management.html).

```sh
POST _security/role/fluentd_writer
{
  "cluster": ["manage_index_templates", "monitor", "manage_ilm"],
  "indices": [
    {
      "names": [ "fluentd-*" ],
      "privileges": ["write","create","create_index","manage","manage_ilm"]
    }
  ]
}
```

1. The cluster needs the `manage_ilm` privilege if index lifecycle management is enabled.
2. If you use a custom Fluentd index pattern, specify your custom pattern instead of the default `fluentd-*` pattern.
3. If index lifecycle management is enabled, the role requires the `manage` and `manage_ilm` privileges to load index lifecycle policies, create rollover aliases, and create and manage rollover indices.
---

2. Create a fluentd_internal user and assign it the fluentd_writer role. You can create users from the Management > Users UI in Kibana or through the user API:
```sh
POST _security/user/fluentd_internal
{
  "password" : "x-pack-test-password",
  "roles" : [ "fluentd_writer"],
  "full_name" : "Internal Fluentd User"
}
```
