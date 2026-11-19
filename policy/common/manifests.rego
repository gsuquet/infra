# Helpers for the policies on rendered manifests. Not "lib/": .gitignore
# ignores lib/ folders (Python section).
# Input: conftest --combine, a list of {"path": ..., "contents": ...}.
package common.manifests

# documents(contents): conftest gives a multi-document file as an array.
documents(contents) := contents if is_array(contents)

documents(contents) := [contents] if is_object(contents)

# resources contains [path, resource]: every Kubernetes object of the input.
resources contains [file.path, doc] if {
	some file in input
	some doc in documents(file.contents)
	is_object(doc)
	is_string(doc.kind)
}

# component(path): the folder after rendered/, the catalog component that
# rendered the file. Undefined for a file outside rendered/.
component(path) := name if {
	matches := regex.find_all_string_submatch_n(`/rendered/([^/]+)/`, path, 1)
	name := matches[0][1]
}

# cluster(path): the cluster folder, <root>/clusters/<cluster>, that holds
# rendered/. It is the key of data.clusters (policy:check generates it).
# Undefined for a file outside rendered/.
cluster(path) := dir if {
	matches := regex.find_all_string_submatch_n(`^(.*)/rendered/[^/]+/`, path, 1)
	dir := matches[0][1]
}

labels(obj) := object.get(obj, ["metadata", "labels"], {})
