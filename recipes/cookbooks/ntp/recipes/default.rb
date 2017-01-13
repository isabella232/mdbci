# Cookbook Name:: ntp

package "ntp" do	
    action [:install]
end
 
service node[:ntp][:service] do
    service_name node[:ntp][:service]         
    action [:enable,:start,:restart]                   
end

template "/etc/ntp.conf" do			
    source "ntp.conf.erb"			# defaults to templates/files/...
    owner "root" 				# set file owner
    group "root"				# set file group
    mode 0644					# set file mode
    notifies :restart, resources(:service => node[:ntp][:service])#, :delayed
end

script "test_date" do
  interpreter "bash"
  user "root"
  environment 'platform' => '#{platform}'
  code <<-EOH
    echo @@@ TEST DATE
    sudo date --set "12 Sep 2012 12:12:12"
    echo @@@ BEFORE `date`
    case $platform in
    ubuntu)
        sudo sntp -s 0.europe.pool.ntp.org
        sudo service ntp stop
        sudo ntpdate 0.europe.pool.ntp.org
        sudo service ntp start
        ;;
    debian)
        sudo sntp -s 0.europe.pool.ntp.org
        ;;
    *)
        sudo service ntpd stop
        sudo ntpdate 0.europe.pool.ntp.org
        sudo service ntpd start
        ;;
    echo @@@ AFTER `date`
  EOH
end