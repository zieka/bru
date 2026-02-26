# Bash completion for bru
_bru() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="install uninstall upgrade update search info list deps uses leaves
              autoremove link unlink cleanup outdated fetch config"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        return 0
    fi

    case "${prev}" in
        install|info|deps|uses|uninstall|link|unlink|upgrade|fetch)
            # Complete with formula names
            local formulae
            formulae=$(bru search "${cur}" 2>/dev/null)
            COMPREPLY=( $(compgen -W "${formulae}" -- "${cur}") )
            ;;
    esac
}
complete -F _bru bru
