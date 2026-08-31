#!/bin/bash

main() {
	check_dependencies || exit 1

	local filename content

	filename="$(resolve_classpath_file "${1}")" || exit 1
	content="$(print_clean_classpath "${filename}")"

	write_classpath_file "${filename}" "${content}"
}

check_dependencies() {
	local -A install_hints=(
		[xidel]="Not in the default Ubuntu/Debian apt repos; get a .deb/source package from https://www.videlibri.de/xidel.html"
		[xmllint]="Install via 'apt install libxml2-utils' (Debian/Ubuntu); it's part of libxml2, see http://xmlsoft.org/"
	)

	local cmd missing=()
	for cmd in "${!install_hints[@]}"; do
		require "${cmd}" "${install_hints[${cmd}]}" || missing+=("${cmd}")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Missing executables: ${missing[*]}" >&2
		return 1
	fi
}

require() {
	local cmd="${1}" hint="${2}"

	command -v "${cmd}" >/dev/null 2>&1 && return 0

	echo "Error: '${cmd}' is required but not installed." >&2
	[ -z "${hint}" ] || echo "${hint}" >&2
	return 1
}

resolve_classpath_file() {
	local filename="${1:-"${PWD}"}"

	if [ -d "${filename}" ]; then
		filename="${filename%/}/.classpath"
	fi

	validate_classpath_file "${filename}" || return 1

	echo "${filename}"
}

validate_classpath_file() {
	local filename="${1}" node
	node="$(xmllint --xpath 'name(/*)' "${filename}" 2>/dev/null)"

	[ "${node}" = "classpath" ] && return 0

	echo "Error: '${filename}' does not look like an Eclipse .classpath file (root element is '<${node}>', expected '<classpath>')." >&2
	return 1
}

print_clean_classpath() {
	local filename="${1}"

	xidel --silent "file://${filename}" \
		--input-format xml \
		--xquery '
			(: sort key for classpathentry attributes: kind, output, path, then alphabetical :)
			declare function local:classpathentry-attr-sort-key($attr as attribute()) as xs:string {
				let $name := name($attr)
				return
					switch ($name)
						case "kind" return "0_kind"
						case "output" return "1_output"
						case "path" return "2_path"
						default return "3_" || $name
			};

			(: rebuild a classpathentry with sorted attributes and, if present, its
			   nested <attributes>/<attribute> children sorted by @name :)
			declare function local:prettify-classpathentry($entry as element()) as element() {
				element { node-name($entry) } {
					for $attr in $entry/@* order by local:classpathentry-attr-sort-key($attr) return $attr,
					for $node in $entry/node()
						return
							if ($node instance of element() and local-name($node) = "attributes")
							then element { node-name($node) } {
								$node/@*,
								for $attr in $node/attribute
									order by $attr/@name
									return $attr
							}
							else $node
				}
			};

			(: entry group: 0 = non-source, 1 = generated source (path under target/), 2 = regular source :)
			declare function local:classpathentry-group($entry as element()) as xs:integer {
				switch (true())
					case not($entry/@kind = "src") return 0
					case starts-with($entry/@path, "target") return 1
					default return 2
			};

			<classpath>
				{
					(: group by entry type, then sort by kind (constant within src groups) and path :)
					for $entry in /classpath/classpathentry
						order by local:classpathentry-group($entry), $entry/@kind, $entry/@path
						return local:prettify-classpathentry($entry)
				}
			</classpath>
		' \
		--output-format xml
}

write_classpath_file() {
	local filename="${1}" content="${2}"

	<<<"${content}" \
	XMLLINT_INDENT=$'\t' \
		xmllint --format - \
	| tee >(cat - >&2) \
	> "${filename}"
}

main "${@}"
