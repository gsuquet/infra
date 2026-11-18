# Every Namespace carries the network policy label, so the cluster-wide
# default-deny selects it (platform namespaces included).
package namespaces

import data.common.manifests
import data.gitops.network_policy_label as label

# A helper rule: in the body of deny, OPA would evaluate the undefined
# reference before the negation, and the rule would never fire.
data_loaded if is_object(label)

deny contains msg if {
	not data_loaded
	msg := "data.gitops.network_policy_label is missing: run conftest with --data policy/data"
}

deny contains msg if {
	some [path, obj] in manifests.resources
	obj.kind == "Namespace"
	obj.apiVersion == "v1"
	not obj.metadata.name in object.get(data.gitops, "network_policy_exempt_namespaces", [])
	object.get(manifests.labels(obj), label.key, "") != label.value
	msg := sprintf("%s: the Namespace %q must have the label %s: %s", [path, obj.metadata.name, label.key, label.value])
}
