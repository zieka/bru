#compdef bru

_bru() {
    local -a global_flags
    global_flags=(
        '--help[Show help]'
        '--version[Show version]'
        '--verbose[Enable verbose output]'
        '--quiet[Quiet output]'
        '--debug[Enable debug output]'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args'

    case $state in
        command)
            local -a commands
            commands=(
                'install:Install a formula'
                'uninstall:Uninstall a formula'
                'upgrade:Upgrade outdated formulae'
                'update:Fetch latest formulae data'
                'search:Search for formulae'
                'info:Show formula info'
                'list:List installed formulae'
                'deps:Show dependencies'
                'uses:Show reverse dependencies'
                'leaves:Show leaf formulae'
                'autoremove:Remove orphaned deps'
                'link:Symlink formula into prefix'
                'unlink:Remove symlinks'
                'cleanup:Remove old versions'
                'outdated:Show outdated formulae'
                'fetch:Download without installing'
                'config:Show configuration'
            )
            _describe 'command' commands
            _arguments $global_flags
            ;;
        args)
            case ${words[1]} in
                deps)
                    _arguments \
                        '--tree[Show as indented tree]' \
                        '--1[Show only direct dependencies]' \
                        '--direct[Show only direct dependencies]' \
                        '--include-build[Include build-time dependencies]' \
                        '--json[Output as JSON]' \
                        '*:formula:_guard "^-*" formula'
                    ;;
                uses)
                    _arguments \
                        '--installed[Only show installed formulae]' \
                        '--include-build[Include build-time dependency relationships]' \
                        '*:formula:_guard "^-*" formula'
                    ;;
                list)
                    _arguments \
                        '--versions[Show version numbers]' \
                        '--cask[Only casks]' \
                        '--casks[Only casks]' \
                        '--json[Output as JSON]' \
                        '*:formula:_guard "^-*" formula'
                    ;;
                info)
                    _arguments \
                        '--json[Output as JSON]' \
                        '*:formula:_guard "^-*" formula'
                    ;;
                search)
                    _arguments \
                        '--json[Output as JSON]' \
                        '*:query:'
                    ;;
                leaves)
                    _arguments \
                        '--json[Output as JSON]'
                    ;;
                outdated)
                    _arguments \
                        '--verbose[Show version comparison]' \
                        '--json[Output as JSON]'
                    ;;
                link)
                    _arguments \
                        '--force[Force linking of keg-only formulae]' \
                        '*:formula:_guard "^-*" formula'
                    ;;
                cleanup)
                    _arguments \
                        '--dry-run[Show what would be removed]' \
                        '-n[Show what would be removed]' \
                        '--prune=[Override default retention (days)]:days:'
                    ;;
                autoremove)
                    _arguments \
                        '--dry-run[Show what would be removed]' \
                        '-n[Show what would be removed]'
                    ;;
                install|uninstall|unlink|upgrade|fetch)
                    _arguments '*:formula:_guard "^-*" formula'
                    ;;
            esac
            ;;
    esac
}

_bru "$@"
