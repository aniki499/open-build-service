class Workflow::Step::RebuildPackage < ::Workflow::Step
  include Triggerable

  REQUIRED_KEYS = [:project, :package].freeze

  attr_reader :project_name, :package_name

  validate :validate_project_and_package_name

  def call(_options = {})
    return unless valid?

    # Call Triggerable method to set all the elements needed for rebuilding
    set_project_name
    set_package_name
    set_project
    set_package
    set_object_to_authorize
    set_multibuild_flavor

    Pundit.authorize(@token.user, @token, :rebuild?)
    rebuild_package
  end

  def set_project_name
    @project_name = step_instructions[:project]
  end

  def set_package_name
    @package_name = step_instructions[:package]
  end

  private

  def rebuild_package
    Backend::Api::Sources::Package.rebuild(project_name, package_name)
  end

  def validate_project_and_package_name
    errors.add(:base, "invalid project '#{step_instructions[:project]}'") if step_instructions[:project] && !Project.valid_name?(step_instructions[:project])
    errors.add(:base, "invalid package '#{step_instructions[:package]}'") if step_instructions[:package] && !Package.valid_name?(step_instructions[:package])
  end
end
