# Every namespace a cluster uses is a rendered Namespace with the network
# policy label, so the cluster-wide default-deny selects it (platform
# namespaces included). A namespace Argo CD (CreateNamespace=true) or
# Terraform creates has no label: it must be rendered instead.
package namespaces

import data.common.manifests
import data.gitops.network_policy_label as label

# Helper rules: in the body of deny, OPA would evaluate the undefined
# reference before the negation, and the rule would never fire.
data_loaded if is_object(label)

clusters_loaded if is_object(data.clusters)

# data.clusters, or {} when missing. Not object.get(data, ...): a reference
# to the whole data document makes the rules recursive.
clusters := data.clusters if clusters_loaded

clusters := {} if not clusters_loaded

exempt(name) if name in object.get(data.gitops, "network_policy_exempt_namespaces", [])

deny contains msg if {
	not data_loaded
	msg := "data.gitops.network_policy_label is missing: run conftest with --data policy/data"
}

deny contains msg if {
	not clusters_loaded
	msg := "data.clusters is missing: run 'mise run policy:check', which generates it from the cluster.yaml files"
}

deny contains msg if {
	some [path, obj] in manifests.resources
	obj.kind == "Namespace"
	obj.apiVersion == "v1"
	not exempt(obj.metadata.name)
	object.get(manifests.labels(obj), label.key, "") != label.value
	msg := sprintf("%s: the Namespace %q must have the label %s: %s", [path, obj.metadata.name, label.key, label.value])
}

# rendered_namespaces[cluster]: the Namespaces rendered on a cluster.
rendered_namespaces[cluster] contains obj.metadata.name if {
	some [path, obj] in manifests.resources
	obj.kind == "Namespace"
	obj.apiVersion == "v1"
	cluster := manifests.cluster(path)
}

# used_namespaces[cluster][namespace]: why the cluster needs the namespace.
# The catalog namespace of each enabled component (its Application deploys
# there, with or without metadata.namespace on the resources).
used_namespaces[cluster] contains [namespace, sprintf("the namespace of the component %q", [component])] if {
	some cluster, spec in clusters
	some component, namespace in object.get(spec, "components", {})
}

# The namespaces of each tenant of the cluster.
used_namespaces[cluster] contains [namespace, sprintf("a namespace of the tenant %q", [tenant])] if {
	some cluster, spec in clusters
	some tenant, namespaces in object.get(spec, "tenants", {})
	some namespace in namespaces
}

# The explicit namespace of each rendered resource.
used_namespaces[cluster] contains [namespace, sprintf("used by %s", [path])] if {
	some [path, obj] in manifests.resources
	namespace := obj.metadata.namespace
	is_string(namespace)
	cluster := manifests.cluster(path)
}

deny contains msg if {
	some cluster, used in used_namespaces
	some [namespace, reason] in used
	not exempt(namespace)
	not namespace in object.get(rendered_namespaces, cluster, set())
	msg := sprintf("%s: the namespace %q (%s) has no rendered Namespace: render it with the label %s: %s, or the default-deny does not select it", [cluster, namespace, reason, label.key, label.value])
}
