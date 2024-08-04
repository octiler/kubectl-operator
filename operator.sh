#!/usr/bin/env bash
set -e

function err () {
    [[ 0 -lt $1 ]] && errcode=$1 && shift || errcode=127
    echo "$@" >&2 && exit $errcode
}

[[ ${#DEVOPS_ROOTPATH} -gt 0 ]] || err please specify environment variable DEVOPS_ROOTPATH
DEVOPS_ROOTPATH=`realpath $DEVOPS_ROOTPATH`
yq -V | grep -q mikefarah || err please install yq utilities

function usage () {
cat << EOF
maintain kubernetes resources within git repository in standard procedure

kubectl operator COMMAND [-f REFERRENCE ][--dry-run ][--classified ][--mock ][FLAGS ...][-- ][FLAGS ...]
EOF
}

PASSTHRU=()
OPTIONS=()
while [[ $# -gt 0 ]];do
    key="$1"
    case $1 in
        --help)
            HELP=TRUE
            shift
            ;;
        --dry-run)
            DRYRUN=TRUE
            shift
            ;;
        --classified)
            CLASSIFIED=TRUE
            shift
            ;;
        --mock)
            MOCK=mock
            shift
            ;;
        -f)
            shift
            ref="$1"
            shift
            ;;
        --)
            shift
            OPTIONS+=("$@")
            break
            ;;
        *)
            PASSTHRU+=("$1")
            shift
            ;;
    esac
done
if [[ "$HELP" == "TRUE" ]];then
    usage
    exit 0
fi

set -- "${PASSTHRU[@]}"
COMMAND=${PASSTHRU[0]} && shift
SUBCOMMAND="$1" && [[ "${SUBCOMMAND}" == "${1#-}" ]] && shift || SUBCOMMAND=""

[[ "$ref" == "-" ]] && ref="" || true
[[ ${#ref} -gt 0 ]] && ( [[ -f "$ref" ]] || err 110 yaml file "$ref" not exist )
[[ ${#ref} -gt 0 ]] && Redacted=`cat < "$ref"` || Redacted=`cat`

readonly cubeconfig=`realpath ~/.kube/config`
declare -A map=(
    [domain]="airflow"
    [kubeconfig]="$cubeconfig"
)

# kubectl api-resources --no-headers | ObjectKind="" awk '$NF==ENVIRON["ObjectKind"] && $(NF-1)=="true" {print $1,$(NF-2),$NF}'
# kubectl api-resources --no-headers | awk -vObjectKind="" '$NF==ObjectKind && $(NF-1)=="true" {print $1,$(NF-2),$NF}'

function resource_examiner () {
    local NamespacedKinds=`kubectl --kubeconfig="${map[kubeconfig]}" --context="${map[world]}" api-resources --no-headers --namespaced | awk '{print $NF}'`
    IncompletedResources=`echo "$Redacted" | NamespacedKinds="$NamespacedKinds" \
        yq 'select(. as $item | "$NamespacedKinds" | envsubst | split("\n") | any_c(. == $item.kind and ($item.metadata|has("namespace")|not)))'`
    [[ "${#IncompletedResources}" -gt 0 ]] && err Please specify namespace for IncompletedResources: "
$IncompletedResource" || true

    # local -a KindSets=()
    # for kind in `echo "$Redacted" | yq '[.kind]|unique[]'`;do
    #     [[ `yq -n '"$kind" | envsubst as $kind | "$NamespacedKinds" | split(" ") | map(. == $kind) | any'` == "true" ]] && KindSets+=("$kind") || true
    # done
}

function locate_kubeconfig () {
    yq '.contexts[].name' "${map[kubeconfig]}" | grep -q "^$1\$" && map[world]=$1 && return 0
    map[kubeconfig]=~/.kube/$1.yaml
    map[world]=`yq '.current-context' "${map[kubeconfig]}"`
    # fail early
}

function guess () {
    [[ "true" == `git rev-parse --is-inside-work-tree` ]] || err 111 not a git repository
    git rev-parse --show-toplevel | grep -q "^${DEVOPS_ROOTPATH%/}/${map[domain]}/" || err git repository not cloned in proper place
    local domainProject=$(git rev-parse --show-toplevel | sed "s#^${DEVOPS_ROOTPATH%/}/##")
    [[ "${domainProject#/}" == "${domainProject}" ]] || err 111 not a regular git repository
    local domain=${domainProject%%/*}
    [[ "$domain" == "${map[domain]}" ]] || err 111 not in domain ${map[domain]}
    local worldProject=${domainProject#${domain}/}
    local world=${worldProject%%/*}
    local -A worldMap=([lab]=lab [demo]=lab)
    [[ ${#world} -gt 0 ]] && [[ ${#worldMap[$world]} -gt 0 ]] && world=${worldMap[$world]} || true
    locate_kubeconfig $world
}

guess
resource_examiner

if [[ "$DRYRUN" == "TRUE" ]];then
cat << EOF >&2
----------------------------------------------------------------
PWD:            `pwd`
DEVOPS_ROOT:    ${DEVOPS_ROOTPATH}
domain:         ${map[domain]}
world:          ${map[world]}
project:        `git rev-parse --show-toplevel | sed "s#^${DEVOPS_ROOTPATH%/}/${map[domain]}/${map[world]}/##"`
workdir:        `git rev-parse --show-prefix`
kubeconfig:     ${map[kubeconfig]}
kube-context:   ${map[world]}
command:        ${COMMAND}
subcommand:     ${SUBCOMMAND}
PASSTHRU:       $@
OPTIONS:        ${OPTIONS[@]}
================================================================
EOF
fi

EVALFLAG="TRUE"
kubectlCommand="echo '
$Redacted
' \
| kubectl revisor ${CLASSIFIED:+--classified} ${MOCK} \
| kubectl \
--kubeconfig ${map[kubeconfig]} \
--context ${map[world]} \
${COMMAND} ${SUBCOMMAND} \
$@ ${OPTIONS[@]} \
-f - \
"

[[ "TRUE" == "$DRYRUN" ]] && echo "${kubectlCommand}" || ( [[ $EVALFLAG == "TRUE" ]] && eval "${kubectlCommand}" || ${kubectlCommand} )
