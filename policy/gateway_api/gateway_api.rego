# One component owns the Gateway API CRDs. An implementation that brings its
# own copy would fight it over the CRD versions.
package gateway_api

import data.common.manifests
import data.gitops.gateway_api as gateway_api

# Helper rules: in the body of deny, OPA would evaluate an undefined value
# before the negation, and the rule would never fire.
data_loaded if is_object(gateway_api)

from_owner(path) if manifests.component(path) == gateway_api.component

deny contains msg if {
	not data_loaded
	msg := "data.gitops.gateway_api is missing: run conftest with --data policy/data"
}

deny contains msg if {
	some [path, obj] in manifests.resources
	obj.kind == "CustomResourceDefinition"
	object.get(obj, ["spec", "group"], "") in gateway_api.groups
	not from_owner(path)
	msg := sprintf("%s: the Gateway API CRD %q must come from the %s component only. Install the implementation without its bundled CRDs.", [path, obj.metadata.name, gateway_api.component])
}
