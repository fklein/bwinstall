#!/usr/bin/env bash

set -o errexit
set -o pipefail
# set -o xtrace

readonly __dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly __file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
readonly __base="$(basename "${__file}" .sh)"


show_help() {
    local helpstring="\
        usage: $(basename "${__file}") [options] [package ...]

        Install one or more TIBCO BusinessWorks application packages into a domain.
        If an application is already installed, attempt to upgrade the application
        with the new archive, keeping the existing configuration.

        Parameters are:
            package
                A directory or ZIP archive containing an installation package.
                Multiple packages may be specified. If no package is specified, it is
                assumed that the working directory contains the installation package.

        Options are:
            -o, --overwrite
                Perform a clean installation, overwriting any existing configuration.

            -d, --deploy
                Deploy the application as part of the installation.
                By default the application archive is only uploaded and configured.

            -v, --verbose
                Turn on verbose output.

            -t, --trace
                Turn on trace output.

            -h, --help
                Print this help message.
    "
    echo "${helpstring}" | sed -r 's/^[[:space:]]{8}//' | sed -r 's/[[:space:]]*$//'
}


# Helper functions for cleaning up on exit
declare -a exit_actions=()

on_exit() {
    local cmd=$(printf '"%s" ' "${@}")
    exit_actions+=("${cmd}")
}

eval_exit_actions() {
    local action
    for action in "${exit_actions[@]}"; do
        eval "${action}" || true
    done
}

trap eval_exit_actions EXIT


