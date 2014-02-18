#!/bin/bash

if ! which chef-client; then
    if [[ -f /etc/redhat-release || -f /etc/centos-release ]]; then
        yum -y makecache
        yum install -y chef ruby rubygems ruby-devel
        gem install cstruct
    elif [[ -d /etc/apt ]]; then
        apt-get -y update
        # Our chef package does not need ruby, but it does need the cstruct gem.
        apt-get -y --force-yes install ruby1.9.1 ruby1.9.1-dev chef
        gem install cstruct
        service chef-client stop
    elif [[ -f /etc/SuSE-release ]]; then
        zypper install -y -l chef
    else
        die "Staged on to unknown OS media!"
    fi
fi

mkdir -p "/etc/chef"
mkdir -p "/var/chef"
clientname=$(read_attribute "crowbar/chef-solo/name")
cat > "/etc/chef/solo.rb" <<EOF
log_level       :info
log_location    STDOUT
node_name       '$clientname'
solo            true
cookbook_path   "/var/chef/cookbooks"
data_bag_path   "/var/chef/data_bags"
role_path       "/var/chef/roles"
EOF
