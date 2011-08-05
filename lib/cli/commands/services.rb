module VMC::Cli::Command

  class Services < Base
    include VMC::Cli::ServicesHelper

    def services
      ss = client.services_info
      ps = client.services
      cs = client.custom_services_info
      ps.sort! {|a, b| a[:name] <=> b[:name] }

      if @options[:json]
        services = { :system => ss, :provisioned => ps }
        return display JSON.pretty_generate(services)
      end
      display_system_services(ss)
      display_custom_services(cs)
      display_provisioned_services(ps)
    end

    def create_service(service=nil, name=nil, appname=nil)
      unless no_prompt || service
        services = client.services_info
        err 'No services available to provision' if services.empty?
        choose do |menu|
          menu.prompt = 'Please select one you wish to provision: '
          menu.select_by = :index_or_name
          services.each do |service_type, value|
            value.each do |vendor, version|
              menu.choice(vendor.to_s) { service = vendor.to_s }
            end
          end
        end
      end
      name = @options[:name] unless name
      unless name
        name = random_service_name(service)
        picked_name = true
      end
      create_service_banner(service, name, picked_name)
      appname = @options[:bind] unless appname
      bind_service_banner(name, appname) if appname
    end

    def delete_service(service=nil)
      unless no_prompt || service
        user_services = client.services
        err 'No services available to delete' if user_services.empty?
        choose do |menu|
          menu.prompt = 'Please select one you wish to delete: '
          menu.select_by = :index_or_name
          user_services.each do |s|
            menu.choice(s[:name]) { service = s[:name] }
          end
        end
      end
      err "Service name required." unless service
      display "Deleting service [#{service}]: ", false
      client.delete_service(service)
      display 'OK'.green
    end

    def bind_service(service, appname)
      bind_service_banner(service, appname)
    end

    def unbind_service(service, appname)
      unbind_service_banner(service, appname)
    end

    def clone_services(src_app, dest_app)
      begin
        src  = client.app_info(src_app)
        dest = client.app_info(dest_app)
      rescue
      end

      err "Application '#{src_app}' does not exist" unless src
      err "Application '#{dest_app}' does not exist" unless dest

      services = src[:services]
      err 'No services to clone' unless services && !services.empty?
      services.each { |service| bind_service_banner(service, dest_app, false) }
      check_app_for_restart(dest_app)
    end

  end
end
