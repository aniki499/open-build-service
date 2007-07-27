require "rexml/document"

class SourceController < ApplicationController
  validate_action :index => :directory, :packagelist => :directory, :filelist => :directory
  validate_action :project_meta => :project, :package_meta => :package
  

  def index
    projectlist
  end

  def projectlist
    #forward_data "/source"
    @dir = Project.find :all
    render :text => @dir.dump_xml, :content_type => "text/xml"
  end

  def index_project
    project_name = params[:project]
    pro = DbProject.find_by_name project_name
    if pro.nil?
      render_error :status => 404, :errorcode => 'unknown_project',
        :message => "Unknown project #{project_name}"
      return
    end
    
    if request.get?
      @dir = Package.find :all, :project => project_name
      render :text => @dir.dump_xml, :content_type => "text/xml"
      return
    elsif request.delete?

      #allowed = permissions.project_change? project_name
      allowed = user.has_role? "Admin"
      if not allowed
        logger.debug "No permission to delete project #{project_name}"
        render_error :status => 403, :errorcode => 'delete_project_no_permission',
          :message => "Permission denied (delete project #{project_name})"
        return
      end

      #check for linking repos
      lreps = Array.new
      pro.repositories.each do |repo|
        repo.linking_repositories.each do |lrep|
          lreps << lrep
        end
      end

      if lreps.length > 0
        lrepstr = lreps.map{|l| l.db_project.name+'/'+l.name}.join "\n"

        render_error :status => 400, :errorcode => "repo_dependency",
          :message => "Unable to delete project #{project_name}; following repositories depend on this project:\n#{lrepstr}\n"
        return
      end

      #destroy all packages
      pro.db_packages.each do |pack|
        DbPackage.transaction(pack) do
          logger.info "destroying package #{pack.name}"
          pack.destroy
          logger.debug "delete request to backend: /source/#{pro.name}/#{pack.name}"
          Suse::Backend.delete "/source/#{pro.name}/#{pack.name}"
        end
      end

      DbProject.transaction(pro) do
        logger.info "destroying project #{pro.name}"
        pro.destroy
        logger.debug "delete request to backend: /source/#{pro.name}"
        #Suse::Backend.delete "/source/#{pro.name}"
        #FIXME: insert deletion request to backend
      end

      render_ok
      return
    else
      render_error :status => 400, :errorcode => "illegal_request",
        :message => "illegal POST request to #{request.request_uri}"
    end
  end

  def index_package
    project_name = params[:project]
    package_name = params[:package]
    rev = params[:rev]
    user = params[:user]
    comment = params[:comment]

    path = "/source/#{project_name}/#{package_name}"
    query = Array.new
    query_string = ""

    #get doesn't need to check for permission, so it's handled extra
    if request.get?
      query_string = URI.escape("rev=#{rev}") if rev
      path += "?#{query_string}" unless query_string.empty?

      forward_data path
      return
    end

    user_has_permission = permissions.package_change?( package_name, project_name )

    if request.delete?
      if not user_has_permission
        render_error :status => 403, :errorcode => "delete_package_no_permission",
          :message => "no permission to delete package"
        return
      end
      
      pack = DbPackage.find_by_project_and_name( project_name, package_name )
      if pack
        DbPackage.transaction(pack) do
          pack.destroy
          Suse::Backend.delete "/source/#{project_name}/#{package_name}"
        end
        render_ok
      else
        render_error :status => 404, :errorcode => "unknown_package",
          :message => "unknown package '#{package_name}' in project '#{project_name}'"
      end
    elsif request.post?
      cmd = params[:cmd]
      
      if not user_has_permission
        render_error :status => 403, :errorcode => "cmd_execution_no_permission",
          :message => "no permission to execute command '#{cmd}'"
        return
      end

      dispatch_command
    end
  end

  def pattern
    valid_http_methods :get, :put, :delete
    if request.get?
      pass_to_source
    else
      # PUT and DELETE
      permerrormsg = nil
      if request.put?
        permerrormsg = "no permission to store pattern"
      elsif request.delete?
        permerrormsg = "no permission to delete pattern"
      end

      @project = DbProject.find_by_name params[:project]
      unless @project
        render_error :message => "Unknown project '#{project_name}'",
          :status => 404, :errorcode => "unknown_project"
        return
      end

      unless @http_user.can_modify_project? @project
        logger.debug "user #{user.login} has no permission to modify project #{@project}"
        render_error :status => 403, :errorcode => "change_project_no_permission", 
          :message => permerrormsg
        return
      end
      
      path = request.path
      unless request.query_string.empty?
        path += "?" + request.query_string
      end

      forward_data path, :method => request.method
    end
  end

  def index_pattern
    valid_http_methods :get
    pass_to_source
  end

  def project_meta
    project_name = params[:project]
    if project_name.nil?
      render_error :status => 400, :errorcode => 'missing_parameter',
        :message => "parameter 'project' is missing"
      return
    end

    unless valid_project_name? project_name
      render_error :status => 400, :errorcode => "invalid_project_name",
        :message => "invalid project name '#{project_name}'"
      return
    end

    if request.get?
      @project = DbProject.find_by_name( project_name )
      unless @project
        render_error :message => "Unknown project '#{project_name}'",
          :status => 404, :errorcode => "unknown_project"
        return
      end
      render :text => @project.to_axml, :content_type => 'text/xml'
      return
    elsif request.put?
      # Need permission
      logger.debug "Checking permission for the put"
      allowed = false
      request_data = request.raw_post

      @project = DbProject.find_by_name( project_name )
      if @project
        #project exists, change it
        unless @http_user.can_modify_project? @project
          logger.debug "user #{user.login} has no permission to modify project #{@project}"
	  render_error :status => 403, :errorcode => "change_project_no_permission", 
            :message => "no permission to change project"
          return
        end
      else
        #project is new
        unless @http_user.can_create_project? project_name
	  logger.debug "Not allowed to create new project"
          render_error :status => 403, :errorcode => 'create_project_no_permission',
            :message => "not allowed to create new project '#{project_name}'"
          return
        end
      end
      
      p = Project.new(request_data, :name => project_name)

      if p.name != project_name
        render_error :status => 400, :errorcode => 'project_name_mismatch',
          :message => "project name in xml data does not match resource path component"
        return
      end

      p.add_person(:userid => @http_user.login) unless @project
      p.save

      render_ok
    else
      render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: POST #{request.path}"
    end
  end

  def project_config
    valid_http_methods :get, :put

    #check if project exists
    unless (@project = DbProject.find_by_name(params[:project]))
      render_error :status => 404, :errorcode => 'project_not_found',
        :message => "Unknown project #{params[:project]}"
      return
    end

    #assemble path for backend
    path = request.path
    unless request.query_string.empty?
      path += "?" + request.query_string
    end

    if request.get?
      forward_data path
    elsif request.put?
      #check for permissions
      unless @http_user.can_modify_project?(@project)
        render_error :status => 403, :errorcode => 'put_project_config_no_permission',
          :message => "No permission to write build configuration for project '#{params[:project]}'"
        return
      end

      forward_data path, :method => :put
      return
    end
  end

  def package_meta
    #TODO: needs cleanup/split to smaller methods
   
    project_name = params[:project]
    package_name = params[:package]

    if project_name.nil?
      render_error :status => 400, :errorcode => "parameter_missing",
        :message => "parameter 'project' missing"
      return
    end

    if package_name.nil?
      render_error :status => 400, :errorcode => "parameter_missing",
        :message => "parameter 'package' missing"
      return
    end

    if request.get?
      @package = Package.find( package_name, :project => project_name )
      render :text => @package.dump_xml, :content_type => 'text/xml'
    elsif request.put?
      allowed = false
      request_data = request.raw_post
      begin
        # Try to fetch the package to see if it already exists
        @package = Package.find( package_name, :project => project_name )
	
        # Being here means that the project already exists
        allowed = permissions.package_change? @package
        if allowed
          @package = Package.new( request_data, :project => project_name, :name => package_name )
        else
          logger.debug "user #{user.login} has no permission to change package #{@package}"
	  render_error :status => 403, :errorcode => "change_package_no_permission",
            :message => "no permission to change package"
          return
        end
      rescue ActiveXML::Transport::NotFoundError
        # Ok, the project is new
	allowed = permissions.package_create?( project_name )
	
        if allowed
          #FIXME: parameters that get substituted into the url must be specified here... should happen
          #somehow automagically... no idea how this might work
          @package = Package.new( request_data, :project => project_name, :name => package_name )
        
          # add package creator as maintainer if he is not added already
          if not @package.has_element?( "person[@userid='#{user.login}']" )
            @package.add_person( :userid => user.login )
          end
        else
          # User is not allowed by global permission.
          logger.debug "Not allowed to create new packages"
          render_error :status => 403, :errorcode => "create_package_no_permission",
            :message => "no permission to create package for project #{project_name}"
          return
        end
      end
      
      if allowed
        if( @package.name != package_name )
          render_error :status => 400, :errorcode => 'package_name_mismatch',
            :message => "package name in xml data does not match resource path component"
          return
        end

        @package.save
        render_ok
      else
        logger.debug "user #{user.login} has no permission to write package meta for package #@package"
      end
    else
      # neither put nor get
      #TODO: return correct error code
      render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: POST #{request.path}"
    end
  end

  def file
    project_name = params[ :project ]
    package_name = params[ :package ]
    file = params[ :file ]
    rev = params[:rev]
    user = params[:user]
    comment = params[:comment]

    
    path = "/source/#{project_name}/#{package_name}/#{file}"
    query = Array.new
    query_string = ""

    if request.get?
      query_string = URI.escape("rev=#{rev}") if rev
      path += "?#{query_string}" unless query_string.empty?

      forward_data path
    elsif request.put?
      query << URI.escape("rev=#{rev}") if rev
      query << URI.escape("user=#{user}") if user
      query << URI.escape("comment=#{comment}") if comment
      query_string = query.join('&')
      path += "?#{query_string}" unless query_string.empty?
      
      allowed = permissions.package_change? package_name, project_name
      if  allowed
        Suse::Backend.put_source path, request.raw_post
        package = Package.find( package_name, :project => project_name )
        package.update_timestamp
        logger.info "wrote #{request.raw_post.size} bytes to #{path}"
        render_ok
      else
        render_error :status => 403, :errorcode => 'put_file_no_permission',
          :message => "Permission denied on package write file"
      end
    elsif request.delete?
      query << URI.escape("rev=#{rev}") if rev
      query << URI.escape("user=#{user}") if user
      query << URI.escape("comment=#{comment}") if comment
      query_string = query.join('&')
      path += "?#{query_string}" unless query_string.empty?
      
      Suse::Backend.delete path
      package = Package.find( package_name, :project => project_name )
      package.update_timestamp
      render_ok
    end
  end

  private

  # POST /source/<project>/<package>?cmd=createSpecFileTemplate
  def index_package_createSpecFileTemplate
    specfile_path = "#{request.path}/#{params[:package]}.spec"
    begin
      backend_get( specfile_path )
      render_error :status => 400, :errorcode => "spec_file_exists",
        :message => "SPEC file already exists."
      return
    rescue ActiveXML::Transport::NotFoundError
      specfile = File.read "#{RAILS_ROOT}/files/specfiletemplate"
      backend_put( specfile_path, specfile )
    end
    render_ok
  end

  # POST /source/<project>/<package>?cmd=rebuild
  def index_package_rebuild
    project_name = params[:project]
    package_name = params[:package]
    repo_name = params[:repo]
    arch_name = params[:arch]

    path = "/build/#{project_name}?cmd=rebuild&package=#{package_name}"
    
    p = DbProject.find_by_name project_name
    if p.nil?
      render_error :status => 400, :errorcode => 'unknown_project',
        :message => "Unknown project '#{project_name}'"
      return
    end

    if p.db_packages.find_by_name(package_name).nil?
      render_error :status => 400, :errorcode => 'unknown_package',
        :message => "Unknown package '#{package_name}'"
      return
    end

    if repo_name
      path += "&repository=#{repo_name}"
      if p.repositories.find_by_name(repo_name).nil?
        render_error :status => 400, :errorcode => 'unknown_repository',
          :message=> "Unknown repository '#{repo_name}'"
        return
      end
    end

    if arch_name
      path += "&arch=#{arch_name}"
    end

    backend.direct_http( URI(path), :method => "POST", :data => "" )
    render_ok
  end

  # POST /source/<project>/<package>?cmd=commit
  def index_package_commit
    path = request.path + "?" + request.query_string
    forward_data path, :method => :post
  end

  # POST /source/<project>/<package>?cmd=diff
  def index_package_diff
    path = request.path + "?" + request.query_string
    forward_data path, :method => :post
  end

  def valid_project_name? name
    name =~ /^\w[-_+\w\.:]+$/
  end

  def valid_package_name? name
    name =~ /^\w[-_+\w\.]+$/
  end

end