# Helpers for prettifying text output
_fmtseq() {
    declare -A escapecodes=(
        # Common
        [reset]=$'\e[0m' [bold]=$'\e[1m' [dim]=$'\e[2m' [italic]=$'\e[3m' [underline]=$'\e[4m'
        [blink]=$'\e[5m' [invert]=$'\e[7m' [invisible]=$'\e[8m' [strikethrough]=$'\e[9m'
        # Text
        [default]=$'\e[39m'
        [black]=$'\e[30m'   [white]=$'\e[97m'
        [gray]=$'\e[90m'    [lightgray]=$'\e[37m'
        [red]=$'\e[31m'     [lightred]=$'\e[91m'
        [green]=$'\e[32m'   [lightgreen]=$'\e[92m'
        [yellow]=$'\e[33m'  [lightyellow]=$'\e[93m'
        [blue]=$'\e[34m'    [lightblue]=$'\e[94m'
        [magenta]=$'\e[35m' [lightmagenta]=$'\e[95m'
        [cyan]=$'\e[36m'    [lightcyan]=$'\e[96m'
        # Background
        [bgdefault]=$'\e[49m'
        [bgblack]=$'\e[40m'     [bgwhite]=$'\e[107m'
        [bggray]=$'\e[100m'     [bglightgray]=$'\e[47m'
        [bgred]='\e[41m'        [bglightred]='\e[101m'
        [bggreen]='\e[42m'      [bglightgreen]='\e[102m'
        [bgyellow]=$'\e[43m'    [bglightyellow]=$'\e[103m'
        [bgblue]='\e[44m'       [bglightblue]='\e[104m'
        [bgmagenta]=$'\e[45m'   [bglightmagenta]=$'\e[105m'
        [bgcyan]=$'\e[46m'      [bglightcyan]=$'\e[106m'
    )
    local formatseq=$''
    while (( $# > 0 )); do
        if [[ -z "${escapecodes[$1]+IsSet}" ]]; then
            echo "${FUNCNAME[0]}: unknown format \"${1}\"" >&2
            return 1
        fi
        formatseq+="${escapecodes[$1]}"
        shift
    done
    printf '%s' "${formatseq}"
}

colorize() {
    local fmtseq=$''
    local fmtreset=$(_fmtseq reset)
    while (( $# > 0 )); do
        [[ "$1" == "--" ]] && { shift ; break ; }
        local format
        for format in ${1//,/ }; do
            fmtseq+=$(_fmtseq "${format}")
        done
        shift
    done
    while (( $# > 0 )); do
        printf "${fmtseq}%s${fmtreset}" "${1}"
        shift
        (( $# > 0 )) && printf " "
    done
}


# Parse any arguments
opts="odvth"
longopts="overwrite,deploy,verbose,trace,help"
args=$(getopt -n "${__base}" -o "${opts}" -l "${longopts}" -- "${@}") || {
    echo >&2
    show_help >&2
    exit 1
}
eval set -- "${args}"
unset deploy overwrite
while true; do
    case "$1" in
        "--")
            shift
            break
            ;;
        "--overwrite" | "-o" )
            overwrite=true
            ;;
        "--deploy" | "-d" )
            deploy=true
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


# Arrange evaluation of the installation status upon exit
unset installation_complete
evaluate_status() {
    if ! ${installation_complete:-false}; then
        echo -e "\n\n$(colorize bgred,white,bold,blink -- " !!! INSTALLATION FAILED !!! ")" >&2
    fi
}
on_exit evaluate_status


# Check and complement the TIBCO envrionment
[[ $(whoami) != "tibco" ]] && echo "This should only be run as user \"tibco\"!" >&2 && exit 1
: ${TIBCO_HOME:?"Variable not set"}
: ${TIBCO_TRA_HOME:?"Variable not set"}
alias AppManage="${TIBCO_TRA_HOME}/bin/AppManage"
alias AppStatusCheck="${TIBCO_TRA_HOME}/bin/AppStatusCheck"
alias obfuscate="${TIBCO_TRA_HOME}/bin/obfuscate"
shopt -s expand_aliases


# Get the target domain
domain=$(grep -v "^ *#" "${TIBCO_HOME}/tra/domain/DomainHomes.properties" 2>/dev/null |
    cut -d"." -f1 | sort -u || true)
if [[ -z "${domain}" ]] || (( $(grep -c "." <<< "${domain}") > 1 )); then
    # ... ask for it, if no domain can be found or there is more than one
    read -p "Install to domain: " domain
fi

# Create a temporary credential file for accessing the domain
read -p "User for domain \"${domain}\": " user
read -s -p "Password for user \"${user}\": " password ; echo >&2
credential=$(mktemp | xargs -0 realpath -m)
on_exit rm -f "${credential}"
chmod 600 "${credential}"
cat > "${credential}" <<< "user=${user}"$'\n'"pw=#!${password}"
unset password
obfuscate "${credential}" >/dev/null 2>&1
chmod 600 "${credential}"


# Process all installation packages
for package in "${@-"."}"; do
    # Attempt to extract zipped packages to a temporary directory
    if [[ -f "${package}" ]]; then
        packagedir=$(mktemp -d | xargs -0 realpath -m)
        unzip -oq "${package}" -d "${packagedir}"
        on_exit rm -rf "${packagedir}"
    else
        packagedir="${package}"
    fi

    # Move to the package directory
    pushd "${packagedir}" >/dev/null

    # Source the "package-info" file, check and map its expected content
    . package-info || { echo "Failed to load package-info from ${package}" >&2 ; exit 1 ; }
    pkg_appname="${appname?"Not specified by package-info"}"
    pkg_archive="${archive?"Not specified by package-info"}"
    pkg_config="${config}"
    pkg_prepare=("${prepare[@]}")
    pkg_complete=("${complete[@]}")
    unset appname archive config prepare complete

    echo -e "\n\n$(colorize bold,yellow,underline -- \
        "Installing application \"${pkg_appname}\" into domain \"${domain}\"")"

    # Unless a clean install is forced, attempt to export the applications current configuration
    if ${overwrite:-false}; then
        echo -e "\n$(colorize bold -- "Forcing clean installation!")"
        unset currentconfig
    else
        echo -e "\n$(colorize bold -- "Checking installation status:")"
        status=$(AppStatusCheck -domain "${domain}" -cred "${credential}" -breaklock \
            -app "${pkg_appname}" 2>/dev/null) || { echo "${status}" >&2 ; exit 2 ; }
        if grep -q "Application Name" <<< "${status}"; then
            echo "The application is already installed!"
            echo -e "\n$(colorize bold -- "Exporting the applications current configuration:")"
            tmpfile=$(mktemp -u | xargs -0 realpath -m)
            on_exit rm -f "${tmpfile}"
            AppManage -export \
                -domain "${domain}" -cred "${credential}" -breaklock \
                -app "${pkg_appname}"  -out "${tmpfile}" 2>/dev/null
            chmod 600 "${tmpfile}"
            currentconfig="${tmpfile}"
        else
            echo "The application is currently not installed!"
            unset currentconfig
        fi
    fi

    # Export installation information for external scripts
    INSTALL_PACKAGEDIR=$(pwd)
    INSTALL_DOMAIN="${domain}"
    INSTALL_USER="${user}"
    INSTALL_CREDENTIAL="${credential}"
    INSTALL_APPNAME="${pkg_appname}"
    INSTALL_ARCHIVE="${pkg_archive}"
    unset INSTALL_BASECONFIG INSTALL_CURRENTCONFIG INSTALL_UPDATE INSTALL_OVERWRITE
    [[ -n "${pkg_config}" ]] && INSTALL_BASECONFIG="${pkg_config}"
    [[ -n "${currentconfig}" ]] && INSTALL_UPDATE=true && INSTALL_CURRENTCONFIG="${currentconfig}"
    ${overwrite:-false} && INSTALL_OVERWRITE=true
    export "${!INSTALL_@}"

    # Execute all custom preparation scripts specified by the package
    for prepare in "${pkg_prepare[@]}"; do
        if [[ -n "${prepare}" ]]; then
            echo -e "\n$(colorize bold -- "Executing preparation script \"${prepare}\":")"
            [[ -x "${prepare}" ]] || chmod a+x "${prepare}"
            ./"${prepare}"
        fi
    done

    # Generate the new deployment configuration ...
    deployconfig=""
    if [[ -n "${currentconfig}" ]]; then
        # ... by merging the existing configuration into the archives default configuration
        echo -e "\n$(colorize bold -- "Merging current configuration with archive configuration:")"
        tmpfile=$(mktemp -u | xargs -0 realpath -m)
        on_exit rm -f "${tmpfile}"
        AppManage -export -ear "${pkg_archive}" -deployconfig "${currentconfig}" -out "${tmpfile}" 2>/dev/null
        chmod 600 "${tmpfile}"
        on_exit rm -f "${tmpfile}.log"
        deployconfig="${tmpfile}"
    else
        if [[ -n "${pkg_config}" ]]; then
            # ... by just using the package configuration, if it exists ...
            echo -e "\n$(colorize bold -- "Using supplied configuration from \"${pkg_config}\"")"
            deployconfig="${pkg_config}"
        else
            # ... or, if everyting else fails, by exporting the archives default configuration
            echo -e "\n$(colorize bold -- "Exporting the archives default configuration:")"
            tmpfile=$(mktemp -u | xargs -0 realpath -m)
            on_exit rm -f "${tmpfile}"
            AppManage -export -ear "${pkg_archive}" -out "${tmpfile}" 2>/dev/null
            deployconfig="${tmpfile}"
        fi
    fi

    # Upload the application archive and its deployment configuration
    echo -e "\n$(colorize bold -- "Uploading the application archive \"${pkg_archive}\":")"
    AppManage -config \
        -domain "${domain}" -cred "${credential}" -breaklock \
        -app "${pkg_appname}" -ear "${pkg_archive}" -deployconfig "${deployconfig}" 2>/dev/null

    # Deploy the application only if explicitly requested
    if ${deploy:-false}; then
        echo -e "\n$(colorize bold -- "Deploying the application:")"
        AppManage -deploy \
            -domain "${domain}" -cred "${credential}" -breaklock \
            -app "${pkg_appname}" -nostart -force 2>/dev/null
    fi

    # Execute all custom installation scripts specified by the package
    export INSTALL_DEPLOYCONFIG="${deployconfig}"
    for complete in "${pkg_complete[@]}"; do
        if [[ -n "${complete}" ]]; then
            echo -e "\n$(colorize bold -- "Executing completion script \"${complete}\":")"
            [[ -x "${complete}" ]] || chmod a+x "${complete}"
            ./"${complete}"
        fi
    done

    echo -e "\n$(colorize bold,green -- "Application \"${pkg_appname}\" installed successfully!")"

    # Restore the original environment
    unset "${!INSTALL_@}"
    popd >/dev/null
done

# Mark the installation as completed
installation_complete=true
