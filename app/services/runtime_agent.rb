module RuntimeAgent
  LABEL_PLATFORM = "hobby.platform".freeze
  LABEL_APP_ID = "hobby.app_id".freeze
  LABEL_DEPLOYMENT_ID = "hobby.deployment_id".freeze
  LABEL_RUNTIME_INSTANCE_ID = "hobby.runtime_instance_id".freeze

  Error = Data.define(:code, :message, :command, :exit_status, :stderr, :details) do
    def to_h
      {
        code: code,
        message: message,
        command: command,
        exit_status: exit_status,
        stderr: stderr,
        details: details || {}
      }.compact
    end
  end

  class Failure < StandardError
    attr_reader :error

    def initialize(error)
      @error = error
      super(error.message)
    end
  end

  Result = Data.define(:success, :payload, :error) do
    alias success? success

    def self.success(payload = {})
      new(true, payload, nil)
    end

    def self.failure(error)
      new(false, {}, error)
    end
  end

  def self.build
    LocalDockerAgent.new
  end
end
