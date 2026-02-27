# Fish completion for bru

# Subcommands
complete -c bru -n '__fish_use_subcommand' -a install -d 'Install a formula'
complete -c bru -n '__fish_use_subcommand' -a uninstall -d 'Uninstall a formula'
complete -c bru -n '__fish_use_subcommand' -a upgrade -d 'Upgrade outdated formulae'
complete -c bru -n '__fish_use_subcommand' -a update -d 'Fetch latest data'
complete -c bru -n '__fish_use_subcommand' -a search -d 'Search for formulae'
complete -c bru -n '__fish_use_subcommand' -a info -d 'Show formula info'
complete -c bru -n '__fish_use_subcommand' -a list -d 'List installed'
complete -c bru -n '__fish_use_subcommand' -a deps -d 'Show dependencies'
complete -c bru -n '__fish_use_subcommand' -a uses -d 'Show reverse deps'
complete -c bru -n '__fish_use_subcommand' -a leaves -d 'Show leaf formulae'
complete -c bru -n '__fish_use_subcommand' -a autoremove -d 'Remove orphaned deps'
complete -c bru -n '__fish_use_subcommand' -a link -d 'Symlink formula'
complete -c bru -n '__fish_use_subcommand' -a unlink -d 'Remove symlinks'
complete -c bru -n '__fish_use_subcommand' -a cleanup -d 'Remove old versions'
complete -c bru -n '__fish_use_subcommand' -a outdated -d 'Show outdated'
complete -c bru -n '__fish_use_subcommand' -a fetch -d 'Download only'
complete -c bru -n '__fish_use_subcommand' -a config -d 'Show config'

# Global flags
complete -c bru -n '__fish_use_subcommand' -l help -d 'Show help'
complete -c bru -n '__fish_use_subcommand' -l version -d 'Show version'
complete -c bru -n '__fish_use_subcommand' -l verbose -d 'Verbose output'
complete -c bru -n '__fish_use_subcommand' -l quiet -d 'Quiet output'
complete -c bru -n '__fish_use_subcommand' -l debug -d 'Debug output'

# deps flags
complete -c bru -n '__fish_seen_subcommand_from deps' -l tree -d 'Show as indented tree'
complete -c bru -n '__fish_seen_subcommand_from deps' -l 1 -d 'Show only direct dependencies'
complete -c bru -n '__fish_seen_subcommand_from deps' -l direct -d 'Show only direct dependencies'
complete -c bru -n '__fish_seen_subcommand_from deps' -l include-build -d 'Include build-time dependencies'
complete -c bru -n '__fish_seen_subcommand_from deps' -l json -d 'Output as JSON'

# uses flags
complete -c bru -n '__fish_seen_subcommand_from uses' -l installed -d 'Only show installed formulae'
complete -c bru -n '__fish_seen_subcommand_from uses' -l include-build -d 'Include build-time dependency relationships'

# list flags
complete -c bru -n '__fish_seen_subcommand_from list' -l versions -d 'Show version numbers'
complete -c bru -n '__fish_seen_subcommand_from list' -l cask -d 'Only casks'
complete -c bru -n '__fish_seen_subcommand_from list' -l casks -d 'Only casks'
complete -c bru -n '__fish_seen_subcommand_from list' -l json -d 'Output as JSON'

# info flags
complete -c bru -n '__fish_seen_subcommand_from info' -l json -d 'Output as JSON'

# search flags
complete -c bru -n '__fish_seen_subcommand_from search' -l json -d 'Output as JSON'

# leaves flags
complete -c bru -n '__fish_seen_subcommand_from leaves' -l json -d 'Output as JSON'

# outdated flags
complete -c bru -n '__fish_seen_subcommand_from outdated' -l verbose -d 'Show version comparison'
complete -c bru -n '__fish_seen_subcommand_from outdated' -l json -d 'Output as JSON'

# link flags
complete -c bru -n '__fish_seen_subcommand_from link' -l force -d 'Force linking of keg-only formulae'

# cleanup flags
complete -c bru -n '__fish_seen_subcommand_from cleanup' -l dry-run -d 'Show what would be removed'
complete -c bru -n '__fish_seen_subcommand_from cleanup' -s n -d 'Show what would be removed'
complete -c bru -n '__fish_seen_subcommand_from cleanup' -l prune -d 'Override default retention (days)' -r

# autoremove flags
complete -c bru -n '__fish_seen_subcommand_from autoremove' -l dry-run -d 'Show what would be removed'
complete -c bru -n '__fish_seen_subcommand_from autoremove' -s n -d 'Show what would be removed'
