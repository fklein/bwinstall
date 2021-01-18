#!/usr/bin/env bash

set -o errexit
set -o pipefail
# set -o xtrace

readonly __dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly __file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
readonly __base="$(basename "${__file}" .sh)"


show_help() {
    local helpstring="\
        usage: $(basename "${__file}") [options] [directory]

        Create a basic installation package stub for a TIBCO BusinessWorks application.

        Parameters are:
            directory
                The directory to create the package in. If this exists it will be
                scanned in an attempt to auto-guess some of the required settings.
                Otherwise it will be created.

        Valid options are:
            -a, --appname NAME
                The name (including folder structure) of the BW application.

            -v, --verbose
                Turn on verbose output.

            -t, --trace
                Turn on trace output.

            -h, --help
                Print this help message.
    "
    echo "${helpstring}" | sed -r 's/^[[:space:]]{8}//' | sed -r 's/[[:space:]]*$//'
}


# Parse any arguments
opts="a:vth"
longopts="appname:,verbose,trace,help"
args=$(getopt -n "${__base}" -o "${opts}" -l "${longopts}" -- "${@}") || {
    echo >&2
    show_help >&2
    exit 1
}
eval set -- "${args}"
while true; do
    case "$1" in
        "--")
            shift
            break
            ;;
        "--appname" | "-a" )
            appname="$2"
            shift
            ;;
        "--verbose" | "-v" )
            set -o verbose
            ;;
        "--trace" | "-t" )
            set -o xtrace
            ;;
        "--help" | "-h" )
            show_help
            exit 0
            ;;
    esac
    shift
done
if (( $# == 1 )); then
    pkgdir="$1"
    shift
else
    show_help >&2
    exit 1
fi


# The default settings for a new package stub
default_appname="MyFolder/BwApplication"
default_config="deployconfig.xml"
default_domains=("dev" "uat" "prod")

# Move to the target directory
[[ -e "${pkgdir}" ]] || mkdir -p "${pkgdir}"
pushd "${pkgdir}" >/dev/null

# Exit if the package has already been initialized
if [[ -e "package-info" ]]; then
    echo "The package has already been inizialized!" >&2
    exit 1
fi

# Check if there is an enterprise archive present
archive=$(find -maxdepth 1 -type f -name "*.ear" | head -1)

# Determine the application name
if [[ -z "${appname}" ]]; then
   if [[ -n "${archive}" ]]; then
        appname=$(basename "${archive}" ".ear")
    else
        appname="${default_appname}"
    fi
fi

# Make sure at least a dummy archive exists
[[ -z "${archive}" ]] && archive="${appname##*/}.ear"
[[ -f "${archive}" ]] || echo "Replace me with a real enterprise archive!" > "${archive}"

# Make sure the default configuration exists
config="${default_config}"
[[ -f "${config}" ]] || echo "Replace me with a real config!" > "${config}"

# Copy the script templates
appid=$(tr '[:upper:] ' '[:lower:]-' <<< "${appname##*/}")
prepare=()
prepare+=("select-config.sh") ; cp --no-clobber "${__dir}/select-config.template" "${prepare[-1]}"
prepare+=("prepare-deploy.sh") ; cp --no-clobber "${__dir}/customscript.template" "${prepare[-1]}"
chmod a+x "${prepare[@]}"
complete=()
complete+=("complete-deploy.sh") ; cp --no-clobber "${__dir}/customscript.template" "${complete[-1]}"
chmod a+x "${complete[@]}"

# Setup a dummy structure for the "select-config.sh" script
[[ -d "envconfig" ]] || mkdir "envconfig"
for domain in "${default_domains[@]}"; do
    domainconfig="envconfig/${domain}.xml"
    dummymsg="Replace me with the deployment configuration for domain \"${domain}\"!"
    [[ -f "${domainconfig}" ]] || echo "${dummymsg}" > "${domainconfig}"
done
ln -sf "$(basename "${domainconfig}")" "envconfig/default.xml"
ln -sf "${domainconfig}" "${config}"

# Create the "package-info" file
cat > package-info <<EOF
appname="${appname}"
archive="${archive#./}"
config="${config#./}"
prepare=($(printf '"%s" ' "${prepare[@]}" | sed 's/ *$//'))
complete=($(printf '"%s" ' "${complete[@]}" | sed 's/ *$//'))
EOF

popd >/dev/null

echo "Package stub created in $(realpath -m "${pkgdir}")"
