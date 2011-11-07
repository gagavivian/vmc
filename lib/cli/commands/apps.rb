require 'digest/sha1'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'set'
require 'rexml/document'

module VMC::Cli::Command

  class Apps < Base
    include VMC::Cli::ServicesHelper
    include REXML
    
    #chang by zjz
    #Store xml data
    attr_accessor :groupname, :appsequence
    attr_accessor :applications
    attr_accessor :addsequence
    
    def list
      apps = client.apps
      apps.sort! {|a, b| a[:name] <=> b[:name] }
      return display JSON.pretty_generate(apps || []) if @options[:json]

      display "\n"
      return display "No Applications" if apps.nil? || apps.empty?

      apps_table = table do |t|
        t.headings = 'Application', '# ', 'Health', 'URLS', 'Services'
        apps.each do |app|
          t << [app[:name], app[:instances], health(app), app[:uris].join(', '), app[:services].join(', ')]
        end
      end
      display apps_table
    end    

    alias :apps :list

    SLEEP_TIME  = 1
    LINE_LENGTH = 80

    # Numerators are in secs
    TICKER_TICKS  = 25/SLEEP_TIME
    HEALTH_TICKS  = 5/SLEEP_TIME
    TAIL_TICKS    = 45/SLEEP_TIME
    GIVEUP_TICKS  = 120/SLEEP_TIME
    YES_SET = Set.new(["y", "Y", "yes", "YES"])

    def start(appname, push = false)
      sequence = client.start_sequence(appname)
      if sequence
        sequence[:start_sequence].each { |em|
          app = client.app_info(em)
          if app[:state] == 'STARTED'
            display "Application #{em} already started".yellow
          else
            display "Start application #{em}".green
            start_app(em, push)
          end
        }
      else
        start app(appname, push)
      end
    end
    
    def start_app(appname, push = false)
      app = client.app_info(appname)

      return display "Application '#{appname}' could not be found".red if app.nil?
      return display "Application '#{appname}' already started".yellow if app[:state] == 'STARTED'

      banner = 'Staging Application: '
      display banner, false

      t = Thread.new do
        count = 0
        while count < TAIL_TICKS do
          display '.', false
          sleep SLEEP_TIME
          count += 1
        end
      end

      app[:state] = 'STARTED'
      if @applications
        app[:args] = @applications[appname]['args']
        app[:ports] = @applications[appname]['ports']
        app[:main_class] = @applications[appname]['mainclass']
      end
      client.update_app(appname, app)

      Thread.kill(t)
      clear(LINE_LENGTH)
      display "#{banner}#{'OK'.green}"

      banner = 'Starting Application: '
      display banner, false

      count = log_lines_displayed = 0
      failed = false
      start_time = Time.now.to_i

      loop do
        display '.', false unless count > TICKER_TICKS
        sleep SLEEP_TIME
        begin
          break if app_started_properly(appname, count > HEALTH_TICKS)
          if !crashes(appname, false, start_time).empty?
            # Check for the existance of crashes
            display "\nError: Application [#{appname}] failed to start, logs information below.\n".red
            grab_crash_logs(appname, '0', true)
            if push
              display "\n"
              should_delete = ask 'Should I delete the application? (Y/n)? ' unless no_prompt
              delete_app(appname, false) unless no_prompt || should_delete.upcase == 'N'
            end
            failed = true
            break
          elsif count > TAIL_TICKS
            log_lines_displayed = grab_startup_tail(appname, log_lines_displayed)
          end
        rescue => e
          err(e.message, '')
        end
        count += 1
        if count > GIVEUP_TICKS # 2 minutes
          display "\nApplication is taking too long to start, check your logs".yellow
          break
        end
      end
      exit(false) if failed
      clear(LINE_LENGTH)
      display "#{banner}#{'OK'.green}"
    end

    def stop(appname)
      sequence = client.get_sequence(appname)
      if sequence
        sequence[:sequence].each { |em|
          stop_app(em)
        }
      else
        stop_app(appname)
      end
    end
    
    def stop_app(appname)
        app = client.app_info(appname)
        return display "Application '#{appname}' already stopped".yellow if app[:state] == 'STOPPED'
        display "Stopping Application '#{appname}': ", false
        app[:state] = 'STOPPED'
        client.update_app(appname, app)
        display 'OK'.green     
    end
    
    def groups
      groups = client.groups
      display "\n"
      return display "No Groups" if groups.nil? || groups.empty?
      groups_table = table do |t|
        t.headings = 'Group', 'Sequence'
        groups.each do |group|
          t << [group[:name], group[:sequence]]
        end
      end
      display groups_table
    end
    
    def groupstop(groupname)
      display "Stop application group '#{groupname}' :".green
      group = client.group_info(groupname)
      appsequence = group[:sequence]
      sequenceArray = appsequence.split(':')
      sequenceArray.reverse!
      sequenceArray.each { |em|
        display "Stop application '#{em}'".green
        stop_app(em)
      }
      display "OK".green  
    end
    
    def groupstart(groupname)
      display "Start application group '#{groupname}' :".green
      group = client.group_info(groupname)
      appsequence = group[:sequence]
      sequenceArray = appsequence.split(':')
      sequenceArray.each { |em|
        display "Start application '#{em}'".green
        start_app(em)
      }
      display "OK".green  
    end
    
    def grouprestart(groupname)
      display "Restart application group '#{groupname}' :".green
      group = client.group_info(groupname)
      appsequence = group[:sequence]
      sequenceArray = appsequence.split(':')
      sequenceArray.each { |em|
        display "Restart application '#{em}'".green
        stop_app(em)
        start_app(em)
      }
      display "OK".green
    end
    
    def groupremove(groupname, appname)
      group = client.group_remove(groupname, appname)
    end

    def restart(appname)
      sequence = client.get_sequence(appname)
      if sequence
        sequence[:sequence].each { |em|
          display "Restart application #{em}".green
          stop_app(em)
          start_app(em)
        }
      else
        stop_app(appname)
        start_app(appname)
      end
    end

    def rename(appname, newname)
      app = client.app_info(appname)
      app[:name] = newname
      display 'Renaming Appliction: '
      client.update_app(newname, app)
      display 'OK'.green
    end

    def mem(appname, memsize=nil)
      app = client.app_info(appname)
      mem = current_mem = mem_quota_to_choice(app[:resources][:memory])
      memsize = normalize_mem(memsize) if memsize

      unless memsize
        choose do |menu|
          menu.layout = :one_line
          menu.prompt = "Update Memory Reservation? [Current:#{current_mem}] "
          menu.default = current_mem
          mem_choices.each { |choice| menu.choice(choice) {  memsize = choice } }
        end
      end

      mem         = mem_choice_to_quota(mem)
      memsize     = mem_choice_to_quota(memsize)
      current_mem = mem_choice_to_quota(current_mem)

      display "Updating Memory Reservation to #{mem_quota_to_choice(memsize)}: ", false

      # check memsize here for capacity
      check_has_capacity_for((memsize - mem) * app[:instances])

      mem = memsize

      if (mem != current_mem)
        app[:resources][:memory] = mem
        client.update_app(appname, app)
        display 'OK'.green
        restart appname if app[:state] == 'STARTED'
      else
        display 'OK'.green
      end
    end

    def map(appname, url)
      app = client.app_info(appname)
      uris = app[:uris] || []
      uris << url
      app[:uris] = uris
      client.update_app(appname, app)
      display "Succesfully mapped url".green
    end

    def unmap(appname, url)
      app = client.app_info(appname)
      uris = app[:uris] || []
      url = url.gsub(/^http(s*):\/\//i, '')
      deleted = uris.delete(url)
      err "Invalid url" unless deleted
      app[:uris] = uris
      client.update_app(appname, app)
      display "Succesfully unmapped url".green
    end

    def delete(appname=nil)
      sequence = client.get_sequence(appname)
      display sequence
      if sequence
        sequence[:sequence].reverse!
        sequence[:sequence].each { |em|
          force = @options[:force]
          if @options[:all]
            should_delete = force && no_prompt ? 'Y' : 'N'
            unless no_prompt || force
              should_delete = ask 'Delete ALL Applications and Services? (y/N)? '
            end
            if should_delete.upcase == 'Y'
              apps = client.apps
              apps.each { |app| delete_app(app[:name], force) }
            end
          else
            err 'No valid appname given' unless em
            delete_app(em, force)
          end
        }
      end
    end

    def delete_app(appname, force)
      app = client.app_info(appname)
      services_to_delete = []
      app_services = app[:services]
      app_services.each { |service|
        del_service = force && no_prompt ? 'Y' : 'N'
        unless no_prompt || force
          del_service = ask("Provisioned service [#{service}] detected, would you like to delete it? [yN]: ")
        end
        services_to_delete << service if del_service.upcase == 'Y'
      }
      display "Deleting application [#{appname}]: ", false
      client.delete_app(appname)
      display 'OK'.green

      services_to_delete.each do |s|
        display "Deleting service [#{s}]: ", false
        client.delete_service(s)
        display 'OK'.green
      end
    end
    
    def groupdelete(groupname)
      display "Delete application group:".green
      group = client.group_info(groupname)
      appsequence = group[:sequence]
      sequenceArray = appsequence.split(':')
      sequenceArray.reverse!
      sequenceArray.each { |em|
        display "Delete application #{em}".green
        delete(em)
      }
      #client.delete_group(groupname)
      display "OK"      
    end

    def all_files(appname, path)
      instances_info_envelope = client.app_instances(appname)
      return if instances_info_envelope.is_a?(Array)
      instances_info = instances_info_envelope[:instances] || []
      instances_info.each do |entry|
        content = client.app_files(appname, path, entry[:index])
        display_logfile(path, content, entry[:index], "====> [#{entry[:index]}: #{path}] <====\n".bold)
      end
    end

    def files(appname, path='/')
      return all_files(appname, path) if @options[:all] && !@options[:instance]
      instance = @options[:instance] || '0'
      content = client.app_files(appname, path, instance)
      display content
    rescue VMC::Client::NotFound => e
      err 'No such file or directory'
    end

    def logs(appname)
      return grab_all_logs(appname) if @options[:all] && !@options[:instance]
      instance = @options[:instance] || '0'
      grab_logs(appname, instance)
    end

    def crashes(appname, print_results=true, since=0)
      crashed = client.app_crashes(appname)[:crashes]
      crashed.delete_if { |c| c[:since] < since }
      instance_map = {}

#      return display JSON.pretty_generate(apps) if @options[:json]


      counter = 0
      crashed = crashed.to_a.sort { |a,b| a[:since] - b[:since] }
      crashed_table = table do |t|
        t.headings = 'Name', 'Instance ID', 'Crashed Time'
        crashed.each do |crash|
          name = "#{appname}-#{counter += 1}"
          instance_map[name] = crash[:instance]
          t << [name, crash[:instance], Time.at(crash[:since]).strftime("%m/%d/%Y %I:%M%p")]
        end
      end

      VMC::Cli::Config.store_instances(instance_map)

      if @options[:json]
        return display JSON.pretty_generate(crashed)
      elsif print_results
        display "\n"
        if crashed.empty?
          display "No crashed instances for [#{appname}]" if print_results
        else
          display crashed_table if print_results
        end
      end

      crashed
    end

    def crashlogs(appname)
      instance = @options[:instance] || '0'
      grab_crash_logs(appname, instance)
    end

    def instances(appname, num=nil)
      if (num)
        change_instances(appname, num)
      else
        get_instances(appname)
      end
    end

    def stats(appname)
      stats = client.app_stats(appname)
      return display JSON.pretty_generate(stats) if @options[:json]

      stats_table = table do |t|
        t.headings = 'Instance', 'CPU (Cores)', 'Memory (limit)', 'Disk (limit)', 'Uptime'
        stats.each do |entry|
          index = entry[:instance]
          stat = entry[:stats]
          hp = "#{stat[:host]}:#{stat[:port]}"
          uptime = uptime_string(stat[:uptime])
          usage = stat[:usage]
          if usage
            cpu   = usage[:cpu]
            mem   = (usage[:mem] * 1024) # mem comes in K's
            disk  = usage[:disk]
          end
          mem_quota = stat[:mem_quota]
          disk_quota = stat[:disk_quota]
          mem  = "#{pretty_size(mem)} (#{pretty_size(mem_quota, 0)})"
          disk = "#{pretty_size(disk)} (#{pretty_size(disk_quota, 0)})"
          cpu = cpu ? cpu.to_s : 'NA'
          cpu = "#{cpu}% (#{stat[:cores]})"
          t << [index, cpu, mem, disk, uptime]
        end
      end
      display "\n"
      if stats.empty?
        display "No runni
      if(grouppath)ng instances for [#{appname}]".yellow
      else
        display stats_table
      end
    end

    def update(appname, grouppath = nil)
      sequence = client.get_sequence(appname)
      path = @options[:grouppath] || '.'
      parseXML(path)
      if sequence
        sequence[:sequence].each { |em|
          app = client.app_info(em)
          if em == appname
            grouppath = @applications[em]['path']
            grouppath = File.expand_path(grouppath)
            check_deploy_directory(grouppath)
            display "Update application '#{em}'".green
            update_app(appname, grouppath)
          else
            stop_app em if app[:state] == 'STARTED'
            start_app em
          end
        }
      else
        grouppath = @applications[appname]['path']
        grouppath = File.expand_path(grouppath)
        check_deploy_directory(grouppath)
        display "Update application '#{appname}'".green
        update_app(appname, grouppath)
      end
    end
    
    def update_app(appname, grouppath = nil)
      app = client.app_info(appname)
      if @options[:canary]
        display "[--canary] is deprecated and will be removed in a future version".yellow
      end
      path = @options[:path] || '.'
      
      if(grouppath)
        path = grouppath
      end
      upload_app_bits(appname, path)
      display "app[:state]".green + app[:state]
      stop_app appname if app[:state] == 'STARTED'
      start_app appname
    end
    
    def groupupdate(groupname)
      display "Update application group '#{groupname}' :".green
      group = client.group_info(groupname)
      appsequence = group[:sequence]
      sequenceArray = appsequence.split(':')
      path = @options[:grouppath] || '.'
      
      parseXML(path)
      
      sequenceArray.each { |em|
        grouppath = @applications[em]['path']
        grouppath = File.expand_path(grouppath)
        check_deploy_directory(grouppath)
        display "Update application '#{em}'".green
        update_app(em, grouppath)
      }
      display "OK" 
    end
    
    #changed by zjz 2011/8/1
    #parse user's config XML
=begin
    def parseXML(appname, path)
      framework = nil
      file = path + "/" + appname + ".xml"
      exist = File.exist? (file)
      if(exist) then
        display "Parse user's xml"
        input = File.new(file)
        doc = Document.new(input)
        root = doc.root
        #Modified by shaoj
        #The value of @isService should be a bool, instead of string
        type = root.elements['app-type'].text
        if(type)
          framework = VMC::Cli::Framework.lookup(type)   
        end
        
        @isService = root.elements['isService'].text
        if @isService == "true" then
          @isService = true
        else
          @isService = false
        end
        args = Hash.new(nil)
        doc.elements.each('*/args/arg') { |em|
          key = em.attributes['key']
          args[key] = em.attributes['value']         
        }
        @args = args
        requirements = Array.new
        doc.elements.each('*/requirements/requirement'){ |em|
          requirement = Hash.new(nil)
          requirement['type'] = em.attributes['type']
          requirement['name'] = em.attributes['name']
          requirement['index'] = em.attributes['index']
          destinations = Array.new
          em.elements.each('destinations/destination'){ |dem|
            destination = Hash.new(nil)
            destination['type'] = dem.attributes['type']
            destination['path'] = dem.attributes['path']
            destination['xpath'] = dem.attributes['xpath']
            destinations << destination            
          }
          requirement['destinations'] = destinations            
          requirements << requirement          
        }
        @requirements = requirements
        cServcie = Array.new
        doc.elements.each('*/cService/arg') { |em| 
          cServcie << em.attributes['name']
        }
        @cService = cServcie
        
        if root.elements['app-type'] then
          @apptype = root.elements['app-type'].text
        else
          @apptype = nil
        end
      else
        display "User's xml not exist"
      end
      framework
    end
=end
    
    def parseXML(path)
      framework = nil
      file = nil
      if Dir.exist? (path)
        file = path + "/" + "cloudfoundry.xml"
      else
        file = path
      end
      exist = File.exist? (file) 
      if(exist) then
        display "Parse user's xml"
        input = File.new(file)
        doc = Document.new(input)
        root = doc.root
        @groupname = root.attributes['name']
        
        dependenRecord = Hash.new(nil)
        applications = Hash.new(nil)
        doc.elements.each('*/Application') { |app|
          appname = app.elements['Name'].text
          type = app.elements['Framework'].text
          instances = app.elements['Instances'].text.to_i
          apppath = app.elements['Path']
          if(apppath == nil)
            apppath = '.'
          else
            apppath = app.elements['Path'].text
          end
          if(type)
            framework = VMC::Cli::Framework.lookup(type)   
          end
          
          args = Hash.new(nil)
          if(app.elements['Arguments'] != nil)
            app.elements['Arguments'].each_element { |em|
              key = em.attributes['name']
              args[key] = em.attributes['value']         
            }
          end
            
          dependencies = Hash.new(nil)
          tempArray = Array.new
          if(app.elements['Dependencies'] != nil) 
            app.elements['Dependencies'].each_element { |em|
              name = em.attributes['name']
              tempArray << name
              cascade = em.attributes["cascade"]
              if(cascade == "true")
                dependencies[name] = true
              elsif(cascade == "false")
                dependencies[name] = false
              else
                dependencies[name] = false
              end
            }
          end
          dependenRecord[appname] = tempArray
          
          ports = Array.new
          i = 0
          if(app.elements['Ports'] != nil)
            app.elements['Ports'].each_element { |em|
              port = Hash.new(nil)          
              port['name'] = em.attributes['name']
              port['index'] = i
              if(em.attributes['primary']=="true")
                port['primary'] = true            
              else
                port['primary'] = false
              end           
              destination = Hash.new(nil)
              destination['type'] = em.elements['destination'].attributes['type']
              destination['path'] =  em.elements['destination'].attributes['path']
              destination['placeholder'] =  em.elements['destination'].attributes['placeholder']
              port['destination'] = destination          
              ports << port    
              i+=1      
            }  
          end
            
          main_class = Hash.new(nil)
          if app.elements['MainClass'] then
            main_class['lib_path'] =  app.elements['MainClass'].elements['LibPath'].text
            main_class['main'] =  app.elements['MainClass'].elements['Main'].text        
          else
            main_class = nil
          end
          
          application = Hash.new
          application['name'] = appname
          application['framework'] = framework
          application['instances'] = instances
          application['path'] = apppath
          application['dependencies'] = dependencies
          application['ports'] = ports
          application['args'] = args
          application['mainclass'] = main_class
          application['groupName'] = @groupname
          
          applications[appname] = application
          
        }
        
        cycleCheckHash = Hash.new(nil)
        isCircle = false
        dependenRecord.each { |key, value|
          cycleCheckHash[key] = 1
          if value
           isCircle = checkCircleDepend(cycleCheckHash, value, dependenRecord)
          end
          if isCircle == true
            err "Exist cycle dependent, please check your configuration file!"
          end
          cycleCheckHash.clear
        }
        
        sequence = Hash.new(nil)
        @appsequence = ""
        dependenRecord.each { |key, value|
          generateAppSequence(dependenRecord, key, sequence)
        }
        sequenceArray = @appsequence.split(':')
        
        #Sort, generate correct push sequence
        @applications = applications

      else
        err "Can not find out user's config file!"
      end
      
      framework
    end
    
    def checkCircleDepend(cycleCheckHash, nextnode, record)
      result = false
      tmpCycleHash = Hash.new(nil)
      cycleCheckHash.each { |key,value|
        tmpCycleHash[key] = value
      }
      if(nextnode == nil) 
        return false
      end
      nextnode.each { |em|
        if tmpCycleHash[em] == 1
          return true
        else
          tmpCycleHash[em] = 1
          result = checkCircleDepend(tmpCycleHash, record[em], record)
          if result == true
            return result
          end
        end
        tmpCycleHash.clear
        cycleCheckHash.each { |key,value|
          tmpCycleHash[key] = value
        }
      }
      return false
    end

    def generateAppSequence(record,key,sequence)
      value = record[key]
      if(value == nil)
        if(!sequence.has_key?(key))
          sequence[key] = nil 
          @appsequence += key
          @appsequence += ":"
        end
      else
        bExist = true
        value.each{ |em|
          if(!sequence.has_key?(em))
            bExist = false
          end
        }
        if(bExist) 
          if(!sequence.has_key?(key))
            sequence[key] = nil
            @appsequence += key
            @appsequence += ":" 
          end
        else
          value.each { |em|
            generateAppSequence(record,em,sequence)
          }
          if(!sequence.has_key?(key))
            sequence[key] = nil 
            @appsequence += key
            @appsequence += ":"
          end
        end
      end
    end
 
    def grouppush(bAdd=nil)
      
      if(!bAdd || bAdd==nil)
        path = @options[:filepath]
        if path == nil
          path = '.'
        end
      
        parseXML(path)

        display 'Creating Application Group:'.green
      else
        display "Adding applications to group #{@groupname}".green
      end

      manifest = {
        :groupname => @groupname,
        :appsequence => @appsequence,
      }
      
      client.create_group(@groupname, manifest)

      sequenceArray = @appsequence.split(':')
      if(bAdd) 
        sequenceArray = @addsequence.split(':')
      end
      
      sequenceArray.each { |saname|
        if(app_exists?(saname))
          display "Application '#{saname}' has already exist".green
          bcontinue = ask('Do you want to continue? [Yn]: ')
          if bcontinue.upcase == 'N'
            break
          else
            myapp = client.app_info(saname)
            err "Application '#{saname}' has not started, please run application '#{saname}' first." unless myapp[:state] != 'RUNNING'
            next
          end
        end

        app = @applications[saname]
        # display @applications
        dependencies = app['dependencies']
        dependencies.each_key { |key|
          checkCService(key)          
        }
        
         instances = app["instances"] || 1
         appname = app["name"]
         display "Deploy application #{appname} :".green
        # Check app existing upfront if we have appname
         app_checked = false
         if appname
           err "Application '#{appname}' already exists, use update" if app_exists?(appname)
           app_checked = true
         else
           raise VMC::Client::AuthError unless client.logged_in?
         end

         # check if we have hit our app limit
         check_app_limit

         path = app["path"]
         path = File.expand_path(path)
         check_deploy_directory(path)

         appname = ask("Application Name: ") unless no_prompt || appname
           err "Application Name required." if appname.nil? || appname.empty?

         unless app_checked
           err "Application '#{appname}' already exists, use update or delete." if app_exists?(appname)
         end    
      
        no_prompt = nil
        url = nil
        unless no_prompt || url
          url = ask("Application Deployed URL: '#{appname}.#{VMC::Cli::Config.suggest_url}'? ")
  
          # common error case is for prompted users to answer y or Y or yes or YES to this ask() resulting in an
          # unintended URL of y. Special case this common error
          if YES_SET.member?(url)
            #silently revert to the stock url
            url = "#{appname}.#{VMC::Cli::Config.suggest_url}"
          end
        end
  
        url = "#{appname}.#{VMC::Cli::Config.suggest_url}" if url.nil? || url.empty?

        # Detect the appropriate framework.
        ignore_framework = false
        framework = app["framework"]
        unless framework
          framework = VMC::Cli::Framework.detect(path)
          framework_correct = ask("Detected a #{framework}, is this correct? [Yn]: ") if prompt_ok && framework
          framework_correct ||= 'y'
          if prompt_ok && (framework.nil? || framework_correct.upcase == 'N')
            display "#{"[WARNING]".yellow} Can't determine the Application Type." unless framework
            framework = nil if framework_correct.upcase == 'N'
            choose do |menu|
              menu.layout = :one_line
              menu.prompt = "Select Application Type: "
              menu.default = framework
              VMC::Cli::Framework.known_frameworks.each do |f|
                menu.choice(f) { framework = VMC::Cli::Framework.lookup(f) }
              end
            end
            display "Selected #{framework}"
          end
          # Framework override, deprecated
          exec = framework.exec if framework && framework.exec
          else 
            unless framework
              framework = VMC::Cli::Framework.new
            end
        end

        err "Application Type undetermined for path '#{path}'" unless framework
        memswitch = nil
        unless memswitch
          mem = framework.memory
          if prompt_ok
            choose do |menu|
              menu.layout = :one_line
              menu.prompt = "Memory Reservation [Default:#{mem}] "
              menu.default = mem
              mem_choices.each { |choice| menu.choice(choice) {  mem = choice } }
            end
          end
        else
          mem = memswitch
        end

        # Set to MB number
        mem_quota = mem_choice_to_quota(mem)

        # check memsize here for capacity
        no_start = nil
        check_has_capacity_for(mem_quota * instances) unless no_start

        display 'Creating Application : ', false

        manifest = {
        :name => app["name"],
        :staging => {
           :framework => framework.name,
        },
        :uris => [url],
        :instances => app["instances"],
        :resources => {
          :memory => mem_quota
          
        },
        :dependencies => app["dependencies"],        
        :args => app["args"],
        :mainclass => app["mainclass"],
        :groupName => app["groupName"]
      }
      
      # Send the manifest to the cloud controller
      client.create_app(appname, manifest)
      display 'OK'.green

      # Services check
      unless no_prompt || @options[:noservices]
        services = client.services_info
        unless services.empty?
          proceed = ask("Would you like to bind any services to '#{appname}'? [yN]: ")
          bind_services(appname, services) if proceed.upcase == 'Y'
        end
      end

      # Stage and upload the app bits.
      upload_app_bits(appname, path)

      start_app(appname, true) unless no_start
        
=begin
        manifest = {
        :name => app[:name],
        :staging => {
           :framework => app[:framework],
           :runtime => @options[:runtime]
        },
        :uris => [url],
        :instances => instances,
        :resources => {
          :memory => mem_quota
          
        },
        :instances => app[:instances],
        :dependencies = app[:dependencies],
        :ports = app[:ports],
        :args = app[:args],
        :mainclass = app[:mainclass],
      }
=end      
      }
      
      gstatus = {
        :groupname => @groupname,
        :status => "1"
      }
      client.set_groupstatus(@groupname, gstatus)
        
    end
 
    def checkCService(appname)
      err "Application '#{appname}' don't exists, please upload application '#{appname}' first." if !app_exists?(appname)
      app = client.app_info(appname)
      err "Application '#{appname}' has not started, please run application '#{appname}' first." if app[:state] == 'STOPPED'
    end
    
    def addElementsToSequence()
      group = client.group_info(@groupname)
      oldsequence = group[:sequence]
      oldsequenceArray = oldsequence.split(':')

      addsequence = ""
      newsequenceArray = @appsequence.split(':')
      
      newsequenceArray.each { |em|
        if !oldsequenceArray.include?(em)
          addsequence += em
          addsequence += ":"
          maxIndex = nil
          dependencies = @applications[em]['dependencies']
          display dependencies
          dependencies.each_key { |key|
            if !maxIndex || maxIndex < oldsequenceArray.index(key)
              maxIndex = oldsequenceArray.index(key)
            end 
          }
          oldsequenceArray.insert(maxIndex+1, em)
        end
      }
      sequence = ""
      oldsequenceArray.each { |em|
        sequence += em
        sequence += ":"
      }
      @appsequence = sequence
      @addsequence = addsequence
    end
    
    def groupadd
      path = @options[:filepath]
      if path == nil
        path = '.'
      end
      
      parseXML(path)
      addElementsToSequence()
      grouppush(true)
    end
    
    def push(appname=nil)
      instances = @options[:instances] || 1
      exec = @options[:exec] || 'thin start'
      ignore_framework = @options[:noframework]
      no_start = @options[:nostart]

      path = @options[:path] || '.'
      appname = @options[:name] unless appname
      url = @options[:url]
      mem, memswitch = nil, @options[:mem]
      group = @options[:groupname]
      memswitch = normalize_mem(memswitch) if memswitch

      # Check app existing upfront if we have appname
      app_checked = false
      if appname
        err "Application '#{appname}' already exists, use update" if app_exists?(appname)
        app_checked = true
      else
        raise VMC::Client::AuthError unless client.logged_in?
      end

      # check if we have hit our app limit
      check_app_limit

      # check memsize here for capacity
      if memswitch && !no_start
        check_has_capacity_for(mem_choice_to_quota(memswitch) * instances)
      end

      unless no_prompt || @options[:path]
        proceed = ask('Would you like to deploy from the current directory? [Yn]: ')
        if proceed.upcase == 'N'
          path = ask('Please enter in the deployment path: ')
        end
      end

      path = File.expand_path(path)
      check_deploy_directory(path)
      
      framework = parseXML(path);
      addElementsToSequence()
      
      
      appname = ask("Application Name: ") unless no_prompt || appname
      err "Application Name required." if appname.nil? || appname.empty?

      if(!@applications.include?(appname))
        err "Can not find out #{appname}\'s configuration file"
      end

      unless app_checked
        err "Application '#{appname}' already exists, use update or delete." if app_exists?(appname)
      end   
      
      unless no_prompt || url
        url = ask("Application Deployed URL: '#{appname}.#{VMC::Cli::Config.suggest_url}'? ")

        # common error case is for prompted users to answer y or Y or yes or YES to this ask() resulting in an
        # unintended URL of y. Special case this common error
        if YES_SET.member?(url)
          #silently revert to the stock url
          url = "#{appname}.#{VMC::Cli::Config.suggest_url}"
        end
      end

      url = "#{appname}.#{VMC::Cli::Config.suggest_url}" if url.nil? || url.empty?

      # Detect the appropriate framework.
      
      unless ignore_framework || framework
        framework = VMC::Cli::Framework.detect(path)
        framework_correct = ask("Detected a #{framework}, is this correct? [Yn]: ") if prompt_ok && framework
        framework_correct ||= 'y'
        if prompt_ok && (framework.nil? || framework_correct.upcase == 'N')
          display "#{"[WARNING]".yellow} Can't determine the Application Type." unless framework
          framework = nil if framework_correct.upcase == 'N'
          choose do |menu|
            menu.layout = :one_line
            menu.prompt = "Select Application Type: "
            menu.default = framework
            VMC::Cli::Framework.known_frameworks.each do |f|
              menu.choice(f) { framework = VMC::Cli::Framework.lookup(f) }
            end
          end
          display "Selected #{framework}"
        end
        # Framework override, deprecated
        exec = framework.exec if framework && framework.exec
      else 
        unless framework
          framework = VMC::Cli::Framework.new
        end
      end

      err "Application Type undetermined for path '#{path}'" unless framework
      unless memswitch
        mem = framework.memory
        if prompt_ok
          choose do |menu|
            menu.layout = :one_line
            menu.prompt = "Memory Reservation [Default:#{mem}] "
            menu.default = mem
            mem_choices.each { |choice| menu.choice(choice) {  mem = choice } }
          end
        end
      else
        mem = memswitch
      end

      # Set to MB number
      mem_quota = mem_choice_to_quota(mem)

      # check memsize here for capacity
      check_has_capacity_for(mem_quota * instances) unless no_start

      display 'Creating Application: ', false
      
      
      manifest = {
        :groupname => @groupname,
        :appsequence => @appsequence,
      }
      
      client.create_group(@groupname, manifest)
      
      manifest = {
        :name => "#{appname}",
        :staging => {
           :framework => framework.name,
           :runtime => @options[:runtime]
        },
        :uris => [url],
        :instances => instances,
        :resources => {
          :memory => mem_quota
          
        },
        :groupName => group,
        :dependencies => @applications[appname]["dependencies"],        
        :args => @applications[appname]["args"],
        :mainclass => @applications[appname]["mainclass"]
        #:isService => @isService,
        #:cService => @cService,
        #:args => @args,
        #:apptype => @apptype,
        #:main_class => @main_class,
        #:ports => @ports
      }
      
      
      # Send the manifest to the cloud controller
      client.create_app(appname, manifest)
      display 'OK'.green

      # Services check
      unless no_prompt || @options[:noservices]
        services = client.services_info
        unless services.empty?
          proceed = ask("Would you like to bind any services to '#{appname}'? [yN]: ")
          bind_services(appname, services) if proceed.upcase == 'Y'
        end
      end

      # Stage and upload the app bits.
      upload_app_bits(appname, path)

      start_app(appname, true) unless no_start
    end

    def environment(appname)
      app = client.app_info(appname)
      env = app[:env] || []
      return display JSON.pretty_generate(env) if @options[:json]
      return display "No Environment Variables" if env.empty?
      etable = table do |t|
        t.headings = 'Variable', 'Value'
        env.each do |e|
          k,v = e.split('=', 2)
          t << [k, v]
        end
      end
      display "\n"
      display etable
    end

    def environment_add(appname, k, v=nil)
      app = client.app_info(appname)
      env = app[:env] || []
      k,v = k.split('=', 2) unless v
      env << "#{k}=#{v}"
      display "Adding Environment Variable [#{k}=#{v}]: ", false
      app[:env] = env
      client.update_app(appname, app)
      display 'OK'.green
      restart appname if app[:state] == 'STARTED'
    end

    def environment_del(appname, variable)
      app = client.app_info(appname)
      env = app[:env] || []
      deleted_env = nil
      env.each do |e|
        k,v = e.split('=')
        if (k == variable)
          deleted_env = e
          break;
        end
      end
      display "Deleting Environment Variable [#{variable}]: ", false
      if deleted_env
        env.delete(deleted_env)
        app[:env] = env
        client.update_app(appname, app)
        display 'OK'.green
        restart appname if app[:state] == 'STARTED'
      else
        display 'OK'.green
      end
    end

    private

    def app_exists?(appname)
      app_info = client.app_info(appname)
      app_info != nil
    rescue VMC::Client::NotFound
      false
    end

    def check_deploy_directory(path)
      err 'Deployment path does not exist' unless File.exists? path
      err 'Deployment path is not a directory' unless File.directory? path
      return if File.expand_path(Dir.tmpdir) != File.expand_path(path)
      err "Can't deploy applications from staging directory: [#{Dir.tmpdir}]"
    end

    def upload_app_bits(appname, path)
      display 'Uploading Application:'

      upload_file, file = "#{Dir.tmpdir}/#{appname}.zip", nil
      FileUtils.rm_f(upload_file)

      explode_dir = "#{Dir.tmpdir}/.vmc_#{appname}_files"
      FileUtils.rm_rf(explode_dir) # Make sure we didn't have anything left over..

      Dir.chdir(path) do
        # Stage the app appropriately and do the appropriate fingerprinting, etc.
        if war_file = Dir.glob(appname + '.war').first
          VMC::Cli::ZipUtil.unpack(war_file, explode_dir)
        #XXX Added jar support
        elsif jar_file = Dir.glob(appname + '.jar').first
          FileUtils.mkdir(explode_dir)
          FileUtils.cp_r(jar_file, explode_dir)
        elsif dir = Dir.glob(appname).first
          FileUtils.mkdir(explode_dir)          
          files = Dir.glob(dir + '/{*,.[^\.]*}')
          files.delete('.git') if files
          FileUtils.cp_r(files, explode_dir)
        else
          FileUtils.mkdir(explode_dir)
          files = Dir.glob('{*,.[^\.]*}')
          # Do not process .git files
          files.delete('.git') if files
          FileUtils.cp_r(files, explode_dir)
        end

        # Send the resource list to the cloudcontroller, the response will tell us what it already has..
        unless @options[:noresources]
          display '  Checking for available resources: ', false
          fingerprints = []
          total_size = 0
          resource_files = Dir.glob("#{explode_dir}/**/*", File::FNM_DOTMATCH)
          resource_files.each do |filename|
            next if (File.directory?(filename) || !File.exists?(filename))
            fingerprints << {
              :size => File.size(filename),
              :sha1 => Digest::SHA1.file(filename).hexdigest,
              :fn => filename
            }
            total_size += File.size(filename)
          end

          # Check to see if the resource check is worth the round trip
          if (total_size > (64*1024)) # 64k for now
            # Send resource fingerprints to the cloud controller
            appcloud_resources = client.check_resources(fingerprints)
          end
          display 'OK'.green

          if appcloud_resources
            display '  Processing resources: ', false
            # We can then delete what we do not need to send.
            appcloud_resources.each do |resource|
              FileUtils.rm_f resource[:fn]
              # adjust filenames sans the explode_dir prefix
              resource[:fn].sub!("#{explode_dir}/", '')
            end
            display 'OK'.green
          end

        end

        # Perform Packing of the upload bits here.
        unless VMC::Cli::ZipUtil.get_files_to_pack(explode_dir).empty?
          display '  Packing application: ', false
          VMC::Cli::ZipUtil.pack(explode_dir, upload_file)
          display 'OK'.green

          upload_size = File.size(upload_file);
          if upload_size > 1024*1024
            upload_size  = (upload_size/(1024.0*1024.0)).round.to_s + 'M'
          elsif upload_size > 0
            upload_size  = (upload_size/1024.0).round.to_s + 'K'
          end
        else
          upload_size = '0K'
        end

        upload_str = "  Uploading (#{upload_size}): "
        display upload_str, false

        unless VMC::Cli::ZipUtil.get_files_to_pack(explode_dir).empty?
          FileWithPercentOutput.display_str = upload_str
          FileWithPercentOutput.upload_size = File.size(upload_file);
          file = FileWithPercentOutput.open(upload_file, 'rb')
        end

        client.upload_app(appname, file, appcloud_resources)
        display 'OK'.green if VMC::Cli::ZipUtil.get_files_to_pack(explode_dir).empty?

        display 'Push Status: ', false
        display 'OK'.green
      end

    ensure
      # Cleanup if we created an exploded directory.
      FileUtils.rm_f(upload_file) if upload_file
      FileUtils.rm_rf(explode_dir) if explode_dir
    end

    def choose_existing_service(appname, user_services)
      return unless prompt_ok
      selected = false
      choose do |menu|
        menu.header = "The following provisioned services are available"
        menu.prompt = 'Please select one you wish to provision: '
        menu.select_by = :index_or_name
        user_services.each do |s|
          menu.choice(s[:name]) do
            display "Binding Service: ", false
            client.bind_service(s[:name], appname)
            display 'OK'.green
            selected = true
          end
        end
      end
      selected
    end

    def choose_new_service(appname, services)
      return unless prompt_ok
      choose do |menu|
        menu.header = "The following system services are available"
        menu.prompt = 'Please select one you wish to provision: '
        menu.select_by = :index_or_name
        service_choices = []
        services.each do |service_type, value|
          value.each do |vendor, version|
            service_choices << vendor
          end
        end
        service_choices.sort! {|a, b| a.to_s <=> b.to_s }
        service_choices.each do |vendor|
          menu.choice(vendor) do
            default_name = random_service_name(vendor)
            service_name = ask("Specify the name of the service [#{default_name}]: ")
            service_name = default_name if service_name.empty?
            create_service_banner(vendor, service_name)
            bind_service_banner(service_name, appname)
          end
        end
      end
    end

    def bind_services(appname, services)
      user_services = client.services
      selected_existing = false
      unless no_prompt || user_services.empty?
        use_existing = ask "Would you like to use an existing provisioned service [yN]? "
        if use_existing.upcase == 'Y'
          selected_existing = choose_existing_service(appname, user_services)
        end
      end
      # Create a new service and bind it here
      unless selected_existing
        choose_new_service(appname, services)
      end
    end

    def check_app_limit
      usage = client_info[:usage]
      limits = client_info[:limits]
      return unless usage and limits and limits[:apps]
      if limits[:apps] == usage[:apps]
        display "Not enough capacity for operation.".red
        tapps = limits[:apps] || 0
        apps  = usage[:apps] || 0
        err "Current Usage: (#{apps} of #{tapps} total apps already in use)"
      end
    end

    def check_has_capacity_for(mem_wanted)
      usage = client_info[:usage]
      limits = client_info[:limits]
      return unless usage and limits
      available_for_use = limits[:memory].to_i - usage[:memory].to_i
      if mem_wanted > available_for_use
        tmem = pretty_size(limits[:memory]*1024*1024)
        mem  = pretty_size(usage[:memory]*1024*1024)
        display "Not enough capacity for operation.".yellow
        available = pretty_size(available_for_use * 1024 * 1024)
        err "Current Usage: (#{mem} of #{tmem} total, #{available} available for use)"
      end
    end

    def mem_choices
      default = ['64M', '128M', '256M', '512M', '1G', '2G']

      return default unless client_info
      return default unless (usage = client_info[:usage] and limits = client_info[:limits])

      available_for_use = limits[:memory].to_i - usage[:memory].to_i
      check_has_capacity_for(64) if available_for_use < 64
      return ['64M'] if available_for_use < 128
      return ['64M', '128M'] if available_for_use < 256
      return ['64M', '128M', '256M'] if available_for_use < 512
      return ['64M', '128M', '256M', '512M'] if available_for_use < 1024
      return ['64M', '128M', '256M', '512M', '1G'] if available_for_use < 2048
      return ['64M', '128M', '256M', '512M', '1G', '2G']
    end

    def normalize_mem(mem)
      return mem if /K|G|M/i =~ mem
      "#{mem}M"
    end

    def mem_choice_to_quota(mem_choice)
      (mem_choice =~ /(\d+)M/i) ? mem_quota = $1.to_i : mem_quota = mem_choice.to_i * 1024
      mem_quota
    end

    def mem_quota_to_choice(mem)
      if mem < 1024
        mem_choice = "#{mem}M"
      else
        mem_choice = "#{(mem/1024).to_i}G"
      end
      mem_choice
    end

    def get_instances(appname)
      instances_info_envelope = client.app_instances(appname)
      # Empty array is returned if there are no instances running.
      instances_info_envelope = {} if instances_info_envelope.is_a?(Array)

      instances_info = instances_info_envelope[:instances] || []
      instances_info = instances_info.sort {|a,b| a[:index] - b[:index]}

      return display JSON.pretty_generate(instances_info) if @options[:json]

      return display "No running instances for [#{appname}]".yellow if instances_info.empty?

      instances_table = table do |t|
        t.headings = 'Index', 'State', 'Start Time'
        instances_info.each do |entry|
          t << [entry[:index], entry[:state], Time.at(entry[:since]).strftime("%m/%d/%Y %I:%M%p")]
        end
      end
      display "\n"
      display instances_table
    end

    def change_instances(appname, instances)
      app = client.app_info(appname)

      match = instances.match(/([+-])?\d+/)
      err "Invalid number of instances '#{instances}'" unless match

      instances = instances.to_i
      current_instances = app[:instances]
      new_instances = match.captures[0] ? current_instances + instances : instances
      err "There must be at least 1 instance." if new_instances < 1

      if current_instances == new_instances
        display "Application [#{appname}] is already running #{new_instances} instance#{'s' if new_instances > 1}.".yellow
        return
      end

      up_or_down = new_instances > current_instances ? 'up' : 'down'
      display "Scaling Application instances #{up_or_down} to #{new_instances}: ", false
      app[:instances] = new_instances
      client.update_app(appname, app)
      display 'OK'.green
    end

    def health(d)
      return 'N/A' unless (d and d[:state])
      return 'STOPPED' if d[:state] == 'STOPPED'

      healthy_instances = d[:runningInstances]
      expected_instance = d[:instances]
      health = nil

      if d[:state] == "STARTED" && expected_instance > 0 && healthy_instances
        health = format("%.3f", healthy_instances.to_f / expected_instance).to_f
      end

      return 'RUNNING' if health && health == 1.0
      return "#{(health * 100).round}%" if health
      return 'N/A'
    end

    def app_started_properly(appname, error_on_health)
      app = client.app_info(appname)
      case health(app)
        when 'N/A'
          # Health manager not running.
          err "\Application '#{appname}'s state is undetermined, not enough information available." if error_on_health
          return false
        when 'RUNNING'
          return true
        else
          return false
      end
    end

    def display_logfile(path, content, instance='0', banner=nil)
      banner ||= "====> #{path} <====\n\n"
      if content && !content.empty?
        display banner
        prefix = "[#{instance}: #{path}] -".bold if @options[:prefixlogs]
        unless prefix
          display content
        else
          lines = content.split("\n")
          lines.each { |line| display "#{prefix} #{line}"}
        end
        display ''
      end
    end

    def log_file_paths
      %w[logs/stderr.log logs/stdout.log logs/startup.log]
    end

    def grab_all_logs(appname)
      instances_info_envelope = client.app_instances(appname)
      return if instances_info_envelope.is_a?(Array)
      instances_info = instances_info_envelope[:instances] || []
      instances_info.each do |entry|
        grab_logs(appname, entry[:index])
      end
    end

    def grab_logs(appname, instance)
      log_file_paths.each do |path|
        begin
          content = client.app_files(appname, path, instance)
        rescue
        end
        display_logfile(path, content, instance)
      end
    end

    def grab_crash_logs(appname, instance, was_staged=false)
      # stage crash info
      crashes(appname, false) unless was_staged

      instance ||= '0'
      map = VMC::Cli::Config.instances
      instance = map[instance] if map[instance]

      ['/logs/err.log', '/logs/staging.log', 'logs/stderr.log', 'logs/stdout.log', 'logs/startup.log'].each do |path|
        begin
          content = client.app_files(appname, path, instance)
        rescue
        end
        display_logfile(path, content, instance)
      end
    end

    def grab_startup_tail(appname, since = 0)
      new_lines = 0
      path = "logs/startup.log"
      content = client.app_files(appname, path)
      if content && !content.empty?
        display "\n==== displaying startup log ====\n\n" if since == 0
        response_lines = content.split("\n")
        lines = response_lines.size
        tail = response_lines[since, lines] || []
        new_lines = tail.size
        display tail.join("\n") if new_lines > 0
      end
      since + new_lines
    end
    rescue
  end

  class FileWithPercentOutput < ::File
    class << self
      attr_accessor :display_str, :upload_size
    end

    def update_display(rsize)
      @read ||= 0
      @read += rsize
      p = (@read * 100 / FileWithPercentOutput.upload_size).to_i
      unless VMC::Cli::Config.output.nil? || !STDOUT.tty?
        clear(FileWithPercentOutput.display_str.size + 5)
        VMC::Cli::Config.output.print("#{FileWithPercentOutput.display_str} #{p}%")
        VMC::Cli::Config.output.flush
      end
    end

    def read(*args)
      result  = super(*args)
      if result && result.size > 0
        update_display(result.size)
      else
        unless VMC::Cli::Config.output.nil? || !STDOUT.tty?
          clear(FileWithPercentOutput.display_str.size + 5)
          VMC::Cli::Config.output.print(FileWithPercentOutput.display_str)
          display('OK'.green)
        end
      end
      result
    end
  end

end
