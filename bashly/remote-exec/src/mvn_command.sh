re::init

mvn_cmd="mvn"
[[ -x ./mvnw ]] && mvn_cmd="./mvnw"

goals=("${other_args[@]}")
[[ "${#goals[@]}" -eq 0 ]] && goals=("dependency:resolve-sources" "dependency:go-offline")

re::sync_project
re::run_remote "${mvn_cmd}" "${goals[@]}"
