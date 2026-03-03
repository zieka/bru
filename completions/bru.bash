# Bash completion for bru
_bru() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="install uninstall upgrade update search info list deps uses leaves
              autoremove link unlink cleanup outdated fetch config tap untap"

    # Position 1: complete commands or global flags
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        if [[ "${cur}" == -* ]]; then
            COMPREPLY=( $(compgen -W "--help --version --verbose --quiet --debug" -- "${cur}") )
        else
            COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        fi
        return 0
    fi

    # Find the subcommand (first non-flag argument after bru)
    local subcmd=""
    local i
    for (( i=1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[i]}" in
            -*) ;;
            *) subcmd="${COMP_WORDS[i]}"; break ;;
        esac
    done

    # Per-command flag completion when current word starts with -
    if [[ "${cur}" == -* && -n "${subcmd}" ]]; then
        local flags=""
        case "${subcmd}" in
            deps)       flags="--tree --1 --direct --include-build --json" ;;
            uses)       flags="--installed --include-build" ;;
            list)       flags="--versions --cask --casks --json" ;;
            info)       flags="--json" ;;
            search)     flags="--json" ;;
            leaves)     flags="--json" ;;
            outdated)   flags="--verbose --json" ;;
            link)       flags="--force" ;;
            cleanup)    flags="--dry-run -n --prune=" ;;
            autoremove) flags="--dry-run -n" ;;
            tap)        flags="--shallow --force" ;;
            untap)      flags="--force" ;;
        esac
        if [[ -n "${flags}" ]]; then
            COMPREPLY=( $(compgen -W "${flags}" -- "${cur}") )
            return 0
        fi
    fi

    # Formula name completion for commands that accept formulae
    case "${subcmd}" in
        install|info|deps|uses|uninstall|link|unlink|upgrade|fetch)
            local formulae
            formulae=$(bru search "${cur}" 2>/dev/null)
            COMPREPLY=( $(compgen -W "${formulae}" -- "${cur}") )
            ;;
    esac
}
complete -F _bru bru
