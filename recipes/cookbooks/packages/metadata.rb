name             'packages'
maintainer       'MariaDB'
maintainer_email 'maxscale@googlegroups.com'
license          'All rights reserved'
description      'Installs packages and configure package management systems'
long_description IO.read(File.join(File.dirname(__FILE__), 'README.md'))
version          '0.1.1'

recipe           'install', 'Installs all required packages'
recipe           'configure_apt', 'Configures the apt to allow HTTPS-based repositories'
