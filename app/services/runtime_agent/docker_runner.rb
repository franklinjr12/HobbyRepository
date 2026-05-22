require "open3"

module RuntimeAgent
  class DockerRunner
    CommandResult = Data.define(:stdout, :stderr, :exit_status) do
      def success?
        exit_status.zero?
      end
    end

    def call(command)
      stdout, stderr, status = Open3.capture3(*command)
      CommandResult.new(stdout, stderr, status.exitstatus)
    rescue Errno::ENOENT => error
      CommandResult.new("", error.message, 127)
    end
  end
end
