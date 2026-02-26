#compdef bru

_bru() {
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
}

_bru "$@"
