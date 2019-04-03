name              'mariadb'
maintainer        'MariaDB, Inc.'
maintainer_email  'Andrey.Kuznetsov@mariadb.com'
license           'Apache 2.0'
description       'MariaDB coockbook'
version           '0.0.2'
recipe            'develop', 'Prepares environment to build MariaDB'
recipe            'install', 'Installs Enterprise edition'
recipe            'uninstall', 'Uninstalls any edition'
recipe            'purge', 'Uninstalls any edition and remove all data'
recipe            'start', 'Creates new instance of service and starts it'
depends           'chrony'
depends           'packages'

supports          'redhat'
supports          'centos'
supports          'fedora'
supports          'debian'
supports          'ubuntu'
supports          'suse'
