# Incstalling git
sudo apt-get install git

# Configuring git
git config --global user.email "timofey.turenko@mariadb.com"
git config --global user.name "Timofey Turenko"

# Cloning repositories
git clone git@github.com:OSLL/mdbci.git $HOME/mdbci
git clone git@github.com:mariadb-corporation/mdbci-boxes.git $HOME/mdbci-boxes
git clone git@github.com:mariadb-corporation/build-scripts-vagrant.git $HOME/build-scripts
git clone git@github.com:mariadb-corporation/mdbci-repository-config.git $HOME/mdbci-repository-config

# MDBCI boxes and keys linking
ln -s $HOME/mdbci-boxes/BOXES $HOME/mdbci/BOXES
ln -s $HOME/mdbci-boxes/KEYS $HOME/mdbci/KEYS

# Credentials for AWS and PPC
scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null vagrant@max-tst-01.mariadb.com:/home/vagrant/mdbci/aws-config.yml $HOME/mdbci
scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null vagrant@max-tst-01.mariadb.com:/home/vagrant/mdbci/maxscale.pem $HOME/mdbci